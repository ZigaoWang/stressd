import Foundation

/// Every error StressKit surfaces to a caller.
///
/// Errors carry enough context to be rendered by a CLI or a GUI without the
/// caller having to guess what failed.
public enum StressKitError: Error, Equatable, Sendable {
  /// A sysctl name does not exist on this kernel.
  case sysctlUnknownName(String)
  /// A sysctl exists but the read failed.
  case sysctlReadFailed(name: String, errno: Int32)
  /// A sysctl value could not be interpreted as the requested type.
  case sysctlMalformedValue(name: String, expected: String, byteCount: Int)
  /// An IORegistry lookup failed.
  case ioRegistryUnavailable(path: String)
  /// The IORegistry was reachable but contained no usable CPU cluster data.
  case ioRegistryNoCPUClusters
  /// stressd was asked to run on hardware it does not support.
  case unsupportedHardware(String)
  /// `host_processor_info` returned an error.
  case processorInfoFailed(kernReturn: Int32)
  /// `host_processor_info` returned fewer values than it reported CPUs.
  case processorInfoTruncated(expected: Int, received: Int)
  /// A sleep assertion could not be taken.
  case powerAssertionFailed(kernReturn: Int32)
  /// The BOINC client is not installed or not reachable.
  case boincUnavailable(String)
  /// A boinccmd invocation failed.
  case boincCommandFailed(command: String, detail: String)
}

extension StressKitError: CustomStringConvertible {
  public var description: String {
    switch self {
    case .sysctlUnknownName(let name):
      return "sysctl '\(name)' does not exist on this system"
    case .sysctlReadFailed(let name, let code):
      return "sysctl '\(name)' failed: \(String(cString: strerror(code))) (errno \(code))"
    case .sysctlMalformedValue(let name, let expected, let byteCount):
      return "sysctl '\(name)' returned \(byteCount) bytes, which is not a valid \(expected)"
    case .ioRegistryUnavailable(let path):
      return "IORegistry path '\(path)' could not be opened"
    case .ioRegistryNoCPUClusters:
      return "IORegistry contained no CPU nodes with cluster-type properties"
    case .unsupportedHardware(let detail):
      return "unsupported hardware: \(detail)"
    case .processorInfoFailed(let code):
      return "host_processor_info failed with kern_return_t \(code)"
    case .processorInfoTruncated(let expected, let received):
      return "host_processor_info returned \(received) values, expected \(expected)"
    case .powerAssertionFailed(let code):
      return "IOPMAssertionCreateWithName failed with IOReturn \(code)"
    case .boincUnavailable(let detail):
      return "BOINC unavailable: \(detail)"
    case .boincCommandFailed(let command, let detail):
      return "boinccmd \(command) failed: \(detail)"
    }
  }
}
