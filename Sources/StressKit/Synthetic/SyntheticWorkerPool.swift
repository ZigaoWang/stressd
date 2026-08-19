import Foundation

/// Owns the synthetic worker threads and the duty cycle they share.
///
/// One thread per targeted logical core, always. A 50% target means every
/// thread runs at 50%, not half the threads at 100%. Spreading the load keeps
/// the power curve close to linear and leaves the closed-loop governor a single
/// scalar to move, which is the whole reason the duty cycler exists.
public final class SyntheticWorkerPool: @unchecked Sendable {

  /// Where a pool was asked to put its threads, and what it was given.
  public struct Placement: Sendable, Equatable, Codable {
    /// Performance level index, or `nil` when spread across all levels.
    public let requestedLevelIndex: Int?
    public let requestedLevelName: String
    public let qosHint: QoSHint
    /// Logical CPU numbers the requested level occupies. Where the work is
    /// *expected* to land, not where it did: QoS is a hint.
    public let targetedLogicalCPUs: [Int]
    public let threadCount: Int
    /// Duty cycle period per performance level, in nanoseconds. Levels whose
    /// QoS class coalesces timers get a longer one; see
    /// `QoSHint.recommendedPeriodNanoseconds`.
    public let periodNanosecondsByLevel: [Int: UInt64]
  }

  /// A read of the whole pool.
  public struct Snapshot: Sendable {
    public let requestedDutyCycle: Double
    public let placement: Placement
    public let workers: [WorkerSample]
    public let isRunning: Bool

    /// Duty cycle achieved across all workers, measured inside the loops.
    public var achievedDutyCycle: Double? {
      let elapsed = workers.reduce(0) { $0 + $1.elapsedNanoseconds }
      guard elapsed > 0 else { return nil }
      let busy = workers.reduce(0) { $0 + $1.busyNanoseconds }
      return Double(busy) / Double(elapsed)
    }

    /// Cycles abandoned because a worker fell too far behind schedule. A
    /// non-zero and rising figure means the machine is oversubscribed and the
    /// duty cycle is no longer being honoured.
    public var abandonedCycles: UInt64 {
      workers.reduce(0) { $0 + $1.abandonedCycles }
    }

    public var totalIterations: UInt64 {
      workers.reduce(0) { $0 + $1.iterations }
    }
  }

  private let clock: any MonotonicClock
  private let periodOverride: UInt64?
  private let dutyCycle = AtomicDouble(0)
  private let isRunningFlag = AtomicFlag(false)
  private let gate: WorkerGate
  private let workers: [SyntheticWorker]
  private var threads: [Thread] = []
  private let periodsByLevel: [Int: UInt64]
  private let lifecycleLock = NSLock()

  public let placement: Placement

  /// - Parameters:
  ///   - topology: Used to size the pool and pick a QoS hint per level.
  ///   - levelIndex: Performance level to target, or `nil` for every core.
  ///   - periodNanoseconds: Overrides the per-level period. Leave `nil` to use
  ///     the period each level's QoS class needs, which is what holds the duty
  ///     cycle without disturbing core placement.
  ///   - clock: Injected so scheduling can be exercised without real threads.
  public init(
    topology: CoreTopology,
    levelIndex: Int?,
    periodNanoseconds: UInt64? = nil,
    clock: any MonotonicClock = MachMonotonicClock()
  ) {
    self.clock = clock
    self.periodOverride = periodNanoseconds.map {
      max($0, DutyCycleScheduler.minimumPeriodNanoseconds)
    }
    self.gate = WorkerGate(dutyCycle: dutyCycle, isRunning: isRunningFlag)

    let levels: [PerformanceLevel]
    if let levelIndex, topology.performanceLevels.indices.contains(levelIndex) {
      levels = [topology.performanceLevels[levelIndex]]
    } else {
      levels = topology.performanceLevels
    }

    var built: [SyntheticWorker] = []
    var targeted: [Int] = []
    var periods: [Int: UInt64] = [:]
    for level in levels {
      targeted.append(contentsOf: level.logicalCPUIDs)
      // Each level gets the period its QoS class needs. A .background level
      // whose timers coalesce by tens of milliseconds cannot hold a target on a
      // 5 ms period, and sharpening its timers instead would move the work off
      // the efficiency cores.
      let period = self.periodOverride ?? level.qosHint.recommendedPeriodNanoseconds
      periods[level.index] = period
      // One thread per logical core on the level, regardless of the duty cycle.
      for _ in 0..<level.logicalCoreCount {
        built.append(
          SyntheticWorker(
            logicalIndex: built.count,
            performanceLevelIndex: level.index,
            qosHint: level.qosHint,
            periodNanoseconds: period,
            clock: clock,
            dutyCycle: dutyCycle,
            isRunning: isRunningFlag,
            gate: gate))
      }
    }
    self.workers = built
    self.periodsByLevel = periods

    self.placement = Placement(
      requestedLevelIndex: levels.count == 1 ? levels[0].index : nil,
      requestedLevelName: levels.count == 1 ? levels[0].name : "all",
      qosHint: levels.count == 1 ? levels[0].qosHint : .userInteractive,
      targetedLogicalCPUs: targeted.sorted(),
      threadCount: self.workers.count,
      periodNanosecondsByLevel: periods)
  }

  public var isRunning: Bool { isRunningFlag.value }

  public var requestedDutyCycle: Double { dutyCycle.load() }

  /// Spawns the threads. Idempotent: a second call is a no-op.
  ///
  /// Threads start parked if `dutyCycle` is zero, so starting a pool costs
  /// nothing until there is work for it.
  public func start(dutyCycle target: Double) {
    lifecycleLock.lock()
    defer { lifecycleLock.unlock() }
    guard threads.isEmpty else {
      gate.setDutyCycle(Self.clamp(target))
      return
    }

    isRunningFlag.value = true
    gate.setDutyCycle(Self.clamp(target))

    threads = workers.map { worker in
      let thread = Thread { worker.run() }
      thread.name = "stressd.synthetic.\(worker.logicalIndex)"
      thread.qualityOfService = worker.qosHint.qualityOfService
      // Large enough for the kernel's vector state with room to spare; small
      // enough that a 16-thread pool costs well under a megabyte.
      thread.stackSize = 128 * 1024
      thread.start()
      return thread
    }
  }

  /// Changes the duty cycle on live threads.
  ///
  /// Never tears the pool down and never respawns. Crossing zero parks or wakes
  /// the threads through the gate; every other change is a single atomic store
  /// the workers pick up on their next cycle, within one period.
  public func setDutyCycle(_ target: Double) {
    gate.setDutyCycle(Self.clamp(target))
  }

  /// Stops every worker and waits for the threads to exit. Idempotent.
  public func stop() {
    lifecycleLock.lock()
    let running = threads
    threads = []
    lifecycleLock.unlock()

    guard !running.isEmpty else {
      isRunningFlag.value = false
      return
    }

    gate.stop()
    // Threads park at most one period deep and check the flag every cycle, so
    // this settles in a few milliseconds. The bound is a backstop, not an
    // expectation.
    let deadline = Date().addingTimeInterval(2)
    while running.contains(where: { !$0.isFinished }), Date() < deadline {
      usleep(1_000)
    }
  }

  public func snapshot() -> Snapshot {
    Snapshot(
      requestedDutyCycle: dutyCycle.load(),
      placement: placement,
      workers: workers.map { $0.statistics.snapshot() },
      isRunning: isRunningFlag.value)
  }

  private static func clamp(_ value: Double) -> Double {
    guard value.isFinite else { return 0 }
    return min(max(value, 0), 1)
  }
}
