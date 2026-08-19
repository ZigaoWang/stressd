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

  // MARK: Power. All optional: package power needs root and is never required,
  // and a desktop has no battery.

  /// CPU package power from powermetrics.
  public let packagePowerWatts: Double?
  public let gpuPowerWatts: Double?
  /// System draw minus package draw: display, radios, storage, everything
  /// else. Only derivable on battery, where battery watts measure the whole
  /// machine rather than just the SoC.
  public let otherPowerWatts: Double?
  /// Why package power is missing, when it is.
  public let powerAvailability: String?

  /// The percentage the OS shows the user. Smoothed.
  public let batteryPercent: Double?
  /// Raw capacity over raw max capacity. The true state of charge, and it will
  /// disagree with `batteryPercent`.
  public let batteryRawPercent: Double?
  /// Instantaneous battery power. **Negative means discharging.**
  public let batteryWatts: Double?
  /// Rolling median of `batteryWatts`, which is noisy sample to sample. This
  /// is the one to close a control loop on.
  public let batterySmoothedWatts: Double?
  public let isCharging: Bool?
  public let isConnectedToPower: Bool?
  public let cycleCount: Int?
  public let batteryTemperatureCelsius: Double?
  /// Fraction of the current load that is real contributed work, `0...1`.
  /// Zero while the synthetic source is the only one running.
  public let contributedFraction: Double
  public let activeSources: [SourceStatus]

  /// Total system draw while on battery, as a positive number of watts.
  ///
  /// Only meaningful on battery. On AC the battery is charging or idle and
  /// says nothing about what the machine is consuming.
  public var systemDrawWatts: Double? {
    guard isConnectedToPower == false, let watts = batterySmoothedWatts ?? batteryWatts,
      watts < 0
    else { return nil }
    return -watts
  }

  public init(
    timestamp: Date,
    interval: TimeInterval,
    cpu: CPUSample,
    thermalState: ThermalState,
    gpuUtilization: Double? = nil,
    packagePowerWatts: Double? = nil,
    gpuPowerWatts: Double? = nil,
    otherPowerWatts: Double? = nil,
    powerAvailability: String? = nil,
    batteryPercent: Double? = nil,
    batteryRawPercent: Double? = nil,
    batteryWatts: Double? = nil,
    batterySmoothedWatts: Double? = nil,
    isCharging: Bool? = nil,
    isConnectedToPower: Bool? = nil,
    cycleCount: Int? = nil,
    batteryTemperatureCelsius: Double? = nil,
    contributedFraction: Double = 0,
    activeSources: [SourceStatus] = []
  ) {
    self.timestamp = timestamp
    self.interval = interval
    self.cpu = cpu
    self.thermalState = thermalState
    self.gpuUtilization = gpuUtilization
    self.packagePowerWatts = packagePowerWatts
    self.gpuPowerWatts = gpuPowerWatts
    self.otherPowerWatts = otherPowerWatts
    self.powerAvailability = powerAvailability
    self.batteryPercent = batteryPercent
    self.batteryRawPercent = batteryRawPercent
    self.batteryWatts = batteryWatts
    self.batterySmoothedWatts = batterySmoothedWatts
    self.isCharging = isCharging
    self.isConnectedToPower = isConnectedToPower
    self.cycleCount = cycleCount
    self.batteryTemperatureCelsius = batteryTemperatureCelsius
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
