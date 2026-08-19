import Foundation

/// Folding@home, via the v8 `fah-client`.
///
/// The one contributing client that folds **anonymously**, with no account and
/// no project signup, which makes it the easiest real work to get running.
/// An account can be attached later to collect credit; see `attachHint`.
///
/// ## Not validated against a live client
///
/// `fah-client` installs a launchd daemon and its installer needs
/// administrator rights, so this has been developed against the documented API
/// shape and unit tested against fixtures. See `DEFERRED.md`.
public actor FoldingSource: LoadSource {

  public nonisolated let id = "folding"
  public nonisolated let isContributing = true

  /// Where `fah-client` lands.
  public static let candidateExecutables = [
    "/Applications/FAHClient.app/Contents/MacOS/fah-client",
    "/opt/homebrew/bin/fah-client",
    "/usr/local/bin/fah-client",
  ]

  /// v8 exposes a WebSocket API here. Preferred over shelling out, because the
  /// client is a long-running daemon and the socket gives state without
  /// spawning a process per sample.
  public static let defaultAPIPort = 7396

  private let runner: any CommandRunning
  private let fileManager: FileManager
  private let session: any FoldingAPIQuerying
  private var executablePath: String?
  private var requestedLoad: Double = 0
  private var isRunning = false
  private var originalPaused: Bool?

  public init(
    runner: any CommandRunning = SubprocessRunner(),
    fileManager: FileManager = .default,
    session: (any FoldingAPIQuerying)? = nil,
    executablePath: String? = nil
  ) {
    self.runner = runner
    self.fileManager = fileManager
    self.session = session ?? FoldingHTTPAPI(port: Self.defaultAPIPort)
    self.executablePath = executablePath
  }

  // MARK: - Detection

  public func detect() async -> DetectionResult {
    // The API answering is better evidence than a binary existing: the client
    // is a daemon and the binary can be present while nothing is running.
    if let snapshot = try? await currentState() {
      let units = snapshot.units.count
      return .available(
        detail: snapshot.version.map { "fah-client \($0), \(units) work unit(s)" }
          ?? "fah-client, \(units) work unit(s)")
    }

    guard locateExecutable() != nil else {
      return .unavailable(
        reason: "fah-client not found",
        installHint: """
          Download the v8 client from https://foldingathome.org/start-folding/

          Folding@home is the one project that folds anonymously, with no \
          account needed. To collect credit instead, create a passkey at
            https://apps.foldingathome.org/getpasskey
          and set it in the client's web control at http://localhost:7396
          """)
    }
    return .unavailable(
      reason: "fah-client is installed but its API on port \(Self.defaultAPIPort) "
        + "is not answering",
      installHint: "Start the client, then check http://localhost:7396")
  }

  // MARK: - Lifecycle

  public func start(budget: ResourceBudget) async throws {
    isRunning = true
    requestedLoad = budget.cpu
    if originalPaused == nil {
      originalPaused = (try? await currentState())?.isPaused
    }
    try await apply(budget.cpu)
  }

  public func adjust(to budget: ResourceBudget) async throws {
    guard isRunning else {
      try await start(budget: budget)
      return
    }
    guard abs(budget.cpu - requestedLoad) > 0.01 else { return }
    requestedLoad = budget.cpu
    try await apply(budget.cpu)
  }

  public func stop() async {
    // Restore whatever the user had, rather than assuming they wanted it
    // folding.
    if let originalPaused {
      _ = try? await session.send(command: originalPaused ? "pause" : "unpause")
    }
    originalPaused = nil
    isRunning = false
    requestedLoad = 0
  }

  public func status() async throws -> SourceStatus {
    let snapshot = try? await currentState()
    let active = snapshot?.units.filter { !$0.isPaused } ?? []

    var detail: [String: String] = ["client": executablePath ?? "api"]
    if let version = snapshot?.version { detail["version"] = version }
    if let unit = active.first {
      detail["project"] = unit.project.map(String.init) ?? "unknown"
      detail["workunit"] = unit.id
      if let progress = unit.progress {
        detail["progress"] = String(format: "%.1f%%", progress * 100)
      }
    }
    detail["units"] = "\(active.count) active of \(snapshot?.units.count ?? 0)"
    if active.isEmpty { detail["idleReason"] = "no work units folding" }

    return SourceStatus(
      sourceID: id,
      isContributing: true,
      state: isRunning ? (active.isEmpty ? .idle : .running) : .stopped,
      requestedLoad: requestedLoad,
      threadCount: active.count,
      detail: detail)
  }

  // MARK: - Internals

  /// Translates a target into the client's controls.
  ///
  /// v8 exposes a CPU count rather than a duty cycle, so a fraction of the
  /// machine becomes a fraction of the cores. Coarser than the synthetic
  /// source's duty cycling, which is exactly why the mixer tops it up.
  private func apply(_ fraction: Double) async throws {
    guard fraction > 0.005 else {
      _ = try? await session.send(command: "pause")
      return
    }
    _ = try? await session.send(command: "unpause")
    let cores = max(
      1, Int((Double(ProcessInfo.processInfo.activeProcessorCount) * fraction).rounded()))
    _ = try? await session.setCPUs(cores)
  }

  private func currentState() async throws -> FoldingSnapshot {
    try await session.snapshot()
  }

  private func locateExecutable() -> String? {
    if let executablePath, fileManager.isExecutableFile(atPath: executablePath) {
      return executablePath
    }
    let found = Self.candidateExecutables.first { fileManager.isExecutableFile(atPath: $0) }
    executablePath = found
    return found
  }
}

/// One Folding@home work unit.
public struct FoldingUnit: Sendable, Codable, Equatable {
  public let id: String
  public let project: Int?
  /// `0...1`.
  public let progress: Double?
  public let isPaused: Bool

  public init(id: String, project: Int?, progress: Double?, isPaused: Bool) {
    self.id = id
    self.project = project
    self.progress = progress
    self.isPaused = isPaused
  }
}

/// A read of the client's state.
public struct FoldingSnapshot: Sendable, Codable, Equatable {
  public let version: String?
  public let isPaused: Bool
  public let units: [FoldingUnit]

  public init(version: String?, isPaused: Bool, units: [FoldingUnit]) {
    self.version = version
    self.isPaused = isPaused
    self.units = units
  }
}

/// The subset of the v8 API stressd uses.
public protocol FoldingAPIQuerying: Sendable {
  func snapshot() async throws -> FoldingSnapshot
  func send(command: String) async throws -> Bool
  func setCPUs(_ count: Int) async throws -> Bool
}

/// Parses the v8 client's JSON state.
///
/// Defensive in the same way the BOINC parser is: every field optional, a
/// missing key is `nil` rather than an error, because the v8 API is still
/// changing shape between releases.
public enum FoldingStateParser {

  public static func parse(_ data: Data) throws -> FoldingSnapshot {
    guard !data.isEmpty else {
      throw StressKitError.boincCommandFailed(command: "fah state", detail: "empty response")
    }
    guard let root = try? JSONSerialization.jsonObject(with: data) else {
      throw StressKitError.boincCommandFailed(
        command: "fah state", detail: "response was not JSON")
    }

    // v8 has moved this between a bare object and an array of frames across
    // releases, so both are accepted.
    let object: [String: Any]
    if let dictionary = root as? [String: Any] {
      object = dictionary
    } else if let array = root as? [Any],
      let first = array.compactMap({ $0 as? [String: Any] }).first
    {
      object = first
    } else {
      throw StressKitError.boincCommandFailed(
        command: "fah state", detail: "unrecognised JSON shape")
    }

    let info = object["info"] as? [String: Any]
    let config = object["config"] as? [String: Any]
    let rawUnits = object["units"] as? [[String: Any]] ?? []

    let units = rawUnits.map { unit -> FoldingUnit in
      FoldingUnit(
        id: (unit["id"] as? String) ?? (unit["number"].map { "\($0)" } ?? "unknown"),
        project: unit["project"] as? Int,
        progress: (unit["progress"] as? NSNumber)?.doubleValue,
        isPaused: (unit["paused"] as? Bool) ?? false)
    }

    return FoldingSnapshot(
      version: info?["version"] as? String,
      isPaused: (config?["paused"] as? Bool) ?? false,
      units: units)
  }
}

/// Talks to the v8 client's local HTTP API.
///
/// v8 also offers a WebSocket for streaming updates. stressd polls once a
/// second, so the request/response endpoint carries the same information
/// without a persistent connection to keep alive.
public struct FoldingHTTPAPI: FoldingAPIQuerying {

  private let port: Int
  private let session: URLSession

  public init(port: Int, session: URLSession = .shared) {
    self.port = port
    self.session = session
  }

  private func url(_ path: String) -> URL? {
    URL(string: "http://127.0.0.1:\(port)/\(path)")
  }

  public func snapshot() async throws -> FoldingSnapshot {
    guard let url = url("api/state") else {
      throw StressKitError.boincUnavailable("bad Folding@home URL")
    }
    var request = URLRequest(url: url)
    request.timeoutInterval = 3
    let (data, _) = try await session.data(for: request)
    return try FoldingStateParser.parse(data)
  }

  public func send(command: String) async throws -> Bool {
    guard let url = url("api/\(command)") else { return false }
    var request = URLRequest(url: url)
    request.httpMethod = "PUT"
    request.timeoutInterval = 3
    let (_, response) = try await session.data(for: request)
    return (response as? HTTPURLResponse)?.statusCode ?? 500 < 400
  }

  public func setCPUs(_ count: Int) async throws -> Bool {
    guard let url = url("api/config") else { return false }
    var request = URLRequest(url: url)
    request.httpMethod = "PUT"
    request.timeoutInterval = 3
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.httpBody = try? JSONSerialization.data(withJSONObject: ["cpus": count])
    let (_, response) = try await session.data(for: request)
    return (response as? HTTPURLResponse)?.statusCode ?? 500 < 400
  }
}
