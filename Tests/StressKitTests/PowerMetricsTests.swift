import Foundation
import Testing

@testable import StressKit

@Suite("powermetrics parsing")
struct PowerMetricsTests {

  /// One `-f plist` frame, in the shape powermetrics emits on Apple silicon:
  /// power in milliwatts, per-cluster entries under `processor`.
  static func frame(cpuMilliwatts: Double, gpuMilliwatts: Double) -> Data {
    // Serialising a literal dictionary cannot fail; an empty Data would make
    // every assertion below fail loudly anyway.
    let root: [String: Any] = [
      "processor": [
        "cpu_power": cpuMilliwatts,
        "gpu_power": gpuMilliwatts,
        "ane_power": 0.0,
        "combined_power": cpuMilliwatts + gpuMilliwatts,
        "clusters": [
          ["name": "E-Cluster", "power": cpuMilliwatts * 0.2],
          ["name": "P-Cluster", "power": cpuMilliwatts * 0.8],
        ],
      ],
      "elapsed_ns": 1_000_000_000,
    ]
    return
      (try? PropertyListSerialization.data(
        fromPropertyList: root, format: .xml, options: 0)) ?? Data()
  }

  @Test("A complete frame yields watts, converted from milliwatts")
  func parsesFrame() throws {
    let sample = try #require(
      PowerMetricsParser.parse(frame: Self.frame(cpuMilliwatts: 12_500, gpuMilliwatts: 3_200)))

    #expect(abs((sample.cpuWatts ?? 0) - 12.5) < 0.001)
    #expect(abs((sample.gpuWatts ?? 0) - 3.2) < 0.001)
    #expect(abs((sample.combinedWatts ?? 0) - 15.7) < 0.001)
    #expect(abs((sample.clusterWatts["P-Cluster"] ?? 0) - 10.0) < 0.001)
    #expect(abs((sample.clusterWatts["E-Cluster"] ?? 0) - 2.5) < 0.001)
  }

  @Test("A truncated frame is rejected rather than half-parsed")
  func truncatedFrameIsRejected() {
    // The expected case for a streaming read: the pipe delivered half a plist.
    let complete = Self.frame(cpuMilliwatts: 10_000, gpuMilliwatts: 1_000)
    let truncated = complete.prefix(complete.count / 2)
    #expect(PowerMetricsParser.parse(frame: Data(truncated)) == nil)
  }

  @Test("Empty and garbage input produce nothing")
  func junkInput() {
    #expect(PowerMetricsParser.parse(frame: Data()) == nil)
    #expect(PowerMetricsParser.parse(frame: Data("not a plist".utf8)) == nil)
    #expect(PowerMetricsParser.parse(frame: Data(repeating: 0, count: 16)) == nil)
  }

  @Test("The stream splits on NUL and carries an incomplete tail forward")
  func drainSplitsFrames() {
    var buffer = Data()
    buffer.append(Self.frame(cpuMilliwatts: 5_000, gpuMilliwatts: 500))
    buffer.append(0x00)
    buffer.append(Self.frame(cpuMilliwatts: 9_000, gpuMilliwatts: 900))
    buffer.append(0x00)

    let complete = PowerMetricsParser.drain(buffer: buffer)
    #expect(complete.samples.count == 2)
    #expect(abs((complete.samples[1].cpuWatts ?? 0) - 9.0) < 0.001)
    #expect(complete.remainder.isEmpty)
  }

  @Test("A partial trailing frame is held until the rest arrives")
  func drainCarriesPartialFrame() {
    let first = Self.frame(cpuMilliwatts: 5_000, gpuMilliwatts: 500)
    let second = Self.frame(cpuMilliwatts: 9_000, gpuMilliwatts: 900)

    var buffer = Data()
    buffer.append(first)
    buffer.append(0x00)
    buffer.append(second.prefix(second.count / 2))

    let firstPass = PowerMetricsParser.drain(buffer: buffer)
    #expect(firstPass.samples.count == 1)
    #expect(!firstPass.remainder.isEmpty, "the partial frame must be carried, not dropped")

    // The next read completes it.
    var continued = firstPass.remainder
    continued.append(second.suffix(second.count - second.count / 2))
    continued.append(0x00)

    let secondPass = PowerMetricsParser.drain(buffer: continued)
    #expect(secondPass.samples.count == 1)
    #expect(abs((secondPass.samples[0].cpuWatts ?? 0) - 9.0) < 0.001)
  }

  @Test("Missing keys degrade to nil instead of zero")
  func missingKeys() {
    let sample = PowerMetricsParser.sample(from: ["processor": ["cpu_power": 8_000.0]])
    #expect(abs((sample.cpuWatts ?? 0) - 8.0) < 0.001)
    #expect(sample.gpuWatts == nil)
    // With no combined_power reported, it falls back to the sum of the parts.
    #expect(abs((sample.combinedWatts ?? 0) - 8.0) < 0.001)
    #expect(sample.clusterWatts.isEmpty)
  }

  @Test("Every availability case explains itself in terms the user can act on")
  func availabilityMessages() {
    #expect(PowerAvailability.requiresRoot.explanation.contains("sudo"))
    #expect(PowerAvailability.toolMissing.explanation.contains("powermetrics"))
    #expect(PowerAvailability.failed("boom").explanation.contains("boom"))
  }
}

@Suite("Telemetry assembly")
struct TelemetryAssemblyTests {

  private func sample(idle: Double) -> CPUSample {
    let cores = (0..<4).map {
      CoreUtilization(cpu: $0, user: 1 - idle, system: 0, nice: 0, idle: idle)
    }
    return CPUSample(timestamp: Date(), interval: 1, perCore: cores, byPerfLevel: [])
  }

  @Test("Everything still works when powermetrics is unavailable")
  func gracefulDegradationWithoutPowerMetrics() {
    let telemetry = TelemetryMonitor.assemble(
      cpu: sample(idle: 0.5),
      battery: BatteryReading(reportedPercent: 80, isConnectedToPower: false, watts: -12),
      smoothedWatts: -12,
      power: nil,
      availability: .requiresRoot,
      statuses: [])

    // The CPU half is untouched, the power half is absent and explains itself.
    #expect(abs(telemetry.cpu.systemWide - 0.5) < 0.001)
    #expect(telemetry.packagePowerWatts == nil)
    #expect(telemetry.gpuPowerWatts == nil)
    #expect(telemetry.otherPowerWatts == nil)
    #expect(telemetry.powerAvailability?.contains("sudo") == true)
    // Battery telemetry does not need root, so it is still there.
    #expect(telemetry.batteryWatts == -12)
    #expect(abs((telemetry.systemDrawWatts ?? 0) - 12) < 0.001)
  }

  @Test("Other power is system draw minus package draw, on battery")
  func otherPowerOnBattery() {
    let other = TelemetryMonitor.otherWatts(
      battery: BatteryReading(isConnectedToPower: false, watts: -20),
      smoothedWatts: -20,
      power: PowerSample(cpuWatts: 12, gpuWatts: 2, combinedWatts: 14))
    // 20 W leaving the battery, 14 W of it the SoC: the rest is the display,
    // radios and storage.
    #expect(abs((other ?? 0) - 6) < 0.001)
  }

  @Test("Other power is not derivable on AC")
  func otherPowerOnAC() {
    // On AC the battery figure describes charging, not consumption, so there
    // is nothing to subtract from.
    let other = TelemetryMonitor.otherWatts(
      battery: BatteryReading(isConnectedToPower: true, watts: 39),
      smoothedWatts: 39,
      power: PowerSample(cpuWatts: 12, combinedWatts: 12))
    #expect(other == nil)
  }

  @Test("A package reading larger than system draw clamps to zero, not negative")
  func otherPowerClamped() {
    // The two sources are sampled a moment apart, so a transient can invert
    // them briefly.
    let other = TelemetryMonitor.otherWatts(
      battery: BatteryReading(isConnectedToPower: false, watts: -10),
      smoothedWatts: -10,
      power: PowerSample(cpuWatts: 14, combinedWatts: 14))
    #expect(other == 0)
  }

  @Test("System draw is nil on AC and positive on battery")
  func systemDrawSign() {
    let onBattery = TelemetryMonitor.assemble(
      cpu: sample(idle: 0.9),
      battery: BatteryReading(isConnectedToPower: false, watts: -8),
      smoothedWatts: -8, power: nil, availability: nil, statuses: [])
    #expect(abs((onBattery.systemDrawWatts ?? 0) - 8) < 0.001)

    let onAC = TelemetryMonitor.assemble(
      cpu: sample(idle: 0.9),
      battery: BatteryReading(isConnectedToPower: true, watts: 39),
      smoothedWatts: 39, power: nil, availability: nil, statuses: [])
    #expect(onAC.systemDrawWatts == nil)
  }
}
