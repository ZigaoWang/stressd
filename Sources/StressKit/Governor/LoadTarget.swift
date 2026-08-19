import Foundation

/// What the governor is trying to hold.
public enum LoadTarget: Sendable, Equatable {
  /// A fraction of the whole machine, `0...1`.
  case utilization(Double)
  /// A whole-system power draw in watts. Requires a battery reading or
  /// package power, and works far better with a calibrated curve.
  case powerDraw(watts: Double)
  /// Load as high as possible without exceeding a thermal state.
  case thermalCeiling(ThermalState)
  /// As much as the machine will take, subject to the hard thermal override.
  case maximum

  /// The fixed utilization this target implies, when it has one.
  public var fixedUtilization: Double? {
    switch self {
    case .utilization(let value): return min(max(value, 0), 1)
    case .maximum, .thermalCeiling: return 1.0
    case .powerDraw: return nil
    }
  }

  public var describes: String {
    switch self {
    case .utilization(let value): return String(format: "%.0f%% utilization", value * 100)
    case .powerDraw(let watts): return String(format: "%.1f W", watts)
    case .thermalCeiling(let state): return "thermal ceiling \(state.rawValue)"
    case .maximum: return "maximum"
    }
  }
}

/// What the thermal override is doing to the requested load.
public enum ThermalAction: String, Sendable, Codable, Equatable {
  /// Thermal state is fine; the requested target passes through.
  case none
  /// Reducing load because the machine is at `.serious`.
  case backingOff
  /// Load stopped because the machine reached `.critical`.
  case stopped
  /// Recovering the ceiling after a back-off.
  case recovering
}

/// The hard thermal override.
///
/// **Not configurable, by design.** A stress tester that lets you disable its
/// own thermal protection is a stress tester that cooks someone's laptop. The
/// two thresholds come straight from `ProcessInfo.ThermalState`: back off at
/// `.serious`, stop at `.critical`.
///
/// Pure and testable: no clock, no telemetry, just a state machine over
/// thermal readings.
public struct ThermalOverride: Sendable, Equatable {

  /// How fast the ceiling comes down while the machine is at `.serious`, as a
  /// fraction per second. Aggressive on purpose: heat is the one thing worth
  /// overreacting to.
  public static let backOffRatePerSecond = 0.25

  /// How fast the ceiling recovers once the machine is back to `.nominal`.
  /// Slower than the back-off so the loop cannot ping-pong across the
  /// threshold.
  public static let recoveryRatePerSecond = 0.05

  /// Time at `.nominal` before recovery starts. Thermal state is coarse and
  /// lags the die, so a brief dip below `.serious` is not evidence of cooling.
  public static let recoveryHoldSeconds = 10.0

  /// Multiplier applied to the requested target, `0...1`.
  public private(set) var ceiling: Double = 1.0
  public private(set) var action: ThermalAction = .none
  private var secondsAtNominal: Double = 0

  public init() {}

  /// Advances the override.
  ///
  /// - Returns: The ceiling to multiply the requested target by.
  @discardableResult
  public mutating func step(state: ThermalState, elapsed: TimeInterval) -> Double {
    let elapsed = max(0, elapsed)

    switch state {
    case .critical:
      // Stop, not reduce. Nothing stressd is doing is worth continuing at
      // this point.
      ceiling = 0
      action = .stopped
      secondsAtNominal = 0

    case .serious:
      ceiling = max(0, ceiling - Self.backOffRatePerSecond * elapsed)
      action = .backingOff
      secondsAtNominal = 0

    case .fair:
      // Hold whatever ceiling is in force. Fair is warm but not a problem, and
      // recovering here would walk straight back into serious.
      action = ceiling < 1 ? .backingOff : .none
      secondsAtNominal = 0

    case .nominal:
      secondsAtNominal += elapsed
      if ceiling >= 1 {
        ceiling = 1
        action = .none
      } else if secondsAtNominal >= Self.recoveryHoldSeconds {
        ceiling = min(1, ceiling + Self.recoveryRatePerSecond * elapsed)
        action = ceiling >= 1 ? .none : .recovering
      } else {
        action = .backingOff
      }
    }
    return ceiling
  }

  /// Whether load must be stopped entirely.
  public var requiresStop: Bool { action == .stopped }

  public mutating func reset() {
    ceiling = 1
    action = .none
    secondsAtNominal = 0
  }
}
