import ArgumentParser
import Foundation
import StressKit

struct RunCommand: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "run",
    abstract: "Put load on the machine.",
    discussion: """
      Only the synthetic source exists so far, so every run is synthetic \
      whether or not --synthetic-only is given. Contributed sources arrive in a \
      later step and will become the default.

      Partial load is duty cycling inside every thread, not fewer threads: \
      --cpu 50 runs every core at 50%, which keeps the power curve close to \
      linear.

      A sleep assertion is held for the duration and released on every exit \
      path, including SIGINT and SIGTERM.
      """
  )

  @OptionGroup var output: OutputOptions

  @Option(name: .long, help: "Target CPU load as a percentage, 0 to 100.")
  var cpu: Double = 100

  @Option(name: .long, help: "Stop after this long, e.g. 60s, 30m, 2h. Default: no limit.")
  var duration: String?

  @Option(
    name: .long,
    help: "Cores to load: 'all', 'performance', 'efficiency', or a performance level index.")
  var level: String = "all"

  @Flag(name: .long, help: "Do not use contributed work. Currently implied.")
  var syntheticOnly = false

  @Option(
    name: .long,
    help: """
      Override the duty cycle period, in milliseconds, for every performance \
      level. By default each level uses the period its QoS class needs: 5 ms \
      for performance cores, 100 ms for efficiency cores, whose timer wake-ups \
      macOS coalesces far too coarsely for a short period.
      """)
  var periodMilliseconds: Double?

  @Option(name: .long, help: "Seconds between telemetry samples.")
  var interval: Double = TelemetryMonitor.defaultInterval

  @Option(
    name: .long,
    help: """
      Seconds spent measuring the machine's existing load before starting, so \
      observed utilization can be reported as a delta. Set 0 to skip.
      """)
  var baselineSeconds: Double = 3

  func validate() throws {
    guard cpu >= 0, cpu <= 100 else {
      throw ValidationError("--cpu must be between 0 and 100")
    }
    if let periodMilliseconds {
      guard periodMilliseconds >= 0.5, periodMilliseconds <= 1000 else {
        throw ValidationError("--period-milliseconds must be between 0.5 and 1000")
      }
    }
  }

  func run() async throws {
    let topology = try CoreTopologyDetector().detect()
    let placement = try Self.placement(for: level, topology: topology)
    let budget = ResourceBudget(cpu: cpu / 100, placement: placement)
    let deadline = try duration.map { Date().addingTimeInterval(try DurationParser.parse($0)) }
    let startedAt = Date()

    CleanupRegistry.installAtExitBackstop()

    // Held for the whole run and released on every exit path. A run that gets
    // suspended halfway through measures nothing.
    let assertion = try? PowerAssertion.preventIdleSleep(reason: "stressd is loading the CPU")
    CleanupRegistry.shared.register("release sleep assertion") { assertion?.release() }

    let source = SyntheticSource(
      topology: topology,
      periodNanoseconds: periodMilliseconds.map { UInt64($0 * 1_000_000) })
    // Synchronous so the atexit backstop can use it. Threads must not outlive
    // the process under any exit path.
    CleanupRegistry.shared.register("stop synthetic workers") { source.emergencyStop() }

    let renderer = InPlaceRenderer()
    CleanupRegistry.shared.register("restore cursor") { renderer.finish() }

    // Measured before the workers spawn. This machine is not idle, and an
    // absolute utilization figure on a busy desktop says more about the
    // browser than about stressd.
    let baseline = try await Self.measureBaseline(
      topology: topology, seconds: baselineSeconds, json: output.json)

    try await source.start(budget: budget)

    let monitor = TelemetryMonitor(
      topology: topology, interval: interval, power: PowerMonitor())
    await monitor.observe([source])
    let emitJSON = output.json

    let work = Task {
      for await telemetry in await monitor.stream() {
        if emitJSON {
          print(try JSONReport.encodeLine(telemetry))
        } else {
          renderer.render(
            TelemetryRenderer.frame(
              telemetry, topology: topology, width: Terminal.columns, baseline: baseline))
        }
        // Thermal back-off belongs here, between reading the state and the next
        // adjust(). It arrives with the governor in a later step; today the
        // state is only reported.
        if let deadline, Date() >= deadline { break }
      }
    }

    let interrupt = InterruptHandler { work.cancel() }
    interrupt.install()

    _ = try? await work.value

    let finalStatus = source.nonisolatedStatus()
    await source.stop()
    CleanupRegistry.shared.run()

    if !emitJSON {
      print(
        Self.summary(
          status: finalStatus, elapsed: Date().timeIntervalSince(startedAt),
          baseline: baseline))
    }
  }

  // MARK: - Helpers

  /// Samples utilization with no stressd load running.
  static func measureBaseline(
    topology: CoreTopology, seconds: Double, json: Bool
  ) async throws
    -> Double?
  {
    guard seconds > 0 else { return nil }
    if !json {
      print("Measuring baseline load for \(Int(seconds))s...")
    }
    let sampler = try CPUUtilizationSampler(topology: topology)
    try await Task.sleep(for: .seconds(seconds))
    return try await sampler.sample()?.systemWide
  }

  /// Resolves `--level` against the machine's actual performance levels rather
  /// than a hardcoded two-level assumption.
  static func placement(for level: String, topology: CoreTopology) throws -> CorePlacement {
    let normalised = level.trimmingCharacters(in: .whitespaces).lowercased()
    if normalised.isEmpty || normalised == "all" { return .allCores }

    if let index = Int(normalised) {
      guard topology.performanceLevels.indices.contains(index) else {
        throw ValidationError(
          "no performance level \(index); this machine has "
            + "\(topology.performanceLevels.count)")
      }
      return .performanceLevel(index)
    }

    if let match = topology.performanceLevels.first(where: {
      $0.name.lowercased().hasPrefix(normalised)
    }) {
      return .performanceLevel(match.index)
    }

    let available = topology.performanceLevels.map { $0.name.lowercased() }.joined(
      separator: ", ")
    throw ValidationError("unknown level '\(level)'. This machine has: all, \(available)")
  }

  static func summary(
    status: SourceStatus, elapsed: TimeInterval, baseline: Double?
  )
    -> String
  {
    var lines = ["", "Session"]
    lines.append(Formatting.field("  Duration", DurationParser.format(elapsed), keyWidth: 20))
    lines.append(
      Formatting.field(
        "  Requested", TelemetryRenderer.percent(status.requestedLoad), keyWidth: 20))
    if let achieved = status.achievedLoad {
      lines.append(
        Formatting.field(
          "  Worker-measured", TelemetryRenderer.percent(achieved), keyWidth: 20))
    }
    if let baseline {
      lines.append(
        Formatting.field(
          "  Baseline load", TelemetryRenderer.percent(baseline), keyWidth: 20))
    }
    lines.append(Formatting.field("  Threads", "\(status.threadCount)", keyWidth: 20))
    if let gflops = status.detail["gflops"] {
      lines.append(
        Formatting.field("  Throughput", "\(gflops) GFLOPS FP64 (estimate)", keyWidth: 20))
    }
    if let abandoned = status.detail["abandonedCycles"], abandoned != "0" {
      lines.append(Formatting.field("  Abandoned cycles", abandoned, keyWidth: 20))
    }
    lines.append("")
    lines.append("  No work was contributed: the synthetic source computes nothing useful.")
    return lines.joined(separator: "\n")
  }
}
