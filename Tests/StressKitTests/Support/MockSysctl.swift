import Foundation

@testable import StressKit

/// A `SysctlReading` backed by a recorded name/value map.
///
/// Values are typed the way the kernel types them so the decoding paths in
/// `SysctlReading` are exercised for real: integers become 4 or 8 byte
/// little-endian words, strings become NUL-terminated UTF-8.
struct MockSysctl: SysctlReading {
  enum Value: Equatable {
    case int32(Int32)
    case int64(Int64)
    case uint64(UInt64)
    case string(String)
    case raw(Data)

    var data: Data {
      switch self {
      case .int32(let value): return withUnsafeBytes(of: value.littleEndian) { Data($0) }
      case .int64(let value): return withUnsafeBytes(of: value.littleEndian) { Data($0) }
      case .uint64(let value): return withUnsafeBytes(of: value.littleEndian) { Data($0) }
      case .string(let value): return Data(value.utf8) + Data([0])
      case .raw(let data): return data
      }
    }
  }

  var values: [String: Value]

  init(_ values: [String: Value]) {
    self.values = values
  }

  func rawValue(for name: String) throws -> Data {
    guard let value = values[name] else {
      throw StressKitError.sysctlUnknownName(name)
    }
    return value.data
  }

  func names(under prefix: String) -> [String] {
    values.keys
      .filter { $0.hasPrefix(prefix + ".") }
      .sorted()
  }
}

/// A `CPUClusterMapping` backed by a recorded device tree.
struct MockClusterMap: CPUClusterMapping {
  var recorded: [CPUClusterAssignment]
  var shouldFail: Bool

  init(_ recorded: [CPUClusterAssignment], shouldFail: Bool = false) {
    self.recorded = recorded
    self.shouldFail = shouldFail
  }

  /// Builds a mapping from cluster type to core count, numbering CPUs in the
  /// order the clusters are listed.
  init(clusters: [(type: String, coreCount: Int)]) {
    var assignments: [CPUClusterAssignment] = []
    var cpu = 0
    for cluster in clusters {
      for _ in 0..<cluster.coreCount {
        assignments.append(CPUClusterAssignment(logicalCPUID: cpu, clusterType: cluster.type))
        cpu += 1
      }
    }
    self.recorded = assignments
    self.shouldFail = false
  }

  /// Stands in for a machine where the IORegistry read fails.
  static var failing: MockClusterMap {
    MockClusterMap([], shouldFail: true)
  }

  func assignments() throws -> [CPUClusterAssignment] {
    if shouldFail { throw StressKitError.ioRegistryNoCPUClusters }
    return recorded
  }
}
