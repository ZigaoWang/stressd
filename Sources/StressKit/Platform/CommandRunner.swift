import Foundation

/// The result of running a subprocess.
public struct CommandResult: Sendable, Equatable {
  public let exitCode: Int32
  public let standardOutput: Data
  public let standardError: String
  /// True when the process had to be killed for exceeding its timeout.
  public let timedOut: Bool

  public var outputText: String { String(decoding: standardOutput, as: UTF8.self) }
  public var succeeded: Bool { exitCode == 0 && !timedOut }

  public init(
    exitCode: Int32, standardOutput: Data, standardError: String, timedOut: Bool = false
  ) {
    self.exitCode = exitCode
    self.standardOutput = standardOutput
    self.standardError = standardError
    self.timedOut = timedOut
  }
}

/// Runs external commands.
///
/// Behind a protocol for the same reason sysctl and IOKit are: the test suite
/// has to exercise `boinccmd` parsing and error handling on machines where
/// BOINC is not installed.
public protocol CommandRunning: Sendable {
  func run(
    _ executable: String, arguments: [String], timeout: TimeInterval
  ) throws
    -> CommandResult
}

extension CommandRunning {
  public func run(_ executable: String, arguments: [String]) throws -> CommandResult {
    try run(executable, arguments: arguments, timeout: 10)
  }
}

/// `CommandRunning` backed by `Process`.
public struct SubprocessRunner: CommandRunning {

  public init() {}

  public func run(
    _ executable: String, arguments: [String], timeout: TimeInterval
  ) throws
    -> CommandResult
  {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: executable)
    process.arguments = arguments

    let output = Pipe()
    let errors = Pipe()
    process.standardOutput = output
    process.standardError = errors
    process.standardInput = FileHandle.nullDevice

    try process.run()

    // Read on background queues before waiting. A command that fills the pipe
    // buffer while we block on waitUntilExit would deadlock.
    let collector = OutputCollector()
    let group = DispatchGroup()
    for (handle, isError) in [
      (output.fileHandleForReading, false), (errors.fileHandleForReading, true),
    ] {
      group.enter()
      DispatchQueue.global(qos: .utility).async {
        let data = handle.readDataToEndOfFile()
        collector.append(data, isError: isError)
        group.leave()
      }
    }

    var timedOut = false
    let deadline = Date().addingTimeInterval(timeout)
    while process.isRunning, Date() < deadline {
      usleep(5_000)
    }
    if process.isRunning {
      timedOut = true
      process.terminate()
      let graceDeadline = Date().addingTimeInterval(1)
      while process.isRunning, Date() < graceDeadline {
        usleep(5_000)
      }
      if process.isRunning {
        kill(process.processIdentifier, SIGKILL)
      }
    }
    process.waitUntilExit()
    _ = group.wait(timeout: .now() + 2)

    return CommandResult(
      exitCode: process.terminationStatus,
      standardOutput: collector.output,
      standardError: String(decoding: collector.errors, as: UTF8.self),
      timedOut: timedOut)
  }

  private final class OutputCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var outputData = Data()
    private var errorData = Data()

    func append(_ data: Data, isError: Bool) {
      lock.lock()
      if isError { errorData.append(data) } else { outputData.append(data) }
      lock.unlock()
    }

    var output: Data {
      lock.lock()
      defer { lock.unlock() }
      return outputData
    }

    var errors: Data {
      lock.lock()
      defer { lock.unlock() }
      return errorData
    }
  }
}
