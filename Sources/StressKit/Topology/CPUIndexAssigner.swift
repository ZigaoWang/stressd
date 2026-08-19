import Foundation

/// Matches performance levels (fastest first, from sysctl) to logical CPU
/// numbers (slowest first, from the Mach/device tree numbering).
///
/// Pure logic with no system calls so it can be tested against recorded
/// topologies for machines that are not the one running the tests.
public enum CPUIndexAssigner {

  /// The part of a performance level this matcher needs.
  public struct LevelSpec: Sendable, Equatable {
    public let name: String
    public let logicalCoreCount: Int

    public init(name: String, logicalCoreCount: Int) {
      self.name = name
      self.logicalCoreCount = logicalCoreCount
    }
  }

  public struct Result: Sendable, Equatable {
    /// Logical CPU numbers per performance level, in the same order as the
    /// `levels` argument (fastest first). Each inner array is ascending.
    public let logicalCPUIDsByLevel: [[Int]]
    public let source: CPUIndexMappingSource

    public init(logicalCPUIDsByLevel: [[Int]], source: CPUIndexMappingSource) {
      self.logicalCPUIDsByLevel = logicalCPUIDsByLevel
      self.source = source
    }
  }

  /// Assigns logical CPU numbers to performance levels.
  ///
  /// - Parameters:
  ///   - levels: Performance levels, fastest first, as `hw.perflevelN` orders
  ///     them.
  ///   - clusterAssignments: Device tree cluster data, or `nil` when the
  ///     IORegistry could not be read.
  ///   - totalLogicalCores: `hw.logicalcpu`, used to lay out the inferred
  ///     fallback and to sanity check the device tree data.
  /// - Returns: Logical CPU numbers per level, plus the source that produced
  ///   them. Never fails: a machine whose device tree cannot be read or whose
  ///   device tree contradicts sysctl falls back to the inferred layout, which
  ///   the caller can detect through `Result.source`.
  public static func assign(
    levels: [LevelSpec],
    clusterAssignments: [CPUClusterAssignment]?,
    totalLogicalCores: Int
  ) -> Result {
    guard !levels.isEmpty else {
      return Result(logicalCPUIDsByLevel: [], source: .inferred)
    }

    if let clusterAssignments, !clusterAssignments.isEmpty {
      let clusters = group(clusterAssignments)
      if clusters.count == levels.count,
        clusters.reduce(0, { $0 + $1.cpuIDs.count }) == totalLogicalCores
      {
        // Strongest signal first: the cluster type letter names the level.
        if let matched = matchByClusterName(levels: levels, clusters: clusters) {
          return Result(logicalCPUIDsByLevel: matched, source: .ioRegistryByClusterName)
        }
        // Next: unambiguous core counts.
        if let matched = matchByCoreCount(levels: levels, clusters: clusters) {
          return Result(logicalCPUIDsByLevel: matched, source: .ioRegistryByCoreCount)
        }
        // Last: cluster ordering. Apple numbers the slowest cluster first, so
        // reversing gives fastest-first to line up with hw.perflevelN.
        if let matched = matchByClusterOrder(levels: levels, clusters: clusters) {
          return Result(logicalCPUIDsByLevel: matched, source: .ioRegistryByClusterOrder)
        }
      }
    }

    return Result(
      logicalCPUIDsByLevel: inferContiguousBlocks(levels: levels, total: totalLogicalCores),
      source: .inferred)
  }

  // MARK: - Cluster grouping

  struct Cluster: Equatable {
    let type: String
    let cpuIDs: [Int]
  }

  /// Groups assignments by cluster type, ordered by the lowest logical CPU
  /// number in each group.
  static func group(_ assignments: [CPUClusterAssignment]) -> [Cluster] {
    var order: [String] = []
    var byType: [String: [Int]] = [:]

    for assignment in assignments.sorted(by: { $0.logicalCPUID < $1.logicalCPUID }) {
      if byType[assignment.clusterType] == nil {
        order.append(assignment.clusterType)
        byType[assignment.clusterType] = []
      }
      byType[assignment.clusterType]?.append(assignment.logicalCPUID)
    }
    return order.map { Cluster(type: $0, cpuIDs: byType[$0] ?? []) }
  }

  // MARK: - Matching strategies

  /// "Performance" -> "P", "Efficiency" -> "E".
  private static func matchByClusterName(
    levels: [LevelSpec], clusters: [Cluster]
  ) -> [[Int]]? {
    let initials = levels.map { $0.name.prefix(1).uppercased() }
    guard Set(initials).count == levels.count else { return nil }

    var matched: [[Int]] = []
    var used = Set<Int>()

    for (levelIndex, initial) in initials.enumerated() {
      guard
        let clusterIndex = clusters.indices.first(where: {
          !used.contains($0) && clusters[$0].type.uppercased().hasPrefix(initial)
        }),
        clusters[clusterIndex].cpuIDs.count == levels[levelIndex].logicalCoreCount
      else { return nil }
      used.insert(clusterIndex)
      matched.append(clusters[clusterIndex].cpuIDs)
    }
    return matched
  }

  private static func matchByCoreCount(levels: [LevelSpec], clusters: [Cluster]) -> [[Int]]? {
    let counts = levels.map(\.logicalCoreCount)
    guard Set(counts).count == levels.count else { return nil }

    var matched: [[Int]] = []
    var used = Set<Int>()

    for count in counts {
      guard
        let clusterIndex = clusters.indices.first(where: {
          !used.contains($0) && clusters[$0].cpuIDs.count == count
        })
      else { return nil }
      used.insert(clusterIndex)
      matched.append(clusters[clusterIndex].cpuIDs)
    }
    return matched
  }

  private static func matchByClusterOrder(levels: [LevelSpec], clusters: [Cluster]) -> [[Int]]? {
    let fastestFirst = Array(clusters.reversed())
    for (level, cluster) in zip(levels, fastestFirst)
    where level.logicalCoreCount != cluster.cpuIDs.count {
      return nil
    }
    return fastestFirst.map(\.cpuIDs)
  }

  // MARK: - Fallback

  /// Lays out contiguous blocks assuming the slowest level owns the lowest
  /// logical CPU numbers, which is how every Apple silicon part shipped so far
  /// is numbered.
  static func inferContiguousBlocks(levels: [LevelSpec], total: Int) -> [[Int]] {
    var blocks = [[Int]](repeating: [], count: levels.count)
    var cursor = 0

    for levelIndex in levels.indices.reversed() {
      let count = max(0, levels[levelIndex].logicalCoreCount)
      let upper = min(cursor + count, max(total, 0))
      blocks[levelIndex] = cursor < upper ? Array(cursor..<upper) : []
      cursor = upper
    }
    return blocks
  }
}
