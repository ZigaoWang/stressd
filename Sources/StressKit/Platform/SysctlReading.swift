import Foundation

/// Read-only access to the kernel state exposed through `sysctl(3)`.
///
/// Everything in StressKit that needs sysctl goes through this protocol so the
/// test suite can drive the code with recorded fixtures from machines that are
/// not the one running the tests.
public protocol SysctlReading: Sendable {
  /// The raw bytes stored under `name`.
  ///
  /// - Throws: `StressKitError.sysctlUnknownName` if the name does not exist,
  ///   `StressKitError.sysctlReadFailed` for any other failure.
  func rawValue(for name: String) throws -> Data

  /// Every sysctl name in the subtree rooted at `prefix`, in kernel MIB order.
  ///
  /// Returns an empty array if the subtree is empty or cannot be walked. The
  /// prefix itself is not included.
  func names(under prefix: String) -> [String]
}

extension SysctlReading {

  /// Reads a signed integer, accepting any of the 1/2/4/8 byte widths the
  /// kernel uses for `CTLTYPE_INT`, `CTLTYPE_QUAD` and friends.
  public func integer(_ name: String) throws -> Int64 {
    let data = try rawValue(for: name)
    switch data.count {
    case 1: return Int64(data.withUnsafeBytes { $0.loadUnaligned(as: Int8.self) })
    case 2: return Int64(data.withUnsafeBytes { $0.loadUnaligned(as: Int16.self) })
    case 4: return Int64(data.withUnsafeBytes { $0.loadUnaligned(as: Int32.self) })
    case 8: return data.withUnsafeBytes { $0.loadUnaligned(as: Int64.self) }
    default:
      throw StressKitError.sysctlMalformedValue(
        name: name, expected: "integer", byteCount: data.count)
    }
  }

  /// Reads an unsigned integer. Used for values such as `hw.memsize` that can
  /// exceed `Int64` in principle.
  public func unsignedInteger(_ name: String) throws -> UInt64 {
    let data = try rawValue(for: name)
    switch data.count {
    case 1: return UInt64(data.withUnsafeBytes { $0.loadUnaligned(as: UInt8.self) })
    case 2: return UInt64(data.withUnsafeBytes { $0.loadUnaligned(as: UInt16.self) })
    case 4: return UInt64(data.withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) })
    case 8: return data.withUnsafeBytes { $0.loadUnaligned(as: UInt64.self) }
    default:
      throw StressKitError.sysctlMalformedValue(
        name: name, expected: "unsigned integer", byteCount: data.count)
    }
  }

  /// Reads a NUL-terminated C string.
  public func string(_ name: String) throws -> String {
    let data = try rawValue(for: name)
    let bytes = data.prefix { $0 != 0 }
    return String(decoding: bytes, as: UTF8.self)
  }

  /// `integer(_:)` that maps a missing name to `nil` instead of throwing.
  ///
  /// Optional sysctls are the norm: cache descriptors and ARM feature flags
  /// come and go between chip generations.
  public func optionalInteger(_ name: String) -> Int64? {
    do { return try integer(name) } catch { return nil }
  }

  /// `string(_:)` that maps a missing name to `nil` instead of throwing.
  public func optionalString(_ name: String) -> String? {
    do {
      let value = try string(name)
      return value.isEmpty ? nil : value
    } catch {
      return nil
    }
  }

  /// Whether `name` exists on this kernel.
  public func exists(_ name: String) -> Bool {
    do {
      _ = try rawValue(for: name)
      return true
    } catch {
      return false
    }
  }
}
