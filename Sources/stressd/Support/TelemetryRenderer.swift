import Foundation
import StressKit

/// Renders a telemetry frame as text.
enum TelemetryRenderer {

  /// Full frame: per-core bars, per-level aggregates, and — when load is
  /// running — requested duty cycle beside observed utilization.
  static func frame(_ telemetry: Telemetry, topology: CoreTopology, width: Int) -> [String] {
    var lines: [String] = []
    lines.append(header(telemetry, topology: topology))
    lines.append("")
    lines.append(contentsOf: perCore(telemetry, topology: topology, width: width))
    lines.append("")
    lines.append(contentsOf: byLevel(telemetry))

    let sources = telemetry.activeSources.filter { $0.state == .running }
    if !sources.isEmpty {
      lines.append("")
      lines.append(contentsOf: load(sources, telemetry: telemetry))
    }
    return lines
  }

  /// One line per sample, for non-interactive output.
  static func line(_ telemetry: Telemetry) -> String {
    let levels =
      telemetry.cpu.byPerfLevel
      .map { "\($0.name.prefix(1)) \(percent($0.busy))" }
      .joined(separator: "  ")
    let requested =
      telemetry.activeSources
      .filter { $0.state == .running }
      .map { "\($0.sourceID) \(percent($0.requestedLoad))" }
      .joined(separator: "  ")

    var parts = [
      Self.timestamp(telemetry.timestamp),
      "total \(percent(telemetry.cpu.systemWide))",
      levels,
      "thermal \(telemetry.thermalState.rawValue)",
    ]
    if !requested.isEmpty { parts.append("requested \(requested)") }
    return parts.filter { !$0.isEmpty }.joined(separator: "  ")
  }

  // MARK: - Sections

  private static func header(_ telemetry: Telemetry, topology: CoreTopology) -> String {
    let chip = topology.chipName ?? topology.machineModel
    let thermal = telemetry.thermalState.rawValue
    let marker = telemetry.thermalState.requiresBackOff ? " !" : ""
    return
      "\(chip)   total \(percent(telemetry.cpu.systemWide))   "
      + "thermal \(thermal)\(marker)   \(timestamp(telemetry.timestamp))"
  }

  private static func perCore(
    _ telemetry: Telemetry, topology: CoreTopology, width: Int
  )
    -> [String]
  {
    // Label each core with the class it belongs to, so the display reads in
    // terms of P and E rather than raw logical numbers.
    let levelForCPU = Dictionary(
      uniqueKeysWithValues: topology.performanceLevels.flatMap { level in
        level.logicalCPUIDs.map { ($0, level) }
      })

    let barWidth = max(10, min(40, width - 34))
    return telemetry.cpu.perCore.map { core in
      let level = levelForCPU[core.cpu]
      let tag = level.map { String($0.name.prefix(1)).uppercased() } ?? "?"
      let label = String(format: "  cpu%-3d %@", core.cpu, tag)
      let detail = String(
        format: "usr %@  sys %@", percent(core.user + core.nice), percent(core.system))
      return "\(label)  \(bar(core.busy, width: barWidth)) \(percent(core.busy))  \(detail)"
    }
  }

  private static func byLevel(_ telemetry: Telemetry) -> [String] {
    telemetry.cpu.byPerfLevel.map { level in
      String(
        format: "  %-12@ %2d cores   busy %@   usr %@  sys %@", level.name as NSString,
        level.coreCount, percent(level.busy), percent(level.user + level.nice),
        percent(level.system))
    }
  }

  private static func load(_ sources: [SourceStatus], telemetry: Telemetry) -> [String] {
    var lines = ["  Load"]
    for source in sources {
      var parts = ["    \(source.sourceID)"]
      parts.append("requested \(percent(source.requestedLoad))")
      if let achieved = source.achievedLoad {
        parts.append("worker-measured \(percent(achieved))")
      }
      parts.append("observed \(percent(telemetry.cpu.systemWide))")
      parts.append("\(source.threadCount) threads")
      lines.append(parts.joined(separator: "   "))

      if let placement = source.detail["placement"], let hint = source.detail["qosHint"] {
        // Requested placement next to where the work landed. QoS is a hint, so
        // this line is the evidence for whether it was honoured.
        let observed =
          telemetry.cpu.byPerfLevel
          .map { "\($0.name) \(percent($0.busy))" }
          .joined(separator: ", ")
        lines.append("      requested \(placement) via .\(hint)   ->   observed \(observed)")
        if let periods = source.detail["periodsMs"], !periods.isEmpty {
          lines.append("      duty cycle period per level: \(periods) ms")
        }
      }
      if let abandoned = source.detail["abandonedCycles"], abandoned != "0" {
        lines.append("      \(abandoned) cycles abandoned (machine oversubscribed)")
      }
      if let gflops = source.detail["gflops"] {
        lines.append("      \(gflops) GFLOPS FP64 (estimate)")
      }
    }
    return lines
  }

  // MARK: - Primitives

  static func bar(_ fraction: Double, width: Int) -> String {
    let clamped = min(max(fraction, 0), 1)
    let filled = Int((Double(width) * clamped).rounded())
    return "[" + String(repeating: "#", count: filled)
      + String(repeating: ".", count: max(0, width - filled)) + "]"
  }

  static func percent(_ fraction: Double) -> String {
    String(format: "%5.1f%%", min(max(fraction, 0), 1) * 100)
  }

  private static func timestamp(_ date: Date) -> String {
    let formatter = DateFormatter()
    formatter.dateFormat = "HH:mm:ss"
    return formatter.string(from: date)
  }
}
