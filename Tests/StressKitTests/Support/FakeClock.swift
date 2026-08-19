import Foundation

@testable import StressKit

/// A `MonotonicClock` the test drives by hand.
///
/// `wait(untilNanoseconds:)` jumps straight to the deadline, so scheduling
/// behaviour over hours of simulated time costs microseconds of real time and
/// is perfectly reproducible.
final class FakeClock: MonotonicClock, @unchecked Sendable {

  private let lock = NSLock()
  private var current: UInt64
  private(set) var waitCount = 0

  init(now: UInt64 = 0) {
    current = now
  }

  func nanoseconds() -> UInt64 {
    lock.lock()
    defer { lock.unlock() }
    return current
  }

  func wait(untilNanoseconds deadline: UInt64) {
    lock.lock()
    defer { lock.unlock() }
    waitCount += 1
    // A deadline in the past returns immediately, as the real one does.
    current = max(current, deadline)
  }

  func advance(by nanoseconds: UInt64) {
    lock.lock()
    defer { lock.unlock() }
    current &+= nanoseconds
  }

  func set(to nanoseconds: UInt64) {
    lock.lock()
    defer { lock.unlock() }
    current = nanoseconds
  }
}

/// Deterministic jitter, so a failing drift test fails the same way twice.
///
/// A 64-bit linear congruential generator: the test needs reproducible spread,
/// not statistical quality.
struct SeededJitter {
  private var state: UInt64

  init(seed: UInt64 = 0x2545_F491_4F6C_DD1D) {
    state = seed
  }

  /// A value in `-magnitude...magnitude`.
  mutating func next(magnitude: Int64) -> Int64 {
    state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
    guard magnitude > 0 else { return 0 }
    let span = UInt64(magnitude) &* 2 &+ 1
    return Int64((state >> 11) % span) - magnitude
  }
}
