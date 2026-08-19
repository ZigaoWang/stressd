import Foundation

/// The `hw.optional.*` subtree, split into boolean capability flags and the
/// handful of scalar values that live alongside them.
///
/// Read by walking the MIB rather than probing a hardcoded list, so a chip that
/// adds `FEAT_` flags after this was written still reports them.
public struct CPUFeatureSet: Sendable, Codable, Equatable {

  /// One raw sysctl leaf: its full dotted name and its integer value.
  public typealias SysctlEntry = (name: String, value: Int64)

  /// Capability flags keyed by short name, e.g. `"FEAT_SME"`, `"AdvSIMD"`,
  /// `"neon"`. The `hw.optional.` and `hw.optional.arm.` prefixes are stripped.
  public let flags: [String: Bool]
  /// Non-boolean values from the same subtree, e.g. `"caps"`,
  /// `"sme_max_svl_b"`.
  public let scalars: [String: Int64]

  public init(flags: [String: Bool], scalars: [String: Int64]) {
    self.flags = flags
    self.scalars = scalars
  }

  /// Present flags, sorted case-insensitively.
  public var supported: [String] {
    flags.filter(\.value).keys.sorted { $0.lowercased() < $1.lowercased() }
  }

  /// Absent flags, sorted case-insensitively.
  public var unsupported: [String] {
    flags.filter { !$0.value }.keys.sorted { $0.lowercased() < $1.lowercased() }
  }

  /// Architectural `FEAT_*` flags only, sorted.
  public var supportedArchitecturalFeatures: [String] {
    supported.filter { $0.hasPrefix("FEAT_") }
  }

  public func has(_ name: String) -> Bool { flags[name] ?? false }

  // Flags stressd itself branches on when picking a synthetic worker kernel.
  public var hasNEON: Bool { has("neon") || has("AdvSIMD") }
  public var hasFP16: Bool { has("FEAT_FP16") || has("neon_fp16") }
  public var hasBF16: Bool { has("FEAT_BF16") }
  public var hasI8MM: Bool { has("FEAT_I8MM") }
  public var hasDotProduct: Bool { has("FEAT_DotProd") }
  public var hasSME: Bool { has("FEAT_SME") }
  public var hasSME2: Bool { has("FEAT_SME2") }

  /// Names whose value is 0 or 1 but which are magnitudes rather than
  /// capability bits, so they must not be presented as flags.
  static let scalarNames: Set<String> = ["caps", "sme_max_svl_b"]

  /// Builds a feature set from raw `hw.optional.*` sysctl names and values.
  ///
  /// Separated from the sysctl read so it can be tested against recorded
  /// subtrees.
  public static func make(fromOptionalSubtree entries: [SysctlEntry]) -> CPUFeatureSet {
    var flags: [String: Bool] = [:]
    var scalars: [String: Int64] = [:]

    for entry in entries {
      let key = shortName(for: entry.name)
      guard !key.isEmpty else { continue }
      if scalarNames.contains(key) || (entry.value != 0 && entry.value != 1) {
        scalars[key] = entry.value
      } else {
        flags[key] = entry.value == 1
      }
    }
    return CPUFeatureSet(flags: flags, scalars: scalars)
  }

  private static func shortName(for sysctlName: String) -> String {
    for prefix in ["hw.optional.arm.", "hw.optional.arm64.", "hw.optional."] {
      if sysctlName.hasPrefix(prefix) {
        return String(sysctlName.dropFirst(prefix.count))
      }
    }
    return sysctlName
  }
}
