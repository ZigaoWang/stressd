import ArgumentParser
import Foundation
import StressKit

struct TopologyCommand: ParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "topology",
    abstract: "Report the CPU topology stressd will load.",
    discussion: """
      Everything is read from the kernel: hw.nperflevels for the number of core \
      classes, hw.perflevelN for their sizes and caches, hw.optional.arm.FEAT_* \
      for architectural features, and the IORegistry device tree for the logical \
      CPU numbers belonging to each class.

      That last part matters. hw.perflevelN is ordered fastest first, but the \
      Mach logical CPU numbering used by per-core telemetry puts the efficiency \
      cores first. stressd resolves the mapping from hardware rather than \
      assuming it, and tells you which source it used.
      """
  )

  @OptionGroup var output: OutputOptions

  @Flag(name: .long, help: "List every hw.optional flag, including absent ones.")
  var allFeatures = false

  func run() throws {
    let topology = try CoreTopologyDetector().detect()

    if output.json {
      print(try JSONReport.encode(topology))
    } else {
      print(Self.render(topology, includeAbsentFeatures: allFeatures))
    }
  }

  // MARK: - Text rendering

  static func render(_ topology: CoreTopology, includeAbsentFeatures: Bool) -> String {
    var lines: [String] = []

    lines.append(contentsOf: renderSummary(topology))
    lines.append("")
    lines.append(contentsOf: renderLevels(topology))
    lines.append("")
    lines.append(contentsOf: renderFeatures(topology, includeAbsent: includeAbsentFeatures))

    if !topology.isNativeAppleSilicon {
      lines.append("")
      lines.append(
        "WARNING  Not running natively on Apple silicon. Load and power numbers")
      lines.append(
        "         from a translated process are not meaningful.")
    }
    return lines.joined(separator: "\n")
  }

  private static func renderSummary(_ topology: CoreTopology) -> [String] {
    var lines = ["Machine"]
    lines.append(Formatting.field("  Model", topology.machineModel))
    if let chip = topology.chipName {
      lines.append(Formatting.field("  Chip", chip))
    }
    lines.append(Formatting.field("  Memory", Formatting.bytes(topology.physicalMemoryBytes)))
    lines.append(
      Formatting.field(
        "  Cores",
        "\(topology.logicalCoreCount) logical / \(topology.physicalCoreCount) physical "
          + "across \(topology.performanceLevels.count) performance "
          + (topology.performanceLevels.count == 1 ? "level" : "levels")))
    if let line = topology.cacheLineSizeBytes {
      lines.append(Formatting.field("  Cache line", "\(line) B"))
    }
    lines.append(
      Formatting.field("  CPU index map", topology.cpuIndexMappingSource.explanation))
    return lines
  }

  private static func renderLevels(_ topology: CoreTopology) -> [String] {
    var lines = ["Performance levels (level 0 is fastest)"]

    for level in topology.performanceLevels {
      lines.append("")
      lines.append(
        "  Level \(level.index)  \(level.name)")
      lines.append(
        Formatting.field(
          "    Cores", "\(level.logicalCoreCount) logical / \(level.physicalCoreCount) physical",
          keyWidth: 20))
      lines.append(
        Formatting.field(
          "    Logical CPUs", Formatting.cpuRanges(level.contiguousCPURanges), keyWidth: 20))

      var cache: [String] = []
      if let l1i = level.l1InstructionCacheBytes { cache.append("L1i \(Formatting.bytes(l1i))") }
      if let l1d = level.l1DataCacheBytes { cache.append("L1d \(Formatting.bytes(l1d))") }
      if let l2 = level.l2CacheBytes {
        let shared = level.coresPerL2.map { " (shared by \($0))" } ?? ""
        cache.append("L2 \(Formatting.bytes(l2))\(shared)")
      }
      if !cache.isEmpty {
        lines.append(
          Formatting.field("    Cache", cache.joined(separator: "   "), keyWidth: 20))
      }
      if let frequency = Formatting.frequency(level.nominalFrequencyHz) {
        lines.append(Formatting.field("    Nominal clock", frequency, keyWidth: 20))
      }
      lines.append(
        Formatting.field("    QoS hint", ".\(level.qosHint.rawValue)", keyWidth: 20))
    }

    if topology.isHeterogeneous {
      lines.append("")
      lines.append("  QoS is a scheduler hint, not thread affinity. macOS has no public API")
      lines.append("  for pinning work to a core class, so stressd reports requested placement")
      lines.append("  alongside observed per-core utilization and lets you see the difference.")
    }
    return lines
  }

  private static func renderFeatures(_ topology: CoreTopology, includeAbsent: Bool) -> [String] {
    let features = topology.features
    var lines = [
      "CPU features (\(features.supported.count) present of \(features.flags.count) reported)"
    ]
    lines.append(contentsOf: Formatting.columns(features.supported, indent: "  "))

    if includeAbsent, !features.unsupported.isEmpty {
      lines.append("")
      lines.append("Absent (\(features.unsupported.count))")
      lines.append(contentsOf: Formatting.columns(features.unsupported, indent: "  "))
    }

    if includeAbsent, !features.scalars.isEmpty {
      lines.append("")
      lines.append("Scalars")
      for key in features.scalars.keys.sorted() {
        lines.append(Formatting.field("  \(key)", "\(features.scalars[key] ?? 0)", keyWidth: 24))
      }
    }
    return lines
  }
}
