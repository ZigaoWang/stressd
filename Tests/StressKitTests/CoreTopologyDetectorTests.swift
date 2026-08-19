import Foundation
import Testing

@testable import StressKit

@Suite("Core topology detection")
struct CoreTopologyDetectorTests {

  @Test("Recorded machines are read correctly", arguments: MachineFixtures.all)
  func recordedMachines(machine: MachineFixtures.Machine) throws {
    let topology = try CoreTopologyDetector(
      sysctl: machine.sysctl, clusterMap: machine.clusterMap
    ).detect()

    #expect(topology.performanceLevels.count == machine.expectedCPUIDsByLevel.count)
    #expect(topology.performanceLevels.map(\.logicalCPUIDs) == machine.expectedCPUIDsByLevel)
    #expect(topology.cpuIndexMappingSource.isAuthoritative)

    // Every logical CPU is accounted for exactly once.
    let allCPUs = topology.performanceLevels.flatMap(\.logicalCPUIDs)
    #expect(Set(allCPUs).count == topology.logicalCoreCount)
    #expect(allCPUs.count == topology.logicalCoreCount)

    // Level core counts agree with the machine total.
    #expect(
      topology.performanceLevels.reduce(0) { $0 + $1.logicalCoreCount }
        == topology.logicalCoreCount)
  }

  @Test("Performance levels are ordered fastest first")
  func levelOrdering() throws {
    let topology = try CoreTopologyDetector(
      sysctl: MachineFixtures.m3Pro.sysctl, clusterMap: MachineFixtures.m3Pro.clusterMap
    ).detect()

    #expect(topology.performanceLevels[0].name == "Performance")
    #expect(topology.performanceLevels[1].name == "Efficiency")
    // The faster level has the larger L2, which is the independent check that
    // the ordering was not inverted.
    #expect(
      topology.performanceLevels[0].l2CacheBytes ?? 0
        > topology.performanceLevels[1].l2CacheBytes ?? 0)
  }

  @Test("Performance cores get the high logical CPU numbers on Apple silicon")
  func performanceCoresAreNumberedLast() throws {
    // This is the whole reason the device tree is consulted. hw.perflevel0 is
    // the Performance level, but its cores are the *last* logical CPUs.
    for machine in MachineFixtures.all {
      let topology = try CoreTopologyDetector(
        sysctl: machine.sysctl, clusterMap: machine.clusterMap
      ).detect()

      let performance = try #require(topology.performanceLevels.first)
      let efficiency = try #require(topology.performanceLevels.last)
      let lowestPerformanceCPU = try #require(performance.logicalCPUIDs.min())
      let highestEfficiencyCPU = try #require(efficiency.logicalCPUIDs.max())

      #expect(
        lowestPerformanceCPU > highestEfficiencyCPU,
        "\(machine.name): P-cores must be numbered above E-cores")
    }
  }

  @Test("QoS hints bias towards the intended level")
  func qosHints() throws {
    let topology = try CoreTopologyDetector(
      sysctl: MachineFixtures.m4Max.sysctl, clusterMap: MachineFixtures.m4Max.clusterMap
    ).detect()

    #expect(topology.performanceLevels[0].qosHint == .userInteractive)
    #expect(topology.performanceLevels[1].qosHint == .background)
  }

  @Test("A single performance level gets .default rather than a bias")
  func qosHintForHomogeneousMachine() {
    #expect(QoSHint.biasing(towardLevel: 0, of: 1) == .default)
    #expect(QoSHint.biasing(towardLevel: 0, of: 3) == .userInteractive)
    #expect(QoSHint.biasing(towardLevel: 1, of: 3) == .utility)
    #expect(QoSHint.biasing(towardLevel: 2, of: 3) == .background)
  }

  @Test("Caches and cluster width are carried through")
  func cacheDetails() throws {
    let topology = try CoreTopologyDetector(
      sysctl: MachineFixtures.m3Pro.sysctl, clusterMap: MachineFixtures.m3Pro.clusterMap
    ).detect()

    let performance = topology.performanceLevels[0]
    #expect(performance.l1InstructionCacheBytes == 196_608)
    #expect(performance.l1DataCacheBytes == 131_072)
    #expect(performance.l2CacheBytes == 16_777_216)
    #expect(performance.coresPerL2 == 6)
    #expect(topology.cacheLineSizeBytes == 128)
    #expect(topology.pageSizeBytes == 16384)
    #expect(topology.physicalMemoryBytes == 18 * 1024 * 1024 * 1024)
  }

  @Test("A failing device tree read degrades to the inferred mapping")
  func degradesWhenIORegistryFails() throws {
    let topology = try CoreTopologyDetector(
      sysctl: MachineFixtures.m3Pro.sysctl, clusterMap: MockClusterMap.failing
    ).detect()

    #expect(topology.cpuIndexMappingSource == .inferred)
    #expect(!topology.cpuIndexMappingSource.isAuthoritative)
    // Still usable: the inferred layout matches reality on shipping hardware.
    #expect(topology.performanceLevels.map(\.logicalCPUIDs) == [Array(6...11), Array(0...5)])
  }

  @Test("A machine without hw.nperflevels is modelled as one level")
  func homogeneousMachine() throws {
    let sysctl = MockSysctl([
      "hw.model": .string("Macmini8,1"),
      "machdep.cpu.brand_string": .string("Generic CPU"),
      "hw.logicalcpu": .int32(8),
      "hw.physicalcpu": .int32(4),
      "hw.memsize": .uint64(8 * 1024 * 1024 * 1024),
    ])
    let topology = try CoreTopologyDetector(sysctl: sysctl, clusterMap: nil).detect()

    #expect(topology.performanceLevels.count == 1)
    #expect(!topology.isHeterogeneous)
    #expect(topology.performanceLevels[0].logicalCPUIDs == Array(0...7))
    #expect(topology.performanceLevels[0].qosHint == .default)
    #expect(topology.cacheLineSizeBytes == nil)
  }

  @Test("Detection fails loudly when hw.logicalcpu is unavailable")
  func failsWithoutCoreCount() {
    let detector = CoreTopologyDetector(sysctl: MockSysctl([:]), clusterMap: nil)
    #expect(throws: StressKitError.sysctlUnknownName("hw.logicalcpu")) {
      _ = try detector.detect()
    }
  }

  @Test("Logical CPU lookup resolves to the owning level")
  func lookupByLogicalCPU() throws {
    let topology = try CoreTopologyDetector(
      sysctl: MachineFixtures.m3Pro.sysctl, clusterMap: MachineFixtures.m3Pro.clusterMap
    ).detect()

    #expect(topology.performanceLevel(forLogicalCPU: 0)?.name == "Efficiency")
    #expect(topology.performanceLevel(forLogicalCPU: 11)?.name == "Performance")
    #expect(topology.performanceLevel(forLogicalCPU: 99) == nil)
  }

  @Test("Contiguous CPU ranges collapse for display")
  func contiguousRanges() throws {
    let topology = try CoreTopologyDetector(
      sysctl: MachineFixtures.m4Max.sysctl, clusterMap: MachineFixtures.m4Max.clusterMap
    ).detect()

    #expect(topology.performanceLevels[0].contiguousCPURanges == [4...15])
    #expect(topology.performanceLevels[1].contiguousCPURanges == [0...3])
  }

  @Test("Topology round-trips through JSON")
  func codableRoundTrip() throws {
    let topology = try CoreTopologyDetector(
      sysctl: MachineFixtures.m3Pro.sysctl, clusterMap: MachineFixtures.m3Pro.clusterMap
    ).detect()

    let encoded = try JSONEncoder().encode(topology)
    let decoded = try JSONDecoder().decode(CoreTopology.self, from: encoded)
    #expect(decoded == topology)
  }
}

extension MachineFixtures.Machine: CustomTestStringConvertible {
  var testDescription: String { name }
}
