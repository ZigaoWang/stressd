import Darwin
import Foundation

/// Measures how far the kernel actually overshoots a requested sleep on a given
/// QoS class, so the duty cycle period can be derived rather than hardcoded.
///
/// ## Why this is measured and not a constant
///
/// macOS coalesces timer wake-ups, and the window depends on the QoS class, the
/// hardware, the OS version, and the current power state. A 5 ms period cannot
/// hold a duty cycle against a 77 ms overshoot, and the fix is a period long
/// enough that the overshoot is small relative to it — which means the right
/// period is a function of the measured window, not a number chosen on one
/// machine.
///
/// 100 ms happened to be the knee on an M3 Pro running macOS 26 because the
/// `.background` window there is roughly 77 ms. On hardware where that window
/// is different, so is the knee.
public enum TimerCoalescingProbe {

  /// Requested sleep per probe sample. The overshoot is what is being measured
  /// and it does not scale with this, so it is kept short.
  private static let probeSleepNanoseconds: UInt64 = 2_000_000

  /// Samples per probe. The median of three is enough to reject a single
  /// unlucky wake-up without making startup noticeably slower.
  private static let sampleCount = 3

  /// Hard ceiling on how long a probe may take. A pathological machine must not
  /// stall startup.
  private static let budgetNanoseconds: UInt64 = 600_000_000

  /// Median overshoot for `qosClass`, in nanoseconds.
  ///
  /// Runs on a dedicated thread set to the class in question, because the
  /// coalescing window is a property of the thread's QoS.
  public static func measureOvershoot(qosClass: qos_class_t) -> UInt64 {
    let result = ProbeResult()

    let thread = Thread {
      pthread_set_qos_class_self_np(qosClass, 0)

      var overshoots: [UInt64] = []
      let started = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
      var timebase = mach_timebase_info_data_t()
      mach_timebase_info(&timebase)

      for _ in 0..<sampleCount {
        let now = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
        guard now &- started < budgetNanoseconds else { break }

        let deadline = now &+ probeSleepNanoseconds
        mach_wait_until(ticks(fromNanoseconds: deadline, timebase: timebase))
        let woke = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
        overshoots.append(woke > deadline ? woke &- deadline : 0)
      }
      result.store(median(overshoots))
    }
    thread.name = "stressd.coalescing-probe"
    thread.stackSize = 64 * 1024
    thread.start()

    // Bounded wait: the probe is capped, and a probe that somehow hangs must
    // not take startup with it.
    let deadline = Date().addingTimeInterval(2)
    while !thread.isFinished, Date() < deadline {
      usleep(2_000)
    }
    return result.value
  }

  /// The duty cycle period to use given a measured coalescing window.
  ///
  /// `max(measured * 1.5, 50 ms)`. The 1.5 multiplier keeps the overshoot to
  /// roughly two thirds of a period, which the work-debt accounting absorbs;
  /// the 50 ms floor stops a machine that reports a tiny window from getting a
  /// period so short that ordinary scheduling noise dominates it.
  public static func period(forOvershoot overshoot: UInt64) -> UInt64 {
    let scaled = UInt64(Double(overshoot) * 1.5)
    return max(scaled, 50_000_000)
  }

  private static func median(_ values: [UInt64]) -> UInt64 {
    guard !values.isEmpty else { return 0 }
    let sorted = values.sorted()
    return sorted[sorted.count / 2]
  }

  private static func ticks(
    fromNanoseconds nanoseconds: UInt64, timebase: mach_timebase_info_data_t
  ) -> UInt64 {
    let numer = UInt64(timebase.numer)
    let denom = UInt64(timebase.denom)
    guard numer != denom, numer != 0 else { return nanoseconds }
    return (nanoseconds / numer) * denom + ((nanoseconds % numer) * denom) / numer
  }

  private final class ProbeResult: @unchecked Sendable {
    private let lock = NSLock()
    private var measured: UInt64 = 0

    func store(_ value: UInt64) {
      lock.lock()
      measured = value
      lock.unlock()
    }

    var value: UInt64 {
      lock.lock()
      defer { lock.unlock() }
      return measured
    }
  }
}

/// Duty cycle periods for a machine, measured once and re-measured when the
/// power state changes.
///
/// Low Power Mode and switching between AC and battery both change how the
/// scheduler behaves, and coalescing is exactly the kind of thing that moves
/// with them, so the measurement is not treated as permanent.
public final class PeriodPolicy: @unchecked Sendable {

  private let lock = NSLock()
  private var periods: [QoSHint: UInt64] = [:]
  private var measuredOvershoots: [QoSHint: UInt64] = [:]

  public init() {}

  /// The period for a QoS class, measuring it on first use.
  public func period(for hint: QoSHint) -> UInt64 {
    lock.lock()
    if let cached = periods[hint] {
      lock.unlock()
      return cached
    }
    lock.unlock()

    // Classes that do not coalesce meaningfully keep the short default: a
    // 638 us overshoot on a 5 ms period is well within what the debt model
    // absorbs, and a short period gives finer control.
    guard hint.coalescesTimersAggressively else {
      lock.lock()
      periods[hint] = DutyCycleScheduler.defaultPeriodNanoseconds
      lock.unlock()
      return DutyCycleScheduler.defaultPeriodNanoseconds
    }

    let overshoot = TimerCoalescingProbe.measureOvershoot(qosClass: hint.qosClass)
    let period = TimerCoalescingProbe.period(forOvershoot: overshoot)

    lock.lock()
    measuredOvershoots[hint] = overshoot
    periods[hint] = period
    lock.unlock()
    return period
  }

  /// The overshoot measured for a class, if it was probed.
  public func measuredOvershoot(for hint: QoSHint) -> UInt64? {
    lock.lock()
    defer { lock.unlock() }
    return measuredOvershoots[hint]
  }

  /// Discards the cache so the next request re-measures. Called when the power
  /// state changes.
  public func invalidate() {
    lock.lock()
    periods.removeAll()
    measuredOvershoots.removeAll()
    lock.unlock()
  }
}
