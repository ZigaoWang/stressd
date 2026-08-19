import Darwin
import Foundation

/// Controls how aggressively the kernel is allowed to coalesce a thread's timer
/// wake-ups.
///
/// ## The measurement
///
/// macOS coalesces timers to save power, and how much depends on the thread's
/// QoS class. Asking `mach_wait_until` for a 2.5 ms sleep on an M3 Pro and
/// recording the median overshoot:
///
/// | QoS                | default   | latency tier 0 |
/// |--------------------|----------:|---------------:|
/// | `.userInteractive` |    638 us |         325 us |
/// | `.utility`         |   7654 us |         324 us |
/// | `.background`      |  77635 us |         329 us |
///
/// A 5 ms duty cycle period cannot survive a 77 ms overshoot. That is what a
/// `.background` worker was really doing: 2.5 ms of work followed by an 80 ms
/// sleep, about 3% duty against a 50% request.
///
/// ## The tradeoff, which is not avoidable
///
/// Requesting a low latency tier also lifts the thread off the efficiency
/// cores. Running six `.background` threads at 50% duty and measuring where the
/// work landed:
///
/// | latency tier | overshoot | E-cores | P-cores |
/// |--------------|----------:|--------:|--------:|
/// | default      |  76880 us |     58% |     14% |
/// | tier 0       |    324 us |     46% |     62% |
/// | tier 1       |    629 us |     50% |     71% |
/// | tier 2       |   1253 us |     41% |     57% |
/// | tier 3       |   8857 us |     60% |     30% |
///
/// Every tier precise enough for a 5 ms period also promotes the thread onto
/// performance cores. There is no setting that gives both, so stressd asks for
/// low latency only when it genuinely needs it: when the worker sleeps at all,
/// and when its QoS class is one that coalesces badly. A worker at 100% duty
/// never sleeps, so it keeps the default tier and stays exactly where the QoS
/// class puts it.
///
/// Which choice was made is reported in `SourceStatus`, because a relaxed
/// placement that nobody is told about is just a wrong placement.
///
/// Reproduce both tables with `Tools/measure-timer-coalescing.swift`.
enum ThreadTimerPolicy {

  /// Sets the calling thread's timer latency tier.
  ///
  /// - Parameter lowLatency: `true` for tier 0, `false` to return the thread to
  ///   the unspecified default.
  /// - Returns: `false` if the kernel refused the request.
  @discardableResult
  static func setLowLatencyTimers(_ lowLatency: Bool) -> Bool {
    let tier =
      lowLatency
      ? LATENCY_QOS_TIER_0.rawValue
      : LATENCY_QOS_TIER_UNSPECIFIED.rawValue

    var policy = thread_latency_qos_policy_data_t(
      thread_latency_qos_tier: thread_latency_qos_t(bitPattern: tier))

    let count = mach_msg_type_number_t(
      MemoryLayout<thread_latency_qos_policy_data_t>.size / MemoryLayout<integer_t>.size)

    let status = withUnsafeMutablePointer(to: &policy) { pointer in
      pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { reboundPointer in
        thread_policy_set(
          mach_thread_self(),
          thread_policy_flavor_t(THREAD_LATENCY_QOS_POLICY),
          reboundPointer,
          count)
      }
    }
    return status == KERN_SUCCESS
  }
}
