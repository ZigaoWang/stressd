import Foundation

/// One telemetry frame.
///
/// Power, battery and GPU fields are declared now and filled in a later step;
/// they read `nil` until then rather than being absent, so consumers of the
/// JSON do not change shape when they arrive.
public struct Telemetry: Sendable, Codable {
  public let timestamp: Date
  public let interval: TimeInterval
  public let cpu: CPUSample
  public let thermalState: ThermalState
  public let gpuUtilization: Double?
  public let packagePowerWatts: Double?
  public let batteryPercent: Double?
  public let batteryWatts: Double?
  /// Fraction of the current load that is real contributed work, `0...1`.
  /// Zero while the synthetic source is the only one running.
  public let contributedFraction: Double
  public let activeSources: [SourceStatus]

  public init(
    timestamp: Date,
    interval: TimeInterval,
    cpu: CPUSample,
    thermalState: ThermalState,
    gpuUtilization: Double? = nil,
    packagePowerWatts: Double? = nil,
    batteryPercent: Double? = nil,
    batteryWatts: Double? = nil,
    contributedFraction: Double = 0,
    activeSources: [SourceStatus] = []
  ) {
    self.timestamp = timestamp
    self.interval = interval
    self.cpu = cpu
    self.thermalState = thermalState
    self.gpuUtilization = gpuUtilization
    self.packagePowerWatts = packagePowerWatts
    self.batteryPercent = batteryPercent
    self.batteryWatts = batteryWatts
    self.contributedFraction = contributedFraction
    self.activeSources = activeSources
  }
}

/// `ProcessInfo.ThermalState`, made `Codable` for the JSON output.
public enum ThermalState: String, Sendable, Codable {
  case nominal
  case fair
  case serious
  case critical

  public init(_ state: ProcessInfo.ThermalState) {
    switch state {
    case .nominal: self = .nominal
    case .fair: self = .fair
    case .serious: self = .serious
    case .critical: self = .critical
    @unknown default: self = .nominal
    }
  }

  /// Whether stressd must reduce load at this state.
  ///
  /// The governor that acts on this arrives in a later step. The classification
  /// lives here so there is one definition of it.
  public var requiresBackOff: Bool { self == .serious || self == .critical }

  /// Whether stressd must stop entirely.
  public var requiresStop: Bool { self == .critical }
}
