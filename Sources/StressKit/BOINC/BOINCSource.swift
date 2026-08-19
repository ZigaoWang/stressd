import Foundation
import os

/// Wraps the BOINC client as a contributing load source.
///
/// Every FLOP this source burns goes to a real project. Its load is not
/// directly settable the way the synthetic source's is: BOINC decides when to
/// start and finish workunits, so its CPU usage steps sharply on its own. The
/// mixer exists to absorb that.
public actor BOINCSource: LoadSource {

  public nonisolated let id = "boinc"
  public nonisolated let isContributing = true

  /// Where `boinccmd` lives, most likely first.
  public static let candidateExecutables = [
    "/opt/homebrew/bin/boinccmd",
    "/usr/local/bin/boinccmd",
    "/Applications/BOINCManager.app/Contents/Resources/boinccmd",
    "/Applications/BOINC.app/Contents/Resources/boinccmd",
  ]

  private let runner: any CommandRunning
  private let fileManager: FileManager
  private let restoreStore: BOINCRestoreStore
  private let logger = Logger(subsystem: "dev.stressd", category: "boinc")

  private var executablePath: String?
  private var preferences: BOINCPreferencesFile?
  private var journal: BOINCRestoreJournal?
  private var lastState: BOINCState?
  private var lastStatus: BOINCStatus?
  private var requestedLoad: Double = 0
  private var isRunning = false
  private var controlsPreferences = false
  /// Unknown XML elements already reported, so a shape difference is logged
  /// once rather than every second.
  private var reportedUnknownElements: Set<String> = []

  public init(
    runner: any CommandRunning = SubprocessRunner(),
    fileManager: FileManager = .default,
    restoreStore: BOINCRestoreStore = BOINCRestoreStore(),
    executablePath: String? = nil,
    dataDirectory: String? = nil
  ) {
    self.runner = runner
    self.fileManager = fileManager
    self.restoreStore = restoreStore
    self.executablePath = executablePath
    self.preferences = dataDirectory.map { BOINCPreferencesFile(dataDirectory: $0) }
  }

  // MARK: - Detection

  public func detect() async -> DetectionResult {
    guard let path = locateExecutable() else {
      return .unavailable(
        reason: "boinccmd not found",
        installHint: """
          brew install --cask boinc

          Then open BOINC Manager and attach to a project. Einstein@Home and \
          PrimeGrid both ship native Apple silicon applications, including GPU \
          apps:
            https://einsteinathome.org
            https://www.primegrid.com
          """)
    }

    // Installed is not the same as running: boinccmd exits with a connection
    // error when the client is not up, and the fix is completely different.
    let probe = try? runner.run(path, arguments: ["--get_cc_status"], timeout: 5)
    guard let probe, probe.succeeded else {
      let detail = probe?.standardError.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
      return .unavailable(
        reason: "boinccmd found at \(path) but the client is not responding"
          + (detail.isEmpty ? "" : ": \(detail)"),
        installHint: """
          The client is installed but not running. Start it with:

            open -a BOINCManager

          or, for the Homebrew formula:

            brew services start boinc
          """)
    }

    let version = (try? currentState())?.clientVersion
    let projects = (try? currentState())?.projects ?? []
    let detail =
      version.map { "boinccmd \($0)" } ?? "boinccmd at \(path)"
    return .available(
      detail: projects.isEmpty
        ? "\(detail), no projects attached"
        : "\(detail), \(projects.count) project(s): "
          + projects.map(\.displayName).joined(separator: ", "))
  }

  /// The client version, for `stressd sources`.
  public func clientVersion() -> String? {
    (try? currentState())?.clientVersion
  }

  public func projects() -> [BOINCProject] {
    (try? currentState())?.projects ?? []
  }

  // MARK: - Lifecycle

  public func start(budget: ResourceBudget) async throws {
    guard let path = locateExecutable() else {
      throw StressKitError.boincUnavailable("boinccmd not found")
    }

    // Repair anything a previous run left behind before taking a new snapshot,
    // or the snapshot would capture stressd's own settings as the user's.
    repairFromPreviousRun()

    if journal == nil {
      let status = try? currentStatus()
      let preferencesFile = resolvePreferences()
      let snapshot = BOINCRestoreJournal(
        overridePath: preferencesFile?.overridePath ?? "",
        originalContents: preferencesFile?.currentContents(),
        originalRunMode: status?.permanentRunMode ?? status?.runMode)
      journal = snapshot
      // Written to disk before anything is modified, so a SIGKILL between here
      // and the change still leaves a valid repair record.
      try? restoreStore.save(snapshot)
    }

    isRunning = true
    requestedLoad = budget.cpu
    try applyLimits(fraction: budget.cpu, executable: path)
  }

  public func adjust(to budget: ResourceBudget) async throws {
    guard isRunning, let path = executablePath else {
      try await start(budget: budget)
      return
    }
    guard abs(budget.cpu - requestedLoad) > 0.005 else { return }
    requestedLoad = budget.cpu
    try applyLimits(fraction: budget.cpu, executable: path)
  }

  public func stop() async {
    restoreSnapshot()
    isRunning = false
    requestedLoad = 0
  }

  /// Synchronous restore for exit paths that cannot await.
  public nonisolated func emergencyRestore() {
    let store = restoreStore
    guard let journal = store.load() else { return }
    let preferences = BOINCPreferencesFile(
      dataDirectory: (journal.overridePath as NSString).deletingLastPathComponent)
    try? preferences.restore(from: journal)
    if let mode = journal.originalRunMode, let path = Self.firstExistingExecutable() {
      _ = try? SubprocessRunner().run(
        path, arguments: ["--set_run_mode", mode.rawValue], timeout: 5)
    }
    store.clear()
  }

  // MARK: - Status

  public func status() async throws -> SourceStatus {
    let state = try? currentState()
    lastState = state

    let executing = state?.executingTasks ?? []
    let idleReason = state?.idleReason

    var detail: [String: String] = [
      "client": executablePath ?? "not found",
      "controlsCPULimits": controlsPreferences ? "true" : "false",
    ]
    if let version = state?.clientVersion { detail["version"] = version }
    if let project = executing.first?.projectURL
      ?? state?.projects.first(where: { !$0.isSuspended })?.masterURL
    {
      let named = state?.projects.first { $0.masterURL == project }
      detail["project"] = named?.displayName ?? project
    }
    if let task = executing.first {
      detail["workunit"] = task.workunitName ?? task.name
      if let fraction = task.fractionDone {
        detail["progress"] = String(format: "%.1f%%", fraction * 100)
      }
      if let remaining = task.remainingSeconds {
        detail["remaining"] = DurationParser.format(remaining)
      }
    }
    detail["tasks"] = "\(executing.count) running of \(state?.tasks.count ?? 0)"
    if let idleReason {
      detail["idleReason"] = idleReason.explanation
    }

    return SourceStatus(
      sourceID: id,
      isContributing: true,
      state: isRunning ? (idleReason == nil ? .running : .idle) : .stopped,
      requestedLoad: requestedLoad,
      achievedLoad: nil,
      threadCount: executing.count,
      detail: detail)
  }

  /// Whether the client currently has nothing to crunch, and why.
  public func idleReason() -> BOINCIdleReason? {
    (try? currentState())?.idleReason
  }

  // MARK: - Internals

  private func locateExecutable() -> String? {
    if let executablePath, fileManager.isExecutableFile(atPath: executablePath) {
      return executablePath
    }
    let found = Self.firstExistingExecutable(fileManager: fileManager)
    executablePath = found
    return found
  }

  static func firstExistingExecutable(fileManager: FileManager = .default) -> String? {
    candidateExecutables.first { fileManager.isExecutableFile(atPath: $0) }
  }

  private func resolvePreferences() -> BOINCPreferencesFile? {
    if let preferences { return preferences }
    guard let directory = BOINCPreferencesFile.locateDataDirectory(fileManager: fileManager)
    else { return nil }
    let file = BOINCPreferencesFile(dataDirectory: directory, fileManager: fileManager)
    preferences = file
    return file
  }

  private func currentState() throws -> BOINCState {
    guard let path = locateExecutable() else {
      throw StressKitError.boincUnavailable("boinccmd not found")
    }
    let result = try runner.run(path, arguments: ["--get_simple_gui_info"], timeout: 10)
    guard result.succeeded else {
      throw StressKitError.boincCommandFailed(
        command: "--get_simple_gui_info", detail: result.standardError)
    }
    let state = try BOINCXMLParser.parseState(result.standardOutput)
    reportUnknown(state.unknownElements)
    return state
  }

  private func currentStatus() throws -> BOINCStatus {
    guard let path = locateExecutable() else {
      throw StressKitError.boincUnavailable("boinccmd not found")
    }
    let result = try runner.run(path, arguments: ["--get_cc_status"], timeout: 10)
    guard result.succeeded else {
      throw StressKitError.boincCommandFailed(
        command: "--get_cc_status", detail: result.standardError)
    }
    let status = try BOINCXMLParser.parseStatus(result.standardOutput)
    lastStatus = status
    reportUnknown(status.unknownElements)
    return status
  }

  /// Applies a target share to the client.
  ///
  /// Two mechanisms, used together. `cpu_usage_limit` in the override file is
  /// the fine control, but the file is often not writable because the official
  /// installer owns the data directory as `boinc_master`. The run mode is
  /// always available and is the coarse fallback: at a zero target the client
  /// is told to stop rather than being left running.
  private func applyLimits(fraction: Double, executable: String) throws {
    let preferencesFile = resolvePreferences()
    controlsPreferences = preferencesFile?.isWritable() ?? false

    if let preferencesFile, controlsPreferences {
      try? preferencesFile.write(limits: .forTarget(fraction))
      // Applies without restarting the client.
      _ = try? runner.run(
        executable, arguments: ["--read_global_prefs_override"], timeout: 5)
    }

    let mode: BOINCRunMode = fraction <= 0.005 ? .never : .always
    _ = try? runner.run(executable, arguments: ["--set_run_mode", mode.rawValue], timeout: 5)
  }

  private func restoreSnapshot() {
    guard let journal else { return }
    if let preferences = resolvePreferences() {
      try? preferences.restore(from: journal)
    }
    if let path = executablePath {
      let mode = journal.originalRunMode ?? .auto
      _ = try? runner.run(path, arguments: ["--set_run_mode", mode.rawValue], timeout: 5)
      if controlsPreferences {
        _ = try? runner.run(path, arguments: ["--read_global_prefs_override"], timeout: 5)
      }
    }
    restoreStore.clear()
    self.journal = nil
  }

  /// Repairs state a previous run left behind after being killed.
  private func repairFromPreviousRun() {
    guard let previous = restoreStore.load() else { return }
    logger.notice(
      "repairing BOINC settings left by a previous run that did not shut down cleanly")
    let preferences = BOINCPreferencesFile(
      dataDirectory: (previous.overridePath as NSString).deletingLastPathComponent,
      fileManager: fileManager)
    try? preferences.restore(from: previous)
    if let path = locateExecutable(), let mode = previous.originalRunMode {
      _ = try? runner.run(path, arguments: ["--set_run_mode", mode.rawValue], timeout: 5)
    }
    restoreStore.clear()
  }

  /// Logs unrecognised elements once each. BOINC 7.x and 8.x differ and new
  /// keys are not errors, so this must not be per-sample noise.
  private func reportUnknown(_ elements: [String]) {
    let fresh = elements.filter { !reportedUnknownElements.contains($0) }
    guard !fresh.isEmpty else { return }
    reportedUnknownElements.formUnion(fresh)
    logger.info(
      "boinccmd reported elements this parser does not use: \(fresh.joined(separator: ", "))")
  }
}
