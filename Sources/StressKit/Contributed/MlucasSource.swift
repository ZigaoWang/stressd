import Foundation

/// GIMPS, via mlucas.
///
/// ## Why mlucas and not Prime95
///
/// Prime95 / mprime is the client most people know, and it is the wrong choice
/// on Apple silicon: its inner loops are hand-written x86 assembly, so it runs
/// under Rosetta translation. A hand-tuned assembly FFT is exactly the kind of
/// code that translates worst, and the result is a client that produces heat
/// without producing competitive throughput.
///
/// mlucas is C with ARM NEON support and builds natively for arm64, so it is
/// the correct GIMPS client here.
///
/// ## Not validated against live work
///
/// Exercising this needs a `worktodo.ini` with real assignments, which needs a
/// GIMPS account. Developed against the documented file formats and unit tested
/// against fixtures. See `DEFERRED.md`.
public actor MlucasSource: LoadSource {

  public nonisolated let id = "mlucas"
  public nonisolated let isContributing = true

  public static let candidateExecutables = [
    "/opt/homebrew/bin/mlucas",
    "/usr/local/bin/mlucas",
  ]

  private let runner: any CommandRunning
  private let fileManager: FileManager
  private let workingDirectory: String
  private var executablePath: String?
  private var process: Process?
  private var requestedLoad: Double = 0

  public init(
    runner: any CommandRunning = SubprocessRunner(),
    fileManager: FileManager = .default,
    executablePath: String? = nil,
    workingDirectory: String? = nil
  ) {
    self.runner = runner
    self.fileManager = fileManager
    self.executablePath = executablePath
    self.workingDirectory =
      workingDirectory
      ?? fileManager.homeDirectoryForCurrentUser
      .appendingPathComponent("Library/Application Support/stressd/mlucas").path
  }

  public func detect() async -> DetectionResult {
    guard let path = locateExecutable() else {
      return .unavailable(
        reason: "mlucas not found",
        installHint: """
          brew install mlucas

          Then get assignments from https://www.mersenne.org/ and put them in
            \(workingDirectory)/worktodo.ini

          Note: Prime95/mprime is hand-written x86 assembly and runs under
          Rosetta on Apple silicon, which makes it a poor choice here. mlucas
          builds natively for arm64.
          """)
    }

    let work = worktodoEntries()
    guard !work.isEmpty else {
      return .unavailable(
        reason: "mlucas is installed but \(workingDirectory)/worktodo.ini has no assignments",
        installHint: """
          Get assignments from https://www.mersenne.org/manual_assignment/ and
          write them to \(workingDirectory)/worktodo.ini
          """)
    }
    return .available(detail: "mlucas at \(path), \(work.count) assignment(s) queued")
  }

  public func start(budget: ResourceBudget) async throws {
    guard let path = locateExecutable() else {
      throw StressKitError.boincUnavailable("mlucas not found")
    }
    guard !worktodoEntries().isEmpty else {
      throw StressKitError.boincUnavailable("no assignments in worktodo.ini")
    }
    requestedLoad = budget.cpu
    try startProcess(executable: path, fraction: budget.cpu)
  }

  /// mlucas has no run-time throttle, so a load change is a restart.
  ///
  /// Unlike the synthetic source, whose whole design is that `adjust` never
  /// respawns. Documented rather than hidden: the mixer prefers to leave
  /// contributed sources alone and move synthetic load instead, precisely
  /// because contributed clients are coarse to control.
  public func adjust(to budget: ResourceBudget) async throws {
    guard abs(budget.cpu - requestedLoad) > 0.05 else { return }
    await stop()
    try await start(budget: budget)
  }

  public func stop() async {
    process?.terminate()
    process = nil
    requestedLoad = 0
  }

  public func status() async throws -> SourceStatus {
    let progress = MlucasLogParser.parse(logText: recentLog())
    var detail: [String: String] = [
      "client": executablePath ?? "not found",
      "workingDirectory": workingDirectory,
    ]
    if let exponent = progress?.exponent { detail["workunit"] = "M\(exponent)" }
    if let percent = progress?.percentComplete {
      detail["progress"] = String(format: "%.2f%%", percent)
    }
    if let iteration = progress?.iteration { detail["iteration"] = String(iteration) }
    detail["assignments"] = String(worktodoEntries().count)

    let running = process?.isRunning ?? false
    return SourceStatus(
      sourceID: id,
      isContributing: true,
      state: running ? .running : (requestedLoad > 0 ? .idle : .stopped),
      requestedLoad: requestedLoad,
      threadCount: running ? 1 : 0,
      detail: detail)
  }

  // MARK: - Internals

  private func startProcess(executable: String, fraction: Double) throws {
    try fileManager.createDirectory(
      atPath: workingDirectory, withIntermediateDirectories: true)

    let task = Process()
    task.executableURL = URL(fileURLWithPath: executable)
    task.currentDirectoryURL = URL(fileURLWithPath: workingDirectory)
    // mlucas takes a thread count, not a duty cycle: a fraction of the machine
    // becomes a fraction of the cores.
    let threads = max(
      1, Int((Double(ProcessInfo.processInfo.activeProcessorCount) * fraction).rounded()))
    task.arguments = ["-cpu", "0:\(threads - 1)"]
    task.standardOutput = FileHandle.nullDevice
    task.standardError = FileHandle.nullDevice
    try task.run()
    process = task
  }

  private func locateExecutable() -> String? {
    if let executablePath, fileManager.isExecutableFile(atPath: executablePath) {
      return executablePath
    }
    let found = Self.candidateExecutables.first { fileManager.isExecutableFile(atPath: $0) }
    executablePath = found
    return found
  }

  private func worktodoEntries() -> [String] {
    let path = (workingDirectory as NSString).appendingPathComponent("worktodo.ini")
    guard let data = fileManager.contents(atPath: path) else { return [] }
    return MlucasWorktodo.parse(String(decoding: data, as: UTF8.self))
  }

  private func recentLog() -> String {
    let path = (workingDirectory as NSString).appendingPathComponent("p*.stat")
    // mlucas names its status file after the exponent, so the directory is
    // scanned rather than a fixed name being assumed.
    guard let entries = try? fileManager.contentsOfDirectory(atPath: workingDirectory) else {
      return ""
    }
    _ = path
    guard let statFile = entries.first(where: { $0.hasSuffix(".stat") }) else { return "" }
    let full = (workingDirectory as NSString).appendingPathComponent(statFile)
    guard let data = fileManager.contents(atPath: full) else { return "" }
    // Only the tail matters, and these files grow without bound.
    return String(decoding: data.suffix(8192), as: UTF8.self)
  }
}

/// Parses `worktodo.ini`.
public enum MlucasWorktodo {
  /// Assignment lines, ignoring comments and blanks.
  public static func parse(_ text: String) -> [String] {
    text.split(separator: "\n", omittingEmptySubsequences: true)
      .map { $0.trimmingCharacters(in: .whitespaces) }
      .filter { !$0.isEmpty && !$0.hasPrefix("#") && !$0.hasPrefix(";") }
      .filter { $0.contains("=") }
  }
}

/// Progress read out of an mlucas status file.
public struct MlucasProgress: Sendable, Equatable {
  public let exponent: Int?
  public let iteration: Int?
  /// Progress as a percentage, `0...100`, as mlucas prints it.
  public let percentComplete: Double?

  public init(exponent: Int?, iteration: Int?, percentComplete: Double?) {
    self.exponent = exponent
    self.iteration = iteration
    self.percentComplete = percentComplete
  }
}

/// Reads mlucas status lines.
///
/// The format is stable but not documented as an interface, so this is written
/// to fail soft: anything it cannot read becomes `nil` rather than an error.
public enum MlucasLogParser {

  /// Lines look like:
  /// `M110503 Iter# = 5000000 [ 45.30% complete] clocks = ...`
  public static func parse(logText: String) -> MlucasProgress? {
    let lines = logText.split(separator: "\n").reversed()
    for line in lines {
      guard line.contains("Iter#") else { continue }

      let exponent = capture(line, prefix: "M", terminator: " ").flatMap(Int.init)
      let iteration = capture(line, prefix: "Iter# = ", terminator: " ").flatMap(Int.init)
      let percent = capture(line, prefix: "[ ", terminator: "%").flatMap(Double.init)

      guard exponent != nil || iteration != nil || percent != nil else { continue }
      return MlucasProgress(
        exponent: exponent, iteration: iteration, percentComplete: percent)
    }
    return nil
  }

  private static func capture(
    _ line: Substring, prefix: String, terminator: Character
  ) -> String? {
    guard let start = line.range(of: prefix) else { return nil }
    let rest = line[start.upperBound...]
    guard let end = rest.firstIndex(of: terminator) else { return nil }
    let value = rest[..<end].trimmingCharacters(in: .whitespaces)
    return value.isEmpty ? nil : value
  }
}
