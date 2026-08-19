import Foundation

/// Per-worker counters, published atomically so the pool can read them while
/// the worker runs.
///
/// `busyNanoseconds / elapsedNanoseconds` is the duty cycle the worker actually
/// achieved, measured from inside the loop. That is independent of
/// `host_processor_info`, so the two together say whether a discrepancy is the
/// duty cycler missing its target or the scheduler putting the work somewhere
/// unexpected.
final class WorkerStatistics: @unchecked Sendable {
  let iterations = AtomicUInt64()
  let busyNanoseconds = AtomicUInt64()
  let elapsedNanoseconds = AtomicUInt64()
  let abandonedCycles = AtomicUInt64()
  let cycles = AtomicUInt64()
  /// Escaping store for the kernel's final accumulator state. Without a use the
  /// optimiser can see, the loop that produced it is dead code.
  let checksum = AtomicDouble()

  func snapshot() -> WorkerSample {
    WorkerSample(
      iterations: iterations.load(),
      busyNanoseconds: busyNanoseconds.load(),
      elapsedNanoseconds: elapsedNanoseconds.load(),
      abandonedCycles: abandonedCycles.load(),
      cycles: cycles.load(),
      checksum: checksum.load())
  }
}

/// A point-in-time read of one worker's counters.
public struct WorkerSample: Sendable, Equatable {
  public let iterations: UInt64
  public let busyNanoseconds: UInt64
  public let elapsedNanoseconds: UInt64
  public let abandonedCycles: UInt64
  public let cycles: UInt64
  public let checksum: Double

  /// The duty cycle this worker achieved, as measured from inside its own loop.
  public var achievedDutyCycle: Double? {
    guard elapsedNanoseconds > 0 else { return nil }
    return Double(busyNanoseconds) / Double(elapsedNanoseconds)
  }

  /// Difference between two reads, for windowed rather than lifetime rates.
  public func delta(since previous: WorkerSample) -> WorkerSample {
    WorkerSample(
      iterations: iterations &- previous.iterations,
      busyNanoseconds: busyNanoseconds &- previous.busyNanoseconds,
      elapsedNanoseconds: elapsedNanoseconds &- previous.elapsedNanoseconds,
      abandonedCycles: abandonedCycles &- previous.abandonedCycles,
      cycles: cycles &- previous.cycles,
      checksum: checksum)
  }
}
