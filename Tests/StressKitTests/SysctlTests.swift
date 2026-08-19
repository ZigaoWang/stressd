import Foundation
import Testing

@testable import StressKit

@Suite("Sysctl decoding")
struct SysctlDecodingTests {

  @Test("Integers decode at every width the kernel uses")
  func integerWidths() throws {
    let sysctl = MockSysctl([
      "a.int32": .int32(-7),
      "a.int64": .int64(9_007_199_254_740_993),
      "a.uint64": .uint64(19_327_352_832),
    ])

    #expect(try sysctl.integer("a.int32") == -7)
    #expect(try sysctl.integer("a.int64") == 9_007_199_254_740_993)
    #expect(try sysctl.unsignedInteger("a.uint64") == 19_327_352_832)
  }

  @Test("Strings stop at the NUL terminator")
  func stringDecoding() throws {
    let sysctl = MockSysctl(["a.string": .raw(Data("Apple M3 Pro\0garbage".utf8))])
    #expect(try sysctl.string("a.string") == "Apple M3 Pro")
  }

  @Test("A missing name is distinguishable from a read failure")
  func missingName() {
    let sysctl = MockSysctl([:])
    #expect(throws: StressKitError.sysctlUnknownName("nope")) {
      _ = try sysctl.integer("nope")
    }
    #expect(sysctl.optionalInteger("nope") == nil)
    #expect(sysctl.optionalString("nope") == nil)
    #expect(!sysctl.exists("nope"))
  }

  @Test("A value of an unexpected width is rejected rather than truncated")
  func malformedWidth() {
    let sysctl = MockSysctl(["a.weird": .raw(Data([1, 2, 3]))])
    #expect(throws: StressKitError.self) {
      _ = try sysctl.integer("a.weird")
    }
  }

  @Test("An empty string reads as nil, not as an empty value")
  func emptyStringIsNil() {
    let sysctl = MockSysctl(["a.empty": .string("")])
    #expect(sysctl.optionalString("a.empty") == nil)
  }
}

enum TestHost {
  /// True only on a native Apple silicon Mac with a heterogeneous CPU.
  static var isAppleSilicon: Bool {
    #if arch(arm64) && os(macOS)
      return LiveSysctl().exists("hw.nperflevels")
    #else
      return false
    #endif
  }

  /// Whether the IORegistry exposes CPU `cluster-type` properties.
  ///
  /// Distinct from `isAppleSilicon`, and the difference is not hypothetical:
  /// GitHub's macOS runners are virtualised Apple silicon, where sysctl
  /// reports performance levels but the guest device tree has no CPU nodes at
  /// all. That is precisely the case the inferred CPU index mapping exists to
  /// handle, so it is a supported configuration rather than a failure — but a
  /// test that requires real device tree data cannot run there.
  static var hasCPUClusterDeviceTree: Bool {
    guard isAppleSilicon else { return false }
    return (try? IORegistryCPUClusterMap().assignments())?.isEmpty == false
  }
}

/// These exercise the real kernel. They are skipped anywhere that is not a
/// native Apple silicon Mac so CI stays green on other hosts.
@Suite("Live sysctl", .enabled(if: TestHost.isAppleSilicon))
struct LiveSysctlTests {

  @Test("The MIB walk finds the ARM feature subtree")
  func featureSubtreeWalk() {
    let names = LiveSysctl().names(under: "hw.optional")

    #expect(names.count > 20, "hw.optional should contain dozens of entries")
    #expect(names.allSatisfy { $0.hasPrefix("hw.optional.") })
    #expect(names.contains("hw.optional.arm.FEAT_LSE"))
    // The walk must stop at the subtree boundary.
    #expect(!names.contains { $0.hasPrefix("hw.perflevel") })
  }

  @Test("The real machine produces a consistent topology")
  func liveTopology() throws {
    let topology = try CoreTopologyDetector().detect()

    #expect(topology.logicalCoreCount > 0)
    #expect(topology.chipName?.isEmpty == false)
    // Deliberately not asserting the mapping is authoritative: on a virtualised
    // host there is no device tree and the inferred layout is the correct
    // outcome. The invariants below have to hold either way.
    #expect(
      topology.performanceLevels.reduce(0) { $0 + $1.logicalCoreCount }
        == topology.logicalCoreCount)

    let cpus = topology.performanceLevels.flatMap(\.logicalCPUIDs)
    #expect(Set(cpus).count == topology.logicalCoreCount)
    #expect(cpus.allSatisfy { (0..<topology.logicalCoreCount).contains($0) })
  }

  @Test(
    "The device tree exposes cluster types for every logical CPU",
    .enabled(if: TestHost.hasCPUClusterDeviceTree))
  func liveClusterMap() throws {
    let assignments = try IORegistryCPUClusterMap().assignments()
    let logicalCount = Int(try LiveSysctl().integer("hw.logicalcpu"))

    #expect(assignments.count == logicalCount)
    #expect(Set(assignments.map(\.logicalCPUID)).count == logicalCount)
    #expect(assignments.allSatisfy { !$0.clusterType.isEmpty })
  }
}
