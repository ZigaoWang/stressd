import Foundation

/// Parks worker threads at a zero duty cycle and wakes them without a respawn.
///
/// A 0% target must not be a busy loop that computes nothing 100% of the time,
/// and it must not tear the pool down either: `adjust(to:)` is called every
/// second once contributed load is mixed in, and crossing zero has to be as
/// cheap as any other change.
///
/// The duty cycle is written under this lock and read under it in the parking
/// predicate, so a worker cannot decide to park using a value that has already
/// been superseded. The hot path never touches the lock: workers read the duty
/// cycle atomically once per cycle and only come here to sleep or wake.
final class WorkerGate: @unchecked Sendable {

  private let condition = NSCondition()
  private let dutyCycle: AtomicDouble
  private let isRunning: AtomicFlag

  init(dutyCycle: AtomicDouble, isRunning: AtomicFlag) {
    self.dutyCycle = dutyCycle
    self.isRunning = isRunning
  }

  /// Publishes a new duty cycle and wakes anything parked on the old one.
  func setDutyCycle(_ value: Double) {
    condition.lock()
    dutyCycle.store(value)
    condition.broadcast()
    condition.unlock()
  }

  /// Clears the run flag and wakes every parked worker so it can exit.
  func stop() {
    condition.lock()
    isRunning.value = false
    condition.broadcast()
    condition.unlock()
  }

  /// Blocks until there is work to do or the pool is shutting down.
  ///
  /// - Returns: `true` if the caller should keep working, `false` to exit.
  func parkUntilWorkAvailable() -> Bool {
    condition.lock()
    defer { condition.unlock() }
    while isRunning.value, dutyCycle.load() <= 0 {
      condition.wait()
    }
    return isRunning.value
  }
}
