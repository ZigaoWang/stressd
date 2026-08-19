import Foundation
import Testing

@testable import StressKit

@Suite("Duration parsing")
struct DurationParserTests {

  @Test(
    "Durations parse to seconds",
    arguments: [
      ("30", 30.0),
      ("30s", 30.0),
      ("90s", 90.0),
      ("5m", 300.0),
      ("2h", 7200.0),
      ("1h30m", 5400.0),
      ("1h30m15s", 5415.0),
      ("0.5m", 30.0),
      (" 2H ", 7200.0),
    ])
  func parsing(text: String, expected: Double) throws {
    #expect(try DurationParser.parse(text) == expected)
  }

  @Test(
    "Malformed durations are rejected rather than guessed at",
    arguments: ["", "   ", "abc", "1d", "-5", "0", "1h30", "h", "5x"])
  func rejection(text: String) {
    #expect(throws: DurationParser.ParseError.self) {
      _ = try DurationParser.parse(text)
    }
  }

  @Test("A trailing magnitude with no unit is a typo, not an instruction")
  func trailingMagnitudeRejected() {
    // "1h30" almost certainly means 1h30m. Silently reading the 30 as seconds
    // would be a 30 minute error in the user's favourite direction.
    #expect(throws: DurationParser.ParseError.unrecognised("1h30")) {
      _ = try DurationParser.parse("1h30")
    }
  }

  @Test(
    "Formatting is compact and unambiguous",
    arguments: [
      (45.0, "45s"),
      (150.0, "2m30s"),
      (3600.0, "1h00m"),
      (5400.0, "1h30m"),
      (0.0, "0s"),
    ])
  func formatting(seconds: Double, expected: String) {
    #expect(DurationParser.format(seconds) == expected)
  }
}
