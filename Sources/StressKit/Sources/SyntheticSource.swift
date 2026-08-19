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
  /// Holds the GPU worker outside actor isolation, for the same reason the CPU
  /// pool is held that way: emergency teardown cannot await.
  private final class GPUBox: @unchecked Sendable {
    private let lock = NSLock()
    private var worker: MetalGPUWorker?

    var current: MetalGPUWorker? {
      lock.lock()
      defer { lock.unlock() }
      return worker
    }

    func replace(with newWorker: MetalGPUWorker?) {
      lock.lock()
      let previous = worker
      worker = newWorker
      lock.unlock()
      previous?.stop()
    }
  }

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
  private let kind: WorkerKind
  private let gpuProfile: GPUProfile
  private nonisolated let gpuBox = GPUBox()
  private let periodNanoseconds: UInt64?
  private let periodPolicy = PeriodPolicy()
  private let clock: any MonotonicClock
  private nonisolated let box = PoolBox()

  /// Passing a `periodNanoseconds` overrides the per-level duty cycle period.
  /// Leave it `nil` to let each performance level use the period its QoS class
  /// needs.
  public init(
    topology: CoreTopology,
    periodNanoseconds: UInt64? = nil,
    kind: WorkerKind = .cpuFloat,
    gpuProfile: GPUProfile = .mixed,
    clock: any MonotonicClock = MachMonotonicClock()
  ) {
    self.topology = topology
    self.kind = kind
    self.gpuProfile = gpuProfile
    self.periodNanoseconds = periodNanoseconds
    self.clock = clock
  }

  public func detect() async -> DetectionResult {
    .available(
      detail: "\(kind.rawValue) (\(kind.summary)), \(topology.logicalCoreCount) logical cores")
  }

  public func start(budget: ResourceBudget) async throws {
    let existing = box.current
    if let existing, existing.placement.requestedLevelIndex == budget.placement.levelIndex {
      existing.start(dutyCycle: budget.cpu)
      // GPU load is independent of the CPU pool and must still be started.
      startGPUIfRequested(budget)
      return
    }

    // Placement is fixed at spawn because it decides the thread count and the
    // QoS class. Changing placement is a restart; changing the duty cycle,
    // which is what `adjust` does every second, is not.
    let pool = SyntheticWorkerPool(
      topology: topology,
      levelIndex: budget.placement.levelIndex,
      kind: kind,
      periodNanoseconds: periodNanoseconds,
      periodPolicy: periodPolicy,
      clock: clock)
    box.replace(with: pool)
    pool.start(dutyCycle: budget.cpu)
    startGPUIfRequested(budget)
  }

  /// Starts or updates the Metal worker. GPU load is always optional: a machine
  /// with no usable Metal device runs CPU load and reports the GPU as absent.
  private func startGPUIfRequested(_ budget: ResourceBudget) {
    guard let gpu = budget.gpu, gpu > 0 else {
      gpuBox.current?.setDutyCycle(0)
      return
    }
    if gpuBox.current == nil {
      gpuBox.replace(with: MetalGPUWorker(profile: gpuProfile, clock: clock))
    }
    gpuBox.current?.start(dutyCycle: gpu)
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
    if let gpu = budget.gpu {
      gpuBox.current?.setDutyCycle(gpu)
    }
  }

  public func stop() async {
    box.replace(with: nil)
    gpuBox.replace(with: nil)
  }

  /// Synchronous teardown for exit paths that cannot await, such as the
  /// `atexit` backstop. Idempotent.
  public nonisolated func emergencyStop() {
    box.replace(with: nil)
    gpuBox.replace(with: nil)
  }

  /// GPU fields for `SourceStatus`, empty when no GPU load is running.
  private nonisolated func gpuDetail() -> [String: String] {
    guard let gpu = gpuBox.current?.snapshot() else { return [:] }
    var detail: [String: String] = [
      "gpuDevice": gpu.deviceName,
      "gpuProfile": gpu.profile.rawValue,
      "gpuRequested": String(format: "%.1f%%", gpu.requestedDutyCycle * 100),
      "gpuDispatches": String(gpu.dispatches),
    ]
    if let achieved = gpu.achievedDutyCycle {
      detail["gpuAchieved"] = String(format: "%.1f%%", achieved * 100)
    }
    if let geometry = gpu.geometry {
      detail["gpuGeometry"] =
        "\(geometry.threadsPerThreadgroup)x\(geometry.threadgroupCount)"
    }
    if let gigaflops = gpu.estimatedGigaflops {
      detail["gpuGflops"] = String(format: "%.1f", gigaflops)
    }
    return detail
  }

  /// A read of the GPU worker's counters, or `nil` when no GPU load is running.
  public nonisolated func gpuSnapshot() -> GPUWorkerSample? {
    gpuBox.current?.snapshot()
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
        "kind": kind.rawValue,
        "placement": snapshot.placement.requestedLevelName,
        "qosHint": snapshot.placement.qosHint.rawValue,
        "targetedCPUs": snapshot.placement.targetedLogicalCPUs.map(String.init)
          .joined(separator: ","),
        "abandonedCycles": String(snapshot.abandonedCycles),
        "coalescingMs": QoSHint.allCases.compactMap { hint -> String? in
          guard let measured = box.current?.measuredOvershoot(for: hint) else { return nil }
          return String(format: "%@:%.1f", hint.rawValue, Double(measured) / 1e6)
        }.joined(separator: " "),
        "periodsMs": snapshot.periodNanosecondsByLevel.keys.sorted()
          .map { "L\($0):\((snapshot.periodNanosecondsByLevel[$0] ?? 0) / 1_000_000)" }
          .joined(separator: " "),
        "gflops": String(format: "%.1f", gigaflops(snapshot: snapshot)),
      ].merging(gpuDetail()) { current, _ in current })
  }

  /// Re-measures the timer coalescing window and updates live worker periods.
  /// Call when the power state changes.
  @discardableResult
  public func remeasurePeriods() -> [Int: UInt64] {
    box.current?.remeasurePeriods(topology: topology) ?? [:]
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
  nonisolated func gigaflops(snapshot: SyntheticWorkerPool.Snapshot) -> Double {
    let workerCount = snapshot.workers.count
    guard workerCount > 0 else { return 0 }
    let summedElapsed = snapshot.workers.reduce(0) { $0 + $1.elapsedNanoseconds }
    let wallNanoseconds = Double(summedElapsed) / Double(workerCount)
    guard wallNanoseconds > 0 else { return 0 }
    let flopsPerIteration =
      AnyComputeKernel(kind: kind, seed: 0).flopsPerIteration
    return Double(snapshot.totalIterations) * flopsPerIteration / wallNanoseconds
  }
}
