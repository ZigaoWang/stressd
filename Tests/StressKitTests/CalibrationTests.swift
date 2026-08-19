import Foundation
import Testing

@testable import StressKit

@Suite("Calibration")
struct CalibrationTests {

  // MARK: - Sweep ordering

  @Test("The sweep is shuffled, not monotonic")
  func measurementOrderIsShuffled() {
    // A monotonic 0 to 100% sweep conflates load with accumulated heat: the
    // top of the range would be measured on a machine that has been hot for
    // ten minutes and would read low from throttling, bending the curve in a
    // way that is an artefact of the sweep rather than a property of the chip.
    let plan = CalibrationPlan(points: CalibrationPlan.defaultPoints, shuffleSeed: 12345)
    let order = plan.measurementOrder()

    #expect(order != plan.points, "measurement order must not be the sorted order")
    #expect(order != plan.points.reversed(), "nor the reverse")
    #expect(Set(order) == Set(plan.points), "but it must cover every point exactly once")
    #expect(order.count == plan.points.count)
  }

  @Test("A seeded sweep is reproducible, and different seeds differ")
  func shuffleIsSeeded() {
    let first = CalibrationPlan(shuffleSeed: 99).measurementOrder()
    let again = CalibrationPlan(shuffleSeed: 99).measurementOrder()
    let other = CalibrationPlan(shuffleSeed: 100).measurementOrder()

    #expect(first == again)
    #expect(first != other)
  }

  @Test("A single point needs no shuffling")
  func degenerateOrder() {
    #expect(CalibrationPlan(points: [0.5]).measurementOrder() == [0.5])
  }

  @Test("The estimate accounts for settle, dwell and cooldown at every point")
  func estimatedDuration() {
    let plan = CalibrationPlan(
      points: [0, 0.5, 1], dwellSeconds: 30, settleSeconds: 5, cooldownSeconds: 60)
    // Three points at 95 s each, plus the baseline window.
    #expect(plan.estimatedSeconds == 3 * 95 + plan.baselineSeconds)
  }

  @Test("Plan inputs are clamped rather than trusted")
  func planClamping() {
    let plan = CalibrationPlan(
      points: [-1, 0.5, 2], dwellSeconds: -5, settleSeconds: -1, cooldownSeconds: -1)
    #expect(plan.points == [0, 0.5, 1])
    #expect(plan.dwellSeconds >= 1)
    #expect(plan.settleSeconds >= 0)
  }

  // MARK: - Cooldown gating

  @Test("Cooldown waits for nominal beyond the floor, and gives up eventually")
  func cooldownGating() async throws {
    let topology = try CoreTopologyDetector(
      sysctl: MachineFixtures.m3Pro.sysctl, clusterMap: MachineFixtures.m3Pro.clusterMap
    ).detect()

    let clock = VirtualSleeper()
    let thermal = MutableThermalState(.serious)

    let calibrator = PowerCalibrator(
      topology: topology,
      plan: CalibrationPlan(
        points: [0, 1], dwellSeconds: 2, settleSeconds: 1, cooldownSeconds: 10,
        maximumCooldownSeconds: 30, shuffleSeed: 7),
      source: SyntheticSource(topology: topology),
      battery: nil,
      power: nil,
      tickSource: SteadyTickSource(),
      sleeper: { seconds in await clock.advance(seconds) },
      thermalState: { thermal.value })

    let curve = try await calibrator.run()

    // Still .serious, so each cooldown ran past the 10 s floor to the 30 s cap
    // rather than waiting forever.
    #expect(await clock.total >= 60)
    // And every point measured under thermal pressure is flagged.
    let allSuspect = curve.points.allSatisfy(\.isSuspect)
    #expect(allSuspect)
    #expect(curve.suspectPoints.count == curve.points.count)
  }

  @Test("Points measured at nominal are not flagged")
  func nominalPointsAreClean() async throws {
    let topology = try CoreTopologyDetector(
      sysctl: MachineFixtures.m3Pro.sysctl, clusterMap: MachineFixtures.m3Pro.clusterMap
    ).detect()
    let clock = VirtualSleeper()

    let calibrator = PowerCalibrator(
      topology: topology,
      plan: CalibrationPlan(
        points: [0, 0.5, 1], dwellSeconds: 2, settleSeconds: 1, cooldownSeconds: 4,
        shuffleSeed: 3),
      source: SyntheticSource(topology: topology),
      battery: nil,
      power: nil,
      tickSource: SteadyTickSource(),
      sleeper: { seconds in await clock.advance(seconds) },
      thermalState: { .nominal })

    let curve = try await calibrator.run()
    #expect(curve.suspectPoints.isEmpty)
    #expect(curve.points.count == 3)
    // Sorted for output regardless of the order they were measured in.
    #expect(curve.points.map(\.requestedLoad) == [0, 0.5, 1])
    #expect(Set(curve.points.map(\.measurementOrder)).count == 3)
  }

  @Test("Progress reports the shuffled order and the baseline")
  func progressReporting() async throws {
    let topology = try CoreTopologyDetector(
      sysctl: MachineFixtures.m3Pro.sysctl, clusterMap: MachineFixtures.m3Pro.clusterMap
    ).detect()
    let clock = VirtualSleeper()
    let collected = ProgressCollector()

    let calibrator = PowerCalibrator(
      topology: topology,
      plan: CalibrationPlan(
        points: [0, 1], dwellSeconds: 1, settleSeconds: 0, cooldownSeconds: 0,
        shuffleSeed: 5),
      source: SyntheticSource(topology: topology),
      battery: nil, power: nil, tickSource: SteadyTickSource(),
      sleeper: { seconds in await clock.advance(seconds) },
      thermalState: { .nominal })

    _ = try await calibrator.run { collected.record($0) }

    #expect(collected.sawStarted)
    #expect(collected.sawBaseline)
    #expect(collected.measuredCount == 2)
    #expect(collected.sawFinished)
  }

  // MARK: - Curve maths

  @Test("Marginal watts per point is flat for a linear curve")
  func marginalCostLinear() {
    let curve = Self.curve(watts: [0, 5, 10, 15, 20])
    let marginals = curve.marginalWattsPerPoint
    #expect(marginals.count == 4)
    // 5 W per 25 percentage points is 0.2 W/pt at every step.
    #expect(marginals.allSatisfy { abs($0.wattsPerPoint - 0.2) < 0.0001 })
  }

  @Test("A knee shows up where the marginal cost starts rising")
  func kneeDetection() {
    // 0.08 W/pt up to 50% load, then 0.32 W/pt beyond it. The knee is the load
    // at which the cost changes, not the segment after it.
    let curve = Self.curve(watts: [0, 2, 4, 12, 20])
    let knee = curve.efficiencyKnee
    #expect(knee?.load == 0.5)
    #expect(abs((knee?.wattsPerPoint ?? 0) - 0.32) < 0.001)
  }

  @Test("A linear fit is available to seed a controller")
  func linearFit() {
    let curve = Self.curve(watts: [0, 5, 10, 15, 20])
    // 20 W across a full-load range of 1.0.
    #expect(abs((curve.linearWattsPerFullLoad ?? 0) - 20) < 0.001)
  }

  @Test("A noisy baseline is flagged")
  func noisyBaselineFlag() {
    #expect(Self.curve(watts: [0, 10], baseline: 0.30).hasNoisyBaseline)
    #expect(!Self.curve(watts: [0, 10], baseline: 0.05).hasNoisyBaseline)
  }

  @Test("Curves round-trip through JSON and CSV")
  func serialisation() throws {
    let curve = Self.curve(watts: [0, 5, 10, 15, 20])

    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    let decoded = try decoder.decode(PowerCurve.self, from: try encoder.encode(curve))
    #expect(decoded.points.count == curve.points.count)

    let csv = curve.csvRepresentation()
    let lines = csv.split(separator: "\n")
    #expect(lines.count == curve.points.count + 1)
    #expect(lines[0].contains("system_watts_delta"))
  }

  @Test("A curve with no power data still produces a usable structure")
  func utilizationOnlyCurve() {
    let point = CalibrationPoint(
      requestedLoad: 0.5, workerMeasuredLoad: 0.5, observedUtilization: 0.6,
      observedUtilizationDelta: 0.5, utilizationByLevel: [:], systemWatts: nil,
      systemWattsDelta: nil, packageWatts: nil, packageWattsDelta: nil, gpuWatts: nil,
      otherWatts: nil, thermalState: .nominal, isSuspect: false, measurementOrder: 0,
      samples: 30)
    let curve = PowerCurve(
      machineModel: "Mac15,6", chipName: "Apple M3 Pro", measuredAt: Date(),
      powerSource: .utilizationOnly, baselineUtilization: 0.1, baselineWatts: nil,
      points: [point], dwellSeconds: 30, settleSeconds: 5, cooldownSeconds: 60)

    #expect(curve.marginalWattsPerPoint.isEmpty)
    #expect(curve.efficiencyKnee == nil)
    #expect(curve.linearWattsPerFullLoad == nil)
    #expect(!curve.csvRepresentation().isEmpty)
  }

  // MARK: - Helpers

  /// Shared with GovernorTests, which needs a curve to seed the power controller.
  static func curve(watts: [Double], baseline: Double = 0.05) -> PowerCurve {
    let step = watts.count > 1 ? 1.0 / Double(watts.count - 1) : 1
    let points = watts.enumerated().map { index, value in
      CalibrationPoint(
        requestedLoad: Double(index) * step,
        workerMeasuredLoad: Double(index) * step,
        observedUtilization: baseline + Double(index) * step,
        observedUtilizationDelta: Double(index) * step,
        utilizationByLevel: [:],
        systemWatts: 10 + value,
        systemWattsDelta: value,
        packageWatts: nil,
        packageWattsDelta: nil,
        gpuWatts: nil,
        otherWatts: nil,
        thermalState: .nominal,
        isSuspect: false,
        measurementOrder: index,
        samples: 30)
    }
    return PowerCurve(
      machineModel: "Mac15,6", chipName: "Apple M3 Pro", measuredAt: Date(),
      powerSource: .battery, baselineUtilization: baseline, baselineWatts: 10,
      points: points, dwellSeconds: 30, settleSeconds: 5, cooldownSeconds: 60)
  }
}

/// Accumulates simulated time instead of really sleeping, so a sweep that would
/// take an hour runs instantly.
actor VirtualSleeper {
  private(set) var total: Double = 0

  func advance(_ seconds: Double) async {
    total += max(0, seconds)
    // Yield so the sweep's own awaits interleave the way they would in reality.
    await Task.yield()
  }
}

/// A thermal state the test controls.
final class MutableThermalState: @unchecked Sendable {
  private let lock = NSLock()
  private var state: ThermalState

  init(_ state: ThermalState) { self.state = state }

  var value: ThermalState {
    get {
      lock.lock()
      defer { lock.unlock() }
      return state
    }
    set {
      lock.lock()
      state = newValue
      lock.unlock()
    }
  }
}

/// Tick counters that advance steadily, so a sweep produces plausible
/// utilization without touching the host.
struct SteadyTickSource: CPUTickReading {
  private let counter = Counter()

  final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var step: UInt32 = 0
    func next() -> UInt32 {
      lock.lock()
      defer { lock.unlock() }
      step &+= 100
      return step
    }
  }

  func read() throws -> [CPUTicks] {
    let value = counter.next()
    return (0..<12).map { _ in
      CPUTicks(user: value / 2, system: 0, idle: value / 2, nice: 0)
    }
  }
}

/// Records which progress cases a sweep emitted.
final class ProgressCollector: @unchecked Sendable {
  private let lock = NSLock()
  private(set) var sawStarted = false
  private(set) var sawBaseline = false
  private(set) var sawFinished = false
  private(set) var measuredCount = 0

  func record(_ progress: CalibrationProgress) {
    lock.lock()
    defer { lock.unlock() }
    switch progress {
    case .started: sawStarted = true
    case .baseline: sawBaseline = true
    case .measured: measuredCount += 1
    case .finished: sawFinished = true
    default: break
    }
  }
}
