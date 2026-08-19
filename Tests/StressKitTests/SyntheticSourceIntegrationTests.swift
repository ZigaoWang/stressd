import Foundation
import Testing

@testable import StressKit

/// Whether the load-generating tests should run.
enum IntegrationTests {
  /// These put the machine under real load for tens of seconds and assert on
  /// observed utilization, so they are meaningless on a busy or virtualised
  /// runner. Enabled by default because the duty cycler is the thing most worth
  /// checking locally; CI sets the variable to skip them.
  static var isEnabled: Bool {
    guard TestHost.isAppleSilicon else { return false }
    return ProcessInfo.processInfo.environment["STRESSD_SKIP_INTEGRATION_TESTS"] == nil
  }
}

@Suite(
  "Synthetic source under load",
  .enabled(if: IntegrationTests.isEnabled),
  .serialized)
struct SyntheticSourceIntegrationTests {

  private func liveTopology() throws -> CoreTopology {
    try CoreTopologyDetector().detect()
  }

  /// Runs the source at `target` and returns observed system-wide utilization
  /// and the duty cycle the workers measured for themselves.
  private func measure(
    target: Double,
    seconds: Double,
    placement: CorePlacement = .allCores
  ) async throws -> (observed: Double, workerMeasured: Double?) {
    let topology = try liveTopology()
    let source = SyntheticSource(topology: topology)
    defer { source.emergencyStop() }

    try await source.start(budget: ResourceBudget(cpu: target, placement: placement))

    // Let frequency scaling and the iteration rate estimator settle before
    // measuring. A cold first second is not representative of a sustained run.
    try await Task.sleep(for: .seconds(2))

    let sampler = try CPUUtilizationSampler(topology: topology)
    try await Task.sleep(for: .seconds(seconds))
    let sample = try #require(try await sampler.sample())

    let status = try await source.status()
    await source.stop()
    return (sample.systemWide, status.achievedLoad)
  }

  @Test("Ten seconds at 50% holds close to 50%", .timeLimit(.minutes(2)))
  func holdsFiftyPercent() async throws {
    let result = try await measure(target: 0.5, seconds: 10)

    // The system-wide figure includes everything else running, which can only
    // push it up, so the lower bound is the meaningful one and the upper bound
    // is deliberately loose.
    #expect(
      result.observed > 0.44 && result.observed < 0.75,
      "observed \(percent(result.observed)) for a 50% request")

    // The workers' own measurement excludes background load, so this is the
    // tight assertion: the duty cycler being right or wrong.
    let measured = try #require(result.workerMeasured)
    #expect(
      abs(measured - 0.5) < 0.03,
      "workers measured \(percent(measured)) for a 50% request")
  }

  @Test(
    "Observed utilization tracks the request across the range", .timeLimit(.minutes(3)),
    arguments: [0.25, 0.75])
  func tracksTarget(target: Double) async throws {
    let result = try await measure(target: target, seconds: 6)
    let measured = try #require(result.workerMeasured)
    #expect(
      abs(measured - target) < 0.03,
      "workers measured \(percent(measured)) for a \(percent(target)) request")
    #expect(
      result.observed > target - 0.08,
      "observed \(percent(result.observed)) for a \(percent(target)) request")
  }

  @Test("adjust changes the load without respawning threads", .timeLimit(.minutes(2)))
  func adjustKeepsTheSameThreads() async throws {
    let topology = try liveTopology()
    let source = SyntheticSource(topology: topology)
    defer { source.emergencyStop() }

    try await source.start(budget: ResourceBudget(cpu: 0.25))
    try await Task.sleep(for: .seconds(1))
    let firstSnapshot = try #require(source.poolSnapshot())

    // Sweep the target, including through zero and back, which is the path that
    // parks and wakes the threads.
    for target in [0.75, 0.0, 0.5, 1.0, 0.3] {
      try await source.adjust(to: ResourceBudget(cpu: target))
      try await Task.sleep(for: .milliseconds(300))
      #expect(source.poolSnapshot()?.requestedDutyCycle == target)
    }

    let finalSnapshot = try #require(source.poolSnapshot())
    #expect(finalSnapshot.placement.threadCount == firstSnapshot.placement.threadCount)
    // Monotonic counters prove these are the same threads: a respawn would
    // reset them.
    #expect(finalSnapshot.totalIterations > firstSnapshot.totalIterations)

    await source.stop()
  }

  @Test("A zero target parks the threads rather than spinning", .timeLimit(.minutes(2)))
  func zeroTargetParks() async throws {
    let topology = try liveTopology()
    let source = SyntheticSource(topology: topology)
    defer { source.emergencyStop() }

    try await source.start(budget: ResourceBudget(cpu: 0))
    try await Task.sleep(for: .seconds(1))

    let sampler = try CPUUtilizationSampler(topology: topology)
    try await Task.sleep(for: .seconds(3))
    let sample = try #require(try await sampler.sample())

    let before = try #require(source.poolSnapshot()).totalIterations
    try await Task.sleep(for: .seconds(1))
    let after = try #require(source.poolSnapshot()).totalIterations

    // The definitive check: a parked worker performs no iterations at all. The
    // utilization figure is a weaker corroboration, since anything else running
    // on the machine lands in it.
    #expect(after == before, "parked workers must not be computing")
    #expect(sample.systemWide < 0.5, "observed \(percent(sample.systemWide)) while parked")

    await source.stop()
  }

  @Test("Every core gets a thread, not a subset", .timeLimit(.minutes(2)))
  func loadIsSpreadAcrossAllCores() async throws {
    let topology = try liveTopology()
    let source = SyntheticSource(topology: topology)
    defer { source.emergencyStop() }

    try await source.start(budget: ResourceBudget(cpu: 0.5))
    try await Task.sleep(for: .seconds(2))

    let sampler = try CPUUtilizationSampler(topology: topology)
    try await Task.sleep(for: .seconds(4))
    let sample = try #require(try await sampler.sample())
    await source.stop()

    // A 50% target implemented as half the threads at 100% would leave cores
    // near idle. Every core must be carrying some of it.
    let quietest = sample.perCore.map(\.busy).min() ?? 0
    #expect(
      quietest > 0.2,
      "quietest core at \(percent(quietest)); load should be spread, not pinned")
  }

  @Test("Targeting one performance level sizes the pool to it", .timeLimit(.minutes(2)))
  func placementTargetsOneLevel() async throws {
    let topology = try liveTopology()
    try #require(topology.isHeterogeneous)
    let efficiency = try #require(topology.performanceLevels.last)

    let source = SyntheticSource(topology: topology)
    defer { source.emergencyStop() }
    try await source.start(
      budget: ResourceBudget(cpu: 1.0, placement: .performanceLevel(efficiency.index)))

    let snapshot = try #require(source.poolSnapshot())
    #expect(snapshot.placement.threadCount == efficiency.logicalCoreCount)
    #expect(snapshot.placement.qosHint == efficiency.qosHint)
    #expect(snapshot.placement.targetedLogicalCPUs == efficiency.logicalCPUIDs)

    await source.stop()
  }

  @Test("Stopping leaves no threads behind", .timeLimit(.minutes(2)))
  func stopIsClean() async throws {
    let topology = try liveTopology()
    let source = SyntheticSource(topology: topology)

    try await source.start(budget: ResourceBudget(cpu: 1.0))
    try await Task.sleep(for: .seconds(2))

    // Compared against load during the run rather than an absolute threshold,
    // which would be at the mercy of whatever else the machine is doing.
    let duringSampler = try CPUUtilizationSampler(topology: topology)
    try await Task.sleep(for: .seconds(2))
    let during = try #require(try await duringSampler.sample())

    await source.stop()
    #expect(source.poolSnapshot() == nil)

    let afterSampler = try CPUUtilizationSampler(topology: topology)
    try await Task.sleep(for: .seconds(2))
    let after = try #require(try await afterSampler.sample())

    let detail =
      "load went from \(percent(during.systemWide)) to \(percent(after.systemWide)) "
      + "after stop; it should have collapsed"
    #expect(after.systemWide < during.systemWide * 0.6, Comment(rawValue: detail))
  }

  private func percent(_ value: Double) -> String {
    String(format: "%.1f%%", value * 100)
  }
}
