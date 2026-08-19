import Foundation
import IOKit

/// Reads the logical-CPU-to-cluster mapping out of the IORegistry device tree.
///
/// Why this is not derived from sysctl: `hw.perflevelN` is ordered fastest
/// first, while the Mach logical CPU numbering used by `host_processor_info`
/// puts the *efficiency* cores first. On an M3 Pro, `hw.perflevel0` is
/// "Performance" but logical CPUs 0...5 are E-cores and 6...11 are P-cores.
/// The two numberings run in opposite directions and nothing in sysctl
/// connects them, so the device tree is the only authoritative source.
public struct IORegistryCPUClusterMap: CPUClusterMapping {

  private static let deviceTreePath = "IODeviceTree:/cpus"

  public init() {}

  public func assignments() throws -> [CPUClusterAssignment] {
    let found = Self.assignmentsFromDeviceTree() ?? Self.assignmentsFromPlatformDevices()
    guard let found, !found.isEmpty else {
      throw StressKitError.ioRegistryNoCPUClusters
    }
    return found.sorted { $0.logicalCPUID < $1.logicalCPUID }
  }

  // MARK: - Primary path: IODeviceTree:/cpus

  private static func assignmentsFromDeviceTree() -> [CPUClusterAssignment]? {
    let root = IORegistryEntryFromPath(kIOMainPortDefault, deviceTreePath)
    guard root != IO_OBJECT_NULL else { return nil }
    defer { IOObjectRelease(root) }

    var iterator: io_iterator_t = IO_OBJECT_NULL
    guard IORegistryEntryGetChildIterator(root, kIODeviceTreePlane, &iterator) == KERN_SUCCESS
    else { return nil }
    defer { IOObjectRelease(iterator) }

    return collect(from: iterator)
  }

  // MARK: - Fallback path: matching IOPlatformDevice services

  private static func assignmentsFromPlatformDevices() -> [CPUClusterAssignment]? {
    guard let matching = IOServiceMatching("IOPlatformDevice") else { return nil }

    var iterator: io_iterator_t = IO_OBJECT_NULL
    guard IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iterator) == KERN_SUCCESS
    else { return nil }
    defer { IOObjectRelease(iterator) }

    return collect(from: iterator)
  }

  // MARK: - Shared decoding

  private static func collect(from iterator: io_iterator_t) -> [CPUClusterAssignment]? {
    var results: [CPUClusterAssignment] = []
    var seen = Set<Int>()

    while case let entry = IOIteratorNext(iterator), entry != IO_OBJECT_NULL {
      defer { IOObjectRelease(entry) }

      guard
        let properties = copyProperties(of: entry),
        let clusterType = decodeString(properties["cluster-type"]),
        let logicalID = decodeInteger(properties["logical-cpu-id"])
          ?? decodeInteger(properties["cpu-id"])
      else { continue }

      // The two lookup paths can overlap; keep the first sighting.
      guard seen.insert(logicalID).inserted else { continue }
      results.append(
        CPUClusterAssignment(logicalCPUID: logicalID, clusterType: clusterType))
    }
    return results.isEmpty ? nil : results
  }

  private static func copyProperties(of entry: io_registry_entry_t) -> [String: Any]? {
    var unmanaged: Unmanaged<CFMutableDictionary>?
    guard
      IORegistryEntryCreateCFProperties(entry, &unmanaged, kCFAllocatorDefault, 0) == KERN_SUCCESS,
      let dictionary = unmanaged?.takeRetainedValue()
    else { return nil }
    return dictionary as? [String: Any]
  }

  /// Device tree strings arrive as NUL-terminated `Data`, but the same key can
  /// be a real `CFString` on some nodes.
  private static func decodeString(_ value: Any?) -> String? {
    if let data = value as? Data {
      let text = String(decoding: data.prefix { $0 != 0 }, as: UTF8.self)
      return text.isEmpty ? nil : text
    }
    if let text = value as? String {
      return text.isEmpty ? nil : text
    }
    return nil
  }

  /// Numbers arrive as `CFNumber` on some nodes and as little-endian `Data` on
  /// others.
  private static func decodeInteger(_ value: Any?) -> Int? {
    if let number = value as? NSNumber { return number.intValue }
    guard let data = value as? Data, !data.isEmpty, data.count <= 8 else { return nil }
    var result = 0
    for (offset, byte) in data.enumerated() {
      result |= Int(byte) << (8 * offset)
    }
    return result
  }
}
