import Foundation

/// The two knobs in `global_prefs_override.xml` that decide how much CPU BOINC
/// may use.
public struct BOINCCPULimits: Sendable, Codable, Equatable {
  /// `max_ncpus_pct`: the fraction of cores BOINC may use, as a percentage.
  public let maxCPUsPercent: Double
  /// `cpu_usage_limit`: a duty cycle BOINC applies to its own work, as a
  /// percentage.
  public let cpuUsagePercent: Double

  public init(maxCPUsPercent: Double, cpuUsagePercent: Double) {
    self.maxCPUsPercent = min(max(maxCPUsPercent, 1), 100)
    self.cpuUsagePercent = min(max(cpuUsagePercent, 1), 100)
  }

  /// Limits for a target fraction of the whole machine.
  ///
  /// Cores are left at 100% and the duty cycle carries the target, for the same
  /// reason the synthetic source duty-cycles every core rather than using
  /// fewer: it keeps the power curve closer to linear and leaves one scalar to
  /// move.
  public static func forTarget(_ fraction: Double) -> BOINCCPULimits {
    let clamped = min(max(fraction, 0), 1)
    return BOINCCPULimits(maxCPUsPercent: 100, cpuUsagePercent: max(1, clamped * 100))
  }
}

/// What stressd changed, recorded so it can be put back.
///
/// Persisted to disk as well as held in memory: if stressd is killed with
/// SIGKILL, no cleanup handler runs, and the only way the machine gets its
/// settings back is for the next launch to find this and repair it.
public struct BOINCRestoreJournal: Sendable, Codable, Equatable {
  /// Path of the override file that was modified.
  public let overridePath: String
  /// The file's exact original bytes, base64 encoded. `nil` when the file did
  /// not exist, in which case restoring means deleting it.
  public let originalContentsBase64: String?
  /// The run mode in force before stressd changed it.
  public let originalRunMode: BOINCRunMode?
  public let recordedAt: Date

  public init(
    overridePath: String,
    originalContents: Data?,
    originalRunMode: BOINCRunMode?,
    recordedAt: Date = Date()
  ) {
    self.overridePath = overridePath
    self.originalContentsBase64 = originalContents?.base64EncodedString()
    self.originalRunMode = originalRunMode
    self.recordedAt = recordedAt
  }

  public var originalContents: Data? {
    originalContentsBase64.flatMap { Data(base64Encoded: $0) }
  }

  /// True when the override file did not exist before stressd ran, so restoring
  /// means removing it rather than writing an empty one.
  public var fileWasAbsent: Bool { originalContentsBase64 == nil }
}

/// Reads and writes BOINC's `global_prefs_override.xml`, and remembers how to
/// put it back.
public struct BOINCPreferencesFile: @unchecked Sendable {

  /// Where BOINC keeps its data on macOS, most likely first.
  public static let candidateDataDirectories = [
    "/Library/Application Support/BOINC Data",
    "/opt/homebrew/var/boinc",
    "/usr/local/var/boinc",
  ]

  public static let overrideFileName = "global_prefs_override.xml"

  public let dataDirectory: String
  /// `FileManager` is not `Sendable`, but the default instance is documented as
  /// thread safe for the file operations used here.
  private let fileManager: FileManager

  public init(dataDirectory: String, fileManager: FileManager = .default) {
    self.dataDirectory = dataDirectory
    self.fileManager = fileManager
  }

  /// Finds the data directory by looking for a client file that is always
  /// present, plus the user's own BOINC directory.
  public static func locateDataDirectory(fileManager: FileManager = .default) -> String? {
    var candidates = candidateDataDirectories
    let home = fileManager.homeDirectoryForCurrentUser
    candidates.append(home.appendingPathComponent("Library/Application Support/BOINC").path)
    candidates.append(
      home.appendingPathComponent("Library/Application Support/BOINC Data").path)

    for candidate in candidates {
      // client_state.xml is written by every running client, so it is a better
      // marker than the override file, which often does not exist.
      let marker = (candidate as NSString).appendingPathComponent("client_state.xml")
      if fileManager.fileExists(atPath: marker) { return candidate }
    }
    return candidates.first { fileManager.fileExists(atPath: $0) }
  }

  public var overridePath: String {
    (dataDirectory as NSString).appendingPathComponent(Self.overrideFileName)
  }

  /// Whether the override file can be written, which decides whether stressd
  /// can control BOINC's CPU share at all.
  ///
  /// The official installer puts the data directory under `boinc_master`, so
  /// this is often false without elevated rights. That is not fatal: the source
  /// falls back to run-mode control and lets synthetic load carry the target.
  public func isWritable() -> Bool {
    if fileManager.fileExists(atPath: overridePath) {
      return fileManager.isWritableFile(atPath: overridePath)
    }
    return fileManager.isWritableFile(atPath: dataDirectory)
  }

  /// Reads the current file, or `nil` if it does not exist.
  public func currentContents() -> Data? {
    fileManager.contents(atPath: overridePath)
  }

  /// Writes limits into the override file, preserving nothing.
  ///
  /// BOINC treats this file as a complete override document, so the two keys
  /// stressd sets are written alongside whatever was already there, with the
  /// stressd keys taking precedence.
  public func write(limits: BOINCCPULimits) throws {
    let existing = currentContents().map { String(decoding: $0, as: UTF8.self) }
    let document = Self.render(limits: limits, mergingInto: existing)
    try Data(document.utf8).write(to: URL(fileURLWithPath: overridePath), options: .atomic)
  }

  /// Puts the file back exactly as it was, or deletes it if it was not there.
  public func restore(from journal: BOINCRestoreJournal) throws {
    let url = URL(fileURLWithPath: journal.overridePath)
    guard let contents = journal.originalContents else {
      // It did not exist before. Leaving an empty file behind would silently
      // override the user's real preferences with nothing.
      if fileManager.fileExists(atPath: journal.overridePath) {
        try fileManager.removeItem(at: url)
      }
      return
    }
    try contents.write(to: url, options: .atomic)
  }

  /// Builds the override document, preserving any keys stressd does not own.
  ///
  /// Pure, so the round trip can be tested without a BOINC installation.
  public static func render(limits: BOINCCPULimits, mergingInto existing: String?) -> String {
    var preserved: [String] = []
    if let existing {
      // Keep every line that is not one of the two keys stressd manages, so a
      // user's other overrides survive.
      let managed = ["<max_ncpus_pct>", "<cpu_usage_limit>"]
      for line in existing.split(separator: "\n", omittingEmptySubsequences: false) {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        if trimmed.hasPrefix("<?xml") || trimmed.hasPrefix("<global_preferences")
          || trimmed.hasPrefix("</global_preferences") || trimmed.isEmpty
        {
          continue
        }
        if managed.contains(where: { trimmed.hasPrefix($0) }) { continue }
        preserved.append("    " + trimmed)
      }
    }

    var lines = ["<global_preferences>"]
    lines.append(String(format: "    <max_ncpus_pct>%.6f</max_ncpus_pct>", limits.maxCPUsPercent))
    lines.append(
      String(format: "    <cpu_usage_limit>%.6f</cpu_usage_limit>", limits.cpuUsagePercent))
    lines.append(contentsOf: preserved)
    lines.append("</global_preferences>")
    return lines.joined(separator: "\n") + "\n"
  }
}

/// Persists a restore journal so a killed process can be repaired next launch.
public struct BOINCRestoreStore: @unchecked Sendable {

  public static var defaultURL: URL {
    let base =
      FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
      ?? FileManager.default.homeDirectoryForCurrentUser
    return
      base
      .appendingPathComponent("stressd", isDirectory: true)
      .appendingPathComponent("boinc-restore.json")
  }

  public let url: URL
  private let fileManager: FileManager

  public init(url: URL = BOINCRestoreStore.defaultURL, fileManager: FileManager = .default) {
    self.url = url
    self.fileManager = fileManager
  }

  public func save(_ journal: BOINCRestoreJournal) throws {
    try fileManager.createDirectory(
      at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    try encoder.encode(journal).write(to: url, options: .atomic)
  }

  public func load() -> BOINCRestoreJournal? {
    guard let data = fileManager.contents(atPath: url.path) else { return nil }
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    return try? decoder.decode(BOINCRestoreJournal.self, from: data)
  }

  public func clear() {
    try? fileManager.removeItem(at: url)
  }
}
