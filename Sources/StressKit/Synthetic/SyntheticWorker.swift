import Foundation

/// One duty-cycled compute thread.
///
/// The loop is: read the target, take the next cycle's deadlines from the
/// anchored scheduler, run calibrated chunks of FP64 until the work deadline,
/// then sleep to the cycle boundary. Nothing here allocates, takes a lock, or
/// makes a syscall other than the clock reads and the one `mach_wait_until`.
final class SyntheticWorker: @unchecked Sendable {

  /// Target length of a single compute chunk. Short enough that the work
  /// deadline is hit within a fraction of a percent, long enough that the two
  /// clock reads bracketing it are noise.
  private static let chunkTargetNanoseconds: UInt64 = 200_000

  /// Work windows shorter than this are left to the sleep path. Trying to fill
  /// them costs more in overshoot than it gains in accuracy.
  private static let minimumChunkNanoseconds: UInt64 = 2_000

  /// Backstop against a wildly wrong estimate turning into a multi-second
  /// chunk that ignores its deadline.
  private static let maximumChunkIterations = 8_000_000

  let logicalIndex: Int
  let performanceLevelIndex: Int
  let qosHint: QoSHint
  let kind: WorkerKind
  let statistics = WorkerStatistics()

  private let clock: any MonotonicClock
  private let dutyCycle: AtomicDouble
  private let isRunning: AtomicFlag
  private let gate: WorkerGate
  /// Read every cycle so a re-measured period takes effect on the live thread.
  private let periodNanoseconds: AtomicUInt64

  init(
    logicalIndex: Int,
    performanceLevelIndex: Int,
    qosHint: QoSHint,
    kind: WorkerKind = .cpuFloat,
    periodNanoseconds: AtomicUInt64,
    clock: any MonotonicClock,
    dutyCycle: AtomicDouble,
    isRunning: AtomicFlag,
    gate: WorkerGate
  ) {
    self.logicalIndex = logicalIndex
    self.performanceLevelIndex = performanceLevelIndex
    self.qosHint = qosHint
    self.kind = kind
    self.periodNanoseconds = periodNanoseconds
    self.clock = clock
    self.dutyCycle = dutyCycle
    self.isRunning = isRunning
    self.gate = gate
  }

  /// Thread entry point. Returns when the run flag clears.
  func run() {
    // Set on the thread itself rather than only on the Thread object: this is
    // the call the kernel actually reads for scheduling. It remains a hint, not
    // affinity, which is why the pool reports observed placement alongside it.
    //
    // Deliberately no THREAD_LATENCY_QOS_POLICY here. It would sharpen the
    // timer wake-ups but also lift the thread off the efficiency cores; the
    // longer period this worker was given for its QoS class solves the timing
    // without touching placement. See QoSHint.recommendedPeriodNanoseconds.
    pthread_set_qos_class_self_np(qosHint.qosClass, 0)

    var kernel = AnyComputeKernel(kind: kind, seed: UInt64(logicalIndex &+ 1))
    defer { kernel.release() }
    var estimator = IterationRateEstimator()
    var activePeriod = periodNanoseconds.load()
    var scheduler = DutyCycleScheduler(
      anchor: clock.nanoseconds(), periodNanoseconds: activePeriod)

    var cycleStart = clock.nanoseconds()

    while isRunning.value {
      var target = dutyCycle.load()

      if target <= 0 {
        publish(checksum: kernel.checksum, abandoned: scheduler.abandonedCycles)
        guard gate.parkUntilWorkAvailable() else { break }
        // Cycles missed while parked are not owed back, or the thread would
        // wake and run flat out to repay them.
        cycleStart = clock.nanoseconds()
        scheduler.reanchor(to: cycleStart)
        target = dutyCycle.load()
        if target <= 0 { continue }
      }

      // A re-measured period rebuilds the scheduler on this thread rather than
      // replacing the thread. Rare: only when the power state changes.
      let requestedPeriod = periodNanoseconds.load()
      if requestedPeriod != activePeriod {
        activePeriod = requestedPeriod
        scheduler = DutyCycleScheduler(anchor: cycleStart, periodNanoseconds: activePeriod)
      }

      let cycle = scheduler.nextCycle(now: cycleStart, dutyCycle: target)
      let busy = compute(until: cycle.workDeadline, kernel: &kernel, estimator: &estimator)
      scheduler.completeCycle(workedNanoseconds: busy)

      // At 100% there is no wait at all. A zero-length mach_wait_until is still
      // a syscall, 200 times a second on every core.
      if !cycle.isSaturated {
        clock.wait(untilNanoseconds: cycle.end)
      }

      // Elapsed is measured, not assumed to be one period: an overslept wait or
      // an abandoned cycle has to show up in the worker's own duty cycle figure
      // rather than being quietly rounded away.
      let next = clock.nanoseconds()
      statistics.busyNanoseconds.add(busy)
      statistics.elapsedNanoseconds.add(next &- cycleStart)
      statistics.cycles.add(1)
      cycleStart = next
    }

    publish(checksum: kernel.checksum, abandoned: scheduler.abandonedCycles)
  }

  /// Runs calibrated chunks until the deadline, returning nanoseconds spent.
  private func compute(
    until deadline: UInt64,
    kernel: inout AnyComputeKernel,
    estimator: inout IterationRateEstimator
  ) -> UInt64 {
    var now = clock.nanoseconds()
    let start = now
    var completedIterations: UInt64 = 0

    while now < deadline {
      let remaining = deadline - now
      guard remaining >= Self.minimumChunkNanoseconds else { break }

      let budget = min(remaining, Self.chunkTargetNanoseconds)
      let iterations =
        estimator.iterations(forNanoseconds: budget, maximum: Self.maximumChunkIterations)
        ?? kernel.calibrationIterations

      kernel.run(iterations: iterations)

      let after = clock.nanoseconds()
      // Every chunk is a measurement: this is the continuous recalibration that
      // keeps chunk sizing correct as core frequency moves with thermal state
      // or as the scheduler migrates the thread between core classes.
      estimator.record(iterations: iterations, nanoseconds: after &- now)
      completedIterations &+= UInt64(iterations)
      now = after
    }

    statistics.iterations.add(completedIterations)
    return now &- start
  }

  private func publish(checksum: Double, abandoned: UInt64) {
    statistics.checksum.store(checksum)
    statistics.abandonedCycles.store(abandoned)
  }
}
