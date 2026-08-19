import Foundation
import StressKit

/// Renders a telemetry frame as text.
enum TelemetryRenderer {

  /// Full frame: per-core bars, per-level aggregates, and — when load is
  /// running — requested duty cycle beside observed utilization.
  static func frame(
    _ telemetry: Telemetry, topology: CoreTopology, width: Int, baseline: Double? = nil,
    mix: LoadMixer.Sample? = nil, governor: GovernorDecision? = nil
  ) -> [String] {
    var lines: [String] = []
    lines.append(header(telemetry, topology: topology))
    lines.append("")
    lines.append(contentsOf: perCore(telemetry, topology: topology, width: width))
    lines.append("")
    lines.append(contentsOf: byLevel(telemetry))

    if let governor, governor.thermalAction != .none {
      lines.append("")
      lines.append("  Governor")
      lines.append("    \(governor.reason)")
      lines.append(
        "    thermal ceiling \(percent(governor.thermalCeiling))   "
          + "requested \(percent(governor.requestedTarget))   "
          + "effective \(percent(governor.effectiveTarget))")
    }

    if let mix {
      lines.append("")
      lines.append(contentsOf: mixSection(mix, width: width))
    }

    lines.append("")
    lines.append(contentsOf: powerSection(telemetry))

    let sources = telemetry.activeSources.filter { $0.state == .running }
    if !sources.isEmpty {
      lines.append("")
      lines.append(contentsOf: load(sources, telemetry: telemetry, baseline: baseline))
    }
    return lines
  }

  /// Contributed versus synthetic load, as separate bars.
  static func mixSection(_ mix: LoadMixer.Sample, width: Int) -> [String] {
    let barWidth = max(10, min(40, width - 44))
    var lines = ["  Mix   target \(percent(mix.target))   baseline \(percent(mix.baseline))"]

    lines.append(
      "    contributed  \(bar(mix.split.contributedUtilization, width: barWidth)) "
        + "\(percent(mix.split.contributedUtilization))   real work")
    lines.append(
      "    synthetic    \(bar(mix.split.syntheticUtilization, width: barWidth)) "
        + "\(percent(mix.split.syntheticUtilization))   computes nothing")
    if mix.split.unattributedUtilization > 0.02 {
      lines.append(
        "    unattributed \(bar(mix.split.unattributedUtilization, width: barWidth)) "
          + "\(percent(mix.split.unattributedUtilization))   baseline drift")
    }
    lines.append(
      "    total        \(bar(mix.split.totalUtilization, width: barWidth)) "
        + "\(percent(mix.split.totalUtilization))   over baseline")

    var notes: [String] = []
    notes.append("duty \(percent(mix.decision.syntheticDuty))")
    if mix.decision.withinDeadband { notes.append("holding (within deadband)") }
    if mix.decision.slewLimited { notes.append("slew limited") }
    if mix.decision.contributedOverTarget { notes.append("contributed over target") }
    lines.append("    synthetic requested: " + notes.joined(separator: ", "))

    if let reason = mix.contributedIdleReason {
      // Surfaced rather than silently substituted: the user should know the
      // work they wanted to contribute is not happening.
      lines.append("    contributed idle: \(reason); synthetic is covering the target")
    }
    return lines
  }

  /// Battery and package power, or an explanation of why they are missing.
  static func powerSection(_ telemetry: Telemetry) -> [String] {
    var lines = ["  Power"]

    if let percent = telemetry.batteryPercent {
      var parts = [String(format: "    battery %.0f%%", percent)]
      if let raw = telemetry.batteryRawPercent {
        // The OS smooths the user-visible figure, so the two disagree. Both
        // are shown rather than picking one and being quietly wrong.
        parts.append(String(format: "raw %.1f%%", raw))
      }
      if telemetry.isConnectedToPower == true {
        parts.append(telemetry.isCharging == true ? "charging" : "on AC")
      } else {
        parts.append("on battery")
      }
      if let cycles = telemetry.cycleCount { parts.append("\(cycles) cycles") }
      if let temperature = telemetry.batteryTemperatureCelsius {
        parts.append(String(format: "%.1f C", temperature))
      }
      lines.append(parts.joined(separator: "   "))
    } else {
      lines.append("    battery      not present")
    }

    if let watts = telemetry.batteryWatts {
      // Sign convention: negative is discharging. Rendered as a direction so
      // nobody has to remember which way round it is.
      let direction = watts < 0 ? "discharging" : "charging"
      var line = String(format: "    %@  %.2f W", direction, abs(watts))
      if let smoothed = telemetry.batterySmoothedWatts {
        line += String(format: "   (median of 5: %.2f W)", abs(smoothed))
      }
      lines.append(line)
    }

    if let package = telemetry.packagePowerWatts {
      var parts = [String(format: "    package %.2f W", package)]
      if let gpu = telemetry.gpuPowerWatts { parts.append(String(format: "gpu %.2f W", gpu)) }
      if let other = telemetry.otherPowerWatts {
        parts.append(String(format: "other %.2f W", other))
      }
      lines.append(parts.joined(separator: "   "))
    } else if let reason = telemetry.powerAvailability, reason != "available" {
      lines.append("    package      unavailable: \(reason)")
    } else {
      lines.append("    package      unavailable: run with sudo for package power")
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

  private static func load(
    _ sources: [SourceStatus], telemetry: Telemetry, baseline: Double?
  ) -> [String] {
    var lines = ["  Load"]
    for source in sources {
      var parts = ["    \(source.sourceID)"]
      parts.append("requested \(percent(source.requestedLoad))")
      if let achieved = source.achievedLoad {
        parts.append("worker-measured \(percent(achieved))")
      }
      parts.append("observed \(percent(telemetry.cpu.systemWide))")
      if let baseline {
        // On a machine with a real working set the absolute figure is mostly
        // other people's work. The delta over baseline is stressd's share.
        parts.append(
          "delta \(percent(max(0, telemetry.cpu.systemWide - baseline)))")
      }
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
          var line = "      duty cycle period per level: \(periods) ms"
          if let measured = source.detail["coalescingMs"], !measured.isEmpty {
            // The period is derived from this, not hardcoded.
            line += "   (measured coalescing \(measured) ms)"
          }
          lines.append(line)
        }
      }
      if let abandoned = source.detail["abandonedCycles"], abandoned != "0" {
        lines.append("      \(abandoned) cycles abandoned (machine oversubscribed)")
      }
      if let gflops = source.detail["gflops"], gflops != "0.0" {
        lines.append("      \(gflops) GFLOPS FP64 (estimate, not a benchmark score)")
      }
      if let device = source.detail["gpuDevice"] {
        var parts = ["      GPU \(device)"]
        if let profile = source.detail["gpuProfile"] { parts.append("profile \(profile)") }
        if let requested = source.detail["gpuRequested"] {
          parts.append("requested \(requested)")
        }
        if let achieved = source.detail["gpuAchieved"] { parts.append("busy \(achieved)") }
        lines.append(parts.joined(separator: "   "))
        var second: [String] = []
        if let geometry = source.detail["gpuGeometry"] {
          second.append("threads/group x groups \(geometry)")
        }
        if let dispatches = source.detail["gpuDispatches"] {
          second.append("\(dispatches) dispatches")
        }
        if let gigaflops = source.detail["gpuGflops"] {
          second.append("\(gigaflops) GFLOPS FP32 (estimate)")
        }
        if !second.isEmpty { lines.append("        " + second.joined(separator: "   ")) }
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
