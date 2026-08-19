import Foundation

/// Parses `boinccmd` XML with `XMLParser`.
///
/// ## Defensive by design
///
/// The XML shape differs between BOINC 7.x and 8.x, and between builds within
/// each. Every field is optional, a missing element yields `nil` rather than an
/// error, and unrecognised elements are collected and reported once rather than
/// failing the parse. A client that adds a key must not stop stressd from
/// reading the keys it already understands.
///
/// Truncated output is the one case that does fail, because a half-read
/// document would otherwise look like a client with no tasks — which the mixer
/// would act on by taking over the whole target.
public enum BOINCXMLParser {

  public enum ParseError: Error, Equatable, CustomStringConvertible {
    case malformed(String)
    case empty

    public var description: String {
      switch self {
      case .malformed(let detail): return "could not parse boinccmd output: \(detail)"
      case .empty: return "boinccmd produced no output"
      }
    }
  }

  /// Top-level elements the state parsers understand. Anything else is
  /// reported as unknown once.
  private static let knownStateElements: Set<String> = [
    "client_state", "simple_gui_info", "project", "app", "app_version", "workunit",
    "result", "active_task", "host_info", "time_stats", "net_stats", "global_preferences",
    "platform", "coproc", "proxy_info", "cc_status", "boinc_gui_rpc_reply",
  ]

  /// Parses `--get_state` or `--get_simple_gui_info`.
  public static func parseState(_ data: Data) throws -> BOINCState {
    let delegate = try run(data)

    let version = [
      delegate.scalars["core_client_major_version"],
      delegate.scalars["core_client_minor_version"],
      delegate.scalars["core_client_release"],
    ].compactMap { $0 }
    return BOINCState(
      clientVersion: version.count == 3 ? version.joined(separator: ".") : nil,
      projects: delegate.projects,
      tasks: delegate.tasks,
      unknownElements: delegate.unknownTopLevel.sorted())
  }

  /// Parses `--get_cc_status`.
  public static func parseStatus(_ data: Data) throws -> BOINCStatus {
    let delegate = try run(data)
    return BOINCStatus(
      runMode: delegate.scalars["task_mode"].flatMap(Int.init).flatMap(BOINCRunMode.init),
      permanentRunMode: delegate.scalars["task_mode_perm"].flatMap(Int.init)
        .flatMap(BOINCRunMode.init),
      gpuMode: delegate.scalars["gpu_mode"].flatMap(Int.init).flatMap(BOINCRunMode.init),
      unknownElements: delegate.unknownTopLevel.sorted())
  }

  private static func run(_ data: Data) throws -> Delegate {
    guard !data.isEmpty else { throw ParseError.empty }

    let parser = XMLParser(data: data)
    let delegate = Delegate()
    parser.delegate = delegate
    guard parser.parse() else {
      let reason = parser.parserError?.localizedDescription ?? "unknown"
      throw ParseError.malformed(reason)
    }
    return delegate
  }

  // MARK: - Delegate

  final class Delegate: NSObject, XMLParserDelegate {
    var projects: [BOINCProject] = []
    var tasks: [BOINCTask] = []
    /// Scalars seen outside any project or result, e.g. client version and
    /// `cc_status` fields.
    var scalars: [String: String] = [:]
    var unknownTopLevel: Set<String> = []

    private var elementStack: [String] = []
    private var text = ""

    private var projectFields: [String: String]?
    private var projectFlags: Set<String> = []
    private var taskFields: [String: String]?
    private var taskFlags: Set<String> = []
    private var inActiveTask = false

    func parser(
      _ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
      qualifiedName: String?, attributes: [String: String]
    ) {
      text = ""
      elementStack.append(elementName)

      switch elementName {
      case "project":
        projectFields = [:]
        projectFlags = []
      case "result":
        taskFields = [:]
        taskFlags = []
      case "active_task":
        inActiveTask = true
      default:
        // Depth 1 is a direct child of the document root.
        if elementStack.count == 2, !knownStateElements.contains(elementName),
          projectFields == nil, taskFields == nil
        {
          // Only flag containers; scalars at this depth are legitimate fields.
          break
        }
      }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
      text += string
    }

    func parser(
      _ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?,
      qualifiedName: String?
    ) {
      let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
      text = ""
      elementStack.removeLast()

      switch elementName {
      case "project":
        if let fields = projectFields {
          projects.append(Self.makeProject(fields: fields, flags: projectFlags))
        }
        projectFields = nil
        projectFlags = []
        return
      case "result":
        if let fields = taskFields {
          tasks.append(Self.makeTask(fields: fields, flags: taskFlags))
        }
        taskFields = nil
        taskFlags = []
        return
      case "active_task":
        inActiveTask = false
        return
      default:
        break
      }

      // An empty element is a boolean flag in BOINC's dialect:
      // <suspended_via_gui/> means true by its presence.
      if value.isEmpty {
        if taskFields != nil {
          taskFlags.insert(elementName)
        } else if projectFields != nil {
          projectFlags.insert(elementName)
        }
        return
      }

      if taskFields != nil {
        // active_task children are namespaced so a task-level and an
        // active-task-level key of the same name cannot collide.
        taskFields?[inActiveTask ? "active_task.\(elementName)" : elementName] = value
      } else if projectFields != nil {
        projectFields?[elementName] = value
      } else {
        scalars[elementName] = value
      }
    }

    /// Records unrecognised container elements so they can be reported once.
    func parser(_ parser: XMLParser, foundUnknownElement elementName: String) {
      unknownTopLevel.insert(elementName)
    }

    private static func makeProject(
      fields: [String: String], flags: Set<String>
    )
      -> BOINCProject
    {
      BOINCProject(
        masterURL: fields["master_url"] ?? "",
        name: fields["project_name"],
        isSuspended: flags.contains("suspended_via_gui")
          || fields["suspended_via_gui"] == "1",
        hasNoWorkAvailable: flags.contains("dont_request_more_work")
          || fields["dont_request_more_work"] == "1")
    }

    private static func makeTask(fields: [String: String], flags: Set<String>) -> BOINCTask {
      BOINCTask(
        name: fields["name"] ?? "",
        workunitName: fields["wu_name"],
        projectURL: fields["project_url"],
        fractionDone: fields["active_task.fraction_done"].flatMap(Double.init)
          ?? fields["fraction_done"].flatMap(Double.init),
        elapsedSeconds: fields["active_task.elapsed_time"].flatMap(Double.init)
          ?? fields["final_elapsed_time"].flatMap(Double.init),
        remainingSeconds: fields["estimated_cpu_time_remaining"].flatMap(Double.init)
          ?? fields["active_task.estimated_cpu_time_remaining"].flatMap(Double.init),
        isSuspended: flags.contains("suspended_via_gui")
          || fields["suspended_via_gui"] == "1",
        activeTaskState: fields["active_task.active_task_state"].flatMap(Int.init))
    }
  }
}
