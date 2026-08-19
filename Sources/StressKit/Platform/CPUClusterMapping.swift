import Foundation

/// Which cluster a single logical CPU belongs to, as reported by the device
/// tree.
public struct CPUClusterAssignment: Sendable, Codable, Equatable {
  /// The logical CPU number. This is the index used by `host_processor_info`,
  /// so it is the number telemetry will report against.
  public let logicalCPUID: Int
  /// The device tree `cluster-type` string. `"P"` and `"E"` on every Apple
  /// silicon part shipped so far, but treated as opaque here.
  public let clusterType: String

  public init(logicalCPUID: Int, clusterType: String) {
    self.logicalCPUID = logicalCPUID
    self.clusterType = clusterType
  }
}

/// Source of the logical-CPU-number to cluster mapping.
///
/// This exists as a protocol because there is no sysctl for it, the IOKit call
/// cannot run in CI, and getting it wrong silently inverts every per-core
/// reading stressd produces.
public protocol CPUClusterMapping: Sendable {
  func assignments() throws -> [CPUClusterAssignment]
}
