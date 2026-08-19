import Foundation

/// How a calibration sweep is run.
public struct CalibrationPlan: Sendable, Equatable {
  /// Load fractions to measure, `0...1`.
  public let points: [Double]
  /// How long to average at each point, after settling.
  public let dwellSeconds: Double
  /// Discarded after changing load, before averaging starts. Power does not
  /// step instantaneously and neither does core frequency.
  public let settleSeconds: Double
  /// Minimum idle time between points.
  public let cooldownSeconds: Double
  /// Give up waiting for `.nominal` after this long and proceed, flagging the
  /// point. Without a bound, a machine that never cools would hang the sweep.
  public let maximumCooldownSeconds: Double
  /// Seed for the measurement order shuffle. Fixed values make a sweep
  /// reproducible; `nil` draws one.
  public let shuffleSeed: UInt64?

  public static let defaultPoints: [Double] = stride(from: 0.0, through: 1.0, by: 0.1).map { $0 }

  public init(
    points: [Double] = defaultPoints,
    dwellSeconds: Double = 30,
    settleSeconds: Double = 5,
    cooldownSeconds: Double = 60,
    maximumCooldownSeconds: Double = 300,
    shuffleSeed: UInt64? = nil
  ) {
    self.points = points.map { min(max($0, 0), 1) }.sorted()
    self.dwellSeconds = max(1, dwellSeconds)
    self.settleSeconds = max(0, settleSeconds)
    self.cooldownSeconds = max(0, cooldownSeconds)
    self.maximumCooldownSeconds = max(cooldownSeconds, maximumCooldownSeconds)
    self.shuffleSeed = shuffleSeed
  }

  /// Wall time if every cooldown finishes at the floor.
  ///
  /// The optimistic figure. A machine that stays above `.nominal` under load
  /// waits up to `maximumCooldownSeconds` at every point instead, which is
  /// what `worstCaseSeconds` reports.
  public var estimatedSeconds: Double {
    let perPoint = settleSeconds + dwellSeconds + cooldownSeconds
    return Double(points.count) * perPoint + baselineSeconds
  }

  /// Wall time if the machine never returns to `.nominal`.
  ///
  /// Worth quoting alongside the estimate: measured on an M3 Pro, a sweep whose
  /// optimistic estimate was 24 minutes took over 40, because sustained load
  /// held the thermal state at `.fair` and every cooldown ran to its cap.
  public var worstCaseSeconds: Double {
    let perPoint = settleSeconds + dwellSeconds + maximumCooldownSeconds
    return Double(points.count) * perPoint + baselineSeconds
  }

  /// Baseline sampling before the sweep starts.
  public var baselineSeconds: Double { 10 }

  /// The order points are measured in.
  ///
  /// **Shuffled deliberately.** A monotonic 0 to 100% sweep conflates load with
  /// accumulated heat: the 90% point would be measured on a machine that has
  /// been hot for ten minutes and would read low because of throttling, making
  /// the curve bend in a way that is an artefact of the sweep order rather than
  /// a property of the hardware. Randomising decorrelates position in the sweep
  /// from load.
  ///
  /// Uses its own generator rather than `shuffled()` so a sweep can be
  /// reproduced from its seed.
  public func measurementOrder() -> [Double] {
    var generator = SplitMix64(seed: shuffleSeed ?? 0x9E37_79B9_7F4A_7C15)
    var ordered = points
    guard ordered.count > 1 else { return ordered }
    for index in stride(from: ordered.count - 1, to: 0, by: -1) {
      let swap = Int(generator.next() % UInt64(index + 1))
      ordered.swapAt(index, swap)
    }
    return ordered
  }
}

/// Deterministic PRNG, so a shuffled sweep can be reproduced from its seed.
struct SplitMix64 {
  private var state: UInt64

  init(seed: UInt64) { state = seed }

  mutating func next() -> UInt64 {
    state = state &+ 0x9E37_79B9_7F4A_7C15
    var z = state
    z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
    z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
    return z ^ (z >> 31)
  }
}

/// Progress reported while a sweep runs.
public enum CalibrationProgress: Sendable {
  case started(
    totalPoints: Int, estimatedSeconds: Double, worstCaseSeconds: Double,
    powerSource: PowerCurve.Source)
  case baseline(utilization: Double, watts: Double?)
  case cooling(pointIndex: Int, totalPoints: Int, thermalState: ThermalState, waited: Double)
  case settling(pointIndex: Int, totalPoints: Int, load: Double)
  case measuring(pointIndex: Int, totalPoints: Int, load: Double)
  case measured(CalibrationPoint)
  case finished(PowerCurve)
}

/// Sweeps load and records power at each point.
///
/// The methodology is the substance here: shuffled order, a settling window
/// discarded after each change, a cooldown gated on thermal state, and a
/// baseline subtracted from everything. Without those the curve measures the
/// sweep as much as the machine.
public actor PowerCalibrator {

  private let topology: CoreTopology
  private let plan: CalibrationPlan
  private let source: SyntheticSource
  private let battery: BatteryMonitor?
  private let power: PowerMonitor?
  private let tickSource: any CPUTickReading
  private let sleeper: @Sendable (Double) async throws -> Void
  private let thermalState: @Sendable () -> ThermalState

  /// `sleeper` and `thermalState` are injected so a sweep that would take an
  /// hour of real waiting can be exercised instantly, and so cooldown gating
  /// can be driven through thermal states the test chooses.
  public init(
    topology: CoreTopology,
    plan: CalibrationPlan = CalibrationPlan(),
    source: SyntheticSource? = nil,
    battery: BatteryMonitor? = BatteryMonitor(),
    power: PowerMonitor? = nil,
    tickSource: any CPUTickReading = HostProcessorInfo(),
    sleeper: (@Sendable (Double) async throws -> Void)? = nil,
    thermalState: (@Sendable () -> ThermalState)? = nil
  ) {
    self.topology = topology
    self.plan = plan
    self.source = source ?? SyntheticSource(topology: topology)
    self.battery = battery
    self.power = power
    self.tickSource = tickSource
    self.sleeper =
      sleeper ?? { seconds in try await Task.sleep(for: .seconds(max(0, seconds))) }
    self.thermalState =
      thermalState ?? { ThermalState(ProcessInfo.processInfo.thermalState) }
  }

  /// Runs the sweep, reporting progress as it goes.
  public func run(
    onProgress: @Sendable (CalibrationProgress) -> Void = { _ in }
  ) async throws -> PowerCurve {
    let order = plan.measurementOrder()

    let baseline = try await measureBaseline()
    let powerSource = resolvePowerSource(baseline: baseline)
    onProgress(
      .started(
        totalPoints: order.count, estimatedSeconds: plan.estimatedSeconds,
        worstCaseSeconds: plan.worstCaseSeconds, powerSource: powerSource))
    onProgress(.baseline(utilization: baseline.utilization, watts: baseline.watts))

    var measured: [CalibrationPoint] = []
    defer { source.emergencyStop() }

    for (index, load) in order.enumerated() {
      // Cooldown first, so even the first point starts from a known state.
      let cooldownState = try await cooldown(
        pointIndex: index, total: order.count, onProgress: onProgress)

      onProgress(.settling(pointIndex: index, totalPoints: order.count, load: load))
      try await source.start(budget: ResourceBudget(cpu: load))
      await battery?.resetSmoothing()
      // Discarded: power and core frequency do not step instantaneously, and
      // averaging across the transient would smear every point towards its
      // neighbours.
      try await sleeper(plan.settleSeconds)

      onProgress(.measuring(pointIndex: index, totalPoints: order.count, load: load))
      let point = try await measure(
        load: load, order: index, baseline: baseline, enteredAt: cooldownState)
      measured.append(point)
      onProgress(.measured(point))

      await source.stop()
    }

    let curve = PowerCurve(
      machineModel: topology.machineModel,
      chipName: topology.chipName,
      measuredAt: Date(),
      powerSource: powerSource,
      baselineUtilization: baseline.utilization,
      baselineWatts: baseline.watts,
      points: measured,
      dwellSeconds: plan.dwellSeconds,
      settleSeconds: plan.settleSeconds,
      cooldownSeconds: plan.cooldownSeconds)
    onProgress(.finished(curve))
    return curve
  }

  // MARK: - Phases

  struct Baseline: Sendable {
    let utilization: Double
    let watts: Double?
    let packageWatts: Double?
  }

  /// Utilization and power with no stressd load.
  ///
  /// Subtracted from every point. Without it the curve measures this machine's
  /// browser tabs as much as it measures our load.
  private func measureBaseline() async throws -> Baseline {
    power?.start()
    await source.stop()
    await battery?.resetSmoothing()

    let sampler = try CPUUtilizationSampler(topology: topology, source: tickSource)
    try await sleeper(plan.baselineSeconds)

    let sample = try await sampler.sample()
    let reading = await battery?.read()
    return Baseline(
      utilization: sample?.systemWide ?? 0,
      watts: dischargeWatts(reading),
      packageWatts: power?.latestSample()?.combinedWatts ?? power?.latestSample()?.cpuWatts)
  }

  /// Idles until the machine returns to `.nominal`, or the floor elapses,
  /// whichever is longer.
  private func cooldown(
    pointIndex: Int, total: Int, onProgress: @Sendable (CalibrationProgress) -> Void
  ) async throws -> ThermalState {
    await source.stop()

    var waited = 0.0
    let step = 2.0
    // The floor runs regardless: thermal state is coarse and lags the actual
    // die temperature, so .nominal alone is not evidence of a cool machine.
    while waited < plan.cooldownSeconds
      || (thermalState() != .nominal && waited < plan.maximumCooldownSeconds)
    {
      onProgress(
        .cooling(
          pointIndex: pointIndex, totalPoints: total, thermalState: thermalState(),
          waited: waited))
      try await sleeper(step)
      waited += step
    }
    return thermalState()
  }

  /// Averages over the dwell window.
  private func measure(
    load: Double, order: Int, baseline: Baseline, enteredAt: ThermalState
  ) async throws -> CalibrationPoint {
    let sampler = try CPUUtilizationSampler(topology: topology, source: tickSource)

    var utilizations: [Double] = []
    var levelTotals: [String: [Double]] = [:]
    var systemWatts: [Double] = []
    var packageWatts: [Double] = []
    var gpuWatts: [Double] = []
    var otherWatts: [Double] = []
    var worstThermal = enteredAt

    let samples = max(1, Int(plan.dwellSeconds))
    for _ in 0..<samples {
      try await sleeper(1)
      if let sample = try await sampler.sample() {
        utilizations.append(sample.systemWide)
        for level in sample.byPerfLevel {
          levelTotals[level.name, default: []].append(level.busy)
        }
      }
      if let reading = await battery?.read() {
        if let watts = dischargeWatts(reading) { systemWatts.append(watts) }
      }
      if let sample = power?.latestSample() {
        if let watts = sample.combinedWatts ?? sample.cpuWatts { packageWatts.append(watts) }
        if let watts = sample.gpuWatts { gpuWatts.append(watts) }
      }
      let state = thermalState()
      if state.severity > worstThermal.severity { worstThermal = state }
    }

    let system = mean(systemWatts)
    let package = mean(packageWatts)
    if let system, let package { otherWatts.append(max(0, system - package)) }

    let status = try? await source.status()
    let observed = mean(utilizations) ?? 0

    return CalibrationPoint(
      requestedLoad: load,
      workerMeasuredLoad: status?.achievedLoad,
      observedUtilization: observed,
      observedUtilizationDelta: max(0, observed - baseline.utilization),
      utilizationByLevel: levelTotals.compactMapValues { mean($0) },
      systemWatts: system,
      systemWattsDelta: subtract(system, baseline.watts),
      packageWatts: package,
      packageWattsDelta: subtract(package, baseline.packageWatts),
      gpuWatts: mean(gpuWatts),
      otherWatts: mean(otherWatts),
      thermalState: worstThermal,
      // Any point not measured entirely at .nominal may have been throttled,
      // which suppresses both power and throughput.
      isSuspect: worstThermal != .nominal,
      measurementOrder: order,
      samples: utilizations.count)
  }

  // MARK: - Helpers

  private func resolvePowerSource(baseline: Baseline) -> PowerCurve.Source {
    if baseline.watts != nil { return .battery }
    if baseline.packageWatts != nil { return .packagePower }
    return .utilizationOnly
  }

  private func dischargeWatts(
    _ reading: (reading: BatteryReading, smoothedWatts: Double?)?
  )
    -> Double?
  {
    guard let reading, reading.reading.isConnectedToPower == false else { return nil }
    guard let watts = reading.smoothedWatts ?? reading.reading.watts, watts < 0 else {
      return nil
    }
    return -watts
  }

  private func mean(_ values: [Double]) -> Double? {
    guard !values.isEmpty else { return nil }
    return values.reduce(0, +) / Double(values.count)
  }

  private func subtract(_ value: Double?, _ baseline: Double?) -> Double? {
    guard let value else { return nil }
    guard let baseline else { return value }
    return value - baseline
  }
}

extension ThermalState {
  /// Ordering for "worst state seen", since the enum is not comparable.
  var severity: Int {
    switch self {
    case .nominal: return 0
    case .fair: return 1
    case .serious: return 2
    case .critical: return 3
    }
  }
}
