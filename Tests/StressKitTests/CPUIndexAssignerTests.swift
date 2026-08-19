import Testing

@testable import StressKit

@Suite("CPU index assignment")
struct CPUIndexAssignerTests {

  private func specs(_ pairs: [(String, Int)]) -> [CPUIndexAssigner.LevelSpec] {
    pairs.map { CPUIndexAssigner.LevelSpec(name: $0.0, logicalCoreCount: $0.1) }
  }

  private func assignments(_ clusters: [(type: String, count: Int)]) -> [CPUClusterAssignment] {
    var result: [CPUClusterAssignment] = []
    var cpu = 0
    for cluster in clusters {
      for _ in 0..<cluster.count {
        result.append(CPUClusterAssignment(logicalCPUID: cpu, clusterType: cluster.type))
        cpu += 1
      }
    }
    return result
  }

  @Test("Equal core counts still resolve, because the cluster type names the level")
  func equalCoreCountsResolveByName() {
    // The M3 Pro case: 6 P and 6 E, so core counts cannot disambiguate.
    let result = CPUIndexAssigner.assign(
      levels: specs([("Performance", 6), ("Efficiency", 6)]),
      clusterAssignments: assignments([("E", 6), ("P", 6)]),
      totalLogicalCores: 12)

    #expect(result.source == .ioRegistryByClusterName)
    #expect(result.logicalCPUIDsByLevel == [[6, 7, 8, 9, 10, 11], [0, 1, 2, 3, 4, 5]])
  }

  @Test("A performance level spanning two clusters is merged")
  func multipleClustersPerLevel() {
    // M4 Max: one E cluster of 4, two P clusters of 6.
    let result = CPUIndexAssigner.assign(
      levels: specs([("Performance", 12), ("Efficiency", 4)]),
      clusterAssignments: assignments([("E", 4), ("P", 6), ("P", 6)]),
      totalLogicalCores: 16)

    #expect(result.source == .ioRegistryByClusterName)
    #expect(result.logicalCPUIDsByLevel == [Array(4...15), [0, 1, 2, 3]])
  }

  @Test("Unrecognised cluster names fall back to matching by core count")
  func unknownNamesMatchByCoreCount() {
    let result = CPUIndexAssigner.assign(
      levels: specs([("Fast", 8), ("Slow", 4)]),
      clusterAssignments: assignments([("beta", 4), ("alpha", 8)]),
      totalLogicalCores: 12)

    #expect(result.source == .ioRegistryByCoreCount)
    #expect(result.logicalCPUIDsByLevel == [Array(4...11), [0, 1, 2, 3]])
  }

  @Test("Unrecognised names with equal counts fall back to cluster ordering")
  func unknownNamesAndEqualCountsMatchByOrder() {
    let result = CPUIndexAssigner.assign(
      levels: specs([("Fast", 4), ("Slow", 4)]),
      clusterAssignments: assignments([("beta", 4), ("alpha", 4)]),
      totalLogicalCores: 8)

    // The slowest cluster is numbered first, so reversing gives fastest first.
    #expect(result.source == .ioRegistryByClusterOrder)
    #expect(result.logicalCPUIDsByLevel == [[4, 5, 6, 7], [0, 1, 2, 3]])
  }

  @Test("Without device tree data, indices are inferred slowest first")
  func inferredWhenClusterDataMissing() {
    let result = CPUIndexAssigner.assign(
      levels: specs([("Performance", 6), ("Efficiency", 6)]),
      clusterAssignments: nil,
      totalLogicalCores: 12)

    #expect(result.source == .inferred)
    #expect(result.logicalCPUIDsByLevel == [[6, 7, 8, 9, 10, 11], [0, 1, 2, 3, 4, 5]])
    #expect(!result.source.isAuthoritative)
  }

  @Test("Device tree data that contradicts sysctl is rejected, not trusted")
  func inconsistentClusterDataIsRejected() {
    // Device tree reports 10 cores while sysctl reports 12: something is
    // wrong, so the mapping must not be presented as authoritative.
    let result = CPUIndexAssigner.assign(
      levels: specs([("Performance", 6), ("Efficiency", 6)]),
      clusterAssignments: assignments([("E", 5), ("P", 5)]),
      totalLogicalCores: 12)

    #expect(result.source == .inferred)
  }

  @Test("A homogeneous machine gets one level covering every CPU")
  func singleLevel() {
    let result = CPUIndexAssigner.assign(
      levels: specs([("CPU", 8)]),
      clusterAssignments: nil,
      totalLogicalCores: 8)

    #expect(result.logicalCPUIDsByLevel == [Array(0...7)])
  }

  @Test("Non-contiguous device tree numbering is preserved, not renumbered")
  func nonContiguousNumbering() {
    let interleaved = [
      CPUClusterAssignment(logicalCPUID: 0, clusterType: "E"),
      CPUClusterAssignment(logicalCPUID: 1, clusterType: "P"),
      CPUClusterAssignment(logicalCPUID: 2, clusterType: "E"),
      CPUClusterAssignment(logicalCPUID: 3, clusterType: "P"),
    ]
    let result = CPUIndexAssigner.assign(
      levels: specs([("Performance", 2), ("Efficiency", 2)]),
      clusterAssignments: interleaved,
      totalLogicalCores: 4)

    #expect(result.source == .ioRegistryByClusterName)
    #expect(result.logicalCPUIDsByLevel == [[1, 3], [0, 2]])
  }

  @Test("Every level count is honoured across a three-level machine")
  func threePerformanceLevels() {
    // No shipping part has three levels. The code must not assume two.
    let result = CPUIndexAssigner.assign(
      levels: specs([("Performance", 4), ("Midrange", 2), ("Efficiency", 6)]),
      clusterAssignments: assignments([("E", 6), ("M", 2), ("P", 4)]),
      totalLogicalCores: 12)

    #expect(result.source == .ioRegistryByClusterName)
    #expect(result.logicalCPUIDsByLevel == [[8, 9, 10, 11], [6, 7], Array(0...5)])
  }
}
