import Foundation
import Testing

@testable import StressKit

@Suite("Folding@home parsing")
struct FoldingParsingTests {

  @Test("A v8 state object parses")
  func parsesStateObject() throws {
    let json = """
      {"info":{"version":"8.3.18"},"config":{"paused":false,"cpus":8},
       "units":[{"id":"01","project":18201,"progress":0.42,"paused":false},
                {"id":"02","project":18202,"progress":0.11,"paused":true}]}
      """
    let snapshot = try FoldingStateParser.parse(Data(json.utf8))

    #expect(snapshot.version == "8.3.18")
    #expect(!snapshot.isPaused)
    #expect(snapshot.units.count == 2)
    #expect(snapshot.units[0].project == 18201)
    #expect(abs((snapshot.units[0].progress ?? 0) - 0.42) < 0.0001)
    #expect(snapshot.units[1].isPaused)
  }

  @Test("A frame array parses too, since v8 has shipped both shapes")
  func parsesFrameArray() throws {
    let json = """
      [{"info":{"version":"8.1.0"},"config":{"paused":true},"units":[]}]
      """
    let snapshot = try FoldingStateParser.parse(Data(json.utf8))
    #expect(snapshot.version == "8.1.0")
    #expect(snapshot.isPaused)
    #expect(snapshot.units.isEmpty)
  }

  @Test("Missing keys degrade to nil rather than throwing")
  func missingKeys() throws {
    let snapshot = try FoldingStateParser.parse(Data("{}".utf8))
    #expect(snapshot.version == nil)
    #expect(!snapshot.isPaused)
    #expect(snapshot.units.isEmpty)
  }

  @Test("Empty, truncated and non-JSON input is rejected")
  func badInput() {
    // XMLParser and JSONSerialization both hand back partial results happily
    // in some shapes, so these are checked explicitly.
    for bad in ["", "{\"units\":", "not json at all", "[1,2,3]"] {
      #expect(throws: (any Error).self) {
        _ = try FoldingStateParser.parse(Data(bad.utf8))
      }
    }
  }
}

@Suite("mlucas parsing")
struct MlucasParsingTests {

  @Test("worktodo entries are counted, comments ignored")
  func parsesWorktodo() {
    let text = """
      # a comment
      ; another comment

      Test=E0F0A1B2C3D4E5F6,110503,75,1
      DoubleCheck=A1B2C3D4,332191517,76,1
      garbage line with no equals
      """
    let entries = MlucasWorktodo.parse(text)
    #expect(entries.count == 2)
  }

  @Test("An empty worktodo yields no assignments")
  func emptyWorktodo() {
    #expect(MlucasWorktodo.parse("").isEmpty)
    #expect(MlucasWorktodo.parse("# only comments\n").isEmpty)
  }

  @Test("Progress is read from a status line")
  func parsesProgress() throws {
    let log = """
      M110503 Iter# = 4000000 [ 36.19% complete] clocks = 00:00:12.345
      M110503 Iter# = 5000000 [ 45.30% complete] clocks = 00:00:12.400
      """
    let progress = try #require(MlucasLogParser.parse(logText: log))

    // The most recent line wins.
    #expect(progress.exponent == 110503)
    #expect(progress.iteration == 5_000_000)
    #expect(abs((progress.percentComplete ?? 0) - 45.30) < 0.001)
  }

  @Test("A log with nothing recognisable yields nil, not a wrong answer")
  func unparseableLog() {
    #expect(MlucasLogParser.parse(logText: "") == nil)
    #expect(MlucasLogParser.parse(logText: "starting up\nreading worktodo\n") == nil)
  }

  @Test("A truncated status line does not produce a bogus reading")
  func truncatedLine() {
    // Half a line is what a concurrent read of a growing file gives you.
    let progress = MlucasLogParser.parse(logText: "M110503 Iter# = 500")
    // Either nil or a partial reading, but never a wrong percentage.
    #expect(progress?.percentComplete == nil)
  }
}
