import Darwin
import Dispatch
import Foundation
import StressKit

/// Turns SIGINT and SIGTERM into an ordinary cancellation.
///
/// The signals are ignored at the disposition level and observed through
/// `DispatchSourceSignal` instead. A C signal handler may only call
/// async-signal-safe functions, which rules out almost everything cleanup needs
/// to do; a dispatch source moves the work onto a normal queue where it is
/// safe.
///
/// A second signal exits immediately. Someone pressing Ctrl-C twice wants out
/// now, not a tidier shutdown.
final class InterruptHandler: @unchecked Sendable {

  /// Its own queue, not the main queue: an `AsyncParsableCommand` never runs a
  /// main run loop, so a source attached to `.main` would never fire.
  private let queue = DispatchQueue(label: "dev.stressd.signals")
  private var sources: [DispatchSourceSignal] = []
  private let lock = NSLock()
  private var hasFired = false
  private let onInterrupt: @Sendable () -> Void

  init(onInterrupt: @escaping @Sendable () -> Void) {
    self.onInterrupt = onInterrupt
  }

  func install() {
    for signalNumber in [SIGINT, SIGTERM] {
      // Required: the dispatch source observes the signal, it does not replace
      // the default disposition, which would still terminate the process.
      signal(signalNumber, SIG_IGN)

      let source = DispatchSource.makeSignalSource(signal: signalNumber, queue: queue)
      source.setEventHandler { [weak self] in
        self?.fire()
      }
      source.resume()
      sources.append(source)
    }
  }

  private func fire() {
    lock.lock()
    let isRepeat = hasFired
    hasFired = true
    lock.unlock()

    guard !isRepeat else {
      CleanupRegistry.shared.run()
      exit(130)
    }
    onInterrupt()
  }
}
