import Foundation
import Testing

@testable import StressKit

@Suite("Governor and thermal override")
struct GovernorTests {

  private func telemetry(thermal: ThermalState, watts: Double? = nil) -> Telemetry {
    let cores = (0..<4).map {
      CoreUtilization(cpu: $0, user: 0.5, system: 0, nice: 0, idle: 0.5)
    }
    return Telemetry(
      timestamp: Date(),
      interval: 1,
      cpu: CPUSample(timestamp: Date(), interval: 1, perCore: cores, byPerfLevel: []),
      thermalState: thermal,
      batteryWatts: watts.map { -$0 },
      batterySmoothedWatts: watts.map { -$0 },
      isConnectedToPower: watts == nil ? nil : false)
  }

  private func topology() throws -> CoreTopology {
    try CoreTopologyDetector(
      sysctl: MachineFixtures.m3Pro.sysctl, clusterMap: MachineFixtures.m3Pro.clusterMap
    ).detect()
  }

  // MARK: - Utilization target

  @Test("A utilization target passes straight through when the machine is cool")
  func utilizationTargetAtNominal() async throws {
    let governor = Governor(topology: try topology(), target: .utilization(0.8))
    let decision = await governor.tick(telemetry: telemetry(thermal: .nominal), elapsed: 1)

    #expect(decision.effectiveTarget == 0.8)
    #expect(decision.thermalAction == .none)
    #expect(decision.thermalCeiling == 1.0)
  }

  @Test("Maximum asks for everything")
  func maximumTarget() async throws {
    let governor = Governor(topology: try topology(), target: .maximum)
    let decision = await governor.tick(telemetry: telemetry(thermal: .nominal), elapsed: 1)
    #expect(decision.effectiveTarget == 1.0)
  }

  @Test("Out of range utilization is clamped")
  func clampsTarget() async throws {
    let high = Governor(topology: try topology(), target: .utilization(4))
    #expect(
      await high.tick(telemetry: telemetry(thermal: .nominal), elapsed: 1)
        .effectiveTarget == 1.0)

    let low = Governor(topology: try topology(), target: .utilization(-1))
    #expect(
      await low.tick(telemetry: telemetry(thermal: .nominal), elapsed: 1)
        .effectiveTarget == 0.0)
  }

  // MARK: - Thermal override

  @Test("Serious backs off, and keeps backing off while it persists")
  func backsOffAtSerious() async throws {
    let governor = Governor(topology: try topology(), target: .utilization(1.0))

    var previous = 1.0
    for _ in 0..<4 {
      let decision = await governor.tick(telemetry: telemetry(thermal: .serious), elapsed: 1)
      #expect(decision.thermalAction == .backingOff)
      #expect(decision.effectiveTarget < previous, "the ceiling must keep coming down")
      previous = decision.effectiveTarget
    }
    #expect(previous <= 0.05, "four seconds at serious should have shed most of the load")
  }

  @Test("Critical stops entirely, not merely reduces")
  func stopsAtCritical() async throws {
    let governor = Governor(topology: try topology(), target: .utilization(1.0))
    let decision = await governor.tick(telemetry: telemetry(thermal: .critical), elapsed: 1)

    #expect(decision.effectiveTarget == 0)
    #expect(decision.thermalAction == .stopped)
    #expect(decision.isStopped)
    #expect(decision.reason.contains("critical"))
  }

  @Test("The override cannot be configured away")
  func overrideIsNotConfigurable() async throws {
    // There is deliberately no way to construct a Governor that ignores heat.
    // If this ever becomes possible, this test should stop compiling.
    let governor = Governor(topology: try topology(), target: .maximum)
    let decision = await governor.tick(telemetry: telemetry(thermal: .critical), elapsed: 1)
    #expect(decision.effectiveTarget == 0)
  }

  @Test("Fair holds the current ceiling rather than recovering into serious")
  func fairHolds() {
    var override = ThermalOverride()
    override.step(state: .serious, elapsed: 2)
    let afterBackOff = override.ceiling
    #expect(afterBackOff < 1)

    override.step(state: .fair, elapsed: 5)
    #expect(override.ceiling == afterBackOff, "fair must not recover; that walks back into serious")
    #expect(override.action == .backingOff)
  }

  @Test("Recovery waits before it starts, then is slower than the back-off")
  func recoveryIsSlowAndDelayed() {
    var override = ThermalOverride()
    override.step(state: .serious, elapsed: 2)
    let floor = override.ceiling

    // Thermal state is coarse and lags the die, so a brief dip to nominal is
    // not evidence the machine has cooled.
    override.step(state: .nominal, elapsed: 5)
    #expect(override.ceiling == floor, "recovery must not start immediately")

    // Past the hold, it creeps up.
    override.step(state: .nominal, elapsed: 6)
    override.step(state: .nominal, elapsed: 1)
    #expect(override.ceiling > floor)
    #expect(
      ThermalOverride.recoveryRatePerSecond < ThermalOverride.backOffRatePerSecond,
      "recovering faster than backing off would let the loop ping-pong")
  }

  @Test("A ceiling that reached zero can still recover")
  func recoversFromZero() {
    var override = ThermalOverride()
    for _ in 0..<10 { override.step(state: .critical, elapsed: 1) }
    #expect(override.ceiling == 0)

    for _ in 0..<40 { override.step(state: .nominal, elapsed: 1) }
    #expect(override.ceiling > 0, "the machine cooled; load should be allowed back")
  }

  @Test("Reset clears the override")
  func resetClears() {
    var override = ThermalOverride()
    override.step(state: .critical, elapsed: 1)
    override.reset()
    #expect(override.ceiling == 1)
    #expect(override.action == .none)
  }

  @Test("A thermal ceiling target loads until it reaches the named state")
  func thermalCeilingTarget() async throws {
    let governor = Governor(topology: try topology(), target: .thermalCeiling(.fair))

    let cool = await governor.tick(telemetry: telemetry(thermal: .nominal), elapsed: 1)
    #expect(cool.effectiveTarget == 1.0)

    let warm = await governor.tick(telemetry: telemetry(thermal: .fair), elapsed: 1)
    #expect(warm.effectiveTarget == 0)
  }

  // MARK: - Power draw

  @Test("The power controller drives load towards the wattage target")
  func powerControllerConverges() {
    var controller = PowerDrawController(targetWatts: 30, initialLoad: 0)
    // A machine that draws 10 W idle and 20 W more at full load.
    var measured = 10.0
    for _ in 0..<60 {
      let load = controller.step(measuredWatts: measured, elapsed: 1)
      measured = 10 + 20 * load
    }
    #expect(abs(measured - 30) < 1.5, "settled at \(measured) W for a 30 W target")
  }

  @Test("A calibrated curve seeds the gain instead of guessing")
  func curveSeedsGain() {
    let curve = CalibrationTests.curve(watts: [0, 10, 20, 30, 40])
    let seeded = PowerDrawController(targetWatts: 25, curve: curve)
    let unseeded = PowerDrawController(targetWatts: 25)

    // The curve says 40 W across the full load range; the default guess is 20.
    // The seeded controller should take a smaller step for the same error.
    var a = seeded
    var b = unseeded
    let seededLoad = a.step(measuredWatts: 5, elapsed: 10)
    let unseededLoad = b.step(measuredWatts: 5, elapsed: 10)
    #expect(seededLoad < unseededLoad)
  }

  @Test("No power reading means hold position, not guess")
  func holdsWithoutReading() {
    var controller = PowerDrawController(targetWatts: 30, initialLoad: 0.4)
    #expect(controller.step(measuredWatts: nil, elapsed: 1) == 0.4)
  }

  @Test("The power controller respects a deadband and a slew limit")
  func powerControllerDamping() {
    var controller = PowerDrawController(targetWatts: 30, initialLoad: 0.5)
    // Half a watt off target: inside the deadband.
    #expect(controller.step(measuredWatts: 29.5, elapsed: 1) == 0.5)

    var fast = PowerDrawController(targetWatts: 100, initialLoad: 0)
    let moved = fast.step(measuredWatts: 0, elapsed: 1)
    #expect(moved <= PowerDrawController.slewRatePerSecond + 1e-9)
  }

  @Test("Load target descriptions are usable in output")
  func targetDescriptions() {
    #expect(LoadTarget.utilization(0.8).describes.contains("80%"))
    #expect(LoadTarget.powerDraw(watts: 30).describes.contains("30"))
    #expect(LoadTarget.maximum.describes == "maximum")
    #expect(LoadTarget.utilization(0.5).fixedUtilization == 0.5)
    #expect(LoadTarget.powerDraw(watts: 1).fixedUtilization == nil)
  }
}
