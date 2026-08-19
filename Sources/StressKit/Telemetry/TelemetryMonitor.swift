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
  private let battery: BatteryMonitor?
  private let power: PowerMonitor?

  /// Sources to poll for status on each frame. The monitor observes; it does
  /// not own what it observes.
  private var observedSources: [any LoadSource] = []

  /// Pass `nil` for `battery` to skip battery telemetry entirely, and `nil`
  /// for `power` to skip package power. When `power` is present but
  /// unavailable, the power fields read `nil` and the reason is reported.
  public init(
    topology: CoreTopology,
    interval: TimeInterval = defaultInterval,
    tickSource: any CPUTickReading = HostProcessorInfo(),
    battery: BatteryMonitor? = BatteryMonitor(),
    power: PowerMonitor? = nil
  ) {
    self.topology = topology
    self.interval = max(interval, Self.minimumInterval)
    self.tickSource = tickSource
    self.battery = battery
    self.power = power
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
    let battery = self.battery
    let power = self.power

    return AsyncStream { continuation in
      let task = Task {
        guard let sampler = try? CPUUtilizationSampler(topology: topology, source: tickSource)
        else {
          continuation.finish()
          return
        }
        power?.start()

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

          let batteryReading = await battery?.read()
          let powerSample = power?.latestSample()

          continuation.yield(
            Self.assemble(
              cpu: cpu,
              battery: batteryReading?.reading,
              smoothedWatts: batteryReading?.smoothedWatts,
              power: powerSample,
              availability: power?.currentAvailability,
              statuses: statuses))
        }
        power?.stop()
        continuation.finish()
      }
      continuation.onTermination = { _ in
        power?.stop()
        task.cancel()
      }
    }
  }

  /// Builds one frame. Pure, so the derived figures can be tested without any
  /// hardware.
  public static func assemble(
    cpu: CPUSample,
    battery: BatteryReading?,
    smoothedWatts: Double?,
    power: PowerSample?,
    availability: PowerAvailability?,
    statuses: [SourceStatus]
  ) -> Telemetry {
    Telemetry(
      timestamp: cpu.timestamp,
      interval: cpu.interval,
      cpu: cpu,
      thermalState: ThermalState(ProcessInfo.processInfo.thermalState),
      packagePowerWatts: power?.cpuWatts,
      gpuPowerWatts: power?.gpuWatts,
      otherPowerWatts: otherWatts(
        battery: battery, smoothedWatts: smoothedWatts, power: power),
      powerAvailability: availability.map(\.explanation),
      batteryPercent: battery?.reportedPercent,
      batteryRawPercent: battery?.rawPercent,
      batteryWatts: battery?.watts,
      batterySmoothedWatts: smoothedWatts,
      isCharging: battery?.isCharging,
      isConnectedToPower: battery?.isConnectedToPower,
      cycleCount: battery?.cycleCount,
      batteryTemperatureCelsius: battery?.temperatureCelsius,
      contributedFraction: contributedFraction(statuses),
      activeSources: statuses)
  }

  /// Everything drawing power that is not the SoC package: display, radios,
  /// storage, fans.
  ///
  /// Only computable on battery. On AC the battery figure describes charging,
  /// not consumption, so there is nothing to subtract from.
  static func otherWatts(
    battery: BatteryReading?, smoothedWatts: Double?, power: PowerSample?
  ) -> Double? {
    guard let battery, battery.isConnectedToPower == false,
      let watts = smoothedWatts ?? battery.watts, watts < 0,
      let packageWatts = power?.combinedWatts ?? power?.cpuWatts
    else { return nil }
    let systemDraw = -watts
    // Clamped at zero: the two sources are sampled a moment apart, so a
    // transient can briefly make the package look larger than the whole.
    return max(0, systemDraw - packageWatts)
  }

  /// Share of requested load coming from sources that do real work.
  static func contributedFraction(_ statuses: [SourceStatus]) -> Double {
    let total = statuses.reduce(0) { $0 + $1.requestedLoad }
    guard total > 0 else { return 0 }
    let contributed = statuses.filter(\.isContributing).reduce(0) { $0 + $1.requestedLoad }
    return min(max(contributed / total, 0), 1)
  }
}
