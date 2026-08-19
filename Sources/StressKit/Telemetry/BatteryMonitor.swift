import Foundation
import IOKit
import IOKit.ps

/// `SmartBatteryReading` backed by the `AppleSmartBattery` IORegistry node.
public struct IORegistrySmartBattery: SmartBatteryReading {

  public init() {}

  public func properties() -> [String: Any]? {
    guard let matching = IOServiceMatching("AppleSmartBattery") else { return nil }
    let service = IOServiceGetMatchingService(kIOMainPortDefault, matching)
    guard service != IO_OBJECT_NULL else { return nil }
    defer { IOObjectRelease(service) }

    var unmanaged: Unmanaged<CFMutableDictionary>?
    guard
      IORegistryEntryCreateCFProperties(service, &unmanaged, kCFAllocatorDefault, 0)
        == KERN_SUCCESS,
      let dictionary = unmanaged?.takeRetainedValue()
    else { return nil }
    return dictionary as? [String: Any]
  }
}

/// `PowerSourceReading` backed by `IOPSCopyPowerSourcesInfo`.
///
/// This is the view the OS shows the user: a smoothed percentage and a
/// time-remaining estimate. Deliberately not `pmset`, which is this data
/// formatted as English and then parsed back out again.
public struct IOPowerSources: PowerSourceReading {

  public init() {}

  public func description() -> [String: Any]? {
    guard let blob = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
      let sources = IOPSCopyPowerSourcesList(blob)?.takeRetainedValue() as? [CFTypeRef]
    else { return nil }

    for source in sources {
      guard
        let description = IOPSGetPowerSourceDescription(blob, source)?.takeUnretainedValue()
          as? [String: Any]
      else { continue }
      // Skip UPSs and other attached power sources.
      if let type = description[kIOPSTypeKey] as? String, type != kIOPSInternalBatteryType {
        continue
      }
      return description
    }
    return nil
  }
}

/// Reads the battery from both of the sources macOS offers.
///
/// ## Sign convention
///
/// **Negative watts means discharging.** Positive means the battery is being
/// charged. This follows `InstantAmperage`, which is negative when current
/// leaves the battery, and it is asserted rather than assumed: verify by
/// watching the sign flip when the adapter is attached. Captured from this
/// machine on AC while charging, `InstantAmperage` was +3182 mA at 11593 mV,
/// or +36.9 W into the battery.
public actor BatteryMonitor {

  /// Window for the rolling median over `InstantAmperage`, which is noisy
  /// sample to sample.
  public static let smoothingWindow = 5

  private let smartBattery: any SmartBatteryReading
  private let powerSource: any PowerSourceReading
  private var wattsMedian = RollingMedian(capacity: smoothingWindow)

  public init(
    smartBattery: any SmartBatteryReading = IORegistrySmartBattery(),
    powerSource: any PowerSourceReading = IOPowerSources()
  ) {
    self.smartBattery = smartBattery
    self.powerSource = powerSource
  }

  /// Whether this machine has a battery at all. Desktops do not.
  public func isAvailable() -> Bool {
    smartBattery.properties() != nil || powerSource.description() != nil
  }

  /// Reads the battery, folding the instantaneous watts into the rolling
  /// median.
  ///
  /// - Returns: The reading and the smoothed watts, or `nil` on a machine with
  ///   no battery.
  public func read() -> (reading: BatteryReading, smoothedWatts: Double?)? {
    guard
      let reading = Self.decode(
        smartBattery: smartBattery.properties(), powerSource: powerSource.description())
    else { return nil }

    if let watts = reading.watts {
      wattsMedian.append(watts)
    }
    return (reading, wattsMedian.value)
  }

  /// Clears the smoothing window, for when a measurement run starts and old
  /// samples would bias the first reading.
  public func resetSmoothing() {
    wattsMedian.reset()
  }

  /// Builds a reading from the two raw property dictionaries.
  ///
  /// Pure, so it can be tested against fixtures captured from machines with
  /// different firmware encodings.
  public static func decode(
    smartBattery: [String: Any]?, powerSource: [String: Any]?
  ) -> BatteryReading? {
    guard smartBattery != nil || powerSource != nil else { return nil }

    let rawCurrent = integer(smartBattery, "AppleRawCurrentCapacity")
    let rawMax = integer(smartBattery, "AppleRawMaxCapacity")
    let rawPercent: Double? = {
      guard let rawCurrent, let rawMax, rawMax > 0 else { return nil }
      return Double(rawCurrent) / Double(rawMax) * 100
    }()

    // Milliamps and millivolts, so the product is microwatts.
    let milliamps =
      integer(smartBattery, "InstantAmperage")
      .map { BatteryMath.signedMilliamps(fromRaw: Int64($0)) }
      ?? integer(smartBattery, "Amperage").map { BatteryMath.signedMilliamps(fromRaw: Int64($0)) }
    let millivolts = integer(smartBattery, "Voltage").map(Double.init)

    let watts: Double? = {
      guard let milliamps, let millivolts,
        BatteryMath.isPlausibleMilliamps(milliamps), millivolts > 0
      else { return nil }
      return BatteryMath.watts(milliamps: milliamps, millivolts: millivolts)
    }()

    return BatteryReading(
      reportedPercent: reportedPercent(powerSource: powerSource, smartBattery: smartBattery),
      rawPercent: rawPercent,
      isCharging: boolean(smartBattery, "IsCharging")
        ?? (powerSource?[kIOPSIsChargingKey] as? Bool ?? false),
      isConnectedToPower: boolean(smartBattery, "ExternalConnected")
        ?? ((powerSource?[kIOPSPowerSourceStateKey] as? String) == kIOPSACPowerValue),
      timeRemaining: timeRemaining(powerSource: powerSource, smartBattery: smartBattery),
      milliamps: milliamps.flatMap { BatteryMath.isPlausibleMilliamps($0) ? $0 : nil },
      millivolts: millivolts,
      watts: watts,
      cycleCount: integer(smartBattery, "CycleCount"),
      // Centi-degrees Celsius: 3091 is 30.91 C.
      temperatureCelsius: integer(smartBattery, "Temperature").map { Double($0) / 100 },
      rawCurrentCapacity: rawCurrent,
      rawMaxCapacity: rawMax,
      designCapacity: integer(smartBattery, "DesignCapacity"))
  }

  // MARK: - Property decoding

  private static func reportedPercent(
    powerSource: [String: Any]?, smartBattery: [String: Any]?
  ) -> Double? {
    if let current = powerSource?[kIOPSCurrentCapacityKey] as? Int,
      let max = powerSource?[kIOPSMaxCapacityKey] as? Int, max > 0
    {
      return Double(current) / Double(max) * 100
    }
    // AppleSmartBattery's CurrentCapacity is already a percentage when
    // MaxCapacity reads 100.
    if let current = integer(smartBattery, "CurrentCapacity"),
      let max = integer(smartBattery, "MaxCapacity"), max > 0
    {
      return Double(current) / Double(max) * 100
    }
    return nil
  }

  private static func timeRemaining(
    powerSource: [String: Any]?, smartBattery: [String: Any]?
  ) -> TimeInterval? {
    // Both are in minutes. Negative or 65535 means "still calculating".
    if let minutes = powerSource?[kIOPSTimeToEmptyKey] as? Int, minutes > 0, minutes < 65535 {
      return TimeInterval(minutes) * 60
    }
    if let minutes = powerSource?[kIOPSTimeToFullChargeKey] as? Int, minutes > 0,
      minutes < 65535
    {
      return TimeInterval(minutes) * 60
    }
    if let minutes = integer(smartBattery, "TimeRemaining"), minutes > 0, minutes < 65535 {
      return TimeInterval(minutes) * 60
    }
    return nil
  }

  /// IORegistry numbers arrive as `NSNumber`; `int64Value` preserves the bit
  /// pattern of a 64-bit unsigned value, which is what makes the sign
  /// correction in `BatteryMath` possible.
  private static func integer(_ properties: [String: Any]?, _ key: String) -> Int? {
    guard let value = properties?[key] else { return nil }
    if let number = value as? NSNumber { return Int(number.int64Value) }
    if let boolean = value as? Bool { return boolean ? 1 : 0 }
    return nil
  }

  private static func boolean(_ properties: [String: Any]?, _ key: String) -> Bool? {
    guard let value = properties?[key] else { return nil }
    if let boolean = value as? Bool { return boolean }
    if let number = value as? NSNumber { return number.intValue != 0 }
    return nil
  }
}
