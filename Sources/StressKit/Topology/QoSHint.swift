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

  public var qualityOfService: QualityOfService {
    switch self {
    case .userInteractive: return .userInteractive
    case .userInitiated: return .userInitiated
    case .default: return .default
    case .utility: return .utility
    case .background: return .background
    }
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
