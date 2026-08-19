import Foundation
import Testing

@testable import StressKit

@Suite("boinccmd XML parsing")
struct BOINCParsingTests {

  // MARK: - Fixtures

  /// BOINC 7.x `--get_state`. Boolean flags appear as empty elements and the
  /// version is split across three scalars.
  static let sevenSeriesState = """
    <client_state>
      <core_client_major_version>7</core_client_major_version>
      <core_client_minor_version>24</core_client_minor_version>
      <core_client_release>1</core_client_release>
      <project>
        <master_url>https://einsteinathome.org/</master_url>
        <project_name>Einstein@Home</project_name>
        <resource_share>100.000000</resource_share>
      </project>
      <app>
        <name>hsgamma_FGRPB1G</name>
      </app>
      <workunit>
        <name>LATeah4013L03_100.0_0_0.0_12345_1</name>
      </workunit>
      <result>
        <name>LATeah4013L03_100.0_0_0.0_12345_1_0</name>
        <wu_name>LATeah4013L03_100.0_0_0.0_12345_1</wu_name>
        <project_url>https://einsteinathome.org/</project_url>
        <state>2</state>
        <active_task>
          <active_task_state>1</active_task_state>
          <fraction_done>0.347000</fraction_done>
          <elapsed_time>1284.220000</elapsed_time>
        </active_task>
        <estimated_cpu_time_remaining>2410.500000</estimated_cpu_time_remaining>
      </result>
    </client_state>
    """

  /// BOINC 8.x `--get_simple_gui_info`. Different root element, a suspended
  /// task expressed as an empty flag, and extra elements this parser does not
  /// use.
  static let eightSeriesState = """
    <simple_gui_info>
      <core_client_major_version>8</core_client_major_version>
      <core_client_minor_version>0</core_client_minor_version>
      <core_client_release>4</core_client_release>
      <project>
        <master_url>https://www.primegrid.com/</master_url>
        <project_name>PrimeGrid</project_name>
        <suspended_via_gui/>
        <sched_rpc_pending>0</sched_rpc_pending>
      </project>
      <result>
        <name>pps_sr2sieve_12345_0</name>
        <wu_name>pps_sr2sieve_12345</wu_name>
        <project_url>https://www.primegrid.com/</project_url>
        <state>2</state>
        <suspended_via_gui/>
        <active_task>
          <active_task_state>0</active_task_state>
          <fraction_done>0.812000</fraction_done>
          <elapsed_time>903.100000</elapsed_time>
        </active_task>
      </result>
      <result>
        <name>pps_sr2sieve_67890_0</name>
        <wu_name>pps_sr2sieve_67890</wu_name>
        <project_url>https://www.primegrid.com/</project_url>
        <state>2</state>
        <active_task>
          <active_task_state>1</active_task_state>
          <fraction_done>0.043000</fraction_done>
          <elapsed_time>61.000000</elapsed_time>
        </active_task>
      </result>
    </simple_gui_info>
    """

  static let ccStatus = """
    <cc_status>
      <network_status>0</network_status>
      <task_suspend_reason>0</task_suspend_reason>
      <task_mode>2</task_mode>
      <task_mode_perm>1</task_mode_perm>
      <task_mode_delay>0.000000</task_mode_delay>
      <gpu_mode>3</gpu_mode>
    </cc_status>
    """

  // MARK: - Version skew

  @Test("A 7.x state parses")
  func parsesSevenSeries() throws {
    let state = try BOINCXMLParser.parseState(Data(Self.sevenSeriesState.utf8))

    #expect(state.clientVersion == "7.24.1")
    #expect(state.projects.count == 1)
    #expect(state.projects[0].displayName == "Einstein@Home")
    #expect(!state.projects[0].isSuspended)

    #expect(state.tasks.count == 1)
    let task = try #require(state.tasks.first)
    #expect(task.workunitName == "LATeah4013L03_100.0_0_0.0_12345_1")
    #expect(abs((task.fractionDone ?? 0) - 0.347) < 0.0001)
    #expect(abs((task.elapsedSeconds ?? 0) - 1284.22) < 0.01)
    #expect(abs((task.remainingSeconds ?? 0) - 2410.5) < 0.01)
    #expect(task.isExecuting)
    #expect(state.idleReason == nil)
  }

  @Test("An 8.x state parses, with a different root element")
  func parsesEightSeries() throws {
    let state = try BOINCXMLParser.parseState(Data(Self.eightSeriesState.utf8))

    #expect(state.clientVersion == "8.0.4")
    #expect(state.projects.count == 1)
    #expect(state.projects[0].displayName == "PrimeGrid")
    // An empty element is a true flag in BOINC's dialect.
    #expect(state.projects[0].isSuspended)

    #expect(state.tasks.count == 2)
    #expect(state.tasks[0].isSuspended)
    #expect(!state.tasks[0].isExecuting)
    #expect(state.tasks[1].isExecuting)
    #expect(state.executingTasks.count == 1)
  }

  @Test("cc_status maps task_mode to a run mode")
  func parsesStatus() throws {
    let status = try BOINCXMLParser.parseStatus(Data(Self.ccStatus.utf8))
    #expect(status.runMode == .auto)
    // The permanent mode is what has to be restored, not the transient one.
    #expect(status.permanentRunMode == .always)
    #expect(status.gpuMode == .never)
  }

  @Test("Run modes round-trip through BOINC's own numbering")
  func runModeNumbering() {
    for mode in BOINCRunMode.allCases {
      #expect(BOINCRunMode(taskMode: mode.taskMode) == mode)
    }
    #expect(BOINCRunMode(taskMode: 99) == nil)
  }

  // MARK: - Defensive behaviour

  @Test("Truncated output fails rather than reading as an empty client")
  func truncatedOutputThrows() {
    // This one has to fail loudly. A half-read document with no <result>
    // elements looks exactly like a client with no work, which the mixer would
    // act on by taking the whole target for synthetic load.
    let truncated = String(Self.sevenSeriesState.prefix(Self.sevenSeriesState.count / 2))
    #expect(throws: BOINCXMLParser.ParseError.self) {
      _ = try BOINCXMLParser.parseState(Data(truncated.utf8))
    }
  }

  @Test("Empty output is rejected")
  func emptyOutputThrows() {
    #expect(throws: BOINCXMLParser.ParseError.empty) {
      _ = try BOINCXMLParser.parseState(Data())
    }
  }

  @Test("Unknown elements are tolerated, not fatal")
  func unknownElementsTolerated() throws {
    // A future client adding keys must not stop stressd reading the ones it
    // already understands.
    let withExtras = """
      <client_state>
        <core_client_major_version>9</core_client_major_version>
        <core_client_minor_version>1</core_client_minor_version>
        <core_client_release>0</core_client_release>
        <quantum_scheduler_state>42</quantum_scheduler_state>
        <project>
          <master_url>https://einsteinathome.org/</master_url>
          <project_name>Einstein@Home</project_name>
          <neural_priority>7</neural_priority>
        </project>
        <result>
          <name>task_1</name>
          <wu_name>wu_1</wu_name>
          <holographic_state>on</holographic_state>
          <active_task>
            <active_task_state>1</active_task_state>
            <fraction_done>0.5</fraction_done>
          </active_task>
        </result>
      </client_state>
      """
    let state = try BOINCXMLParser.parseState(Data(withExtras.utf8))

    #expect(state.clientVersion == "9.1.0")
    #expect(state.projects.count == 1)
    #expect(state.tasks.count == 1)
    #expect(state.tasks[0].isExecuting)
    #expect(abs((state.tasks[0].fractionDone ?? 0) - 0.5) < 0.0001)
  }

  @Test("A missing field is nil rather than an error")
  func missingFieldsAreNil() throws {
    let sparse = """
      <client_state>
        <result>
          <name>task_1</name>
        </result>
      </client_state>
      """
    let state = try BOINCXMLParser.parseState(Data(sparse.utf8))

    #expect(state.clientVersion == nil)
    #expect(state.tasks.count == 1)
    #expect(state.tasks[0].fractionDone == nil)
    #expect(state.tasks[0].activeTaskState == nil)
    #expect(!state.tasks[0].isExecuting)
  }

  // MARK: - Idle detection

  @Test(
    "Every reason the client might be idle is distinguished",
    arguments: [
      ("<client_state></client_state>", BOINCIdleReason.noProjectsAttached),
      (
        "<client_state><project><master_url>u</master_url></project></client_state>",
        BOINCIdleReason.noTasks
      ),
    ])
  func idleReasons(xml: String, expected: BOINCIdleReason) throws {
    let state = try BOINCXMLParser.parseState(Data(xml.utf8))
    #expect(state.idleReason == expected)
  }

  @Test("Suspended tasks are distinguished from tasks that simply are not running")
  func suspendedVersusNotRunning() throws {
    let suspended = """
      <client_state>
        <project><master_url>u</master_url></project>
        <result><name>a</name><suspended_via_gui/></result>
      </client_state>
      """
    #expect(
      try BOINCXMLParser.parseState(Data(suspended.utf8)).idleReason == .allTasksSuspended)

    let waiting = """
      <client_state>
        <project><master_url>u</master_url></project>
        <result><name>a</name><active_task><active_task_state>9</active_task_state></active_task></result>
      </client_state>
      """
    #expect(
      try BOINCXMLParser.parseState(Data(waiting.utf8)).idleReason == .noTasksExecuting)
  }

  @Test("Idle reasons all explain themselves")
  func idleReasonExplanations() {
    for reason in [
      BOINCIdleReason.noProjectsAttached, .noTasks, .allTasksSuspended, .noTasksExecuting,
      .allProjectsSuspended,
    ] {
      #expect(!reason.explanation.isEmpty)
    }
  }

  @Test("A project with no name falls back to its host")
  func projectDisplayNameFallback() {
    let project = BOINCProject(
      masterURL: "https://einsteinathome.org/", name: nil, isSuspended: false)
    #expect(project.displayName == "einsteinathome.org")
  }
}
