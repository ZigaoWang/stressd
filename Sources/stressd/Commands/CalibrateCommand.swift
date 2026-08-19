import ArgumentParser
import Foundation
import StressKit

struct CalibrateCommand: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "calibrate",
    abstract: "Sweep load and record power, producing a load-to-power curve.",
    discussion: """
      Run this on battery. On AC the only power figure available is the SoC \
      package, which misses the display, the radios, and everything else; on \
      battery the discharge rate is the whole machine.

      The methodology matters more than the numbers. Points are measured in \
      random order, because a monotonic sweep would measure the top of the \
      range on a machine that has been hot for ten minutes and read low from \
      throttling. Each point gets a settling window that is discarded, and a \
      cooldown that waits for the thermal state to return to nominal. A \
      baseline is captured before the sweep and subtracted from every point, \
      so the curve measures stressd's load rather than whatever else the \
      machine happens to be doing.

      The curve is written to ~/.config/stressd/power-curve.json so the power \
      governor can seed itself from it instead of learning cold.
      """
  )

  @OptionGroup var output: OutputOptions

  @Option(name: .long, help: "Load percentages to measure, comma separated.")
  var points: String = "0,10,20,30,40,50,60,70,80,90,100"

  @Option(name: .long, help: "How long to average at each point, e.g. 30s.")
  var dwell: String = "30s"

  @Option(name: .long, help: "Discarded after each load change, e.g. 5s.")
  var settle: String = "5s"

  @Option(name: .long, help: "Minimum idle time between points, e.g. 60s.")
  var cooldown: String = "60s"

  @Option(name: .long, help: "Write CSV to this path in addition to the cached JSON.")
  var outputPath: String?

  @Flag(name: .long, help: "Do not write the curve to ~/.config/stressd.")
  var noCache = false

  @Flag(name: .long, help: "Proceed even when running on AC power.")
  var allowAC = false

  func run() async throws {
    let topology = try CoreTopologyDetector().detect()
    let plan = CalibrationPlan(
      points: try Self.parsePoints(points),
      dwellSeconds: try DurationParser.parse(dwell),
      settleSeconds: try DurationParser.parse(settle),
      cooldownSeconds: try DurationParser.parse(cooldown))

    CleanupRegistry.installAtExitBackstop()

    let assertion = try? PowerAssertion.preventIdleSleep(reason: "stressd is calibrating")
    CleanupRegistry.shared.register("release sleep assertion") { assertion?.release() }

    let battery = BatteryMonitor()
    let power = PowerMonitor(intervalMilliseconds: 1000)
    // Killed on every exit path, including the atexit backstop.
    CleanupRegistry.shared.register("stop powermetrics") { power.stop() }

    let onBattery = await Self.isOnBattery(battery)
    if !onBattery, !allowAC {
      throw ValidationError(
        """
        Not on battery. The curve would only cover SoC package power, which \
        misses the display and radios, and package power additionally needs \
        root. Unplug the adapter, or pass --allow-ac to measure anyway.
        """)
    }

    let source = SyntheticSource(topology: topology)
    CleanupRegistry.shared.register("stop synthetic workers") { source.emergencyStop() }

    let calibrator = PowerCalibrator(
      topology: topology, plan: plan, source: source, battery: battery, power: power)

    let quiet = output.json
    // A sweep has no partial result worth keeping, so an interrupt tears down
    // and leaves rather than trying to finish. Cleanup restores the machine.
    let interrupt = InterruptHandler {
      CleanupRegistry.shared.run()
      Foundation.exit(130)
    }
    interrupt.install()

    let curve = try await calibrator.run { progress in
      guard !quiet else { return }
      if let line = Self.describe(progress) {
        FileHandle.standardError.write(Data((line + "\n").utf8))
      }
    }

    CleanupRegistry.shared.run()

    if !noCache {
      try? curve.write()
    }
    if let outputPath {
      try curve.csvRepresentation().write(
        toFile: outputPath, atomically: true, encoding: .utf8)
    }

    if output.json {
      print(try JSONReport.encode(curve))
    } else {
      print(CurveRenderer.summary(curve, plot: Terminal.isInteractive))
      if !noCache {
        print("\nCurve cached at \(PowerCurve.defaultURL.path)")
      }
      if let outputPath {
        print("CSV written to \(outputPath)")
      }
    }
  }

  // MARK: - Helpers

  static func parsePoints(_ text: String) throws -> [Double] {
    let parsed = text.split(separator: ",").map {
      $0.trimmingCharacters(in: .whitespaces)
    }
    var loads: [Double] = []
    for entry in parsed {
      guard let value = Double(entry), value >= 0, value <= 100 else {
        throw ValidationError("'\(entry)' is not a load percentage between 0 and 100")
      }
      loads.append(value / 100)
    }
    guard loads.count >= 2 else {
      throw ValidationError("--points needs at least two values")
    }
    return loads
  }

  static func isOnBattery(_ battery: BatteryMonitor) async -> Bool {
    guard let reading = await battery.read() else { return false }
    return reading.reading.isConnectedToPower == false
  }

  static func describe(_ progress: CalibrationProgress) -> String? {
    switch progress {
    case .started(let total, let seconds, let source):
      return """
        Calibrating \(total) points, up to \(DurationParser.format(seconds)).
        Power source: \(source.explanation)
        Measurement order is randomised so accumulated heat does not correlate \
        with load.
        """
    case .baseline(let utilization, let watts):
      var line = "Baseline: \(TelemetryRenderer.percent(utilization)) utilization"
      if let watts { line += String(format: ", %.2f W", watts) }
      if utilization > PowerCurve.noisyBaselineThreshold {
        line += "  [noisy: this machine is busy, curve quality will suffer]"
      }
      return line
    case .cooling(let index, let total, let state, let waited):
      return
        "  [\(index + 1)/\(total)] cooling, thermal \(state.rawValue), "
        + "\(Int(waited))s elapsed"
    case .settling(let index, let total, let load):
      return
        "  [\(index + 1)/\(total)] settling at \(TelemetryRenderer.percent(load))"
    case .measuring(let index, let total, let load):
      return
        "  [\(index + 1)/\(total)] measuring \(TelemetryRenderer.percent(load))"
    case .measured(let point):
      var line = "  -> \(TelemetryRenderer.percent(point.requestedLoad))"
      if let watts = point.incrementalWatts {
        line += String(format: "  %+.2f W over baseline", watts)
      }
      if point.isSuspect { line += "  [suspect: \(point.thermalState.rawValue)]" }
      return line
    case .finished:
      return nil
    }
  }
}
