import Foundation

/// What the governor decided this tick.
public struct GovernorDecision: Sendable, Equatable {
  /// The target after the thermal ceiling has been applied.
  public let effectiveTarget: Double
  /// What was asked for before the thermal override.
  public let requestedTarget: Double
  public let thermalAction: ThermalAction
  public let thermalCeiling: Double
  public let thermalState: ThermalState
  /// Human-readable reason, for display and for the session log.
  public let reason: String

  public var isStopped: Bool { thermalAction == .stopped }
}

/// Sits above the mixer and decides what total load to ask for.
///
/// The split between contributed and synthetic is the mixer's job. The
/// governor's job is what the total should be, and the one thing it will
/// override no matter what was requested: heat.
///
/// For `.utilization` the target is a constant and the interesting behaviour is
/// entirely the thermal override. `.powerDraw` closes a second loop on measured
/// watts and needs a calibrated curve to seed it.
public actor Governor {

  private let topology: CoreTopology
  private let target: LoadTarget
  private var thermal = ThermalOverride()
  private var powerController: PowerDrawController?
  private var lastDecision: GovernorDecision?

  /// Passing a calibrated `curve` seeds the power controller so it does not
  /// have to learn the machine's watts-per-load slope from zero.
  public init(topology: CoreTopology, target: LoadTarget, curve: PowerCurve? = nil) {
    self.topology = topology
    self.target = target
    if case .powerDraw(let watts) = target {
      powerController = PowerDrawController(targetWatts: watts, curve: curve)
    }
  }

  /// Advances the governor.
  ///
  /// - Parameters:
  ///   - telemetry: The most recent frame.
  ///   - elapsed: Seconds since the previous tick.
  /// - Returns: The total load the mixer should aim for.
  public func tick(telemetry: Telemetry, elapsed: TimeInterval) -> GovernorDecision {
    let ceiling = thermal.step(state: telemetry.thermalState, elapsed: elapsed)

    let requested: Double
    var reason: String

    switch target {
    case .utilization(let value):
      requested = min(max(value, 0), 1)
      reason = "holding \(Self.percent(requested)) utilization"
    case .maximum:
      requested = 1
      reason = "maximum load"
    case .thermalCeiling(let limit):
      // Run flat out and let the override do the limiting, but start backing
      // off at the requested state rather than waiting for .serious.
      requested = telemetry.thermalState.severity >= limit.severity ? 0 : 1
      reason = "loading up to thermal state \(limit.rawValue)"
    case .powerDraw(let watts):
      let measured = telemetry.systemDrawWatts ?? telemetry.packagePowerWatts
      if var controller = powerController {
        requested = controller.step(measuredWatts: measured, elapsed: elapsed)
        powerController = controller
        reason =
          measured.map { String(format: "holding %.1f W, measured %.1f W", watts, $0) }
          ?? "holding \(watts) W, no power reading available"
      } else {
        requested = 0
        reason = "power target requested but no controller"
      }
    }

    let effective = requested * ceiling
    switch thermal.action {
    case .stopped:
      reason = "thermal state critical: load stopped"
    case .backingOff:
      reason =
        "thermal state \(telemetry.thermalState.rawValue): backing off to "
        + Self.percent(effective)
    case .recovering:
      reason = "recovering after thermal back-off, ceiling \(Self.percent(ceiling))"
    case .none:
      break
    }

    let decision = GovernorDecision(
      effectiveTarget: effective,
      requestedTarget: requested,
      thermalAction: thermal.action,
      thermalCeiling: ceiling,
      thermalState: telemetry.thermalState,
      reason: reason)
    lastDecision = decision
    return decision
  }

  public func latest() -> GovernorDecision? { lastDecision }

  public func reset() {
    thermal.reset()
    powerController?.reset()
  }

  private static func percent(_ value: Double) -> String {
    String(format: "%.0f%%", min(max(value, 0), 1) * 100)
  }
}

/// Closes a loop on measured watts.
///
/// Proportional control on the load fraction, with the gain derived from a
/// calibrated curve when one is available. Without a curve it starts from a
/// conservative guess and adapts, which converges more slowly.
///
/// Not exercised on hardware yet: it needs a battery reading for true system
/// draw, or root for package power.
public struct PowerDrawController: Sendable, Equatable {

  /// Watts per unit of load fraction, when no curve says otherwise. Deliberately
  /// low so an uncalibrated controller creeps up rather than overshooting.
  static let defaultWattsPerFullLoad = 20.0

  /// Ignore errors smaller than this many watts, for the same reason the mixer
  /// has a deadband.
  public static let deadbandWatts = 0.75

  /// Most the load fraction may move per second.
  public static let slewRatePerSecond = 0.10

  /// Whole-system draw being held, in watts.
  public let targetWatts: Double
  private let wattsPerFullLoad: Double
  private(set) public var load: Double = 0

  public init(targetWatts: Double, curve: PowerCurve? = nil, initialLoad: Double = 0) {
    self.targetWatts = max(0, targetWatts)
    // A measured curve gives the actual watts-per-load slope for this machine,
    // which is the whole reason calibrate writes one out.
    self.wattsPerFullLoad = curve?.linearWattsPerFullLoad ?? Self.defaultWattsPerFullLoad
    self.load = min(max(initialLoad, 0), 1)
  }

  /// Advances the controller.
  ///
  /// - Returns: The load fraction to request. Holds position when no power
  ///   reading is available, rather than guessing.
  public mutating func step(measuredWatts: Double?, elapsed: TimeInterval) -> Double {
    guard let measuredWatts else { return load }

    let error = targetWatts - measuredWatts
    guard abs(error) > Self.deadbandWatts else { return load }

    // Convert a watts error into a load error using the measured slope.
    let slope = max(1.0, wattsPerFullLoad)
    let desired = min(max(load + error / slope, 0), 1)

    let maximumChange = Self.slewRatePerSecond * max(0, elapsed)
    let change = desired - load
    load = min(max(load + min(max(change, -maximumChange), maximumChange), 0), 1)
    return load
  }

  public mutating func reset() { load = 0 }
}
