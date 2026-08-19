import Foundation

/// The monotonic timeline the duty cycler anchors to.
///
/// Times are absolute nanoseconds on the same uptime timeline as
/// `mach_absolute_time`, and waits are to an absolute deadline. Relative sleeps
/// are deliberately not part of this interface: each one rounds up by however
/// long the scheduler took to get back to the thread, and the error accumulates
/// until the average duty cycle no longer resembles the target.
public protocol MonotonicClock: Sendable {
  /// Nanoseconds since boot, excluding time the machine spent asleep.
  func nanoseconds() -> UInt64

  /// Blocks until the absolute deadline. Returns immediately if it has passed.
  func wait(untilNanoseconds deadline: UInt64)
}

/// `MonotonicClock` backed by the Mach timebase.
public struct MachMonotonicClock: MonotonicClock {

  /// `mach_absolute_time` ticks per nanosecond, as numerator and denominator.
  /// 125/3 on Apple silicon: the timebase runs at 24 MHz, not 1 GHz, so ticks
  /// and nanoseconds are not interchangeable.
  private let timebase: mach_timebase_info_data_t

  public init() {
    var info = mach_timebase_info_data_t()
    mach_timebase_info(&info)
    // A zero denominator would be a kernel bug, but dividing by it would be
    // ours. Fall back to a 1:1 timebase.
    timebase =
      (info.numer == 0 || info.denom == 0)
      ? mach_timebase_info_data_t(numer: 1, denom: 1)
      : info
  }

  /// `CLOCK_UPTIME_RAW` is `mach_absolute_time` already converted to
  /// nanoseconds, so this is the same timeline the deadline maths uses.
  public func nanoseconds() -> UInt64 {
    clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
  }

  public func wait(untilNanoseconds deadline: UInt64) {
    mach_wait_until(ticks(fromNanoseconds: deadline))
  }

  /// Converts nanoseconds to Mach ticks without overflowing on a machine that
  /// has been up for a long time. `nanoseconds * denom` would overflow after
  /// roughly 195 years at a 125/3 timebase, but the split form never does.
  func ticks(fromNanoseconds nanoseconds: UInt64) -> UInt64 {
    let numer = UInt64(timebase.numer)
    let denom = UInt64(timebase.denom)
    guard numer != denom else { return nanoseconds }
    return (nanoseconds / numer) * denom + ((nanoseconds % numer) * denom) / numer
  }
}
