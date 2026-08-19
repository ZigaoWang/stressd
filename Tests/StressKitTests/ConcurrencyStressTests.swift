import Foundation
import Testing

@testable import StressKit

/// The two concurrency shapes most likely to hide a bug in this codebase:
/// the park/unpark handoff, and unbounded debt after a long stall.
/// These deliberately still run under a sanitizer: the park/unpark handoff is
/// exactly what TSan should be watching. Only the assertions that need real
/// throughput are relaxed there.
@Suite("Concurrency and debt bounds", .enabled(if: TestHost.isAppleSilicon), .serialized)
struct ConcurrencyStressTests {

  @Test("Crossing zero repeatedly never loses a wakeup", .timeLimit(.minutes(3)))
  func zeroCrossingDoesNotLoseWakeups() async throws {
    // Park and unpark is the one place a lost wakeup could hide: the worker
    // decides to park based on an atomic read, then blocks on a condition
    // variable. If a duty change lands between those two steps and the
    // publisher does not hold the lock, the worker sleeps forever.
    let topology = try CoreTopologyDetector().detect()
    let pool = SyntheticWorkerPool(topology: topology, levelIndex: nil)
    defer { pool.stop() }

    pool.start(dutyCycle: 0)

    // Hammer the boundary from several threads at once, which is a far harsher
    // schedule than the mixer's once-a-second adjustment.
    await withTaskGroup(of: Void.self) { group in
      for worker in 0..<4 {
        group.addTask {
          for index in 0..<500 {
            pool.setDutyCycle((index + worker).isMultiple(of: 2) ? 0 : 0.35)
          }
        }
      }
    }

    // Leave it awake and confirm the pool is actually computing again. A lost
    // wakeup shows up here as iterations that never advance.
    pool.setDutyCycle(0.5)
    try await Task.sleep(for: .seconds(2))
    let before = pool.snapshot().totalIterations
    try await Task.sleep(for: .seconds(2))
    let after = pool.snapshot().totalIterations

    #expect(after > before, "workers did not resume after 2000 zero crossings")

    // And parking still works after all that.
    pool.setDutyCycle(0)
    try await Task.sleep(for: .seconds(1))
    let parked = pool.snapshot().totalIterations
    try await Task.sleep(for: .seconds(2))
    #expect(pool.snapshot().totalIterations == parked, "workers did not park")
  }

  @Test("A stall far in the past cannot make a worker repay unbounded debt")
  func debtIsBoundedAfterALongStall() {
    // The failure this guards against: the machine sleeps mid-cycle, the
    // worker wakes to find its deadline hours in the past, and tries to repay
    // every missed cycle at once, pinning a core at 100% for as long as it
    // takes.
    var scheduler = DutyCycleScheduler(anchor: 0, periodNanoseconds: 5_000_000)
    _ = scheduler.nextCycle(now: 0, dutyCycle: 0.25)

    // Two hours later.
    let farFuture: UInt64 = 2 * 60 * 60 * 1_000_000_000
    let resumed = scheduler.nextCycle(now: farFuture, dutyCycle: 0.25)

    // The cycle it hands back is a normal one, not a marathon.
    #expect(resumed.workNanoseconds(now: farFuture) <= 5_000_000)
    #expect(resumed.end - resumed.start == 5_000_000)
    // Missed cycles are abandoned rather than owed.
    #expect(scheduler.abandonedCycles > 1_000_000)

    // And the debt itself stays capped no matter how long the stall.
    let quantum: UInt64 = 5_000_000 / 4
    #expect(
      scheduler.workDebtNanoseconds <= quantum * DutyCycleScheduler.maximumDebtQuanta)
  }

  @Test("Repeated stalls do not accumulate debt across them")
  func repeatedStallsStayBounded() {
    var scheduler = DutyCycleScheduler(anchor: 0, periodNanoseconds: 5_000_000)
    var now: UInt64 = 0
    let quantum: UInt64 = 5_000_000 / 2

    for _ in 0..<50 {
      _ = scheduler.nextCycle(now: now, dutyCycle: 0.5)
      // Sleep an hour between every cycle, paying nothing down.
      now &+= 60 * 60 * 1_000_000_000
    }
    #expect(
      scheduler.workDebtNanoseconds <= quantum * DutyCycleScheduler.maximumDebtQuanta)
  }

  @Test("adjust takes effect within about one period, without a respawn", .timeLimit(.minutes(2)))
  func adjustAppliesPromptly() async throws {
    // The race between writing the atomic target and the worker reading it at
    // its next cycle boundary. The guarantee is bounded latency, not
    // instantaneous effect.
    let topology = try CoreTopologyDetector().detect()
    let source = SyntheticSource(topology: topology)
    defer { source.emergencyStop() }

    try await source.start(budget: ResourceBudget(cpu: 0.2))
    try await Task.sleep(for: .seconds(2))
    let firstSnapshot = try #require(source.poolSnapshot())

    try await source.adjust(to: ResourceBudget(cpu: 0.8))
    // One efficiency period is the worst case, and that is ~100 ms here.
    try await Task.sleep(for: .milliseconds(500))
    #expect(source.poolSnapshot()?.requestedDutyCycle == 0.8)

    try await Task.sleep(for: .seconds(2))
    let secondSnapshot = try #require(source.poolSnapshot())
    #expect(
      secondSnapshot.placement.threadCount == firstSnapshot.placement.threadCount,
      "adjust must never respawn")
    #expect(secondSnapshot.totalIterations > firstSnapshot.totalIterations)

    await source.stop()
  }
}
