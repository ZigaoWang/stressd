import Foundation
import Testing

@testable import StressKit

@Suite("BOINC preferences round trip")
struct BOINCPreferencesTests {

  /// A scratch directory that cleans itself up.
  private func withTemporaryDirectory<T>(_ body: (String) throws -> T) throws -> T {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("stressd-boinc-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    return try body(directory.path)
  }

  @Test("An existing override file is restored byte for byte")
  func restoresExistingFileExactly() throws {
    try withTemporaryDirectory { directory in
      let file = BOINCPreferencesFile(dataDirectory: directory)

      // Deliberately idiosyncratic: unusual spacing, a key stressd manages, a
      // key it does not, and a trailing comment. All of it must come back.
      let original = """
        <global_preferences>
           <run_on_batteries>1</run_on_batteries>
             <max_ncpus_pct>42.000000</max_ncpus_pct>
           <disk_max_used_gb>17.500000</disk_max_used_gb>
        </global_preferences>
        """
      try Data(original.utf8).write(to: URL(fileURLWithPath: file.overridePath))
      let before = try #require(file.currentContents())

      let journal = BOINCRestoreJournal(
        overridePath: file.overridePath, originalContents: before, originalRunMode: .auto)

      try file.write(limits: .forTarget(0.5))
      let modified = try #require(file.currentContents())
      #expect(modified != before, "the file should actually have been changed")

      try file.restore(from: journal)
      let after = try #require(file.currentContents())
      #expect(after == before, "restore must be byte identical, not merely equivalent")
    }
  }

  @Test("A file that did not exist is deleted, not left empty")
  func restoresAbsentFileByDeleting() throws {
    try withTemporaryDirectory { directory in
      let file = BOINCPreferencesFile(dataDirectory: directory)
      #expect(file.currentContents() == nil)

      let journal = BOINCRestoreJournal(
        overridePath: file.overridePath, originalContents: nil, originalRunMode: .never)
      #expect(journal.fileWasAbsent)

      try file.write(limits: .forTarget(0.8))
      #expect(FileManager.default.fileExists(atPath: file.overridePath))

      try file.restore(from: journal)
      // Leaving an empty override behind would silently replace the user's
      // real preferences with nothing.
      #expect(!FileManager.default.fileExists(atPath: file.overridePath))
    }
  }

  @Test("Restoring twice is harmless")
  func restoreIsIdempotent() throws {
    try withTemporaryDirectory { directory in
      let file = BOINCPreferencesFile(dataDirectory: directory)
      let journal = BOINCRestoreJournal(
        overridePath: file.overridePath, originalContents: nil, originalRunMode: nil)
      try file.write(limits: .forTarget(0.5))
      try file.restore(from: journal)
      try file.restore(from: journal)
      #expect(!FileManager.default.fileExists(atPath: file.overridePath))
    }
  }

  @Test("Keys stressd does not manage survive being written over")
  func preservesForeignKeys() {
    let existing = """
      <global_preferences>
        <max_ncpus_pct>10.000000</max_ncpus_pct>
        <cpu_usage_limit>20.000000</cpu_usage_limit>
        <run_on_batteries>1</run_on_batteries>
        <suspend_if_no_recent_input>60.000000</suspend_if_no_recent_input>
      </global_preferences>
      """
    let rendered = BOINCPreferencesFile.render(
      limits: BOINCCPULimits(maxCPUsPercent: 100, cpuUsagePercent: 75),
      mergingInto: existing)

    // The two keys stressd owns take the new values.
    #expect(rendered.contains("<max_ncpus_pct>100.000000</max_ncpus_pct>"))
    #expect(rendered.contains("<cpu_usage_limit>75.000000</cpu_usage_limit>"))
    // Everything else is the user's and must survive.
    #expect(rendered.contains("<run_on_batteries>1</run_on_batteries>"))
    #expect(rendered.contains("<suspend_if_no_recent_input>60.000000"))
    // And the old values are gone, not duplicated.
    #expect(!rendered.contains("<max_ncpus_pct>10.000000"))
    #expect(!rendered.contains("<cpu_usage_limit>20.000000"))
  }

  @Test("Rendering from nothing produces a valid document")
  func rendersFromScratch() throws {
    let rendered = BOINCPreferencesFile.render(
      limits: .forTarget(0.35), mergingInto: nil)
    #expect(rendered.hasPrefix("<global_preferences>"))
    #expect(rendered.hasSuffix("</global_preferences>\n"))
    // It has to be parseable, since BOINC will read it back.
    let parser = XMLParser(data: Data(rendered.utf8))
    #expect(parser.parse())
  }

  @Test("A target becomes a duty cycle, leaving core count alone")
  func targetMapsToDutyCycle() {
    // Same reasoning as the synthetic source: duty cycle across all cores
    // rather than fewer cores at full tilt.
    let limits = BOINCCPULimits.forTarget(0.6)
    #expect(limits.maxCPUsPercent == 100)
    #expect(abs(limits.cpuUsagePercent - 60) < 1e-9)
  }

  @Test("Limits are clamped into BOINC's accepted range")
  func limitsClamped() {
    #expect(BOINCCPULimits.forTarget(0).cpuUsagePercent == 1)
    #expect(BOINCCPULimits.forTarget(5).cpuUsagePercent == 100)
    #expect(BOINCCPULimits(maxCPUsPercent: 0, cpuUsagePercent: 500).maxCPUsPercent == 1)
  }

  // MARK: - Crash repair

  @Test("A journal survives to disk so a killed run can be repaired")
  func journalRoundTrip() throws {
    try withTemporaryDirectory { directory in
      let url = URL(fileURLWithPath: directory).appendingPathComponent("restore.json")
      let store = BOINCRestoreStore(url: url)

      let journal = BOINCRestoreJournal(
        overridePath: "/tmp/global_prefs_override.xml",
        originalContents: Data("<global_preferences/>".utf8),
        originalRunMode: .auto)
      try store.save(journal)

      // This is the SIGKILL path: nothing ran on the way out, and the next
      // launch has to find this and put the machine back.
      let recovered = try #require(store.load())
      #expect(recovered.overridePath == journal.overridePath)
      #expect(recovered.originalContents == journal.originalContents)
      #expect(recovered.originalRunMode == .auto)

      store.clear()
      #expect(store.load() == nil)
    }
  }

  @Test("A journal recording an absent file round-trips as absent")
  func journalPreservesAbsence() throws {
    try withTemporaryDirectory { directory in
      let url = URL(fileURLWithPath: directory).appendingPathComponent("restore.json")
      let store = BOINCRestoreStore(url: url)
      try store.save(
        BOINCRestoreJournal(
          overridePath: "/tmp/x.xml", originalContents: nil, originalRunMode: nil))

      let recovered = try #require(store.load())
      #expect(recovered.fileWasAbsent)
      #expect(recovered.originalContents == nil)
    }
  }

  @Test("A missing or corrupt journal is not an error")
  func missingJournalIsSilent() throws {
    try withTemporaryDirectory { directory in
      let url = URL(fileURLWithPath: directory).appendingPathComponent("restore.json")
      let store = BOINCRestoreStore(url: url)
      #expect(store.load() == nil)

      try Data("not json".utf8).write(to: url)
      #expect(store.load() == nil)
    }
  }

  @Test("Simulated crash and relaunch leaves the file as the user had it")
  func crashRepairRestoresState() throws {
    try withTemporaryDirectory { directory in
      let file = BOINCPreferencesFile(dataDirectory: directory)
      let storeURL = URL(fileURLWithPath: directory).appendingPathComponent("restore.json")
      let store = BOINCRestoreStore(url: storeURL)

      let userPreferences =
        "<global_preferences>\n  <run_on_batteries>1</run_on_batteries>\n</global_preferences>\n"
      try Data(userPreferences.utf8).write(to: URL(fileURLWithPath: file.overridePath))
      let original = try #require(file.currentContents())

      // A run starts: snapshot first, then modify.
      try store.save(
        BOINCRestoreJournal(
          overridePath: file.overridePath, originalContents: original,
          originalRunMode: .auto))
      try file.write(limits: .forTarget(0.9))
      #expect(file.currentContents() != original)

      // SIGKILL here. No cleanup handler runs, no restore happens.

      // Next launch finds the journal and repairs.
      let recovered = try #require(store.load())
      try file.restore(from: recovered)
      store.clear()

      #expect(file.currentContents() == original)
      #expect(store.load() == nil)
    }
  }
}
