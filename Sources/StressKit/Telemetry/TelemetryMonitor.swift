import Foundation

/// Emits telemetry frames on an interval.
///
/// One stream, subscribed to by whatever needs it. The CLI reads it today and
/// the menu bar app will read the same thing.
public actor TelemetryMonitor {

  /// Below this the sampling interval is shorter than the scheduler tick rate
  /// the counters advance at, and the numbers become quantisation noise.
  public static let minimumInterval: TimeInterval = 0.1
  public static let defaultInterval: TimeInterval = 1.0

  private let topology: CoreTopology
  private let tickSource: any CPUTickReading
  private let interval: TimeInterval

  /// Sources to poll for status on each frame. Held weakly by intent: the
  /// monitor observes, it does not own what it observes.
  private var observedSources: [any LoadSource] = []

  public init(
    topology: CoreTopology,
    interval: TimeInterval = defaultInterval,
    tickSource: any CPUTickReading = HostProcessorInfo()
  ) {
    self.topology = topology
    self.interval = max(interval, Self.minimumInterval)
    self.tickSource = tickSource
  }

  public func observe(_ sources: [any LoadSource]) {
    observedSources = sources
  }

  /// A stream of telemetry frames, one per interval.
  ///
  /// The first frame arrives one interval in, because a frame is a delta and
  /// there is nothing to subtract from before then. The stream finishes when
  /// the consuming task is cancelled.
  public func stream() -> AsyncStream<Telemetry> {
    let topology = self.topology
    let tickSource = self.tickSource
    let interval = self.interval
    let sources = self.observedSources

    return AsyncStream { continuation in
      let task = Task {
        guard let sampler = try? CPUUtilizationSampler(topology: topology, source: tickSource)
        else {
          continuation.finish()
          return
        }

        while !Task.isCancelled {
          do {
            try await Task.sleep(for: .seconds(interval))
          } catch {
            break
          }
          guard let cpu = try? await sampler.sample() else { continue }

          var statuses: [SourceStatus] = []
          for source in sources {
            if let status = try? await source.status() {
              statuses.append(status)
            }
          }

          continuation.yield(
            Telemetry(
              timestamp: cpu.timestamp,
              interval: cpu.interval,
              cpu: cpu,
              thermalState: ThermalState(ProcessInfo.processInfo.thermalState),
              contributedFraction: Self.contributedFraction(statuses),
              activeSources: statuses))
        }
        continuation.finish()
      }
      continuation.onTermination = { _ in task.cancel() }
    }
  }

  /// Share of requested load coming from sources that do real work.
  static func contributedFraction(_ statuses: [SourceStatus]) -> Double {
    let total = statuses.reduce(0) { $0 + $1.requestedLoad }
    guard total > 0 else { return 0 }
    let contributed = statuses.filter(\.isContributing).reduce(0) { $0 + $1.requestedLoad }
    return min(max(contributed / total, 0), 1)
  }
}
