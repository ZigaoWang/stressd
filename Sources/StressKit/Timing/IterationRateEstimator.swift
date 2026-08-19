import Foundation

/// Tracks how many compute iterations fit in a nanosecond, so a worker can size
/// a chunk of work to a deadline instead of reading the clock every iteration.
///
/// At the rates the FP64 kernel runs, a clock read per iteration would be a
/// double-digit share of the work. Sizing chunks from a measured rate moves the
/// clock reads to once per chunk, a few dozen times per 5 ms cycle.
///
/// The rate is re-measured continuously rather than on a timer: every chunk the
/// worker runs is itself a measurement, folded in through an exponentially
/// weighted average. Core frequency moves with thermal state, with the P/E core
/// the scheduler picked, and with what else is running, and this tracks all of
/// it for free — the clock reads it needs are the ones the worker already
/// makes.
public struct IterationRateEstimator: Sendable, Equatable {

  /// Weight given to each new measurement. Low enough to ride out a single
  /// noisy chunk, high enough to follow a P-to-E core migration within a few
  /// cycles.
  public static let defaultSmoothingFactor = 0.2

  /// A chunk this much slower than predicted was descheduled rather than slow,
  /// and would drag the estimate down if believed. Deschedules only ever make a
  /// chunk look slower, never faster, so the guard is one-sided.
  private static let outlierSlownessFactor = 4.0

  /// After this many rejections in a row the estimate is presumed wrong rather
  /// than the measurements, so the next sample is taken at face value. Without
  /// this, an estimate that starts far too high can never recover.
  private static let rejectionsBeforeForcedAccept = 8

  private let smoothingFactor: Double
  private var rate: Double?
  private var consecutiveRejections = 0

  public init(smoothingFactor: Double = defaultSmoothingFactor) {
    self.smoothingFactor = min(max(smoothingFactor, 0.01), 1.0)
  }

  /// Iterations per nanosecond, or `nil` before the first measurement.
  public var iterationsPerNanosecond: Double? { rate }

  /// Whether the estimator has enough data to size a chunk.
  public var isCalibrated: Bool { rate != nil }

  /// Folds in one completed chunk.
  public mutating func record(iterations: Int, nanoseconds: UInt64) {
    guard iterations > 0, nanoseconds > 0 else { return }
    let observed = Double(iterations) / Double(nanoseconds)

    guard let current = rate else {
      rate = observed
      return
    }

    let isImplausiblySlow = observed * Self.outlierSlownessFactor < current
    guard isImplausiblySlow else {
      consecutiveRejections = 0
      rate = current + smoothingFactor * (observed - current)
      return
    }

    consecutiveRejections += 1
    guard consecutiveRejections > Self.rejectionsBeforeForcedAccept else { return }

    // Every recent measurement disagreed with the estimate by the same large
    // margin. The measurements are not all wrong; the estimate is. Reset to it
    // outright rather than easing towards it, or a badly seeded estimate takes
    // hundreds of chunks to recover.
    consecutiveRejections = 0
    rate = observed
  }

  /// Iterations expected to fill `nanoseconds`, clamped to `1...maximum`.
  ///
  /// Returns `nil` before the first measurement, so the caller knows to run a
  /// calibration chunk instead of guessing.
  public func iterations(forNanoseconds nanoseconds: UInt64, maximum: Int = .max) -> Int? {
    guard let rate, rate > 0 else { return nil }
    let ideal = rate * Double(nanoseconds)
    guard ideal.isFinite else { return maximum }
    return min(max(Int(ideal.rounded()), 1), maximum)
  }

  /// Nanoseconds `iterations` is expected to take. Used to predict whether a
  /// chunk fits before the deadline.
  public func nanoseconds(forIterations iterations: Int) -> UInt64? {
    guard let rate, rate > 0 else { return nil }
    let ideal = Double(iterations) / rate
    guard ideal.isFinite, ideal >= 0 else { return nil }
    return UInt64(min(ideal, Double(UInt64.max / 2)))
  }
}
