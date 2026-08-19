import Foundation

/// Builds a `CoreTopology` by reading the kernel. Nothing here assumes a chip,
/// a core count, or a number of performance levels.
public struct CoreTopologyDetector: Sendable {

  private let sysctl: any SysctlReading
  private let clusterMap: (any CPUClusterMapping)?

  /// - Parameters:
  ///   - sysctl: Kernel reader. Injected so tests can replay recorded
  ///     machines.
  ///   - clusterMap: Device tree reader, or `nil` to force the inferred CPU
  ///     index mapping.
  public init(
    sysctl: any SysctlReading = LiveSysctl(),
    clusterMap: (any CPUClusterMapping)? = IORegistryCPUClusterMap()
  ) {
    self.sysctl = sysctl
    self.clusterMap = clusterMap
  }

  public func detect() throws -> CoreTopology {
    let logicalCoreCount = Int(try sysctl.integer("hw.logicalcpu"))
    let physicalCoreCount = Int(
      sysctl.optionalInteger("hw.physicalcpu") ?? Int64(logicalCoreCount))

    let levelSpecs = readLevelSpecs(logicalCoreCount: logicalCoreCount)
    let assignment = CPUIndexAssigner.assign(
      levels: levelSpecs.map {
        CPUIndexAssigner.LevelSpec(name: $0.name, logicalCoreCount: $0.logicalCoreCount)
      },
      clusterAssignments: try? clusterMap?.assignments(),
      totalLogicalCores: logicalCoreCount)

    let levels = levelSpecs.enumerated().map { index, spec in
      PerformanceLevel(
        index: index,
        name: spec.name,
        logicalCoreCount: spec.logicalCoreCount,
        physicalCoreCount: spec.physicalCoreCount,
        logicalCPUIDs: assignment.logicalCPUIDsByLevel.indices.contains(index)
          ? assignment.logicalCPUIDsByLevel[index] : [],
        l1InstructionCacheBytes: spec.l1InstructionCacheBytes,
        l1DataCacheBytes: spec.l1DataCacheBytes,
        l2CacheBytes: spec.l2CacheBytes,
        coresPerL2: spec.coresPerL2,
        nominalFrequencyHz: spec.nominalFrequencyHz,
        qosHint: QoSHint.biasing(towardLevel: index, of: levelSpecs.count))
    }

    return CoreTopology(
      machineModel: sysctl.optionalString("hw.model") ?? "unknown",
      chipName: sysctl.optionalString("machdep.cpu.brand_string"),
      logicalCoreCount: logicalCoreCount,
      physicalCoreCount: physicalCoreCount,
      physicalMemoryBytes: (try? sysctl.unsignedInteger("hw.memsize")) ?? 0,
      cacheLineSizeBytes: sysctl.optionalInteger("hw.cachelinesize").map(Int.init),
      pageSizeBytes: sysctl.optionalInteger("hw.pagesize").map(Int.init),
      performanceLevels: levels,
      cpuIndexMappingSource: assignment.source,
      features: readFeatures(),
      isNativeAppleSilicon: readIsNativeAppleSilicon())
  }

  // MARK: - Performance levels

  private struct LevelSpec {
    let name: String
    let logicalCoreCount: Int
    let physicalCoreCount: Int
    let l1InstructionCacheBytes: Int?
    let l1DataCacheBytes: Int?
    let l2CacheBytes: Int?
    let coresPerL2: Int?
    let nominalFrequencyHz: Int?
  }

  private func readLevelSpecs(logicalCoreCount: Int) -> [LevelSpec] {
    let declaredLevels = Int(sysctl.optionalInteger("hw.nperflevels") ?? 0)

    // A machine with no hw.nperflevels (or one level) is homogeneous. Model it
    // as a single level so the rest of the code has one shape to handle.
    guard declaredLevels > 1 else {
      return [
        LevelSpec(
          name: "CPU",
          logicalCoreCount: logicalCoreCount,
          physicalCoreCount: Int(
            sysctl.optionalInteger("hw.physicalcpu") ?? Int64(logicalCoreCount)),
          l1InstructionCacheBytes: sysctl.optionalInteger("hw.l1icachesize").map(Int.init),
          l1DataCacheBytes: sysctl.optionalInteger("hw.l1dcachesize").map(Int.init),
          l2CacheBytes: sysctl.optionalInteger("hw.l2cachesize").map(Int.init),
          coresPerL2: nil,
          nominalFrequencyHz: sysctl.optionalInteger("hw.cpufrequency").map(Int.init))
      ]
    }

    return (0..<declaredLevels).compactMap { index in
      let prefix = "hw.perflevel\(index)"
      guard let logical = sysctl.optionalInteger("\(prefix).logicalcpu") else { return nil }
      return LevelSpec(
        name: sysctl.optionalString("\(prefix).name") ?? "Level \(index)",
        logicalCoreCount: Int(logical),
        physicalCoreCount: Int(sysctl.optionalInteger("\(prefix).physicalcpu") ?? logical),
        l1InstructionCacheBytes: sysctl.optionalInteger("\(prefix).l1icachesize").map(Int.init),
        l1DataCacheBytes: sysctl.optionalInteger("\(prefix).l1dcachesize").map(Int.init),
        l2CacheBytes: sysctl.optionalInteger("\(prefix).l2cachesize").map(Int.init),
        coresPerL2: sysctl.optionalInteger("\(prefix).cpusperl2").map(Int.init),
        nominalFrequencyHz: sysctl.optionalInteger("\(prefix).nominal_frequency").map(Int.init))
    }
  }

  // MARK: - Features

  private func readFeatures() -> CPUFeatureSet {
    let names = sysctl.names(under: "hw.optional")
    let entries: [(name: String, value: Int64)] = names.compactMap { name in
      guard let value = sysctl.optionalInteger(name) else { return nil }
      return (name, value)
    }
    return CPUFeatureSet.make(fromOptionalSubtree: entries)
  }

  // MARK: - Rosetta

  /// An arm64 binary is never translated, so the architecture check is the
  /// real answer. `sysctl.proc_translated` is read as a cross-check so a
  /// mistakenly x86_64 build reports honestly instead of silently producing
  /// meaningless numbers under Rosetta.
  private func readIsNativeAppleSilicon() -> Bool {
    #if arch(arm64)
      return (sysctl.optionalInteger("sysctl.proc_translated") ?? 0) == 0
    #else
      return false
    #endif
  }
}
