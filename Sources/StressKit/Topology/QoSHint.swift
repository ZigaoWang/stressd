import Dispatch
import Foundation

/// The QoS class stressd asks for when it wants work to land on a particular
/// class of core.
///
/// macOS exposes no public API for pinning a thread to P-cores or E-cores.
/// QoS is a *scheduler hint*: `.userInteractive` biases towards performance
/// cores and `.background` is restricted to efficiency cores, but neither is a
/// guarantee and the scheduler is free to ignore both. Everywhere stressd acts
/// on this hint it also reports the observed per-core utilization so the gap
/// between requested and actual placement stays visible.
public enum QoSHint: String, Sendable, Codable, CaseIterable {
  case userInteractive
  case userInitiated
  case `default`
  case utility
  case background

  public var dispatchQoSClass: DispatchQoS.QoSClass {
    switch self {
    case .userInteractive: return .userInteractive
    case .userInitiated: return .userInitiated
    case .default: return .default
    case .utility: return .utility
    case .background: return .background
    }
  }

  public var dispatchQoS: DispatchQoS {
    switch self {
    case .userInteractive: return .userInteractive
    case .userInitiated: return .userInitiated
    case .default: return .default
    case .utility: return .utility
    case .background: return .background
    }
  }

  /// The value `pthread_set_qos_class_self_np` takes. Setting QoS on the thread
  /// itself is what the kernel scheduler reads; setting it on a `Thread` object
  /// is a convenience that ultimately does the same thing.
  public var qosClass: qos_class_t {
    switch self {
    case .userInteractive: return QOS_CLASS_USER_INTERACTIVE
    case .userInitiated: return QOS_CLASS_USER_INITIATED
    case .default: return QOS_CLASS_DEFAULT
    case .utility: return QOS_CLASS_UTILITY
    case .background: return QOS_CLASS_BACKGROUND
    }
  }

  public var qualityOfService: QualityOfService {
    switch self {
    case .userInteractive: return .userInteractive
    case .userInitiated: return .userInitiated
    case .default: return .default
    case .utility: return .utility
    case .background: return .background
    }
  }

  /// Whether this class's timer wake-ups are coalesced far beyond a
  /// millisecond-scale duty cycle period.
  ///
  /// Measured on an M3 Pro, median overshoot on a requested 2.5 ms sleep:
  /// `.userInteractive` 638 us, `.utility` 7654 us, `.background` 77635 us.
  public var coalescesTimersAggressively: Bool {
    switch self {
    case .userInteractive, .userInitiated, .default: return false
    case .utility, .background: return true
    }
  }

  /// Fallback duty cycle period when the coalescing window has not been
  /// measured.
  ///
  /// Prefer `PeriodPolicy`, which measures the window on the running machine.
  /// This value is what that measurement produced on an M3 Pro under macOS 26,
  /// kept as a sane default for the paths that cannot probe.
  ///
  /// ## Why the two levels differ
  ///
  /// macOS coalesces `.background` timer wake-ups by up to 77 ms, which a 5 ms
  /// period cannot survive: measured, it produced 3% duty against a 50%
  /// request. The obvious fix is `THREAD_LATENCY_QOS_POLICY`, and it does fix
  /// the timing — but every latency tier precise enough to matter also lifts
  /// the thread off the efficiency cores, which defeats the reason the worker
  /// asked for `.background` in the first place.
  ///
  /// Lengthening the period fixes it with no such cost. Measured on an M3 Pro
  /// with six `.background` threads and no latency tier, P-core bleed at idle
  /// being ~13%:
  ///
  /// | period | duty at 25% | duty at 50% | P-cores at 50% |
  /// |--------|------------:|------------:|---------------:|
  /// | 5 ms   |        4.5% |       12.3% |          13.4% |
  /// | 20 ms  |       11.0% |       24.6% |          13.4% |
  /// | 50 ms  |       19.5% |       39.8% |          19.8% |
  /// | 100 ms |       25.0% |       49.8% |          11.3% |
  /// | 200 ms |       24.8% |       50.1% |          14.9% |
  ///
  /// For comparison, 5 ms with latency tier 0 hits the duty target exactly but
  /// pushes P-core usage to 59%: the work is no longer on the efficiency cores
  /// at all.
  ///
  /// 100 ms is the knee *on that machine*, and it is the knee because it
  /// exceeds the 77 ms coalescing window — the knee tracks the window, not a
  /// constant, which is why `PeriodPolicy` derives it from a measurement.
  ///
  /// Reproduce with `swift Tools/measure-timer-coalescing.swift`.
  public var recommendedPeriodNanoseconds: UInt64 {
    coalescesTimersAggressively ? 100_000_000 : DutyCycleScheduler.defaultPeriodNanoseconds
  }

  /// The hint that best biases work onto performance level `index` of
  /// `levelCount`, where level 0 is the fastest.
  ///
  /// Written for an arbitrary number of performance levels rather than the two
  /// that ship today.
  public static func biasing(towardLevel index: Int, of levelCount: Int) -> QoSHint {
    guard levelCount > 1 else { return .default }
    if index <= 0 { return .userInteractive }
    if index >= levelCount - 1 { return .background }
    return .utility
  }
}
