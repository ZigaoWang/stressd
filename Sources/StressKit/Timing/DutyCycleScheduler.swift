import Foundation

/// Produces the work and sleep deadlines a worker thread alternates between.
///
/// Two mechanisms, and both are needed:
///
/// **The cycle boundary is anchored.** Cycle *n* ends at `anchor + (n+1) *
/// period`, never at "now plus a bit". That fixes the denominator of the duty
/// cycle: after *n* cycles exactly `n * period` has elapsed, with no
/// accumulated drift. Repeated relative sleeps compound their jitter instead,
/// and the average duty cycle walks away from the target over minutes.
///
/// **The work quantum is a debt, measured from arrival.** Each cycle adds
/// `period * dutyCycle` nanoseconds of owed work, and the worker pays it down.
/// This fixes the numerator. It matters because `mach_wait_until` reliably
/// *over*sleeps — macOS coalesces timers, by around 20% of the requested
/// interval in practice — so a worker routinely arrives at a cycle already
/// late. Measuring the work window from the grid start would silently hand that
/// oversleep back as lost work, and because oversleep is one-sided the loss is
/// a systematic undershoot rather than noise: measured at 5 ms and 25%, it cost
/// close to 15 percentage points.
///
/// Debt is capped, so a thread that loses the CPU for a while cannot come back
/// and run flat out to repay it.
///
/// Pure value semantics and no system calls, so the scheduling behaviour can be
/// tested against a fake clock without running a worker.
public struct DutyCycleScheduler: Sendable, Equatable {

  /// One work-then-sleep cycle, in absolute nanoseconds.
  public struct Cycle: Sendable, Equatable {
    /// Cycle number since the current anchor.
    public let index: UInt64
    /// Where this cycle sits on the anchored grid. May be in the past when the
    /// previous cycle overran or its sleep overshot.
    public let start: UInt64
    /// Run compute until this instant.
    public let workDeadline: UInt64
    /// Sleep until this instant, then start the next cycle.
    public let end: UInt64

    /// The compute budget for this cycle, from the instant the worker arrived.
    public func workNanoseconds(now: UInt64) -> UInt64 {
      workDeadline > now ? workDeadline - now : 0
    }

    /// True when the whole period is compute and the worker must not sleep.
    /// At 100% there is no wait path at all: even `mach_wait_until` with a past
    /// deadline costs a syscall, and at 200 cycles per second per thread that
    /// is not free.
    public var isSaturated: Bool { workDeadline >= end }
  }

  /// The default cycle period. Fine enough that a 50% duty cycle is invisible
  /// to the user, coarse enough that per-cycle overhead stays negligible: two
  /// clock reads and at most one `mach_wait_until` per 5 ms is well under 1%.
  public static let defaultPeriodNanoseconds: UInt64 = 5_000_000

  /// Below this the syscall and wake-up cost starts to distort the duty cycle.
  public static let minimumPeriodNanoseconds: UInt64 = 500_000

  /// How far behind schedule a worker may fall before the anchor is reset.
  ///
  /// Without this, a thread that loses the CPU for 200 ms would come back and
  /// run flat out to "catch up" on 40 missed cycles, producing exactly the
  /// overshoot the duty cycler exists to prevent. Missed cycles are abandoned,
  /// not repaid.
  public static let maximumCatchUpPeriods: UInt64 = 4

  /// How much unpaid work may accumulate, as a multiple of one cycle's quantum.
  ///
  /// Enough to absorb an oversleep or a single overrun, not enough for a
  /// visible burst of catch-up load. Work beyond this is written off.
  public static let maximumDebtQuanta: UInt64 = 2

  /// Length of one work-then-sleep cycle, in nanoseconds.
  public let periodNanoseconds: UInt64

  /// The instant cycle 0 began. Reset when a worker falls too far behind.
  public private(set) var anchor: UInt64
  /// Cycles issued since the current anchor.
  public private(set) var issuedCycles: UInt64
  /// Cycles abandoned because the worker fell too far behind. Surfaced as a
  /// health signal: a rising count means the machine is oversubscribed and the
  /// duty cycle is no longer being honoured.
  public private(set) var abandonedCycles: UInt64
  /// Owed but not yet performed compute, in nanoseconds.
  public private(set) var workDebtNanoseconds: UInt64

  public init(anchor: UInt64, periodNanoseconds: UInt64 = defaultPeriodNanoseconds) {
    self.anchor = anchor
    self.periodNanoseconds = max(periodNanoseconds, Self.minimumPeriodNanoseconds)
    self.issuedCycles = 0
    self.abandonedCycles = 0
    self.workDebtNanoseconds = 0
  }

  /// Issues the next cycle.
  ///
  /// - Parameters:
  ///   - now: The current instant, from the same clock the anchor came from.
  ///   - dutyCycle: Target fraction of the period to spend computing, clamped
  ///     to `0...1`.
  /// - Returns: The cycle to run. The work deadline is measured from `now`, so
  ///   arriving late costs nothing; the cycle boundary stays on the grid, so
  ///   arriving late does not push the schedule back either.
  ///
  /// - Important: Every call must be paired with `completeCycle(workedNanoseconds:)`.
  ///   Without it the debt is never paid down, and after a couple of cycles
  ///   every deadline clamps to the cycle boundary and the worker runs at 100%
  ///   regardless of the target.
  public mutating func nextCycle(now: UInt64, dutyCycle: Double) -> Cycle {
    reanchorIfFallenBehind(now: now)

    let start = anchor &+ issuedCycles &* periodNanoseconds
    let end = start &+ periodNanoseconds
    issuedCycles &+= 1

    let quantum = Self.workNanoseconds(period: periodNanoseconds, dutyCycle: dutyCycle)
    workDebtNanoseconds = min(
      workDebtNanoseconds &+ quantum, quantum &* Self.maximumDebtQuanta)

    // From `now`, not from `start`: an overslept wait must not be charged to
    // the work window. Clamped to the cycle boundary so repaying a backlog can
    // never exceed 100% within a cycle.
    let deadline = min(max(now, start) &+ workDebtNanoseconds, end)

    return Cycle(index: issuedCycles &- 1, start: start, workDeadline: deadline, end: end)
  }

  /// Records compute actually performed, paying down the debt.
  ///
  /// A worker that fell short carries the remainder into the next cycle, up to
  /// the debt cap.
  public mutating func completeCycle(workedNanoseconds: UInt64) {
    workDebtNanoseconds &-= min(workDebtNanoseconds, workedNanoseconds)
  }

  /// Moves the anchor to `now`, restarts the cycle count, and clears the debt.
  ///
  /// Called when the duty cycle crosses zero: a parked thread owes nothing for
  /// the time it spent parked.
  public mutating func reanchor(to now: UInt64) {
    anchor = now
    issuedCycles = 0
    workDebtNanoseconds = 0
  }

  private mutating func reanchorIfFallenBehind(now: UInt64) {
    let scheduledStart = anchor &+ issuedCycles &* periodNanoseconds
    guard now > scheduledStart else { return }

    let lateBy = now - scheduledStart
    guard lateBy > periodNanoseconds &* Self.maximumCatchUpPeriods else { return }

    abandonedCycles &+= lateBy / periodNanoseconds
    reanchor(to: now)
  }

  /// The compute budget for one period at a given duty cycle.
  ///
  /// Separated out so the arithmetic can be tested on its own.
  public static func workNanoseconds(period: UInt64, dutyCycle: Double) -> UInt64 {
    guard dutyCycle > 0 else { return 0 }
    guard dutyCycle < 1 else { return period }
    // Round to nearest rather than truncating: at a 5 ms period, truncation
    // biases every cycle low by up to a nanosecond, which is negligible, but
    // rounding costs nothing and removes the systematic direction.
    return UInt64((Double(period) * dutyCycle).rounded())
  }
}
