import Foundation
import Testing

@testable import StressKit

@Suite("Duty cycle scheduling")
struct DutyCycleSchedulerTests {

  private let period: UInt64 = 5_000_000

  // MARK: - Duty cycle arithmetic

  @Test(
    "Work window is the requested fraction of the period",
    arguments: [
      (0.0, UInt64(0)),
      (0.25, UInt64(1_250_000)),
      (0.5, UInt64(2_500_000)),
      (0.75, UInt64(3_750_000)),
      (1.0, UInt64(5_000_000)),
    ])
  func workWindow(dutyCycle: Double, expected: UInt64) {
    #expect(
      DutyCycleScheduler.workNanoseconds(period: 5_000_000, dutyCycle: dutyCycle) == expected)
  }

  @Test("Out of range duty cycles are clamped, not wrapped")
  func clampedWorkWindow() {
    #expect(DutyCycleScheduler.workNanoseconds(period: period, dutyCycle: -1) == 0)
    #expect(DutyCycleScheduler.workNanoseconds(period: period, dutyCycle: 4) == period)
    #expect(DutyCycleScheduler.workNanoseconds(period: period, dutyCycle: .nan) == 0)
  }

  @Test("100% skips the sleep path entirely")
  func saturationSkipsWaiting() {
    var saturated = DutyCycleScheduler(anchor: 0, periodNanoseconds: period)
    #expect(saturated.nextCycle(now: 0, dutyCycle: 1.0).isSaturated)

    var partial = DutyCycleScheduler(anchor: 0, periodNanoseconds: period)
    #expect(!partial.nextCycle(now: 0, dutyCycle: 0.999).isSaturated)
  }

  @Test("Unpaid debt overshoots the target, so the pairing is not optional")
  func unpaidDebtOvershoots() {
    // The failure mode of forgetting completeCycle: debt runs up to the cap and
    // every work window is the maximum the cap allows rather than the target.
    var scheduler = DutyCycleScheduler(anchor: 0, periodNanoseconds: period)
    for index in 0..<8 {
      _ = scheduler.nextCycle(now: UInt64(index) * period, dutyCycle: 0.25)
    }
    let starved = scheduler.nextCycle(now: 8 * period, dutyCycle: 0.25)
    #expect(
      starved.workNanoseconds(now: 8 * period)
        == (period / 4) * DutyCycleScheduler.maximumDebtQuanta)

    // Paying it down each cycle keeps the window at the requested quantum.
    var paid = DutyCycleScheduler(anchor: 0, periodNanoseconds: period)
    for index in 0..<4 {
      let cycle = paid.nextCycle(now: UInt64(index) * period, dutyCycle: 0.25)
      paid.completeCycle(workedNanoseconds: cycle.workNanoseconds(now: UInt64(index) * period))
    }
    let cycle = paid.nextCycle(now: 4 * period, dutyCycle: 0.25)
    #expect(!cycle.isSaturated)
    #expect(cycle.workNanoseconds(now: 4 * period) == period / 4)
  }

  @Test("A period below the floor is raised to it")
  func periodFloor() {
    let scheduler = DutyCycleScheduler(anchor: 0, periodNanoseconds: 1)
    #expect(scheduler.periodNanoseconds == DutyCycleScheduler.minimumPeriodNanoseconds)
  }

  // MARK: - Anchoring

  @Test("Deadlines come from the anchor, not from when the last cycle finished")
  func deadlinesAreAbsolute() {
    var scheduler = DutyCycleScheduler(anchor: 1_000, periodNanoseconds: period)

    let first = scheduler.nextCycle(now: 1_000, dutyCycle: 0.5)
    #expect(first.start == 1_000)
    #expect(first.workDeadline == 1_000 + period / 2)
    #expect(first.end == 1_000 + period)

    // The worker overran by 1 ms. The next cycle still starts on the grid, so
    // the overrun is repaid out of that cycle's work window rather than pushing
    // every later cycle back.
    let second = scheduler.nextCycle(now: 1_000 + period + 1_000_000, dutyCycle: 0.5)
    #expect(second.start == 1_000 + period)
    #expect(second.end == 1_000 + 2 * period)
  }

  @Test("Arriving late still gets the full work quantum")
  func oversleepDoesNotCostWork() {
    // The bug this fixes: mach_wait_until reliably oversleeps, so a worker
    // routinely arrives after its cycle should have started. Measuring the work
    // window from the grid start would hand that oversleep back as lost work,
    // and because oversleep is one-sided the loss is a systematic undershoot.
    var scheduler = DutyCycleScheduler(anchor: 0, periodNanoseconds: period)
    let first = scheduler.nextCycle(now: 0, dutyCycle: 0.5)
    scheduler.completeCycle(workedNanoseconds: first.workNanoseconds(now: 0))

    // Cycle 1 is due at 5 ms but the sleep overshot to 6.5 ms. The full 2.5 ms
    // quantum is still owed.
    let late = scheduler.nextCycle(now: 6_500_000, dutyCycle: 0.5)
    #expect(late.workNanoseconds(now: 6_500_000) == 2_500_000)
    // And the cycle boundary has not moved, so the duty cycle denominator is
    // untouched.
    #expect(late.end == 10_000_000)
  }

  @Test("A work window can never exceed the cycle boundary")
  func repaymentCannotExceedFullLoad() {
    var scheduler = DutyCycleScheduler(anchor: 0, periodNanoseconds: period)

    // Two cycles of debt built up with nothing paid down. Repaying it must not
    // produce a work window longer than the cycle itself.
    _ = scheduler.nextCycle(now: 0, dutyCycle: 0.5)
    _ = scheduler.nextCycle(now: period, dutyCycle: 0.5)
    let third = scheduler.nextCycle(now: 2 * period, dutyCycle: 0.5)

    #expect(third.workDeadline <= third.end)
    #expect(third.workNanoseconds(now: 2 * period) <= period)
  }

  @Test("Debt is capped so a backlog cannot become a burst")
  func debtIsCapped() {
    var scheduler = DutyCycleScheduler(anchor: 0, periodNanoseconds: period)
    for index in 0..<50 {
      _ = scheduler.nextCycle(now: UInt64(index) * period, dutyCycle: 0.25)
    }
    let quantum = period / 4
    #expect(
      scheduler.workDebtNanoseconds <= quantum * DutyCycleScheduler.maximumDebtQuanta)
  }

  @Test("A thread that loses the CPU abandons missed cycles instead of repaying them")
  func longStallReanchors() {
    var scheduler = DutyCycleScheduler(anchor: 0, periodNanoseconds: period)
    _ = scheduler.nextCycle(now: 0, dutyCycle: 0.5)

    // Descheduled for 200 ms: 40 cycles missed. Repaying them would mean
    // running flat out to catch up, which is the overshoot the duty cycler
    // exists to prevent.
    let resumed = scheduler.nextCycle(now: 200_000_000, dutyCycle: 0.5)
    #expect(resumed.start == 200_000_000)
    #expect(scheduler.abandonedCycles > 30)
    #expect(resumed.workNanoseconds(now: 200_000_000) == period / 2)
  }

  @Test("Being slightly late does not reanchor")
  func smallOverrunDoesNotReanchor() {
    var scheduler = DutyCycleScheduler(anchor: 0, periodNanoseconds: period)
    _ = scheduler.nextCycle(now: 0, dutyCycle: 0.5)

    let slightlyLate = scheduler.nextCycle(now: period + 2_000_000, dutyCycle: 0.5)
    #expect(slightlyLate.start == period)
    #expect(scheduler.abandonedCycles == 0)
  }

  // MARK: - Drift

  /// Simulates a worker for `cycles` cycles with injected jitter on both the
  /// work and the sleep, and reports what it achieved.
  private func simulate(
    cycles: Int,
    dutyCycle: Double,
    workJitter: Int64,
    oversleepFraction: Double
  ) -> (elapsed: UInt64, busy: UInt64, abandoned: UInt64) {
    var scheduler = DutyCycleScheduler(anchor: 0, periodNanoseconds: period)
    var jitter = SeededJitter()
    let clock = FakeClock(now: 0)
    var busyNanoseconds: UInt64 = 0

    for _ in 0..<cycles {
      let now = clock.nanoseconds()
      let cycle = scheduler.nextCycle(now: now, dutyCycle: dutyCycle)

      let target = Int64(cycle.workDeadline) + jitter.next(magnitude: workJitter)
      let finished = UInt64(max(target, Int64(now)))
      clock.set(to: finished)
      let worked = finished - now
      busyNanoseconds += worked
      scheduler.completeCycle(workedNanoseconds: worked)

      if !cycle.isSaturated {
        clock.wait(untilNanoseconds: cycle.end)
        // mach_wait_until overshoots, and always in the same direction.
        let requested = cycle.end > finished ? cycle.end - finished : 0
        clock.advance(by: UInt64(Double(requested) * oversleepFraction))
      }
    }
    return (clock.nanoseconds(), busyNanoseconds, scheduler.abandonedCycles)
  }

  @Test("Ten thousand jittered cycles hold the target with bounded drift")
  func noDriftUnderJitter() {
    let cycles = 10_000
    let result = simulate(
      cycles: cycles,
      dutyCycle: 0.5,
      // Work overshoots or undershoots by up to 400 us, 8% of a period: far
      // more jitter than a real chunked worker produces.
      workJitter: 400_000,
      // And every sleep overshoots by a quarter, as macOS really does.
      oversleepFraction: 0.25)

    let ideal = UInt64(cycles) * period
    let drift = result.elapsed > ideal ? result.elapsed - ideal : ideal - result.elapsed
    // Anchored cycle boundaries mean the error stays within a single cycle no
    // matter how many cycles run. It does not accumulate.
    #expect(drift < period, "drift of \(drift) ns after \(cycles) cycles")
    #expect(result.abandoned == 0)

    // Tolerance of 3 points, not 1, because the jitter here is deliberately
    // extreme: plus or minus 400 us on a 2.5 ms quantum is 16%, and the debt
    // model repays an undershoot while never refunding an overshoot, so heavy
    // symmetric jitter biases very slightly high. A real chunked worker
    // overshoots by at most one chunk; on hardware a 50% request measures
    // 50.3%. The parameterised test below uses realistic jitter and holds to
    // within one point.
    let achieved = Double(result.busy) / Double(result.elapsed)
    #expect(abs(achieved - 0.5) < 0.03, "achieved \(achieved) for a 50% request")
  }

  @Test(
    "The target is held across the range even with the sleep overshooting",
    arguments: [0.1, 0.25, 0.5, 0.75, 0.9])
  func holdsTargetUnderOversleep(target: Double) {
    let result = simulate(
      cycles: 10_000, dutyCycle: target, workJitter: 100_000, oversleepFraction: 0.25)
    let achieved = Double(result.busy) / Double(result.elapsed)
    #expect(abs(achieved - target) < 0.01, "achieved \(achieved) for \(target)")
  }

  @Test("Measuring the work window from the grid start would undershoot instead")
  func gridRelativeWindowUndershoots() {
    // The behaviour before the work-debt model, reproduced here so the fix has
    // something to be a fix of. Measured on hardware, a 5 ms period at 25%
    // came out at 10%.
    var jitter = SeededJitter()
    var now: UInt64 = 0
    var busy: UInt64 = 0
    let cycles = 10_000
    let quantum = period / 4

    for index in 0..<cycles {
      let start = UInt64(index) * period
      let deadline = start + quantum
      let target = Int64(deadline) + jitter.next(magnitude: 100_000)
      let finished = UInt64(max(target, Int64(now)))
      // Work window clamped by the grid start: arriving late loses the
      // difference.
      busy += finished > now ? finished - now : 0
      now = max(finished, start + period)
      now += UInt64(Double(period - quantum) * 0.25)  // oversleep
    }

    let achieved = Double(busy) / Double(now)
    #expect(achieved < 0.22, "grid-relative windows should undershoot 25%")
  }

  @Test("The same jitter under relative sleeps drifts badly, which is why anchoring exists")
  func relativeSleepsDrift() {
    // The comparison the anchored design is justified by. Each cycle sleeps for
    // the remaining time computed from "now", so every overshoot lengthens the
    // period permanently.
    var jitter = SeededJitter()
    var now: UInt64 = 0
    let cycles = 10_000
    let workWindow = period / 2

    for _ in 0..<cycles {
      let target = Int64(workWindow) + jitter.next(magnitude: 400_000)
      now &+= UInt64(max(target, 0))
      now &+= period - workWindow
    }

    let ideal = UInt64(cycles) * period
    let drift = now > ideal ? now - ideal : ideal - now
    #expect(drift > 1_000_000, "relative sleeps should visibly drift; anchored ones do not")
  }

  @Test("Reanchoring resets the grid to the new origin")
  func reanchor() {
    var scheduler = DutyCycleScheduler(anchor: 0, periodNanoseconds: period)
    _ = scheduler.nextCycle(now: 0, dutyCycle: 1.0)
    _ = scheduler.nextCycle(now: period, dutyCycle: 1.0)

    scheduler.reanchor(to: 50_000_000)
    let cycle = scheduler.nextCycle(now: 50_000_000, dutyCycle: 1.0)
    #expect(cycle.index == 0)
    #expect(cycle.start == 50_000_000)
  }

  @Test("A parked thread does not repay the cycles it slept through")
  func parkingDoesNotOweWork() {
    var scheduler = DutyCycleScheduler(anchor: 0, periodNanoseconds: period)
    _ = scheduler.nextCycle(now: 0, dutyCycle: 0.5)

    // Duty cycle went to zero, the thread parked for ten seconds, then woke.
    // This is what the worker does on wake.
    scheduler.reanchor(to: 10_000_000_000)
    let cycle = scheduler.nextCycle(now: 10_000_000_000, dutyCycle: 0.5)
    #expect(cycle.workNanoseconds(now: 10_000_000_000) == period / 2)
  }
}
