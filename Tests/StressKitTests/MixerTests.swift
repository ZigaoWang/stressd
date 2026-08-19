import Foundation
import Testing

@testable import StressKit

@Suite("Load mixing")
struct MixerTests {

  /// A BOINC that behaves the way the real one does: flat for a while, then a
  /// sharp step when a workunit finishes and another starts.
  struct SimulatedContributedLoad {
    var schedule: [Double]

    func utilization(atStep step: Int) -> Double {
      guard !schedule.isEmpty else { return 0 }
      return schedule[min(step, schedule.count - 1)]
    }
  }

  /// Runs the controller against a simulated machine.
  ///
  /// The machine's observed utilization is contributed load plus whatever
  /// synthetic actually delivered, which is the previous step's duty cycle.
  /// That one-step lag is what makes a naive controller oscillate.
  private func simulate(
    target: Double,
    contributed: SimulatedContributedLoad,
    steps: Int,
    configuration: MixerConfiguration = MixerConfiguration()
  ) -> (duties: [Double], totals: [Double], decisions: [MixerDecision]) {
    var controller = MixerController(configuration: configuration)
    var duties: [Double] = []
    var totals: [Double] = []
    var decisions: [MixerDecision] = []
    var deliveredSynthetic = 0.0

    for step in 0..<steps {
      let contributedNow = contributed.utilization(atStep: step)
      let observed = min(1, contributedNow + deliveredSynthetic)
      let decision = controller.step(
        target: target,
        observedDelta: observed,
        contributedUtilization: contributedNow,
        elapsed: 1.0)

      duties.append(decision.syntheticDuty)
      totals.append(observed)
      decisions.append(decision)
      // Synthetic delivers what it was asked for, on the next step.
      deliveredSynthetic = decision.syntheticDuty
    }
    return (duties, totals, decisions)
  }

  // MARK: - Convergence

  @Test("Synthetic fills the gap when contributed load is flat")
  func convergesOnSteadyContributed() {
    let result = simulate(
      target: 0.8,
      contributed: SimulatedContributedLoad(schedule: [0.3]),
      steps: 40)

    let settled = result.totals.suffix(10)
    for total in settled {
      #expect(abs(total - 0.8) < 0.05, "settled at \(total) for a 0.8 target")
    }
  }

  @Test("Synthetic takes the whole target when contributed load is absent")
  func coversFullTargetWhenContributedIdle() {
    let result = simulate(
      target: 0.6,
      contributed: SimulatedContributedLoad(schedule: [0.0]),
      steps: 40)

    #expect(abs((result.duties.last ?? 0) - 0.6) < 0.05)
    #expect(abs((result.totals.last ?? 0) - 0.6) < 0.05)
  }

  // MARK: - No oscillation

  @Test("An abrupt contributed step does not make the loop ring")
  func absorbsAbruptStepWithoutOscillating() {
    // Flat at 10%, then a workunit starts and BOINC jumps to 70%, then it
    // finishes and drops back. This is the pattern that makes a naive
    // proportional controller oscillate.
    var schedule = [Double](repeating: 0.1, count: 20)
    schedule += [Double](repeating: 0.7, count: 25)
    schedule += [Double](repeating: 0.1, count: 25)

    let result = simulate(
      target: 0.8,
      contributed: SimulatedContributedLoad(schedule: schedule),
      steps: 70)

    // Count direction reversals in the duty cycle after the first step has
    // been absorbed. Ringing shows up as repeated changes of direction.
    let tail = Array(result.duties[25...])
    var reversals = 0
    var previousDirection = 0
    for (before, after) in zip(tail, tail.dropFirst()) {
      let change = after - before
      guard abs(change) > 0.001 else { continue }
      let direction = change > 0 ? 1 : -1
      if previousDirection != 0, direction != previousDirection { reversals += 1 }
      previousDirection = direction
    }
    #expect(reversals <= 2, "duty cycle reversed direction \(reversals) times; that is ringing")

    // And it does settle back on target after the drop.
    let settled = result.totals.suffix(8)
    for total in settled {
      #expect(abs(total - 0.8) < 0.06, "settled at \(total)")
    }
  }

  @Test("Total never exceeds the target by more than the deadband")
  func neverOversubscribes() {
    var schedule = [Double](repeating: 0.2, count: 15)
    schedule += [Double](repeating: 0.75, count: 30)

    let configuration = MixerConfiguration()
    let result = simulate(
      target: 0.8,
      contributed: SimulatedContributedLoad(schedule: schedule),
      steps: 50,
      configuration: configuration)

    for (index, total) in result.totals.enumerated() {
      // A transient overshoot is possible the instant contributed load jumps,
      // because synthetic cannot un-run work already done. What must not happen
      // is a sustained overshoot.
      guard index > 20 else { continue }
      #expect(total <= 0.8 + configuration.deadband + 0.02, "total \(total) at step \(index)")
    }
  }

  // MARK: - Slew and deadband

  @Test("The duty cycle never moves faster than the slew limit")
  func respectsSlewRate() {
    let configuration = MixerConfiguration(slewRatePerSecond: 0.10)
    // A step from nothing to a full target: the controller wants to jump the
    // whole way at once.
    let result = simulate(
      target: 1.0,
      contributed: SimulatedContributedLoad(schedule: [0.0]),
      steps: 20,
      configuration: configuration)

    for (before, after) in zip(result.duties, result.duties.dropFirst()) {
      #expect(
        abs(after - before) <= configuration.slewRatePerSecond + 1e-9,
        "moved \(abs(after - before)) in one second")
    }
    // First move is exactly the slew limit, and it reports as limited.
    #expect(abs(result.duties[0] - 0.10) < 1e-9)
    #expect(result.decisions[0].slewLimited)
  }

  @Test("Elapsed time scales the slew allowance")
  func slewScalesWithElapsed() {
    var controller = MixerController(configuration: MixerConfiguration(slewRatePerSecond: 0.1))
    // Two seconds since the last step means twice the allowance.
    let decision = controller.step(
      target: 1.0, observedDelta: 0, contributedUtilization: 0, elapsed: 2.0)
    #expect(abs(decision.syntheticDuty - 0.2) < 1e-9)
  }

  @Test("Errors inside the deadband produce no movement at all")
  func respectsDeadband() {
    let configuration = MixerConfiguration(deadband: 0.03)
    var controller = MixerController(configuration: configuration, initialDuty: 0.40)

    // 2 points of error, inside the 3 point deadband.
    let decision = controller.step(
      target: 0.60, observedDelta: 0.58, contributedUtilization: 0, elapsed: 1.0)
    #expect(decision.withinDeadband)
    #expect(decision.syntheticDuty == 0.40, "nothing should have moved")

    // 15 points is well outside it, and there is headroom to act.
    let acted = controller.step(
      target: 0.60, observedDelta: 0.45, contributedUtilization: 0, elapsed: 1.0)
    #expect(!acted.withinDeadband)
    #expect(acted.syntheticDuty > 0.40)
  }

  @Test("Requested synthetic duty never exceeds the target's remaining headroom")
  func neverRequestsMoreThanHeadroom() {
    // "Never oversubscribe" is about requested work, not just delivered work.
    // Even facing a shortfall, synthetic must not be asked for more than the
    // target minus what contributed load is already measured to be taking.
    var controller = MixerController(initialDuty: 0.5)
    let decision = controller.step(
      target: 0.50, observedDelta: 0.45, contributedUtilization: 0, elapsed: 1.0)
    #expect(decision.syntheticDuty <= 0.50)

    var withContributed = MixerController(initialDuty: 0.4)
    for _ in 0..<20 {
      _ = withContributed.step(
        target: 0.80, observedDelta: 0.5, contributedUtilization: 0.30, elapsed: 1.0)
    }
    #expect(withContributed.syntheticDuty <= 0.50 + 1e-9, "0.80 target less 0.30 contributed")
  }

  @Test("Measurement noise inside the deadband does not cause churn")
  func noiseDoesNotCauseChurn() {
    var controller = MixerController(
      configuration: MixerConfiguration(deadband: 0.03), initialDuty: 0.4)
    var jitter = SeededJitter()

    var moves = 0
    for _ in 0..<50 {
      // Plus or minus 2 points of measurement noise around a perfect reading.
      let noise = Double(jitter.next(magnitude: 20)) / 1000
      let before = controller.syntheticDuty
      _ = controller.step(
        target: 0.4, observedDelta: 0.4 + noise, contributedUtilization: 0, elapsed: 1.0)
      if abs(controller.syntheticDuty - before) > 1e-9 { moves += 1 }
    }
    #expect(moves == 0, "the controller moved \(moves) times chasing noise")
  }

  // MARK: - Contributed over target

  @Test("Contributed load above target drives synthetic to zero first")
  func contributedOverTargetParksSynthetic() {
    let result = simulate(
      target: 0.4,
      contributed: SimulatedContributedLoad(schedule: [0.7]),
      steps: 30)

    #expect(result.duties.last == 0, "synthetic must be at zero, not merely low")
    #expect(result.decisions.last?.contributedOverTarget == true)
  }

  @Test("Contributed load is only dialled back once synthetic is already at zero")
  func contributedReducedOnlyAfterSyntheticParks() {
    var controller = MixerController(initialDuty: 0.5)

    // Contributed jumps over the target while synthetic is still running.
    // Reducing real work while burning synthetic cycles would be backwards.
    let first = controller.step(
      target: 0.4, observedDelta: 0.9, contributedUtilization: 0.7, elapsed: 1.0)
    #expect(first.contributedOverTarget)
    #expect(first.contributedTarget == nil, "synthetic is still running; do not cut real work")

    // Once synthetic has been driven to zero, the contributed source is asked
    // to come down.
    var settled = first
    for _ in 0..<20 {
      settled = controller.step(
        target: 0.4, observedDelta: 0.7, contributedUtilization: 0.7, elapsed: 1.0)
    }
    #expect(controller.syntheticDuty == 0)
    #expect(settled.contributedTarget == 0.4)
  }

  // MARK: - Attribution

  @Test("Synthetic's share is measured over the interval, not the whole run")
  func windowedAttribution() {
    // Lifetime counters would describe history: after the mixer changes the
    // duty cycle, a cumulative average still reflects the old value and the
    // loop would chase a stale number.
    let previous = [
      WorkerSample(
        iterations: 0, busyNanoseconds: 100, elapsedNanoseconds: 1000, abandonedCycles: 0,
        cycles: 1, checksum: 0)
    ]
    let current = [
      WorkerSample(
        iterations: 0, busyNanoseconds: 1000, elapsedNanoseconds: 2000, abandonedCycles: 0,
        cycles: 2, checksum: 0)
    ]

    // Lifetime would be 1000/2000 = 50%. The last interval was 900/1000 = 90%.
    let windowed = LoadMixer.windowedDutyCycle(current: current, previous: previous)
    #expect(abs((windowed ?? 0) - 0.9) < 1e-9)
  }

  @Test("The first read has nothing to subtract from")
  func windowedAttributionNeedsTwoReads() {
    #expect(LoadMixer.windowedDutyCycle(current: [], previous: []) == nil)
    let sample = WorkerSample(
      iterations: 0, busyNanoseconds: 1, elapsedNanoseconds: 1, abandonedCycles: 0, cycles: 1,
      checksum: 0)
    #expect(LoadMixer.windowedDutyCycle(current: [sample], previous: []) == nil)
  }

  @Test("The contributed fraction comes from measured load, not from requests")
  func contributedFractionFromMeasurement() {
    let split = LoadSplit(
      contributedUtilization: 0.6,
      syntheticUtilization: 0.2,
      totalUtilization: 0.8,
      attribution: .workerMeasured)
    #expect(abs(split.contributedFraction - 0.75) < 1e-9)
  }

  @Test("An idle machine reports no contribution rather than dividing by zero")
  func contributedFractionWhenIdle() {
    let split = LoadSplit(
      contributedUtilization: 0, syntheticUtilization: 0, totalUtilization: 0,
      attribution: .idle)
    #expect(split.contributedFraction == 0)
  }

  // MARK: - Configuration

  @Test("Configuration values are clamped to something usable")
  func configurationClamping() {
    let configuration = MixerConfiguration(
      slewRatePerSecond: -1, deadband: -1, gain: -1, interval: 0)
    #expect(configuration.slewRatePerSecond > 0)
    #expect(configuration.deadband >= 0)
    #expect(configuration.gain > 0)
    #expect(configuration.interval >= 0.1)
  }
}
