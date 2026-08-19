import Foundation
import Testing

@testable import StressKit

/// Whether the load-generating tests should run.
enum IntegrationTests {
  /// True when a sanitizer is instrumenting this process.
  ///
  /// ThreadSanitizer slows the compute kernels by roughly an order of
  /// magnitude, so a worker asked for 50% duty cannot deliver it and the
  /// measured utilization says nothing about the duty cycler. The scheduling
  /// and lifecycle tests still run and are exactly what TSan should see; only
  /// the assertions about achieved load magnitude are skipped.
  static var isSanitizerActive: Bool {
    dlsym(UnsafeMutableRawPointer(bitPattern: -2), "__tsan_init") != nil
      || dlsym(UnsafeMutableRawPointer(bitPattern: -2), "__asan_init") != nil
  }

  /// These put the machine under real load for tens of seconds and assert on
  /// observed utilization, so they are meaningless on a busy or virtualised
  /// runner. Enabled by default because the duty cycler is the thing most worth
  /// checking locally; CI sets the variable to skip them.
  static var isEnabled: Bool {
    guard TestHost.isAppleSilicon, !isSanitizerActive else { return false }
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

  /// Measures utilization with no stressd load, for use as a baseline.
  ///
  /// This suite runs on machines with a real working set. An absolute
  /// utilization threshold would be asserting something about the host, not
  /// about stressd, so every observed figure is compared against this instead.
  private func baselineUtilization(
    _ topology: CoreTopology, seconds: Double = 4
  ) async throws
    -> Double
  {
    let sampler = try CPUUtilizationSampler(topology: topology)
    try await Task.sleep(for: .seconds(seconds))
    return try #require(try await sampler.sample()).systemWide
  }

  /// Runs the source at `target` and returns the baseline, the observed
  /// utilization under load, and the duty cycle the workers measured.
  private func measure(
    target: Double,
    seconds: Double,
    placement: CorePlacement = .allCores
  ) async throws -> (baseline: Double, observed: Double, workerMeasured: Double?) {
    let topology = try liveTopology()
    let baseline = try await baselineUtilization(topology)

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
    return (baseline, sample.systemWide, status.achievedLoad)
  }

  /// How much of the requested load must show up as a utilization delta.
  ///
  /// Not 100%, and deliberately generous. stressd's threads compete with the
  /// machine's existing work rather than stacking on top of it, so part of the
  /// requested load displaces what was already running instead of adding to it.
  /// The effect is proportionally largest at low targets on a busy host: a 25%
  /// request measured a 15% delta against a 45% baseline here.
  ///
  /// This is a sanity floor, not the regression detector. The tight assertion
  /// in every one of these tests is the worker-measured duty cycle, which is
  /// recorded inside the worker loops and owes nothing to what else is running.
  private static let minimumDeltaFraction = 0.5

  @Test("Ten seconds at 50% holds close to 50%", .timeLimit(.minutes(2)))
  func holdsFiftyPercent() async throws {
    let result = try await measure(target: 0.5, seconds: 10)

    // Differential, so the assertion is about stressd rather than about
    // whatever else the host is running.
    let delta = result.observed - result.baseline
    let fiftyDetail =
      "baseline \(percent(result.baseline)), observed \(percent(result.observed)), "
      + "delta \(percent(delta)) for a 50% request"
    #expect(delta > 0.5 * Self.minimumDeltaFraction, Comment(rawValue: fiftyDetail))

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
    // Five points over a six second window. On a contended host the debt model
    // repays shortfalls caused by descheduling, which biases slightly high over
    // a short sample; a three minute run on a quiet machine lands within one
    // point. Still far tighter than the 15 point error this suite was written
    // to catch.
    #expect(
      abs(measured - target) < 0.05,
      "workers measured \(percent(measured)) for a \(percent(target)) request")

    let delta = result.observed - result.baseline
    let deltaDetail =
      "baseline \(percent(result.baseline)), observed \(percent(result.observed)), "
      + "delta \(percent(delta)) for a \(percent(target)) request"
    #expect(delta > target * Self.minimumDeltaFraction, Comment(rawValue: deltaDetail))
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
    let baseline = try await baselineUtilization(topology)

    let source = SyntheticSource(topology: topology)
    defer { source.emergencyStop() }

    try await source.start(budget: ResourceBudget(cpu: 0))
    try await Task.sleep(for: .seconds(1))

    let before = try #require(source.poolSnapshot()).totalIterations
    let sampler = try CPUUtilizationSampler(topology: topology)
    try await Task.sleep(for: .seconds(3))
    let parked = try #require(try await sampler.sample())
    let after = try #require(source.poolSnapshot()).totalIterations

    // The worker's own iteration counter is the definitive check, and it is
    // exact: a parked thread performs no iterations at all, where a thread
    // spinning at 0% duty would perform millions.
    #expect(after == before, "parked workers must not be computing")

    // Corroborated differentially: parked workers must not raise utilization
    // measurably above what the machine was already doing.
    let parkedDetail =
      "baseline \(percent(baseline)), parked \(percent(parked.systemWide)); "
      + "a parked pool should add nothing"
    #expect(parked.systemWide - baseline < 0.10, Comment(rawValue: parkedDetail))

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

    // A 50% target implemented as half the threads at 100% would leave half
    // the cores at their baseline. Every core must be carrying some of it.
    let quietest = sample.perCore.map(\.busy).min() ?? 0
    #expect(
      quietest > 0.2,
      "quietest core at \(percent(quietest)); load should be spread, not pinned")

    // Differential form of the same claim: the spread between the busiest and
    // quietest core stays narrow. Pinning would make it enormous.
    let busiest = sample.perCore.map(\.busy).max() ?? 0
    #expect(
      busiest - quietest < 0.6,
      "spread \(percent(busiest - quietest)) between busiest and quietest core")
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
