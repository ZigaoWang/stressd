import Foundation
import Testing

@testable import StressKit

@Suite("Battery decoding")
struct BatteryTests {

  // MARK: - Sign correction

  @Test("A plausible signed value passes through untouched")
  func plausibleAmperage() {
    #expect(BatteryMath.signedMilliamps(fromRaw: -1500) == -1500)
    #expect(BatteryMath.signedMilliamps(fromRaw: 3182) == 3182)
    #expect(BatteryMath.signedMilliamps(fromRaw: 0) == 0)
  }

  @Test("A 32-bit unsigned encoding of a negative current is corrected")
  func thirtyTwoBitUnsignedEncoding() {
    // -1500 mA widened from a 32-bit unsigned word becomes 4294965796.
    #expect(BatteryMath.signedMilliamps(fromRaw: 4_294_965_796) == -1500)
    // -6692 mA, the value this machine's own MaximumDischargeCurrent holds.
    #expect(BatteryMath.signedMilliamps(fromRaw: 4_294_960_604) == -6692)
  }

  @Test("A 64-bit unsigned encoding arrives already signed and is left alone")
  func sixtyFourBitUnsignedEncoding() {
    // 18446744073709544924 as UInt64 is -6692 as Int64: reading it into Int64
    // restores the sign for free, so no correction is needed or wanted.
    let raw = Int64(bitPattern: 18_446_744_073_709_544_924)
    #expect(raw == -6692)
    #expect(BatteryMath.signedMilliamps(fromRaw: raw) == -6692)
  }

  @Test("A value that cannot be a current is reported, not fabricated")
  func implausibleValueSurvives() {
    // Better to surface nonsense than to invent a plausible-looking number.
    let absurd: Int64 = 9_000_000_000_000
    #expect(BatteryMath.signedMilliamps(fromRaw: absurd) == Double(absurd))
    #expect(!BatteryMath.isPlausibleMilliamps(Double(absurd)))
  }

  // MARK: - Watts

  @Test("Watts are milliamps times millivolts over a million")
  func wattsArithmetic() {
    // Milli times milli is micro, so the divisor is 1e6, not 1e3.
    #expect(abs(BatteryMath.watts(milliamps: 3182, millivolts: 11593) - 36.88) < 0.01)
    #expect(abs(BatteryMath.watts(milliamps: -1500, millivolts: 11600) - -17.4) < 0.01)
    #expect(BatteryMath.watts(milliamps: 0, millivolts: 11600) == 0)
  }

  @Test("Negative watts means discharging, and the convention holds end to end")
  func signConvention() throws {
    let discharging = try #require(
      BatteryMonitor.decode(smartBattery: Fixtures.discharging, powerSource: nil))
    let charging = try #require(
      BatteryMonitor.decode(smartBattery: Fixtures.charging, powerSource: nil))

    let dischargingWatts = try #require(discharging.watts)
    let chargingWatts = try #require(charging.watts)
    #expect(dischargingWatts < 0, "discharging must be negative")
    #expect(chargingWatts > 0, "charging must be positive")
    // dischargeWatts flips it to a positive magnitude, and only while
    // discharging.
    #expect(abs((discharging.dischargeWatts ?? 0) - 17.4) < 0.05)
    #expect(charging.dischargeWatts == nil)
  }

  // MARK: - Full decode

  @Test("Raw state of charge is reported separately from the smoothed one")
  func rawVersusReportedPercent() throws {
    // Captured from an M3 Pro: the OS said 25% while raw capacity said 24.0%.
    // Reporting only one of them would be quietly wrong either way.
    let reading = try #require(
      BatteryMonitor.decode(smartBattery: Fixtures.charging, powerSource: nil))

    #expect(abs((reading.rawPercent ?? 0) - 17.005) < 0.01)
    #expect(reading.reportedPercent == 18)
    #expect(reading.rawPercent != reading.reportedPercent)
  }

  @Test("Temperature is centi-Celsius and cycle count passes through")
  func temperatureAndCycles() throws {
    let reading = try #require(
      BatteryMonitor.decode(smartBattery: Fixtures.charging, powerSource: nil))
    #expect(abs((reading.temperatureCelsius ?? 0) - 30.91) < 0.001)
    #expect(reading.cycleCount == 274)
    #expect(reading.isCharging)
    #expect(reading.isConnectedToPower)
  }

  @Test("Battery health is raw max over design capacity")
  func health() throws {
    let reading = try #require(
      BatteryMonitor.decode(smartBattery: Fixtures.charging, powerSource: nil))
    #expect(abs((reading.healthPercent ?? 0) - 85.7) < 0.2)
  }

  @Test("A machine with no battery reports nothing rather than zeroes")
  func noBattery() {
    #expect(BatteryMonitor.decode(smartBattery: nil, powerSource: nil) == nil)
  }

  @Test("An implausible amperage does not produce a watts figure")
  func implausibleAmperageSuppressesWatts() throws {
    var properties = Fixtures.charging
    properties["InstantAmperage"] = NSNumber(value: Int64(9_000_000_000_000))
    let reading = try #require(
      BatteryMonitor.decode(smartBattery: properties, powerSource: nil))
    #expect(reading.watts == nil)
    #expect(reading.milliamps == nil)
  }

  @Test("The IOPS percentage is preferred over the raw node's own percentage")
  func powerSourcePercentWins() throws {
    let reading = try #require(
      BatteryMonitor.decode(
        smartBattery: Fixtures.charging,
        powerSource: [
          kIOPSCurrentCapacityKey: 25,
          kIOPSMaxCapacityKey: 100,
        ]))
    #expect(reading.reportedPercent == 25)
  }

  // MARK: - Rolling median

  @Test("The rolling median keeps a fixed window")
  func rollingMedianWindow() {
    var median = RollingMedian(capacity: 5)
    #expect(median.value == nil)

    for value in [10.0, 12.0, 11.0] { median.append(value) }
    #expect(median.value == 11)
    #expect(!median.isFull)

    for value in [13.0, 9.0, 100.0, 12.0] { median.append(value) }
    #expect(median.isFull)
    #expect(median.count == 5)
  }

  @Test("A single spike does not move the median, where a mean would follow it")
  func medianRejectsSpikes() {
    var median = RollingMedian(capacity: 5)
    for value in [10.0, 10.0, 10.0, 10.0] { median.append(value) }
    median.append(500)
    // InstantAmperage is noisy sample to sample; the governor closes its loop
    // on this value, so one bad read must not move it.
    #expect(median.value == 10)
  }

  @Test("An even-sized window averages the middle pair")
  func evenWindow() {
    var median = RollingMedian(capacity: 4)
    for value in [1.0, 2.0, 3.0, 4.0] { median.append(value) }
    #expect(median.value == 2.5)
  }

  @Test("Non-finite samples are ignored rather than poisoning the window")
  func ignoresNonFinite() {
    var median = RollingMedian(capacity: 3)
    median.append(10)
    median.append(.nan)
    median.append(.infinity)
    #expect(median.value == 10)
  }

  // MARK: - Fixtures

  enum Fixtures {
    // Dictionaries of Any are not Sendable; these are read-only fixtures.
    /// Captured from an M3 Pro on AC, charging.
    nonisolated(unsafe) static let charging: [String: Any] = [
      "InstantAmperage": NSNumber(value: 3182),
      "Voltage": NSNumber(value: 11593),
      "AppleRawCurrentCapacity": NSNumber(value: 911),
      "AppleRawMaxCapacity": NSNumber(value: 5357),
      "DesignCapacity": NSNumber(value: 6249),
      "CycleCount": NSNumber(value: 274),
      "Temperature": NSNumber(value: 3091),
      "IsCharging": true,
      "ExternalConnected": true,
      "CurrentCapacity": NSNumber(value: 18),
      "MaxCapacity": NSNumber(value: 100),
      "TimeRemaining": NSNumber(value: 148),
    ]

    /// The same machine on battery, with the current in the 32-bit unsigned
    /// encoding that needs correcting.
    nonisolated(unsafe) static let discharging: [String: Any] = [
      "InstantAmperage": NSNumber(value: Int64(4_294_965_796)),
      "Voltage": NSNumber(value: 11600),
      "AppleRawCurrentCapacity": NSNumber(value: 2500),
      "AppleRawMaxCapacity": NSNumber(value: 5357),
      "DesignCapacity": NSNumber(value: 6249),
      "CycleCount": NSNumber(value: 274),
      "Temperature": NSNumber(value: 3210),
      "IsCharging": false,
      "ExternalConnected": false,
      "CurrentCapacity": NSNumber(value: 47),
      "MaxCapacity": NSNumber(value: 100),
    ]
  }
}
