import Foundation
import Testing

@testable import StressKit

/// A `boinccmd` that never existed, driven entirely by recorded responses.
///
/// Behind the same protocol layer as sysctl and IOKit, so the whole BOINC path
/// runs in CI on machines with no BOINC installed.
final class MockCommandRunner: CommandRunning, @unchecked Sendable {

  struct Invocation: Equatable {
    let executable: String
    let arguments: [String]
  }

  private let lock = NSLock()
  private var responses: [String: CommandResult] = [:]
  private var recorded: [Invocation] = []
  private var defaultResult: CommandResult

  init(
    defaultResult: CommandResult = CommandResult(
      exitCode: 0, standardOutput: Data(), standardError: "")
  ) {
    self.defaultResult = defaultResult
  }

  /// Keys on the first argument, which is the boinccmd verb.
  func stub(_ verb: String, output: String, exitCode: Int32 = 0, error: String = "") {
    lock.lock()
    responses[verb] = CommandResult(
      exitCode: exitCode, standardOutput: Data(output.utf8), standardError: error)
    lock.unlock()
  }

  func stub(_ verb: String, result: CommandResult) {
    lock.lock()
    responses[verb] = result
    lock.unlock()
  }

  var invocations: [Invocation] {
    lock.lock()
    defer { lock.unlock() }
    return recorded
  }

  func arguments(for verb: String) -> [[String]] {
    invocations.filter { $0.arguments.first == verb }.map(\.arguments)
  }

  func run(
    _ executable: String, arguments: [String], timeout: TimeInterval
  ) throws
    -> CommandResult
  {
    lock.lock()
    recorded.append(Invocation(executable: executable, arguments: arguments))
    let result = arguments.first.flatMap { responses[$0] } ?? defaultResult
    lock.unlock()
    return result
  }
}

@Suite("BOINC source")
struct BOINCSourceTests {

  private static let runningState = """
    <simple_gui_info>
      <core_client_major_version>8</core_client_major_version>
      <core_client_minor_version>0</core_client_minor_version>
      <core_client_release>4</core_client_release>
      <project>
        <master_url>https://einsteinathome.org/</master_url>
        <project_name>Einstein@Home</project_name>
      </project>
      <result>
        <name>task_1</name>
        <wu_name>LATeah_1</wu_name>
        <project_url>https://einsteinathome.org/</project_url>
        <active_task>
          <active_task_state>1</active_task_state>
          <fraction_done>0.25</fraction_done>
          <elapsed_time>600.0</elapsed_time>
        </active_task>
        <estimated_cpu_time_remaining>1800.0</estimated_cpu_time_remaining>
      </result>
    </simple_gui_info>
    """

  private static let noWorkState = """
    <simple_gui_info>
      <core_client_major_version>8</core_client_major_version>
      <core_client_minor_version>0</core_client_minor_version>
      <core_client_release>4</core_client_release>
      <project>
        <master_url>https://einsteinathome.org/</master_url>
        <project_name>Einstein@Home</project_name>
      </project>
    </simple_gui_info>
    """

  private static let ccStatus = """
    <cc_status><task_mode>2</task_mode><task_mode_perm>2</task_mode_perm></cc_status>
    """

  /// A runner stubbed to look like a healthy client.
  private func healthyRunner(
    state: String = BOINCSourceTests.runningState
  )
    -> MockCommandRunner
  {
    let runner = MockCommandRunner()
    runner.stub("--get_cc_status", output: Self.ccStatus)
    runner.stub("--get_simple_gui_info", output: state)
    runner.stub("--get_state", output: state)
    runner.stub("--set_run_mode", output: "")
    runner.stub("--read_global_prefs_override", output: "")
    return runner
  }

  private func temporaryDirectory() throws -> String {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("stressd-boinc-src-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory.path
  }

  // MARK: - Detection

  @Test("A missing client is distinguished from a stopped one")
  func detectionDistinguishesMissingFromStopped() async throws {
    // Not installed: the hint is an install command.
    let missing = BOINCSource(
      runner: MockCommandRunner(), executablePath: "/nonexistent/boinccmd")
    let missingResult = await missing.detect()
    #expect(!missingResult.isAvailable)
    if case .unavailable(let reason, let hint) = missingResult {
      #expect(reason.contains("not found"))
      #expect(hint?.contains("brew install") == true)
      // The projects worth recommending on this hardware.
      #expect(hint?.contains("einsteinathome") == true)
      #expect(hint?.contains("primegrid") == true)
    }
  }

  @Test("An installed but unreachable client gets a different hint")
  func detectionOfStoppedClient() async throws {
    let runner = MockCommandRunner()
    // boinccmd exits non-zero with a connection error when the client is down.
    runner.stub(
      "--get_cc_status", output: "", exitCode: 1,
      error: "can't connect to local host")

    let source = BOINCSource(runner: runner, executablePath: "/bin/sh")
    let result = await source.detect()

    #expect(!result.isAvailable)
    if case .unavailable(let reason, let hint) = result {
      #expect(reason.contains("not responding"))
      // The fix is to start it, not to install it.
      #expect(hint?.contains("open -a BOINCManager") == true)
      #expect(hint?.contains("brew install") == false)
    }
  }

  @Test("A healthy client reports its version and projects")
  func detectionOfHealthyClient() async throws {
    let source = BOINCSource(runner: healthyRunner(), executablePath: "/bin/sh")
    let result = await source.detect()

    #expect(result.isAvailable)
    if case .available(let detail) = result {
      #expect(detail.contains("8.0.4"))
      #expect(detail.contains("Einstein@Home"))
    }
    #expect(await source.clientVersion() == "8.0.4")
  }

  // MARK: - Control

  @Test("Starting snapshots the run mode before changing anything")
  func startSnapshotsBeforeModifying() async throws {
    let directory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(atPath: directory) }
    let runner = healthyRunner()
    let store = BOINCRestoreStore(
      url: URL(fileURLWithPath: directory).appendingPathComponent("restore.json"))

    let source = BOINCSource(
      runner: runner, restoreStore: store, executablePath: "/bin/sh",
      dataDirectory: directory)
    try await source.start(budget: ResourceBudget(cpu: 0.5))

    // The status query must come before the first mutation, or the snapshot
    // would record stressd's own settings as the user's.
    let verbs = runner.invocations.map { $0.arguments.first ?? "" }
    let statusIndex = try #require(verbs.firstIndex(of: "--get_cc_status"))
    let mutateIndex = try #require(verbs.firstIndex(of: "--set_run_mode"))
    #expect(statusIndex < mutateIndex)

    // And it is on disk before the change, so a SIGKILL is still repairable.
    #expect(store.load() != nil)
    await source.stop()
  }

  @Test("A zero target stops the client rather than leaving it running")
  func zeroTargetStopsClient() async throws {
    let directory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(atPath: directory) }
    let runner = healthyRunner()

    let source = BOINCSource(
      runner: runner,
      restoreStore: BOINCRestoreStore(
        url: URL(fileURLWithPath: directory).appendingPathComponent("r.json")),
      executablePath: "/bin/sh", dataDirectory: directory)
    try await source.start(budget: ResourceBudget(cpu: 0))

    let modes = runner.arguments(for: "--set_run_mode").compactMap { $0.dropFirst().first }
    #expect(modes.contains("never"))
    await source.stop()
  }

  @Test("Stopping restores the run mode that was in force before")
  func stopRestoresRunMode() async throws {
    let directory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(atPath: directory) }
    let runner = MockCommandRunner()
    runner.stub(
      "--get_cc_status",
      output: "<cc_status><task_mode>1</task_mode><task_mode_perm>3</task_mode_perm></cc_status>"
    )
    runner.stub("--get_simple_gui_info", output: Self.runningState)
    runner.stub("--set_run_mode", output: "")
    runner.stub("--read_global_prefs_override", output: "")

    let store = BOINCRestoreStore(
      url: URL(fileURLWithPath: directory).appendingPathComponent("r.json"))
    let source = BOINCSource(
      runner: runner, restoreStore: store, executablePath: "/bin/sh",
      dataDirectory: directory)

    try await source.start(budget: ResourceBudget(cpu: 0.8))
    await source.stop()

    // The permanent mode is what the user set; the transient one is not.
    let modes = runner.arguments(for: "--set_run_mode").compactMap { $0.dropFirst().first }
    #expect(modes.last == "never")
    #expect(store.load() == nil, "a clean stop clears the repair journal")
  }

  @Test("The override file is written and applied without restarting the client")
  func writesAndAppliesPreferences() async throws {
    let directory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(atPath: directory) }
    let runner = healthyRunner()

    let source = BOINCSource(
      runner: runner,
      restoreStore: BOINCRestoreStore(
        url: URL(fileURLWithPath: directory).appendingPathComponent("r.json")),
      executablePath: "/bin/sh", dataDirectory: directory)
    try await source.start(budget: ResourceBudget(cpu: 0.4))

    let overridePath = (directory as NSString)
      .appendingPathComponent("global_prefs_override.xml")
    let written = try #require(FileManager.default.contents(atPath: overridePath))
    let text = String(decoding: written, as: UTF8.self)
    #expect(text.contains("<cpu_usage_limit>40.000000</cpu_usage_limit>"))

    // Applied in place, not by bouncing the client.
    #expect(!runner.arguments(for: "--read_global_prefs_override").isEmpty)
    await source.stop()
  }

  @Test("A previous run's leftovers are repaired before a new snapshot is taken")
  func repairsPreviousRunOnStart() async throws {
    let directory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(atPath: directory) }
    let overridePath = (directory as NSString)
      .appendingPathComponent("global_prefs_override.xml")

    // A previous run was killed: its settings are still in place and its
    // journal is still on disk.
    let userOriginal =
      "<global_preferences>\n  <run_on_batteries>1</run_on_batteries>\n</global_preferences>\n"
    try Data(
      "<global_preferences>\n  <cpu_usage_limit>95.0</cpu_usage_limit>\n</global_preferences>\n"
        .utf8
    )
    .write(to: URL(fileURLWithPath: overridePath))

    let store = BOINCRestoreStore(
      url: URL(fileURLWithPath: directory).appendingPathComponent("r.json"))
    try store.save(
      BOINCRestoreJournal(
        overridePath: overridePath, originalContents: Data(userOriginal.utf8),
        originalRunMode: .auto))

    let runner = healthyRunner()
    let source = BOINCSource(
      runner: runner, restoreStore: store, executablePath: "/bin/sh",
      dataDirectory: directory)
    try await source.start(budget: ResourceBudget(cpu: 0.5))
    await source.stop()

    // After the repair-then-run-then-stop cycle, the user's file is back.
    let final = String(
      decoding: FileManager.default.contents(atPath: overridePath) ?? Data(), as: UTF8.self)
    #expect(final == userOriginal, "the repaired original must survive the new run")
  }

  // MARK: - Status

  @Test("Status reports the project, workunit and progress")
  func statusReportsWork() async throws {
    let source = BOINCSource(runner: healthyRunner(), executablePath: "/bin/sh")
    try await source.start(budget: ResourceBudget(cpu: 0.5))
    let status = try await source.status()

    #expect(status.isContributing)
    #expect(status.state == .running)
    #expect(status.detail["project"] == "Einstein@Home")
    #expect(status.detail["workunit"] == "LATeah_1")
    #expect(status.detail["progress"] == "25.0%")
    #expect(status.detail["version"] == "8.0.4")
    await source.stop()
  }

  @Test("No work available is reported, not silently treated as running")
  func noWorkIsSurfaced() async throws {
    let source = BOINCSource(
      runner: healthyRunner(state: Self.noWorkState), executablePath: "/bin/sh")
    try await source.start(budget: ResourceBudget(cpu: 0.5))

    let status = try await source.status()
    // Idle, not running: the mixer needs to know so synthetic can take over and
    // the user needs to know so it does not look like contribution happened.
    #expect(status.state == .idle)
    #expect(status.detail["idleReason"] == BOINCIdleReason.noTasks.explanation)
    #expect(await source.idleReason() == .noTasks)
    await source.stop()
  }

  @Test("A client that stops responding does not throw out of status")
  func statusSurvivesClientFailure() async throws {
    let runner = healthyRunner()
    let source = BOINCSource(runner: runner, executablePath: "/bin/sh")
    try await source.start(budget: ResourceBudget(cpu: 0.5))

    // The client goes away mid-run.
    runner.stub("--get_simple_gui_info", output: "", exitCode: 1, error: "can't connect")
    let status = try await source.status()
    #expect(status.sourceID == "boinc")
    #expect(status.detail["tasks"] == "0 running of 0")
    await source.stop()
  }
}
