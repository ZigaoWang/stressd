import Foundation

/// `SysctlReading` backed by the real kernel.
public struct LiveSysctl: SysctlReading {

  /// Deepest MIB the kernel will hand back. `CTL_MAXNAME` is 12 on Darwin;
  /// the extra headroom costs nothing and survives a future bump.
  private static let maximumMIBDepth = 24

  /// Backstop for the subtree walk. No real sysctl subtree comes close.
  private static let maximumWalkSteps = 100_000

  public init() {}

  public func rawValue(for name: String) throws -> Data {
    var size = 0
    guard sysctlbyname(name, nil, &size, nil, 0) == 0 else {
      throw Self.mapErrno(errno, name: name)
    }
    guard size > 0 else { return Data() }

    var buffer = [UInt8](repeating: 0, count: size)
    let status = buffer.withUnsafeMutableBytes { raw in
      sysctlbyname(name, raw.baseAddress, &size, nil, 0)
    }
    guard status == 0 else {
      throw Self.mapErrno(errno, name: name)
    }
    return Data(buffer.prefix(size))
  }

  public func names(under prefix: String) -> [String] {
    guard let root = Self.mib(for: prefix) else { return [] }

    var names: [String] = []
    var cursor = root
    var steps = 0

    while steps < Self.maximumWalkSteps {
      steps += 1
      guard let next = Self.nextOID(after: cursor) else { break }
      // The walk is depth-first over the whole tree; stop as soon as it leaves
      // the subtree we asked about.
      guard next.count > root.count, Array(next.prefix(root.count)) == root else { break }
      cursor = next
      if let name = Self.name(of: next) {
        names.append(name)
      }
    }
    return names
  }

  // MARK: - MIB plumbing

  /// Translates a dotted sysctl name into its numeric MIB.
  private static func mib(for name: String) -> [Int32]? {
    var oid = [Int32](repeating: 0, count: maximumMIBDepth)
    var length = oid.count
    guard sysctlnametomib(name, &oid, &length) == 0 else { return nil }
    return Array(oid.prefix(length))
  }

  /// The OID that follows `oid` in kernel MIB order.
  ///
  /// Uses the `{0, 2}` (`CTL_SYSCTL_NEXT`) meta-OID, which is how `sysctl -a`
  /// itself enumerates the tree. There is no higher level API for this.
  private static func nextOID(after oid: [Int32]) -> [Int32]? {
    var query: [Int32] = [0, 2] + oid
    var out = [Int32](repeating: 0, count: maximumMIBDepth)
    var outSize = out.count * MemoryLayout<Int32>.stride

    let status = out.withUnsafeMutableBytes { raw in
      sysctl(&query, u_int(query.count), raw.baseAddress, &outSize, nil, 0)
    }
    guard status == 0 else { return nil }

    let count = outSize / MemoryLayout<Int32>.stride
    guard count > 0 else { return nil }
    return Array(out.prefix(count))
  }

  /// The dotted name of an OID, via the `{0, 1}` (`CTL_SYSCTL_NAME`) meta-OID.
  private static func name(of oid: [Int32]) -> String? {
    var query: [Int32] = [0, 1] + oid
    var buffer = [UInt8](repeating: 0, count: 1024)
    var size = buffer.count

    let status = buffer.withUnsafeMutableBytes { raw in
      sysctl(&query, u_int(query.count), raw.baseAddress, &size, nil, 0)
    }
    guard status == 0 else { return nil }
    return String(decoding: buffer.prefix(size).prefix { $0 != 0 }, as: UTF8.self)
  }

  private static func mapErrno(_ code: Int32, name: String) -> StressKitError {
    // The kernel reports both "no such MIB" and "no such leaf" as ENOENT.
    code == ENOENT
      ? .sysctlUnknownName(name)
      : .sysctlReadFailed(name: name, errno: code)
  }
}
