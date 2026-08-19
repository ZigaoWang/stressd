import Foundation

/// Raw scheduler tick counters for one logical CPU.
///
/// These are free-running `natural_t` counts since boot. On their own they mean
/// nothing: utilization is the ratio of deltas between two reads.
public struct CPUTicks: Sendable, Equatable, Codable {
  public let user: UInt32
  public let system: UInt32
  public let idle: UInt32
  public let nice: UInt32

  public init(user: UInt32, system: UInt32, idle: UInt32, nice: UInt32) {
    self.user = user
    self.system = system
    self.idle = idle
    self.nice = nice
  }

  /// Ticks elapsed since an earlier read.
  ///
  /// Subtraction wraps deliberately. The counters are 32 bit and increment at
  /// the scheduler tick rate, so each one rolls over roughly every 497 days of
  /// accumulated time in that state. Wrapping subtraction gives the correct
  /// delta across a single rollover; signed subtraction would produce a
  /// nonsensical negative interval and a utilization figure to match.
  public func delta(since previous: CPUTicks) -> Delta {
    Delta(
      user: user &- previous.user,
      system: system &- previous.system,
      idle: idle &- previous.idle,
      nice: nice &- previous.nice)
  }

  /// A difference between two reads.
  public struct Delta: Sendable, Equatable {
    public let user: UInt32
    public let system: UInt32
    public let idle: UInt32
    public let nice: UInt32

    public var total: UInt64 {
      UInt64(user) + UInt64(system) + UInt64(idle) + UInt64(nice)
    }

    /// Fractions of the interval, or `nil` when no ticks elapsed at all, which
    /// happens when two samples land inside the same scheduler tick.
    public func utilization(cpu: Int) -> CoreUtilization? {
      let total = total
      guard total > 0 else { return nil }
      let divisor = Double(total)
      return CoreUtilization(
        cpu: cpu,
        user: Double(user) / divisor,
        system: Double(system) / divisor,
        nice: Double(nice) / divisor,
        idle: Double(idle) / divisor)
    }
  }
}

/// Utilization of one logical CPU over an interval, as fractions summing to 1.
public struct CoreUtilization: Sendable, Equatable, Codable {
  /// Logical CPU number, matching `CoreTopology`'s `logicalCPUIDs`.
  public let cpu: Int
  public let user: Double
  public let system: Double
  public let nice: Double
  public let idle: Double
  /// Everything that is not idle. Stored rather than computed so it appears in
  /// the JSON alongside `idle`, which callers diff against `top`.
  public let busy: Double

  public init(cpu: Int, user: Double, system: Double, nice: Double, idle: Double) {
    self.cpu = cpu
    self.user = user
    self.system = system
    self.nice = nice
    self.idle = idle
    // Derived from idle rather than summed from the other three, so busy and
    // idle can never disagree.
    self.busy = min(max(1 - idle, 0), 1)
  }

  /// Whether the four buckets partition the interval, as they must.
  public var sumsToWhole: Bool {
    abs((user + system + nice + idle) - 1) < 1e-9
  }
}

/// Utilization aggregated over one performance level.
public struct PerfLevelUtilization: Sendable, Equatable, Codable {
  public let levelIndex: Int
  public let name: String
  public let coreCount: Int
  public let user: Double
  public let system: Double
  public let nice: Double
  public let idle: Double
  /// Everything that is not idle. Stored so it appears in the JSON.
  public let busy: Double

  /// Mean over the cores on a level. Every core is one thread's worth of
  /// capacity, so an unweighted mean is the right aggregate.
  public init?(levelIndex: Int, name: String, cores: [CoreUtilization]) {
    guard !cores.isEmpty else { return nil }
    let count = Double(cores.count)
    self.levelIndex = levelIndex
    self.name = name
    self.coreCount = cores.count
    self.user = cores.reduce(0) { $0 + $1.user } / count
    self.system = cores.reduce(0) { $0 + $1.system } / count
    self.nice = cores.reduce(0) { $0 + $1.nice } / count
    self.idle = cores.reduce(0) { $0 + $1.idle } / count
    self.busy = min(max(1 - (cores.reduce(0) { $0 + $1.idle } / count), 0), 1)
  }
}

/// One interval of CPU utilization.
public struct CPUSample: Sendable, Equatable, Codable {
  public let timestamp: Date
  public let interval: TimeInterval
  /// One entry per logical CPU, ordered by logical CPU number.
  public let perCore: [CoreUtilization]
  /// Aggregated using the topology's CPU index map, so these carry the
  /// Performance / Efficiency labels rather than raw indices.
  public let byPerfLevel: [PerfLevelUtilization]
  /// Mean busy fraction across every logical CPU: 1.0 is the whole machine.
  public let systemWide: Double
  /// Mean idle fraction. Reported alongside `systemWide` so the output can be
  /// diffed directly against `top -l 2 -n 0`, which quotes idle rather than
  /// busy. The two must sum to 1.
  public let systemWideIdle: Double
  /// Mean user, system and nice fractions across every logical CPU.
  public let systemWideUser: Double
  public let systemWideSystem: Double
  public let systemWideNice: Double

  public init(
    timestamp: Date,
    interval: TimeInterval,
    perCore: [CoreUtilization],
    byPerfLevel: [PerfLevelUtilization]
  ) {
    self.timestamp = timestamp
    self.interval = interval
    self.perCore = perCore
    self.byPerfLevel = byPerfLevel

    let count = Double(max(perCore.count, 1))
    self.systemWide =
      perCore.isEmpty ? 0 : perCore.reduce(0) { $0 + $1.busy } / count
    self.systemWideIdle =
      perCore.isEmpty ? 1 : perCore.reduce(0) { $0 + $1.idle } / count
    self.systemWideUser = perCore.reduce(0) { $0 + $1.user } / count
    self.systemWideSystem = perCore.reduce(0) { $0 + $1.system } / count
    self.systemWideNice = perCore.reduce(0) { $0 + $1.nice } / count

    assert(
      perCore.allSatisfy { $0.sumsToWhole },
      "CPU state fractions must sum to 1: a bucket is being dropped or double counted")
  }

  /// Largest deviation from 1.0 across the per-core fractions.
  ///
  /// The four `CPU_STATE_*` buckets partition the interval, so they must sum to
  /// exactly 1. Anything else means a bucket was dropped, counted twice, or
  /// divided by the wrong base — the failure modes that would silently invert
  /// or inflate every utilization figure stressd reports.
  public var largestFractionError: Double {
    perCore.map { abs(($0.user + $0.system + $0.nice + $0.idle) - 1) }.max() ?? 0
  }
}
