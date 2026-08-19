import Foundation

/// How the logical CPU numbers in `PerformanceLevel.logicalCPUIDs` were
/// determined.
public enum CPUIndexMappingSource: String, Sendable, Codable {
  /// Device tree `cluster-type` matched a performance level by name.
  case ioRegistryByClusterName
  /// Device tree clusters matched performance levels by core count.
  case ioRegistryByCoreCount
  /// Device tree clusters matched performance levels by cluster order,
  /// assuming the slowest cluster is numbered first.
  case ioRegistryByClusterOrder
  /// The device tree was unavailable. Indices were assigned on the assumption
  /// that logical CPU numbering runs slowest-first, which holds on every Apple
  /// silicon part shipped so far but is not contractual.
  case inferred

  /// Whether the mapping came from hardware rather than an assumption.
  public var isAuthoritative: Bool { self != .inferred }

  public var explanation: String {
    switch self {
    case .ioRegistryByClusterName:
      return "IORegistry device tree, clusters matched to performance levels by name"
    case .ioRegistryByCoreCount:
      return "IORegistry device tree, clusters matched to performance levels by core count"
    case .ioRegistryByClusterOrder:
      return "IORegistry device tree, clusters matched to performance levels by cluster order"
    case .inferred:
      return "inferred from performance level sizes (device tree unavailable)"
    }
  }
}

/// One `hw.perflevelN` entry, with the logical CPU numbers that belong to it.
///
/// Level 0 is always the fastest, matching the kernel's ordering.
public struct PerformanceLevel: Sendable, Codable, Equatable, Identifiable {
  /// `N` in `hw.perflevelN`. 0 is the fastest level.
  public let index: Int
  /// `hw.perflevelN.name`, e.g. "Performance" or "Efficiency".
  public let name: String
  public let logicalCoreCount: Int
  public let physicalCoreCount: Int
  /// The logical CPU numbers on this level, ascending. These are the indices
  /// used by `host_processor_info`, so per-core telemetry lines up with them
  /// directly.
  public let logicalCPUIDs: [Int]
  public let l1InstructionCacheBytes: Int?
  public let l1DataCacheBytes: Int?
  public let l2CacheBytes: Int?
  /// Cores sharing an L2, i.e. the cluster width.
  public let coresPerL2: Int?
  /// Nominal core frequency in Hz, when the kernel publishes one.
  public let nominalFrequencyHz: Int?
  /// The QoS class that biases work onto this level. A hint, not a guarantee.
  public let qosHint: QoSHint

  public var id: Int { index }

  /// The clusters on this level, as contiguous runs of logical CPU numbers.
  /// Usually one run; an M4 Max style part with two P clusters yields two.
  public var contiguousCPURanges: [ClosedRange<Int>] {
    var ranges: [ClosedRange<Int>] = []
    for cpu in logicalCPUIDs {
      if let last = ranges.last, last.upperBound + 1 == cpu {
        ranges[ranges.count - 1] = last.lowerBound...cpu
      } else {
        ranges.append(cpu...cpu)
      }
    }
    return ranges
  }

  public init(
    index: Int,
    name: String,
    logicalCoreCount: Int,
    physicalCoreCount: Int,
    logicalCPUIDs: [Int],
    l1InstructionCacheBytes: Int? = nil,
    l1DataCacheBytes: Int? = nil,
    l2CacheBytes: Int? = nil,
    coresPerL2: Int? = nil,
    nominalFrequencyHz: Int? = nil,
    qosHint: QoSHint
  ) {
    self.index = index
    self.name = name
    self.logicalCoreCount = logicalCoreCount
    self.physicalCoreCount = physicalCoreCount
    self.logicalCPUIDs = logicalCPUIDs
    self.l1InstructionCacheBytes = l1InstructionCacheBytes
    self.l1DataCacheBytes = l1DataCacheBytes
    self.l2CacheBytes = l2CacheBytes
    self.coresPerL2 = coresPerL2
    self.nominalFrequencyHz = nominalFrequencyHz
    self.qosHint = qosHint
  }
}

/// Everything stressd knows about the CPU it is about to load.
///
/// Read from the kernel, never assumed. Nothing here hardcodes a chip name or
/// a core count.
public struct CoreTopology: Sendable, Codable, Equatable {
  /// `hw.model`, e.g. "Mac15,6".
  public let machineModel: String
  /// `machdep.cpu.brand_string`, e.g. "Apple M3 Pro".
  public let chipName: String?
  public let logicalCoreCount: Int
  public let physicalCoreCount: Int
  public let physicalMemoryBytes: UInt64
  public let cacheLineSizeBytes: Int?
  public let pageSizeBytes: Int?
  /// Fastest level first.
  public let performanceLevels: [PerformanceLevel]
  public let cpuIndexMappingSource: CPUIndexMappingSource
  public let features: CPUFeatureSet
  /// True when the process is running natively on arm64 rather than under
  /// Rosetta. Load numbers taken under translation are meaningless.
  public let isNativeAppleSilicon: Bool

  public init(
    machineModel: String,
    chipName: String?,
    logicalCoreCount: Int,
    physicalCoreCount: Int,
    physicalMemoryBytes: UInt64,
    cacheLineSizeBytes: Int?,
    pageSizeBytes: Int?,
    performanceLevels: [PerformanceLevel],
    cpuIndexMappingSource: CPUIndexMappingSource,
    features: CPUFeatureSet,
    isNativeAppleSilicon: Bool
  ) {
    self.machineModel = machineModel
    self.chipName = chipName
    self.logicalCoreCount = logicalCoreCount
    self.physicalCoreCount = physicalCoreCount
    self.physicalMemoryBytes = physicalMemoryBytes
    self.cacheLineSizeBytes = cacheLineSizeBytes
    self.pageSizeBytes = pageSizeBytes
    self.performanceLevels = performanceLevels
    self.cpuIndexMappingSource = cpuIndexMappingSource
    self.features = features
    self.isNativeAppleSilicon = isNativeAppleSilicon
  }

  /// Whether this machine has more than one class of core. Everything about
  /// placement and QoS only matters when this is true.
  public var isHeterogeneous: Bool { performanceLevels.count > 1 }

  /// The performance level owning a given logical CPU number, or `nil` if the
  /// mapping does not cover it.
  public func performanceLevel(forLogicalCPU cpu: Int) -> PerformanceLevel? {
    performanceLevels.first { $0.logicalCPUIDs.contains(cpu) }
  }
}
