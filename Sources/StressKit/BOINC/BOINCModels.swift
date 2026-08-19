import Foundation

/// BOINC's run mode, as `--get_cc_status` reports it and `--set_run_mode`
/// takes it.
public enum BOINCRunMode: String, Sendable, Codable, CaseIterable {
  case always
  case auto
  case never
  case restore

  /// `task_mode` in `cc_status`. The numbering is BOINC's own.
  public init?(taskMode: Int) {
    switch taskMode {
    case 1: self = .always
    case 2: self = .auto
    case 3: self = .never
    case 4: self = .restore
    default: return nil
    }
  }

  public var taskMode: Int {
    switch self {
    case .always: return 1
    case .auto: return 2
    case .never: return 3
    case .restore: return 4
    }
  }
}

/// A project the client is attached to.
public struct BOINCProject: Sendable, Codable, Equatable {
  public let masterURL: String
  public let name: String?
  public let isSuspended: Bool
  /// True when the project's scheduler said it has no work.
  public let hasNoWorkAvailable: Bool

  public init(
    masterURL: String, name: String?, isSuspended: Bool, hasNoWorkAvailable: Bool = false
  ) {
    self.masterURL = masterURL
    self.name = name
    self.isSuspended = isSuspended
    self.hasNoWorkAvailable = hasNoWorkAvailable
  }

  /// Display name, falling back to the host of the master URL.
  public var displayName: String {
    if let name, !name.isEmpty { return name }
    return URL(string: masterURL)?.host ?? masterURL
  }
}

/// One task, from `--get_state` or `--get_simple_gui_info`.
public struct BOINCTask: Sendable, Codable, Equatable {
  public let name: String
  public let workunitName: String?
  public let projectURL: String?
  /// `0...1`, when the task is running.
  public let fractionDone: Double?
  public let elapsedSeconds: Double?
  public let remainingSeconds: Double?
  public let isSuspended: Bool
  /// `active_task_state`: 1 is executing. Absent means the task is not
  /// currently in memory.
  public let activeTaskState: Int?

  public init(
    name: String,
    workunitName: String? = nil,
    projectURL: String? = nil,
    fractionDone: Double? = nil,
    elapsedSeconds: Double? = nil,
    remainingSeconds: Double? = nil,
    isSuspended: Bool = false,
    activeTaskState: Int? = nil
  ) {
    self.name = name
    self.workunitName = workunitName
    self.projectURL = projectURL
    self.fractionDone = fractionDone
    self.elapsedSeconds = elapsedSeconds
    self.remainingSeconds = remainingSeconds
    self.isSuspended = isSuspended
    self.activeTaskState = activeTaskState
  }

  /// `EXECUTING` in BOINC's own numbering.
  public var isExecuting: Bool { activeTaskState == 1 && !isSuspended }
}

/// A parsed `--get_state` or `--get_simple_gui_info` response.
public struct BOINCState: Sendable, Codable, Equatable {
  public let clientVersion: String?
  public let projects: [BOINCProject]
  public let tasks: [BOINCTask]
  /// Top-level elements the parser did not recognise. Logged once rather than
  /// per sample, because BOINC 7.x and 8.x differ and new keys are not errors.
  public let unknownElements: [String]

  public init(
    clientVersion: String? = nil,
    projects: [BOINCProject] = [],
    tasks: [BOINCTask] = [],
    unknownElements: [String] = []
  ) {
    self.clientVersion = clientVersion
    self.projects = projects
    self.tasks = tasks
    self.unknownElements = unknownElements
  }

  public var executingTasks: [BOINCTask] { tasks.filter(\.isExecuting) }

  /// Why the client is not crunching, when it is not.
  ///
  /// Distinguished because the mixer has to let synthetic take the full target
  /// and say why, rather than silently substituting.
  public var idleReason: BOINCIdleReason? {
    if projects.isEmpty { return .noProjectsAttached }
    if tasks.isEmpty { return .noTasks }
    if executingTasks.isEmpty {
      return tasks.allSatisfy(\.isSuspended) ? .allTasksSuspended : .noTasksExecuting
    }
    if projects.allSatisfy(\.isSuspended) { return .allProjectsSuspended }
    return nil
  }
}

/// Why BOINC is contributing nothing right now.
public enum BOINCIdleReason: String, Sendable, Codable {
  case noProjectsAttached
  case noTasks
  case allTasksSuspended
  case noTasksExecuting
  case allProjectsSuspended

  public var explanation: String {
    switch self {
    case .noProjectsAttached:
      return "no projects attached"
    case .noTasks:
      return "no work downloaded"
    case .allTasksSuspended:
      return "all tasks suspended"
    case .noTasksExecuting:
      return "work downloaded but nothing executing"
    case .allProjectsSuspended:
      return "all projects suspended"
    }
  }
}

/// A parsed `--get_cc_status` response.
public struct BOINCStatus: Sendable, Codable, Equatable {
  public let runMode: BOINCRunMode?
  public let permanentRunMode: BOINCRunMode?
  public let gpuMode: BOINCRunMode?
  public let unknownElements: [String]

  public init(
    runMode: BOINCRunMode? = nil,
    permanentRunMode: BOINCRunMode? = nil,
    gpuMode: BOINCRunMode? = nil,
    unknownElements: [String] = []
  ) {
    self.runMode = runMode
    self.permanentRunMode = permanentRunMode
    self.gpuMode = gpuMode
    self.unknownElements = unknownElements
  }
}
