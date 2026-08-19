import Foundation

/// How the two kinds of load are split at one instant.
public struct LoadSplit: Sendable, Codable, Equatable {
  /// Measured utilization above baseline, from contributed sources.
  public let contributedUtilization: Double
  /// Measured utilization above baseline, from synthetic load.
  public let syntheticUtilization: Double
  /// Total measured utilization above baseline.
  public let totalUtilization: Double
  /// Contributed share of the measured total, `0...1`.
  public let contributedFraction: Double
  /// How synthetic's share was determined.
  public let attribution: Attribution

  public enum Attribution: String, Sendable, Codable {
    /// Synthetic's share came from the workers' own duty cycle measurement.
    case workerMeasured
    /// Nothing was running, so there was nothing to attribute.
    case idle
  }

  public init(
    contributedUtilization: Double,
    syntheticUtilization: Double,
    totalUtilization: Double,
    attribution: Attribution
  ) {
    self.contributedUtilization = max(0, contributedUtilization)
    self.syntheticUtilization = max(0, syntheticUtilization)
    self.totalUtilization = max(0, totalUtilization)
    self.contributedFraction =
      totalUtilization > 0.001 ? min(max(contributedUtilization / totalUtilization, 0), 1) : 0
    self.attribution = attribution
  }
}

/// Drives contributed and synthetic sources together to hold a total target.
///
/// The mechanic this exists for: BOINC's CPU usage moves on its own as
/// workunits start and finish, so the only way to hold a total is to measure
/// what is happening every second and top it up with synthetic load. When BOINC
/// ramps, synthetic backs off; when BOINC has no work, synthetic takes the
/// whole target.
public actor LoadMixer {

  public struct Sample: Sendable {
    public let split: LoadSplit
    public let decision: MixerDecision
    public let target: Double
    public let baseline: Double
    public let observedAbsolute: Double
    /// Why contributed load is doing nothing, when it is not.
    public let contributedIdleReason: String?
  }

  private let topology: CoreTopology
  private let synthetic: SyntheticSource
  private let contributed: [any LoadSource]
  private let boinc: BOINCSource?
  private var controller: MixerController
  private let budget: ResourceBudget
  /// When false, synthetic never tops up and the shortfall is reported.
  private let allowSyntheticTopUp: Bool

  private var baseline: Double = 0
  private var lastSample: Sample?
  /// Previous pool counters, so synthetic's share is measured over the last
  /// interval rather than over the whole run.
  private var previousWorkers: [WorkerSample] = []

  public init(
    topology: CoreTopology,
    budget: ResourceBudget,
    synthetic: SyntheticSource,
    contributed: [any LoadSource] = [],
    boinc: BOINCSource? = nil,
    configuration: MixerConfiguration = MixerConfiguration(),
    allowSyntheticTopUp: Bool = true
  ) {
    self.topology = topology
    self.budget = budget
    self.synthetic = synthetic
    self.contributed = contributed
    self.boinc = boinc
    self.controller = MixerController(configuration: configuration)
    self.allowSyntheticTopUp = allowSyntheticTopUp
  }

  /// Records the machine's pre-existing load. Everything after is measured
  /// against this.
  public func setBaseline(_ utilization: Double) {
    baseline = max(0, utilization)
  }

  /// Starts contributed sources first, then synthetic parked at zero.
  ///
  /// Contributed load is given the whole target: it is the load that is worth
  /// generating, so it gets first claim, and synthetic only fills what is left.
  public func start() async throws {
    for source in contributed {
      try? await source.start(budget: budget)
    }
    // Parked, not duty cycling at zero. The gate blocks the threads on a
    // condition variable until there is something to do.
    try await synthetic.start(budget: ResourceBudget(cpu: 0, placement: budget.placement))
  }

  /// One step of the loop.
  public func tick(observed: CPUSample, elapsed: TimeInterval) async -> Sample {
    let observedDelta = max(0, observed.systemWide - baseline)
    let split = await measureSplit(observedDelta: observedDelta)

    var decision = controller.step(
      target: budget.cpu,
      observedDelta: observedDelta,
      contributedUtilization: split.contributedUtilization,
      elapsed: elapsed)

    if allowSyntheticTopUp {
      // adjust, never start: this changes the duty cycle on the live threads.
      try? await synthetic.adjust(
        to: ResourceBudget(cpu: decision.syntheticDuty, placement: budget.placement))
    } else {
      // --contributed-only: the shortfall is reported rather than filled.
      controller.reset(to: 0)
      decision = MixerDecision(
        syntheticDuty: 0,
        contributedOverTarget: decision.contributedOverTarget,
        contributedTarget: decision.contributedTarget,
        rawError: decision.rawError,
        withinDeadband: decision.withinDeadband,
        slewLimited: false)
    }

    // Only once synthetic is already at zero, so real work is never reduced
    // while synthetic cycles are still being burned.
    if let contributedTarget = decision.contributedTarget, let boinc {
      try? await boinc.adjust(
        to: ResourceBudget(cpu: contributedTarget, placement: budget.placement))
    }

    let sample = Sample(
      split: split,
      decision: decision,
      target: budget.cpu,
      baseline: baseline,
      observedAbsolute: observed.systemWide,
      contributedIdleReason: await contributedIdleReason())
    lastSample = sample
    return sample
  }

  public func stop() async {
    await synthetic.stop()
    for source in contributed {
      await source.stop()
    }
  }

  public func latest() -> Sample? { lastSample }

  // MARK: - Attribution

  /// Splits measured load between contributed and synthetic.
  ///
  /// Synthetic's share is the one thing that can be measured directly: the
  /// workers record their own duty cycle from inside their loops, and they run
  /// on a known number of cores. Everything else above baseline is contributed.
  /// This is deliberately not derived from what was *requested*, because the
  /// entire point of the mixer is that requested and actual differ.
  private func measureSplit(observedDelta: Double) async -> LoadSplit {
    guard let snapshot = synthetic.poolSnapshot(), snapshot.isRunning else {
      previousWorkers = []
      return LoadSplit(
        contributedUtilization: observedDelta,
        syntheticUtilization: 0,
        totalUtilization: observedDelta,
        attribution: observedDelta > 0.001 ? .workerMeasured : .idle)
    }

    // Windowed, not lifetime. The pool's cumulative duty cycle averages over
    // the whole run, so after the mixer has moved the target it would describe
    // history rather than now, and the loop would chase a stale number.
    let achieved = Self.windowedDutyCycle(
      current: snapshot.workers, previous: previousWorkers)
    previousWorkers = snapshot.workers

    guard let achieved else {
      return LoadSplit(
        contributedUtilization: observedDelta,
        syntheticUtilization: 0,
        totalUtilization: observedDelta,
        attribution: .idle)
    }

    let threadShare =
      Double(snapshot.placement.threadCount) / Double(max(topology.logicalCoreCount, 1))
    let syntheticUtilization = min(1, max(0, achieved * threadShare))
    return LoadSplit(
      contributedUtilization: max(0, observedDelta - syntheticUtilization),
      syntheticUtilization: syntheticUtilization,
      totalUtilization: observedDelta,
      attribution: .workerMeasured)
  }

  /// Duty cycle achieved since the previous read.
  ///
  /// Returns `nil` on the first call, when there is no previous read to
  /// subtract, and when no measurable time elapsed.
  static func windowedDutyCycle(current: [WorkerSample], previous: [WorkerSample]) -> Double? {
    guard !previous.isEmpty, current.count == previous.count else { return nil }
    var busy: UInt64 = 0
    var elapsed: UInt64 = 0
    for (now, before) in zip(current, previous) {
      let delta = now.delta(since: before)
      busy &+= delta.busyNanoseconds
      elapsed &+= delta.elapsedNanoseconds
    }
    guard elapsed > 0 else { return nil }
    return Double(busy) / Double(elapsed)
  }

  private func contributedIdleReason() async -> String? {
    guard let boinc else {
      return contributed.isEmpty ? "no contributed sources available" : nil
    }
    return await boinc.idleReason()?.explanation
  }
}

extension Telemetry {
  /// Folds the mixer's measured split into a telemetry frame.
  ///
  /// `contributedFraction` comes from measured utilization, not from what was
  /// requested: the whole reason the mixer exists is that contributed load does
  /// not do what it is told.
  public func merging(_ sample: LoadMixer.Sample) -> Telemetry {
    Telemetry(
      timestamp: timestamp,
      interval: interval,
      cpu: cpu,
      thermalState: thermalState,
      gpuUtilization: gpuUtilization,
      packagePowerWatts: packagePowerWatts,
      gpuPowerWatts: gpuPowerWatts,
      otherPowerWatts: otherPowerWatts,
      powerAvailability: powerAvailability,
      batteryPercent: batteryPercent,
      batteryRawPercent: batteryRawPercent,
      batteryWatts: batteryWatts,
      batterySmoothedWatts: batterySmoothedWatts,
      isCharging: isCharging,
      isConnectedToPower: isConnectedToPower,
      cycleCount: cycleCount,
      batteryTemperatureCelsius: batteryTemperatureCelsius,
      contributedFraction: sample.split.contributedFraction,
      activeSources: activeSources,
      loadSplit: sample.split)
  }
}
