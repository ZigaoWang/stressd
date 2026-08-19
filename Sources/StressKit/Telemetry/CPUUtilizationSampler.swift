import Foundation

/// Source of raw per-CPU tick counters.
public protocol CPUTickReading: Sendable {
  /// One entry per logical CPU, ordered by logical CPU number.
  func read() throws -> [CPUTicks]
}

/// `CPUTickReading` backed by `host_processor_info`.
///
/// Not `top`, not `iostat`, not `ps`: those are the same counters after a
/// round trip through a subprocess, a text formatter and a parser, sampled on
/// their schedule rather than ours.
public struct HostProcessorInfo: CPUTickReading {

  public init() {}

  public func read() throws -> [CPUTicks] {
    var cpuCount: natural_t = 0
    var info: processor_info_array_t?
    var infoCount: mach_msg_type_number_t = 0

    let status = host_processor_info(
      mach_host_self(), PROCESSOR_CPU_LOAD_INFO, &cpuCount, &info, &infoCount)
    guard status == KERN_SUCCESS, let info else {
      throw StressKitError.processorInfoFailed(kernReturn: status)
    }

    // The kernel allocates this in our address space and it is ours to release.
    // Missing this leaks a page per sample, which at one sample a second is a
    // leak you notice within the hour.
    defer {
      vm_deallocate(
        mach_task_self_,
        vm_address_t(UInt(bitPattern: info)),
        vm_size_t(Int(infoCount) * MemoryLayout<integer_t>.stride))
    }

    let states = Int(CPU_STATE_MAX)
    guard Int(infoCount) >= Int(cpuCount) * states else {
      throw StressKitError.processorInfoTruncated(
        expected: Int(cpuCount) * states, received: Int(infoCount))
    }

    return (0..<Int(cpuCount)).map { cpu in
      let base = cpu * states
      return CPUTicks(
        user: UInt32(bitPattern: info[base + Int(CPU_STATE_USER)]),
        system: UInt32(bitPattern: info[base + Int(CPU_STATE_SYSTEM)]),
        idle: UInt32(bitPattern: info[base + Int(CPU_STATE_IDLE)]),
        nice: UInt32(bitPattern: info[base + Int(CPU_STATE_NICE)]))
    }
  }
}

/// Turns successive tick reads into utilization, labelled by performance level.
public actor CPUUtilizationSampler {

  private let source: any CPUTickReading
  private let topology: CoreTopology
  private var previous: [CPUTicks]
  private var previousTimestamp: Date

  /// Primes the sampler with a first read, so the next `sample()` covers a real
  /// interval rather than all of uptime.
  public init(topology: CoreTopology, source: any CPUTickReading = HostProcessorInfo()) throws {
    self.topology = topology
    self.source = source
    self.previous = try source.read()
    self.previousTimestamp = Date()
  }

  /// Utilization since the previous call.
  ///
  /// Returns `nil` when no scheduler ticks elapsed on any CPU, which happens if
  /// two calls land inside the same tick.
  public func sample() throws -> CPUSample? {
    let current = try source.read()
    let now = Date()
    let interval = now.timeIntervalSince(previousTimestamp)
    let baseline = previous

    previous = current
    previousTimestamp = now

    let perCore = Self.utilization(current: current, previous: baseline)
    guard !perCore.isEmpty else { return nil }

    return CPUSample(
      timestamp: now,
      interval: interval,
      perCore: perCore,
      byPerfLevel: Self.aggregate(perCore: perCore, topology: topology))
  }

  /// Per-core utilization from two tick reads. Pure, so it can be tested
  /// against fixture counters including the rollover case.
  static func utilization(current: [CPUTicks], previous: [CPUTicks]) -> [CoreUtilization] {
    // A CPU count that changes between reads means the previous baseline is not
    // comparable. Cover the overlap and drop the rest rather than pairing
    // mismatched cores.
    let count = min(current.count, previous.count)
    return (0..<count).compactMap { cpu in
      current[cpu].delta(since: previous[cpu]).utilization(cpu: cpu)
    }
  }

  /// Groups per-core utilization by performance level using the topology's CPU
  /// index map, which is what turns raw indices into Performance / Efficiency.
  static func aggregate(
    perCore: [CoreUtilization], topology: CoreTopology
  )
    -> [PerfLevelUtilization]
  {
    let byCPU = Dictionary(perCore.map { ($0.cpu, $0) }, uniquingKeysWith: { first, _ in first })
    return topology.performanceLevels.compactMap { level in
      PerfLevelUtilization(
        levelIndex: level.index,
        name: level.name,
        cores: level.logicalCPUIDs.compactMap { byCPU[$0] })
    }
  }
}
