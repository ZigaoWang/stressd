import Foundation

/// A package power sample from `powermetrics`.
public struct PowerSample: Sendable, Codable, Equatable {
  /// CPU package power in watts.
  public let cpuWatts: Double?
  /// GPU power in watts.
  public let gpuWatts: Double?
  /// Apple Neural Engine, when the sampler reports it.
  public let aneWatts: Double?
  /// Whole-package figure when reported, otherwise the sum of the parts.
  public let combinedWatts: Double?
  /// Per-cluster power, keyed by the cluster name powermetrics uses, e.g.
  /// `"E-Cluster"`, `"P0-Cluster"`.
  public let clusterWatts: [String: Double]

  public init(
    cpuWatts: Double? = nil,
    gpuWatts: Double? = nil,
    aneWatts: Double? = nil,
    combinedWatts: Double? = nil,
    clusterWatts: [String: Double] = [:]
  ) {
    self.cpuWatts = cpuWatts
    self.gpuWatts = gpuWatts
    self.aneWatts = aneWatts
    self.combinedWatts = combinedWatts
    self.clusterWatts = clusterWatts
  }
}

/// Why package power is unavailable, phrased so the CLI can act on it.
public enum PowerAvailability: Sendable, Equatable {
  case available
  case requiresRoot
  case toolMissing
  case failed(String)

  public var explanation: String {
    switch self {
    case .available:
      return "available"
    case .requiresRoot:
      return "powermetrics needs root; re-run with sudo for package power"
    case .toolMissing:
      return "powermetrics not found at /usr/bin/powermetrics"
    case .failed(let detail):
      return "powermetrics failed: \(detail)"
    }
  }
}

/// Parses `powermetrics -f plist` output.
///
/// Separated from the subprocess so it can be tested against captured output,
/// including the truncated frames a streaming read produces.
public enum PowerMetricsParser {

  /// `powermetrics` writes a stream of plists back to back, each preceded by a
  /// NUL byte after the first. Splits the buffer into complete plists and
  /// returns whatever remains.
  ///
  /// - Returns: Parsed samples and the unconsumed tail, which is a partial
  ///   plist that the next read will complete.
  public static func drain(buffer: Data) -> (samples: [PowerSample], remainder: Data) {
    var samples: [PowerSample] = []
    var remainder = buffer

    // Frames are separated by NUL. A trailing fragment with no terminator is
    // an incomplete plist and must be carried forward, not parsed.
    while let separator = remainder.firstIndex(of: 0x00) {
      let frame = remainder[remainder.startIndex..<separator]
      remainder = remainder[remainder.index(after: separator)...]
      if let sample = parse(frame: Data(frame)) {
        samples.append(sample)
      }
    }
    return (samples, Data(remainder))
  }

  /// Parses one complete plist frame. Returns `nil` if it is not valid, which
  /// is the expected outcome for a truncated read.
  public static func parse(frame: Data) -> PowerSample? {
    let trimmed = frame.drop { $0 == 0x00 || $0 == 0x0A }
    guard !trimmed.isEmpty else { return nil }
    guard
      let object = try? PropertyListSerialization.propertyList(
        from: Data(trimmed), options: [], format: nil),
      let root = object as? [String: Any]
    else { return nil }
    return sample(from: root)
  }

  /// Builds a sample from a decoded plist root.
  public static func sample(from root: [String: Any]) -> PowerSample {
    let processor = root["processor"] as? [String: Any] ?? [:]

    // powermetrics reports milliwatts on Apple silicon.
    let cpu = milliwatts(processor, "cpu_power")
    let gpu =
      milliwatts(processor, "gpu_power") ?? milliwatts(root["gpu"] as? [String: Any], "gpu_power")
    let ane = milliwatts(processor, "ane_power")
    let combined = milliwatts(processor, "combined_power")

    var clusters: [String: Double] = [:]
    if let list = processor["clusters"] as? [[String: Any]] {
      for cluster in list {
        guard let name = cluster["name"] as? String else { continue }
        if let watts = milliwatts(cluster, "power") {
          clusters[name] = watts
        }
      }
    }

    return PowerSample(
      cpuWatts: cpu,
      gpuWatts: gpu,
      aneWatts: ane,
      combinedWatts: combined ?? sum(cpu, gpu, ane),
      clusterWatts: clusters)
  }

  private static func milliwatts(_ dictionary: [String: Any]?, _ key: String) -> Double? {
    guard let value = (dictionary?[key] as? NSNumber)?.doubleValue else { return nil }
    return value / 1000
  }

  private static func sum(_ values: Double?...) -> Double? {
    let present = values.compactMap { $0 }
    return present.isEmpty ? nil : present.reduce(0, +)
  }
}

/// Streams package power from a long-lived `powermetrics` subprocess.
///
/// ## Never required
///
/// `powermetrics` needs root. When it is unavailable every power field reads
/// `nil` and stressd works normally; nothing here is allowed to become a
/// precondition. The reason is surfaced so the CLI can say *why* rather than
/// showing a blank.
///
/// ## One process, not one per sample
///
/// `powermetrics` takes hundreds of milliseconds to start and its startup is
/// itself a measurable load. Forking one per sample would perturb the very
/// thing being measured, so a single process is spawned with `-i` and its
/// output is read as a stream.
public final class PowerMonitor: @unchecked Sendable {

  private static let executable = "/usr/bin/powermetrics"

  private let lock = NSLock()
  private var process: Process?
  private var buffer = Data()
  private var latest: PowerSample?
  private var availability: PowerAvailability = .available
  private var stderrText = ""

  /// Sampling interval handed to powermetrics, in milliseconds.
  public let intervalMilliseconds: Int

  public init(intervalMilliseconds: Int = 1000) {
    self.intervalMilliseconds = max(100, intervalMilliseconds)
  }

  /// Whether the tool exists and this process could plausibly run it.
  ///
  /// Root is not checked by asking the user: it is checked by trying, because
  /// `powermetrics` is also usable when the binary carries the right
  /// entitlement.
  public static var isToolPresent: Bool {
    FileManager.default.isExecutableFile(atPath: executable)
  }

  public var currentAvailability: PowerAvailability {
    lock.lock()
    defer { lock.unlock() }
    return availability
  }

  /// Starts the subprocess. Idempotent, and never throws: a failure to start
  /// is recorded as unavailability, not an error the caller must handle.
  public func start() {
    lock.lock()
    guard process == nil else {
      lock.unlock()
      return
    }

    guard Self.isToolPresent else {
      availability = .toolMissing
      lock.unlock()
      return
    }

    let task = Process()
    task.executableURL = URL(fileURLWithPath: Self.executable)
    task.arguments = [
      "--samplers", "cpu_power,gpu_power",
      "-i", String(intervalMilliseconds),
      "-f", "plist",
    ]

    let output = Pipe()
    let errors = Pipe()
    task.standardOutput = output
    task.standardError = errors

    output.fileHandleForReading.readabilityHandler = { [weak self] handle in
      let data = handle.availableData
      guard !data.isEmpty else { return }
      self?.consume(data)
    }
    errors.fileHandleForReading.readabilityHandler = { [weak self] handle in
      let data = handle.availableData
      guard !data.isEmpty else { return }
      self?.consumeError(data)
    }

    do {
      try task.run()
      process = task
      availability = .available
    } catch {
      availability = .failed(error.localizedDescription)
    }
    lock.unlock()
  }

  /// The most recent sample, or `nil` if none has arrived yet.
  public func latestSample() -> PowerSample? {
    lock.lock()
    defer { lock.unlock() }
    return latest
  }

  /// Terminates the subprocess. Idempotent, and safe from any exit path
  /// including the `atexit` backstop.
  public func stop() {
    lock.lock()
    let task = process
    process = nil
    if let output = task?.standardOutput as? Pipe {
      output.fileHandleForReading.readabilityHandler = nil
    }
    if let errors = task?.standardError as? Pipe {
      errors.fileHandleForReading.readabilityHandler = nil
    }
    lock.unlock()

    guard let task, task.isRunning else { return }
    task.terminate()
    // powermetrics exits promptly on SIGTERM. The wait bounds a hang rather
    // than expecting one.
    let deadline = Date().addingTimeInterval(2)
    while task.isRunning, Date() < deadline {
      usleep(20_000)
    }
    if task.isRunning {
      kill(task.processIdentifier, SIGKILL)
    }
  }

  deinit {
    stop()
  }

  // MARK: - Stream handling

  private func consume(_ data: Data) {
    lock.lock()
    defer { lock.unlock() }
    buffer.append(data)
    let (samples, remainder) = PowerMetricsParser.drain(buffer: buffer)
    buffer = remainder
    if let last = samples.last {
      latest = last
    }
    // A partial frame is normal; an unbounded one means the output is not what
    // we expect and the buffer must not grow forever.
    if buffer.count > 4_000_000 {
      buffer.removeAll(keepingCapacity: false)
    }
  }

  private func consumeError(_ data: Data) {
    lock.lock()
    defer { lock.unlock() }
    stderrText += String(decoding: data, as: UTF8.self)
    // powermetrics is explicit about this, and it is by far the most common
    // reason it fails, so it gets its own case rather than a generic message.
    if stderrText.localizedCaseInsensitiveContains("requires root")
      || stderrText.localizedCaseInsensitiveContains("must be invoked as the superuser")
      || stressdIsPermissionDenied(stderrText)
    {
      availability = .requiresRoot
    } else if !stderrText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
      availability = .failed(
        stderrText.trimmingCharacters(in: .whitespacesAndNewlines).prefix(200).description)
    }
  }

  private func stressdIsPermissionDenied(_ text: String) -> Bool {
    text.localizedCaseInsensitiveContains("permission denied")
      || text.localizedCaseInsensitiveContains("not permitted")
  }
}
