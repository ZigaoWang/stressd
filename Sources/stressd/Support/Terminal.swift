import Darwin
import Foundation

/// Terminal capabilities and ANSI control, for the in-place `watch` display.
enum Terminal {

  /// Whether standard output is a terminal.
  ///
  /// When it is not — a pipe, a file, a CI log — cursor movement would be
  /// written literally into the output, so the renderers fall back to plain
  /// lines.
  static var isInteractive: Bool {
    isatty(STDOUT_FILENO) == 1
  }

  /// Terminal width in columns, or a sane default when it cannot be determined.
  static var columns: Int {
    var size = winsize()
    guard ioctl(STDOUT_FILENO, TIOCGWINSZ, &size) == 0, size.ws_col > 0 else {
      return 80
    }
    return Int(size.ws_col)
  }

  static let hideCursor = "\u{1B}[?25l"
  static let showCursor = "\u{1B}[?25h"
  static let clearToEndOfLine = "\u{1B}[0K"
  static let clearToEndOfScreen = "\u{1B}[0J"

  static func moveCursorUp(_ lines: Int) -> String {
    lines > 0 ? "\u{1B}[\(lines)A" : ""
  }

  /// Writes without a trailing newline and flushes, so a partially drawn frame
  /// never sits in the buffer.
  static func write(_ text: String) {
    FileHandle.standardOutput.write(Data(text.utf8))
  }
}

/// Draws a frame in place, moving the cursor back over the previous one.
///
/// Falls back to appending plain lines when stdout is not a terminal.
///
/// Locked rather than actor-isolated: the cleanup path has to restore the
/// cursor from an `atexit` handler, which cannot await.
final class InPlaceRenderer: @unchecked Sendable {

  private let lock = NSLock()
  private var previousLineCount = 0
  private let interactive: Bool

  init(interactive: Bool = Terminal.isInteractive) {
    self.interactive = interactive
    if interactive {
      Terminal.write(Terminal.hideCursor)
    }
  }

  func render(_ lines: [String]) {
    guard interactive else {
      print(lines.joined(separator: "\n"))
      return
    }

    lock.lock()
    defer { lock.unlock() }

    var frame = Terminal.moveCursorUp(previousLineCount)
    for line in lines {
      frame += line + Terminal.clearToEndOfLine + "\n"
    }
    // A shorter frame than the last one would leave stale rows behind.
    frame += Terminal.clearToEndOfScreen
    Terminal.write(frame)
    previousLineCount = lines.count
  }

  /// Restores the cursor. Idempotent.
  func finish() {
    guard interactive else { return }
    Terminal.write(Terminal.showCursor)
  }
}
