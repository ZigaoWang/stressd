import Foundation
import Testing

@testable import StressKit

/// A `CPUTickReading` that replays recorded counters.
struct StubTickSource: CPUTickReading {
  var frames: [[CPUTicks]]
  private let cursor = Cursor()

  final class Cursor: @unchecked Sendable {
    private let lock = NSLock()
    private var index = 0
    func next() -> Int {
      lock.lock()
      defer { lock.unlock() }
      let current = index
      index += 1
      return current
    }
  }

  init(_ frames: [[CPUTicks]]) {
    self.frames = frames
  }

  func read() throws -> [CPUTicks] {
    let index = cursor.next()
    guard frames.indices.contains(index) else {
      return frames.last ?? []
    }
    return frames[index]
  }
}

@Suite("CPU utilization")
struct CPUUtilizationTests {

  private func ticks(user: UInt32, system: UInt32, idle: UInt32, nice: UInt32 = 0) -> CPUTicks {
    CPUTicks(user: user, system: system, idle: idle, nice: nice)
  }

  @Test("Utilization is the ratio of deltas, not of absolute counters")
  func deltaBased() throws {
    // Absolute counts are large and mostly idle; the interval is half busy.
    let previous = ticks(user: 1_000_000, system: 500_000, idle: 9_000_000)
    let current = ticks(user: 1_000_030, system: 500_020, idle: 9_000_050)

    let utilization = try #require(current.delta(since: previous).utilization(cpu: 3))
    #expect(utilization.cpu == 3)
    #expect(abs(utilization.busy - 0.5) < 0.0001)
    #expect(abs(utilization.user - 0.3) < 0.0001)
    #expect(abs(utilization.system - 0.2) < 0.0001)
  }

  @Test("Nice time counts as busy")
  func niceIsBusy() throws {
    let previous = ticks(user: 0, system: 0, idle: 0, nice: 0)
    let current = ticks(user: 10, system: 10, idle: 50, nice: 30)

    let utilization = try #require(current.delta(since: previous).utilization(cpu: 0))
    #expect(abs(utilization.busy - 0.5) < 0.0001)
    #expect(abs(utilization.nice - 0.3) < 0.0001)
  }

  @Test("A counter that rolls over produces the right delta, not a negative interval")
  func counterWraparound() throws {
    // The counters are 32 bit and free-running. Each state rolls over after
    // roughly 497 days of accumulated time, so this is a real event on a
    // long-lived machine, not a hypothetical.
    let previous = ticks(user: .max - 10, system: 100, idle: 100)
    let current = ticks(user: 9, system: 110, idle: 110)

    let delta = current.delta(since: previous)
    #expect(delta.user == 20)
    #expect(delta.total == 40)

    let utilization = try #require(delta.utilization(cpu: 0))
    #expect(abs(utilization.busy - 0.75) < 0.0001)
  }

  @Test("Every counter rolling over at once is still handled")
  func allCountersWrap() {
    let previous = ticks(
      user: .max - 4, system: .max - 4, idle: .max - 4, nice: .max - 4)
    let current = ticks(user: 5, system: 5, idle: 5, nice: 5)

    let delta = current.delta(since: previous)
    #expect(delta.total == 40)
  }

  @Test("An interval with no elapsed ticks reports nothing rather than dividing by zero")
  func zeroInterval() {
    let sample = ticks(user: 100, system: 100, idle: 100)
    #expect(sample.delta(since: sample).utilization(cpu: 0) == nil)
  }

  @Test("Per-core utilization is aggregated by performance level, not by index")
  func aggregationUsesTheTopologyMap() throws {
    let topology = try CoreTopologyDetector(
      sysctl: MachineFixtures.m3Pro.sysctl, clusterMap: MachineFixtures.m3Pro.clusterMap
    ).detect()

    // E-cores (0-5) idle, P-cores (6-11) fully busy. If the level map were
    // inverted, this test would report the opposite and nothing else would
    // catch it.
    let perCore = (0..<12).map { cpu in
      CoreUtilization(
        cpu: cpu,
        user: cpu >= 6 ? 1 : 0,
        system: 0,
        nice: 0,
        idle: cpu >= 6 ? 0 : 1)
    }

    let levels = CPUUtilizationSampler.aggregate(perCore: perCore, topology: topology)
    #expect(levels.count == 2)
    #expect(levels[0].name == "Performance")
    #expect(levels[0].busy == 1.0)
    #expect(levels[1].name == "Efficiency")
    #expect(levels[1].busy == 0.0)
  }

  @Test("A CPU count that changes between reads does not pair mismatched cores")
  func mismatchedReadLengths() {
    let previous = (0..<4).map { _ in ticks(user: 0, system: 0, idle: 0) }
    let current = (0..<2).map { _ in ticks(user: 50, system: 0, idle: 50) }

    let result = CPUUtilizationSampler.utilization(current: current, previous: previous)
    #expect(result.count == 2)
  }

  @Test("The sampler turns two reads into one labelled sample")
  func samplerEndToEnd() async throws {
    let topology = try CoreTopologyDetector(
      sysctl: MachineFixtures.m3Pro.sysctl, clusterMap: MachineFixtures.m3Pro.clusterMap
    ).detect()

    let idle = (0..<12).map { _ in self.ticks(user: 0, system: 0, idle: 0) }
    let busy = (0..<12).map { cpu in
      cpu >= 6
        ? self.ticks(user: 75, system: 25, idle: 0)
        : self.ticks(user: 0, system: 0, idle: 100)
    }

    let sampler = try CPUUtilizationSampler(
      topology: topology, source: StubTickSource([idle, busy]))
    let sample = try #require(try await sampler.sample())

    #expect(sample.perCore.count == 12)
    #expect(abs(sample.systemWide - 0.5) < 0.0001)
    #expect(sample.byPerfLevel.first { $0.name == "Performance" }?.busy == 1.0)
    #expect(sample.byPerfLevel.first { $0.name == "Efficiency" }?.busy == 0.0)
  }

  @Test("Contributed fraction weighs sources by requested load")
  func contributedFraction() {
    let synthetic = SourceStatus(
      sourceID: "synthetic", isContributing: false, state: .running, requestedLoad: 0.25)
    let contributed = SourceStatus(
      sourceID: "boinc", isContributing: true, state: .running, requestedLoad: 0.75)

    #expect(TelemetryMonitor.contributedFraction([synthetic, contributed]) == 0.75)
    #expect(TelemetryMonitor.contributedFraction([synthetic]) == 0)
    #expect(TelemetryMonitor.contributedFraction([]) == 0)
  }
}
