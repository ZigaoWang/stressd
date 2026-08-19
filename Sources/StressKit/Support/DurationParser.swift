import Foundation

/// Parses human durations like `90s`, `2h`, `1h30m`.
public enum DurationParser {

  public enum ParseError: Error, Equatable, CustomStringConvertible {
    case empty
    case unrecognised(String)
    case notPositive(String)

    public var description: String {
      switch self {
      case .empty:
        return "duration is empty"
      case .unrecognised(let text):
        return
          "'\(text)' is not a duration. Use a number of seconds, or a value with "
          + "units: 30s, 15m, 2h, 1h30m"
      case .notPositive(let text):
        return "'\(text)' must be greater than zero"
      }
    }
  }

  private static let unitSeconds: [Character: Double] = [
    "h": 3600,
    "m": 60,
    "s": 1,
  ]

  /// Converts a duration string to seconds.
  ///
  /// Accepts a bare number, read as seconds, or one or more magnitude/unit
  /// pairs which are summed: `1h30m` is 5400.
  public static func parse(_ text: String) throws -> TimeInterval {
    let trimmed = text.trimmingCharacters(in: .whitespaces).lowercased()
    guard !trimmed.isEmpty else { throw ParseError.empty }

    if let bareSeconds = Double(trimmed) {
      guard bareSeconds > 0 else { throw ParseError.notPositive(text) }
      return bareSeconds
    }

    var total: TimeInterval = 0
    var magnitude = ""
    var sawUnit = false

    for character in trimmed {
      if character.isNumber || character == "." {
        magnitude.append(character)
        continue
      }
      guard let seconds = unitSeconds[character], let value = Double(magnitude) else {
        throw ParseError.unrecognised(text)
      }
      total += value * seconds
      magnitude = ""
      sawUnit = true
    }

    // A trailing magnitude with no unit, as in "1h30", is a typo rather than an
    // instruction. Rejecting it is better than silently picking a unit.
    guard sawUnit, magnitude.isEmpty else { throw ParseError.unrecognised(text) }
    guard total > 0 else { throw ParseError.notPositive(text) }
    return total
  }

  /// Formats seconds compactly: `45s`, `2m30s`, `1h05m`.
  public static func format(_ seconds: TimeInterval) -> String {
    guard seconds.isFinite, seconds >= 0 else { return "-" }
    let total = Int(seconds.rounded())
    let hours = total / 3600
    let minutes = (total % 3600) / 60
    let remainder = total % 60

    if hours > 0 { return String(format: "%dh%02dm", hours, minutes) }
    if minutes > 0 { return String(format: "%dm%02ds", minutes, remainder) }
    return "\(remainder)s"
  }
}
