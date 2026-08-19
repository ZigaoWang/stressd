import Foundation

/// A snapshot of the battery, combining both sources macOS offers.
public struct BatteryReading: Sendable, Codable, Equatable {
  /// The percentage the OS shows the user. Smoothed, and it lies a little near
  /// the ends of the range so the menu bar behaves predictably.
  public let reportedPercent: Double?
  /// `AppleRawCurrentCapacity / AppleRawMaxCapacity`. The true state of charge,
  /// which will disagree with `reportedPercent`.
  public let rawPercent: Double?
  public let isCharging: Bool
  public let isConnectedToPower: Bool
  /// The OS estimate of time to empty, or to full while charging.
  public let timeRemaining: TimeInterval?

  /// Instantaneous current in milliamps, signed: negative is discharging.
  public let milliamps: Double?
  /// Pack voltage in millivolts. Watts are (mA x mV) / 1e6.
  public let millivolts: Double?
  /// Instantaneous power in watts, signed: **negative means discharging**.
  public let watts: Double?

  /// Charge cycles the battery has completed.
  public let cycleCount: Int?
  /// Degrees Celsius.
  public let temperatureCelsius: Double?
  public let rawCurrentCapacity: Int?
  public let rawMaxCapacity: Int?
  public let designCapacity: Int?

  /// Battery health as raw max capacity over design capacity.
  public var healthPercent: Double? {
    guard let rawMaxCapacity, let designCapacity, designCapacity > 0 else { return nil }
    return Double(rawMaxCapacity) / Double(designCapacity) * 100
  }

  /// Power being drawn from the battery, as a positive number. `nil` while
  /// charging or on AC, where there is no discharge to report.
  public var dischargeWatts: Double? {
    guard let watts, watts < 0 else { return nil }
    return -watts
  }

  public init(
    reportedPercent: Double? = nil,
    rawPercent: Double? = nil,
    isCharging: Bool = false,
    isConnectedToPower: Bool = false,
    timeRemaining: TimeInterval? = nil,
    milliamps: Double? = nil,
    millivolts: Double? = nil,
    watts: Double? = nil,
    cycleCount: Int? = nil,
    temperatureCelsius: Double? = nil,
    rawCurrentCapacity: Int? = nil,
    rawMaxCapacity: Int? = nil,
    designCapacity: Int? = nil
  ) {
    self.reportedPercent = reportedPercent
    self.rawPercent = rawPercent
    self.isCharging = isCharging
    self.isConnectedToPower = isConnectedToPower
    self.timeRemaining = timeRemaining
    self.milliamps = milliamps
    self.millivolts = millivolts
    self.watts = watts
    self.cycleCount = cycleCount
    self.temperatureCelsius = temperatureCelsius
    self.rawCurrentCapacity = rawCurrentCapacity
    self.rawMaxCapacity = rawMaxCapacity
    self.designCapacity = designCapacity
  }
}

/// The raw `AppleSmartBattery` IORegistry properties.
public protocol SmartBatteryReading: Sendable {
  /// Returns the node's properties, or `nil` on a machine with no battery.
  func properties() -> [String: Any]?
}

/// The `IOPSCopyPowerSourcesInfo` view: what the OS shows the user.
public protocol PowerSourceReading: Sendable {
  func description() -> [String: Any]?
}

/// Arithmetic and decoding for battery values, separated from IOKit so it can
/// be tested against fixtures from machines with different firmware.
public enum BatteryMath {

  /// Amperage above this magnitude is not a real current and means the value
  /// arrived as an unsigned word that needs two's-complement correction.
  ///
  /// Apple silicon laptops draw at most a few thousand milliamps; 100 A is far
  /// outside anything physical while being far below the 2^63 range a
  /// misinterpreted negative lands in.
  static let implausibleMilliampThreshold = 100_000.0

  /// Sign-corrects `InstantAmperage`.
  ///
  /// The key is documented as signed, but firmware hands it over in two
  /// different encodings and the API erases the difference:
  ///
  /// - **64-bit unsigned.** A discharge of -6692 mA arrives as
  ///   18446744073709544924. Reading it as `Int64` restores the sign for free,
  ///   because that is the same bit pattern. Real values are visible in this
  ///   machine's own `AppleSmartBattery` node, where
  ///   `MaximumDischargeCurrent` reads 18446744073709544924.
  /// - **32-bit unsigned widened to 64.** The same current arrives as
  ///   4294960604, which is a large *positive* number after widening and needs
  ///   `2^32` subtracted.
  ///
  /// Only the second needs correcting, and it is safe to detect because no
  /// laptop battery moves 100 A.
  public static func signedMilliamps(fromRaw raw: Int64) -> Double {
    guard abs(Double(raw)) > implausibleMilliampThreshold else { return Double(raw) }

    if raw > 0, raw <= Int64(UInt32.max) {
      let corrected = raw - (Int64(UInt32.max) + 1)
      if abs(Double(corrected)) <= implausibleMilliampThreshold {
        return Double(corrected)
      }
    }
    // Anything still out of range is not a current we can interpret. Returned
    // as-is so the caller can see the nonsense rather than a fabricated value.
    return Double(raw)
  }

  /// Whether a milliamp figure is physically plausible for a laptop battery.
  public static func isPlausibleMilliamps(_ value: Double) -> Bool {
    value.isFinite && abs(value) <= implausibleMilliampThreshold
  }

  /// Watts from milliamps and millivolts.
  ///
  /// `(mA * mV) / 1e6`, because milli times milli is micro. Sign follows the
  /// current: **negative watts means discharging**.
  public static func watts(milliamps: Double, millivolts: Double) -> Double {
    milliamps * millivolts / 1_000_000
  }

  /// Median of the values, for smoothing a noisy instantaneous current.
  public static func median(_ values: [Double]) -> Double? {
    guard !values.isEmpty else { return nil }
    let sorted = values.sorted()
    let middle = sorted.count / 2
    if sorted.count.isMultiple(of: 2) {
      return (sorted[middle - 1] + sorted[middle]) / 2
    }
    return sorted[middle]
  }
}

/// A fixed-size rolling median.
///
/// `InstantAmperage` is noisy sample to sample, and a mean would let a single
/// spike through. The governor closes its loop on the smoothed value; the raw
/// one is reported alongside it.
public struct RollingMedian: Sendable, Equatable {
  public let capacity: Int
  private var samples: [Double] = []

  public init(capacity: Int = 5) {
    self.capacity = max(1, capacity)
  }

  public mutating func append(_ value: Double) {
    guard value.isFinite else { return }
    samples.append(value)
    if samples.count > capacity {
      samples.removeFirst(samples.count - capacity)
    }
  }

  public var value: Double? { BatteryMath.median(samples) }
  public var count: Int { samples.count }
  public var isFull: Bool { samples.count >= capacity }

  public mutating func reset() { samples.removeAll() }
}
