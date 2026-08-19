import Foundation

/// How much of the machine a source may use.
///
/// The same budget is handed to every source. A contributed source translates
/// it into whatever knobs its client exposes; the synthetic source translates
/// it directly into a duty cycle.
public struct ResourceBudget: Sendable, Equatable, Codable {
  /// Target CPU load as a fraction of one fully busy machine, `0...1`.
  public var cpu: Double
  /// Target GPU load, `0...1`, or `nil` to leave the GPU alone.
  public var gpu: Double?
  /// Which cores to load.
  public var placement: CorePlacement

  public init(cpu: Double, gpu: Double? = nil, placement: CorePlacement = .allCores) {
    self.cpu = Self.clamp(cpu)
    self.gpu = gpu.map(Self.clamp)
    self.placement = placement
  }

  public static let idle = ResourceBudget(cpu: 0)

  private static func clamp(_ value: Double) -> Double {
    guard value.isFinite else { return 0 }
    return min(max(value, 0), 1)
  }
}

/// Which class of core a source should load.
public enum CorePlacement: Sendable, Equatable, Codable {
  case allCores
  /// A `hw.perflevelN` index. 0 is the fastest level.
  case performanceLevel(Int)

  /// The level index to target, or `nil` for every level.
  public var levelIndex: Int? {
    switch self {
    case .allCores: return nil
    case .performanceLevel(let index): return index
    }
  }
}

/// Whether a source can run on this machine.
public enum DetectionResult: Sendable, Equatable {
  case available(detail: String)
  case unavailable(reason: String, installHint: String?)

  public var isAvailable: Bool {
    if case .available = self { return true }
    return false
  }
}

/// What a source is doing right now.
public struct SourceStatus: Sendable, Equatable, Codable {
  public let sourceID: String
  public let isContributing: Bool
  public let state: State
  /// Fraction of one fully busy machine this source was asked for.
  public let requestedLoad: Double
  /// What it achieved, when the source can measure itself.
  public let achievedLoad: Double?
  public let threadCount: Int
  /// Free-form detail for display: project and workunit for contributed
  /// sources, worker kind and placement for synthetic ones.
  public let detail: [String: String]

  public enum State: String, Sendable, Codable {
    case idle
    case running
    case stopped
    case failed
  }

  public init(
    sourceID: String,
    isContributing: Bool,
    state: State,
    requestedLoad: Double,
    achievedLoad: Double? = nil,
    threadCount: Int = 0,
    detail: [String: String] = [:]
  ) {
    self.sourceID = sourceID
    self.isContributing = isContributing
    self.state = state
    self.requestedLoad = requestedLoad
    self.achievedLoad = achievedLoad
    self.threadCount = threadCount
    self.detail = detail
  }
}

/// Something that can put load on the machine.
///
/// Contributed sources wrap a real volunteer computing client; the synthetic
/// source generates load directly. The governor drives both through the same
/// interface, which is what lets it hold a total target by topping contributed
/// load up with synthetic load.
public protocol LoadSource: Sendable {
  /// Stable identifier, e.g. `"synthetic"` or `"boinc"`.
  var id: String { get }
  /// Whether the FLOPs this source burns go somewhere useful.
  var isContributing: Bool { get }

  func detect() async -> DetectionResult
  func start(budget: ResourceBudget) async throws
  /// Changes the load on a running source. Must not tear down and respawn:
  /// this is called every second once contributed load is mixed in.
  func adjust(to budget: ResourceBudget) async throws
  /// Stops and restores any state the source modified. Idempotent.
  func stop() async
  func status() async throws -> SourceStatus
}
