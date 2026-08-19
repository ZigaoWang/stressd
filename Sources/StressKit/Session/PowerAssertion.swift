import Foundation
import IOKit.pwr_mgt

/// Keeps the machine awake while load is running.
///
/// Without this, a long run on a laptop with the lid closed or the idle timer
/// running gets suspended partway through and the results are worthless.
/// Release is idempotent and safe from a cleanup path that may run twice.
public final class PowerAssertion: @unchecked Sendable {

  private let lock = NSLock()
  private var assertionID: IOPMAssertionID?

  public let reason: String

  private init(assertionID: IOPMAssertionID, reason: String) {
    self.assertionID = assertionID
    self.reason = reason
  }

  /// Prevents idle system sleep. Display sleep is deliberately still allowed:
  /// the screen is a large share of total draw and keeping it lit would distort
  /// every power measurement.
  public static func preventIdleSleep(reason: String) throws -> PowerAssertion {
    var identifier = IOPMAssertionID(0)
    let status = IOPMAssertionCreateWithName(
      kIOPMAssertPreventUserIdleSystemSleep as CFString,
      IOPMAssertionLevel(kIOPMAssertionLevelOn),
      reason as CFString,
      &identifier)

    guard status == kIOReturnSuccess else {
      throw StressKitError.powerAssertionFailed(kernReturn: status)
    }
    return PowerAssertion(assertionID: identifier, reason: reason)
  }

  /// Releases the assertion. Safe to call any number of times.
  public func release() {
    lock.lock()
    defer { lock.unlock() }
    guard let assertionID else { return }
    IOPMAssertionRelease(assertionID)
    self.assertionID = nil
  }

  public var isHeld: Bool {
    lock.lock()
    defer { lock.unlock() }
    return assertionID != nil
  }

  deinit {
    if let assertionID {
      IOPMAssertionRelease(assertionID)
    }
  }
}
