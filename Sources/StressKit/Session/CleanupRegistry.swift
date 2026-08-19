import Foundation

/// Runs registered teardown work exactly once, from whichever exit path gets
/// there first.
///
/// stressd can leave the machine in a modified state: threads running, a sleep
/// assertion held, and later a BOINC run mode and a display brightness that
/// were not what the user set. All of it has to be undone on a normal exit, on
/// SIGINT, on SIGTERM, and on an unexpected termination.
///
/// Handlers run in reverse registration order, so teardown unwinds the way
/// setup was built up. A handler that throws does not prevent the rest from
/// running: a partially restored machine is the failure mode this exists to
/// avoid.
public final class CleanupRegistry: @unchecked Sendable {

  /// The registry the `atexit` backstop drains. A process has one exit, so it
  /// has one of these.
  public static let shared = CleanupRegistry()

  private let lock = NSLock()
  private var handlers: [(name: String, body: @Sendable () -> Void)] = []
  private var hasRun = false

  public init() {}

  /// Registers teardown work. Ignored once the registry has run, so a handler
  /// added during shutdown cannot be silently dropped without notice.
  ///
  /// - Returns: `false` if cleanup had already run, in which case the caller
  ///   should undo its own work immediately.
  @discardableResult
  public func register(_ name: String, _ body: @escaping @Sendable () -> Void) -> Bool {
    lock.lock()
    defer { lock.unlock() }
    guard !hasRun else { return false }
    handlers.append((name, body))
    return true
  }

  /// Runs every handler once. Idempotent and safe to call from several exit
  /// paths racing each other.
  public func run() {
    lock.lock()
    guard !hasRun else {
      lock.unlock()
      return
    }
    hasRun = true
    let pending = handlers.reversed()
    handlers = []
    lock.unlock()

    for handler in pending {
      handler.body()
    }
  }

  public var hasCompleted: Bool {
    lock.lock()
    defer { lock.unlock() }
    return hasRun
  }

  /// Installs the `atexit` backstop.
  ///
  /// This is the last line of defence, not the primary path: `atexit` does not
  /// run on an uncaught signal, which is why signal handling is wired up
  /// separately. Call once at startup.
  public static func installAtExitBackstop() {
    atexit {
      CleanupRegistry.shared.run()
    }
  }
}
