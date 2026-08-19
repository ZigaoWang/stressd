import ArgumentParser
import Foundation
import StressKit

struct WatchCommand: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "watch",
    abstract: "Show live telemetry. Applies no load.",
    discussion: """
      Per-core utilization comes from host_processor_info, sampled directly \
      rather than parsed out of top, and is aggregated by performance level \
      using the CPU index map from 'stressd topology'.

      Power and battery figures arrive in a later step and read as absent \
      until then.
      """
  )

  @OptionGroup var output: OutputOptions

  @Option(name: .long, help: "Seconds between samples. Minimum 0.1.")
  var interval: Double = TelemetryMonitor.defaultInterval

  @Option(name: .long, help: "Stop after this long, e.g. 30s, 5m, 1h.")
  var duration: String?

  func run() async throws {
    let topology = try CoreTopologyDetector().detect()
    let deadline = try duration.map { Date().addingTimeInterval(try DurationParser.parse($0)) }

    CleanupRegistry.installAtExitBackstop()
    let renderer = InPlaceRenderer()
    CleanupRegistry.shared.register("restore cursor") { renderer.finish() }

    let monitor = TelemetryMonitor(topology: topology, interval: interval, power: PowerMonitor())
    let emitJSON = output.json

    let work = Task {
      for await telemetry in await monitor.stream() {
        if emitJSON {
          print(try JSONReport.encodeLine(telemetry))
        } else {
          renderer.render(
            TelemetryRenderer.frame(telemetry, topology: topology, width: Terminal.columns))
        }
        if let deadline, Date() >= deadline { break }
      }
    }

    let interrupt = InterruptHandler { work.cancel() }
    interrupt.install()

    // A cancelled task is the expected way out, not a failure.
    _ = try? await work.value
    CleanupRegistry.shared.run()
  }
}
