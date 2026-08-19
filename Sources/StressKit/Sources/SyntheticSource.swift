import Foundation

/// Load generated locally, contributing nothing.
///
/// The fallback for when no contributed work is available, and the precision
/// instrument for holding an exact target: unlike a BOINC client, its load is a
/// number this process sets directly and can change within one duty cycle
/// period.
public actor SyntheticSource: LoadSource {

  /// Holds the pool outside the actor's isolation.
  ///
  /// `emergencyStop()` has to work from an `atexit` handler and from a signal
  /// path, neither of which can await an actor. The pool's own `stop()` is
  /// synchronous and idempotent, so a plain lock around the reference is enough
  /// and avoids leaving threads running after the process is on its way out.
  private final class PoolBox: @unchecked Sendable {
    private let lock = NSLock()
    private var pool: SyntheticWorkerPool?

    var current: SyntheticWorkerPool? {
      lock.lock()
      defer { lock.unlock() }
      return pool
    }

    func replace(with newPool: SyntheticWorkerPool?) {
      lock.lock()
      let previous = pool
      pool = newPool
      lock.unlock()
      previous?.stop()
    }
  }

  public nonisolated let id = "synthetic"
  public nonisolated let isContributing = false

  private let topology: CoreTopology
  private let periodNanoseconds: UInt64?
  private let clock: any MonotonicClock
  private nonisolated let box = PoolBox()

  /// Passing a `periodNanoseconds` overrides the per-level duty cycle period.
  /// Leave it `nil` to let each performance level use the period its QoS class
  /// needs.
  public init(
    topology: CoreTopology,
    periodNanoseconds: UInt64? = nil,
    clock: any MonotonicClock = MachMonotonicClock()
  ) {
    self.topology = topology
    self.periodNanoseconds = periodNanoseconds
    self.clock = clock
  }

  public func detect() async -> DetectionResult {
    .available(detail: "cpuFloat, \(topology.logicalCoreCount) logical cores")
  }

  public func start(budget: ResourceBudget) async throws {
    let existing = box.current
    if let existing, existing.placement.requestedLevelIndex == budget.placement.levelIndex {
      existing.start(dutyCycle: budget.cpu)
      return
    }

    // Placement is fixed at spawn because it decides the thread count and the
    // QoS class. Changing placement is a restart; changing the duty cycle,
    // which is what `adjust` does every second, is not.
    let pool = SyntheticWorkerPool(
      topology: topology,
      levelIndex: budget.placement.levelIndex,
      periodNanoseconds: periodNanoseconds,
      clock: clock)
    box.replace(with: pool)
    pool.start(dutyCycle: budget.cpu)
  }

  /// Changes the duty cycle on live threads.
  ///
  /// A CPU-only change never touches the threads: it is one atomic store, which
  /// every worker picks up on its next cycle. Dropping to zero parks them on a
  /// condition variable rather than spinning; raising from zero wakes them
  /// without a respawn.
  public func adjust(to budget: ResourceBudget) async throws {
    guard let pool = box.current,
      pool.placement.requestedLevelIndex == budget.placement.levelIndex
    else {
      try await start(budget: budget)
      return
    }
    pool.setDutyCycle(budget.cpu)
  }

  public func stop() async {
    box.replace(with: nil)
  }

  /// Synchronous teardown for exit paths that cannot await, such as the
  /// `atexit` backstop. Idempotent.
  public nonisolated func emergencyStop() {
    box.replace(with: nil)
  }

  public func status() async throws -> SourceStatus {
    nonisolatedStatus()
  }

  /// The same status without awaiting, for renderers already on another thread.
  public nonisolated func nonisolatedStatus() -> SourceStatus {
    guard let pool = box.current else {
      return SourceStatus(sourceID: id, isContributing: false, state: .idle, requestedLoad: 0)
    }
    let snapshot = pool.snapshot()
    return SourceStatus(
      sourceID: id,
      isContributing: false,
      state: snapshot.isRunning ? .running : .stopped,
      requestedLoad: snapshot.requestedDutyCycle,
      achievedLoad: snapshot.achievedDutyCycle,
      threadCount: snapshot.placement.threadCount,
      detail: [
        "kind": "cpuFloat",
        "placement": snapshot.placement.requestedLevelName,
        "qosHint": snapshot.placement.qosHint.rawValue,
        "targetedCPUs": snapshot.placement.targetedLogicalCPUs.map(String.init)
          .joined(separator: ","),
        "abandonedCycles": String(snapshot.abandonedCycles),
        "periodsMs": snapshot.placement.periodNanosecondsByLevel.keys.sorted()
          .map { "L\($0):\((snapshot.placement.periodNanosecondsByLevel[$0] ?? 0) / 1_000_000)" }
          .joined(separator: " "),
        "gflops": String(format: "%.1f", Self.gigaflops(snapshot: snapshot)),
      ])
  }

  /// A read of the pool's own counters, for callers that want more than
  /// `SourceStatus` carries.
  public nonisolated func poolSnapshot() -> SyntheticWorkerPool.Snapshot? {
    box.current?.snapshot()
  }

  /// Estimated whole-machine FP64 throughput, from a known FLOP count per
  /// iteration. An estimate, not a benchmark score.
  ///
  /// The divisor is wall-clock time, not summed thread time. Thread time would
  /// give the mean throughput of a single worker, which on a twelve core
  /// machine is off by a factor of twelve.
  static func gigaflops(snapshot: SyntheticWorkerPool.Snapshot) -> Double {
    let workerCount = snapshot.workers.count
    guard workerCount > 0 else { return 0 }
    let summedElapsed = snapshot.workers.reduce(0) { $0 + $1.elapsedNanoseconds }
    let wallNanoseconds = Double(summedElapsed) / Double(workerCount)
    guard wallNanoseconds > 0 else { return 0 }
    return CPUFloatKernel.flops(forIterations: Int(snapshot.totalIterations)) / wallNanoseconds
  }
}
