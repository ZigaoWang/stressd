import Foundation

@testable import StressKit

/// Recorded `sysctl` and device tree state for real machines.
///
/// The M3 Pro entry was captured from hardware. The others follow the same
/// published shape for their part. What matters is that core counts, level
/// names and cluster layouts match real silicon, including the cases where the
/// two performance levels have equal core counts (M1, M3 Pro) and where one
/// performance level spans two clusters (M2 Pro, M4 Max).
enum MachineFixtures {

  struct Machine: Sendable {
    let name: String
    let sysctl: MockSysctl
    let clusterMap: MockClusterMap
    /// Logical CPU numbers expected on each performance level, fastest first.
    let expectedCPUIDsByLevel: [[Int]]
  }

  // MARK: - M1: 4 performance + 4 efficiency, equal counts

  static let m1 = Machine(
    name: "M1",
    sysctl: combine(
      base(model: "Macmini9,1", chip: "Apple M1", memoryGB: 16, logical: 8, physical: 8),
      level(
        0, "Performance", logical: 4, physical: 4,
        l1i: 196_608, l1d: 131_072, l2: 12_582_912, cpusPerL2: 4),
      level(
        1, "Efficiency", logical: 4, physical: 4,
        l1i: 131_072, l1d: 65_536, l2: 4_194_304, cpusPerL2: 4)),
    clusterMap: MockClusterMap(clusters: [("E", 4), ("P", 4)]),
    expectedCPUIDsByLevel: [[4, 5, 6, 7], [0, 1, 2, 3]]
  )

  // MARK: - M2 Pro: 8 performance + 4 efficiency, two P clusters

  static let m2Pro = Machine(
    name: "M2 Pro",
    sysctl: combine(
      base(model: "Mac14,9", chip: "Apple M2 Pro", memoryGB: 16, logical: 12, physical: 12),
      level(
        0, "Performance", logical: 8, physical: 8,
        l1i: 196_608, l1d: 131_072, l2: 16_777_216, cpusPerL2: 4),
      level(
        1, "Efficiency", logical: 4, physical: 4,
        l1i: 131_072, l1d: 65_536, l2: 4_194_304, cpusPerL2: 4)),
    clusterMap: MockClusterMap(clusters: [("E", 4), ("P", 4), ("P", 4)]),
    expectedCPUIDsByLevel: [[4, 5, 6, 7, 8, 9, 10, 11], [0, 1, 2, 3]]
  )

  // MARK: - M3 Pro: 6 performance + 6 efficiency, captured from hardware

  static let m3Pro = Machine(
    name: "M3 Pro",
    sysctl: combine(
      base(model: "Mac15,6", chip: "Apple M3 Pro", memoryGB: 18, logical: 12, physical: 12),
      level(
        0, "Performance", logical: 6, physical: 6,
        l1i: 196_608, l1d: 131_072, l2: 16_777_216, cpusPerL2: 6),
      level(
        1, "Efficiency", logical: 6, physical: 6,
        l1i: 131_072, l1d: 65_536, l2: 4_194_304, cpusPerL2: 6)),
    clusterMap: MockClusterMap(clusters: [("E", 6), ("P", 6)]),
    expectedCPUIDsByLevel: [[6, 7, 8, 9, 10, 11], [0, 1, 2, 3, 4, 5]]
  )

  // MARK: - M4 Max: 12 performance + 4 efficiency, two P clusters

  static let m4Max = Machine(
    name: "M4 Max",
    sysctl: combine(
      base(model: "Mac16,5", chip: "Apple M4 Max", memoryGB: 48, logical: 16, physical: 16),
      level(
        0, "Performance", logical: 12, physical: 12,
        l1i: 196_608, l1d: 131_072, l2: 16_777_216, cpusPerL2: 6),
      level(
        1, "Efficiency", logical: 4, physical: 4,
        l1i: 131_072, l1d: 65_536, l2: 4_194_304, cpusPerL2: 4)),
    clusterMap: MockClusterMap(clusters: [("E", 4), ("P", 6), ("P", 6)]),
    expectedCPUIDsByLevel: [Array(4...15), [0, 1, 2, 3]]
  )

  static let all: [Machine] = [m1, m2Pro, m3Pro, m4Max]

  // MARK: - Builders

  private static func combine(_ parts: [String: MockSysctl.Value]...) -> MockSysctl {
    var combined: [String: MockSysctl.Value] = [:]
    for part in parts {
      combined.merge(part) { _, new in new }
    }
    return MockSysctl(combined)
  }

  private static func base(
    model: String, chip: String, memoryGB: Int, logical: Int, physical: Int
  ) -> [String: MockSysctl.Value] {
    [
      "hw.model": .string(model),
      "machdep.cpu.brand_string": .string(chip),
      "hw.memsize": .uint64(UInt64(memoryGB) * 1024 * 1024 * 1024),
      "hw.logicalcpu": .int32(Int32(logical)),
      "hw.physicalcpu": .int32(Int32(physical)),
      "hw.ncpu": .int32(Int32(logical)),
      "hw.nperflevels": .int32(2),
      "hw.cachelinesize": .int64(128),
      "hw.pagesize": .int64(16384),
      "sysctl.proc_translated": .int32(0),
      // A representative slice of hw.optional, including the two names that
      // are magnitudes rather than capability bits.
      "hw.optional.arm.FEAT_AES": .int32(1),
      "hw.optional.arm.FEAT_BF16": .int32(1),
      "hw.optional.arm.FEAT_DotProd": .int32(1),
      "hw.optional.arm.FEAT_FP16": .int32(1),
      "hw.optional.arm.FEAT_I8MM": .int32(1),
      "hw.optional.arm.FEAT_LSE": .int32(1),
      "hw.optional.arm.FEAT_SME": .int32(0),
      "hw.optional.arm.FEAT_SME2": .int32(0),
      "hw.optional.arm.AdvSIMD": .int32(1),
      "hw.optional.arm.caps": .int64(868_632_465_256_738_815),
      "hw.optional.arm.sme_max_svl_b": .int32(0),
      "hw.optional.neon": .int32(1),
      "hw.optional.floatingpoint": .int32(1),
    ]
  }

  private static func level(
    _ index: Int, _ name: String, logical: Int, physical: Int,
    l1i: Int, l1d: Int, l2: Int, cpusPerL2: Int
  ) -> [String: MockSysctl.Value] {
    let prefix = "hw.perflevel\(index)"
    return [
      "\(prefix).name": .string(name),
      "\(prefix).logicalcpu": .int32(Int32(logical)),
      "\(prefix).physicalcpu": .int32(Int32(physical)),
      "\(prefix).l1icachesize": .int64(Int64(l1i)),
      "\(prefix).l1dcachesize": .int64(Int64(l1d)),
      "\(prefix).l2cachesize": .int64(Int64(l2)),
      "\(prefix).cpusperl2": .int32(Int32(cpusPerL2)),
    ]
  }
}
