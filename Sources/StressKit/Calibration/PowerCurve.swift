import Foundation

/// One measured point on the load-to-power curve.
public struct CalibrationPoint: Sendable, Codable, Equatable {
  /// Requested duty cycle, `0...1`.
  public let requestedLoad: Double
  /// What the workers measured for themselves.
  public let workerMeasuredLoad: Double?
  /// Observed system-wide utilization, including everything else running.
  public let observedUtilization: Double
  /// Observed utilization minus the baseline captured before the sweep. This
  /// is stressd's own contribution.
  public let observedUtilizationDelta: Double
  /// Observed utilization per performance level, keyed by level name.
  public let utilizationByLevel: [String: Double]

  /// Whole-system draw from the battery, positive watts. `nil` on AC.
  public let systemWatts: Double?
  /// `systemWatts` minus the baseline draw: the cost of the load itself.
  public let systemWattsDelta: Double?
  public let packageWatts: Double?
  public let packageWattsDelta: Double?
  public let gpuWatts: Double?
  /// System draw minus package draw: display, radios, everything else.
  public let otherWatts: Double?

  public let thermalState: ThermalState
  /// True when this point was not measured at `.nominal`, which means
  /// throttling may have suppressed it.
  public let isSuspect: Bool
  /// Order in which this point was actually measured, which is randomised.
  public let measurementOrder: Int
  public let samples: Int

  public init(
    requestedLoad: Double,
    workerMeasuredLoad: Double?,
    observedUtilization: Double,
    observedUtilizationDelta: Double,
    utilizationByLevel: [String: Double],
    systemWatts: Double?,
    systemWattsDelta: Double?,
    packageWatts: Double?,
    packageWattsDelta: Double?,
    gpuWatts: Double?,
    otherWatts: Double?,
    thermalState: ThermalState,
    isSuspect: Bool,
    measurementOrder: Int,
    samples: Int
  ) {
    self.requestedLoad = requestedLoad
    self.workerMeasuredLoad = workerMeasuredLoad
    self.observedUtilization = observedUtilization
    self.observedUtilizationDelta = observedUtilizationDelta
    self.utilizationByLevel = utilizationByLevel
    self.systemWatts = systemWatts
    self.systemWattsDelta = systemWattsDelta
    self.packageWatts = packageWatts
    self.packageWattsDelta = packageWattsDelta
    self.gpuWatts = gpuWatts
    self.otherWatts = otherWatts
    self.thermalState = thermalState
    self.isSuspect = isSuspect
    self.measurementOrder = measurementOrder
    self.samples = samples
  }

  /// The watts this point costs over baseline, from whichever source is
  /// available. Battery is preferred: it measures the whole machine.
  public var incrementalWatts: Double? { systemWattsDelta ?? packageWattsDelta }
}

/// A measured load-to-power curve.
public struct PowerCurve: Sendable, Codable, Equatable {
  public let machineModel: String
  public let chipName: String?
  public let measuredAt: Date
  /// `battery` gives whole-system draw; `package` only the SoC.
  public let powerSource: Source
  /// Utilization with no stressd load, captured before the sweep.
  public let baselineUtilization: Double
  public let baselineWatts: Double?
  /// Points sorted by requested load, regardless of measurement order.
  public let points: [CalibrationPoint]
  public let dwellSeconds: Double
  public let settleSeconds: Double
  public let cooldownSeconds: Double

  public enum Source: String, Sendable, Codable {
    case battery
    case packagePower
    case utilizationOnly

    public var explanation: String {
      switch self {
      case .battery:
        return "battery (whole system draw)"
      case .packagePower:
        return "powermetrics (SoC package only, excludes display and radios)"
      case .utilizationOnly:
        return "none: no battery discharge and no package power available"
      }
    }
  }

  /// Baseline utilization above this makes the curve noticeably noisier,
  /// because the machine's own work moves independently of the sweep.
  public static let noisyBaselineThreshold = 0.15

  public var hasNoisyBaseline: Bool { baselineUtilization > Self.noisyBaselineThreshold }
  public var suspectPoints: [CalibrationPoint] { points.filter(\.isSuspect) }

  public init(
    machineModel: String,
    chipName: String?,
    measuredAt: Date,
    powerSource: Source,
    baselineUtilization: Double,
    baselineWatts: Double?,
    points: [CalibrationPoint],
    dwellSeconds: Double,
    settleSeconds: Double,
    cooldownSeconds: Double
  ) {
    self.machineModel = machineModel
    self.chipName = chipName
    self.measuredAt = measuredAt
    self.powerSource = powerSource
    self.baselineUtilization = baselineUtilization
    self.baselineWatts = baselineWatts
    self.points = points.sorted { $0.requestedLoad < $1.requestedLoad }
    self.dwellSeconds = dwellSeconds
    self.settleSeconds = settleSeconds
    self.cooldownSeconds = cooldownSeconds
  }

  /// Watts per percentage point of load, between consecutive points.
  ///
  /// The interesting derived number: a flat series means power scales linearly
  /// with load, and a rise or fall locates the efficiency knee.
  public var marginalWattsPerPoint: [(from: Double, to: Double, wattsPerPoint: Double)] {
    var result: [(Double, Double, Double)] = []
    for (previous, current) in zip(points, points.dropFirst()) {
      guard let a = previous.incrementalWatts, let b = current.incrementalWatts else { continue }
      let span = (current.requestedLoad - previous.requestedLoad) * 100
      guard span > 0 else { continue }
      result.append((previous.requestedLoad, current.requestedLoad, (b - a) / span))
    }
    return result
  }

  /// Where the marginal cost of load changes most sharply.
  public var efficiencyKnee: (load: Double, wattsPerPoint: Double)? {
    let marginals = marginalWattsPerPoint
    guard marginals.count > 1 else { return nil }
    var steepest: (Double, Double, Double)?
    var largestJump = 0.0
    for (previous, current) in zip(marginals, marginals.dropFirst()) {
      let jump = abs(current.wattsPerPoint - previous.wattsPerPoint)
      if jump > largestJump {
        largestJump = jump
        steepest = (current.from, current.to, current.wattsPerPoint)
      }
    }
    guard let steepest else { return nil }
    return (steepest.0, steepest.2)
  }

  /// Linear watts-per-load-fraction fit through the incremental points, for
  /// seeding a controller before it has learned anything.
  public var linearWattsPerFullLoad: Double? {
    let usable = points.compactMap { point -> (Double, Double)? in
      guard let watts = point.incrementalWatts else { return nil }
      return (point.requestedLoad, watts)
    }
    guard usable.count >= 2 else { return nil }
    let meanX = usable.reduce(0) { $0 + $1.0 } / Double(usable.count)
    let meanY = usable.reduce(0) { $0 + $1.1 } / Double(usable.count)
    let numerator = usable.reduce(0) { $0 + ($1.0 - meanX) * ($1.1 - meanY) }
    let denominator = usable.reduce(0) { $0 + pow($1.0 - meanX, 2) }
    guard denominator > 0 else { return nil }
    return numerator / denominator
  }

  // MARK: - Persistence

  /// Where the curve is cached so the power governor can seed itself from it
  /// rather than learning cold.
  public static var defaultURL: URL {
    let base =
      FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask).first
      .map { $0.deletingLastPathComponent() }
      ?? FileManager.default.homeDirectoryForCurrentUser
    return
      base
      .appendingPathComponent(".config", isDirectory: true)
      .appendingPathComponent("stressd", isDirectory: true)
      .appendingPathComponent("power-curve.json")
  }

  public func write(to url: URL = PowerCurve.defaultURL) throws {
    try FileManager.default.createDirectory(
      at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    encoder.dateEncodingStrategy = .iso8601
    try encoder.encode(self).write(to: url, options: .atomic)
  }

  public static func read(from url: URL = PowerCurve.defaultURL) throws -> PowerCurve {
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    return try decoder.decode(PowerCurve.self, from: Data(contentsOf: url))
  }

  /// Comma-separated values, for feeding a spreadsheet or a plot.
  public func csvRepresentation() -> String {
    var lines = [
      "requested_load,worker_measured_load,observed_utilization,"
        + "observed_utilization_delta,system_watts,system_watts_delta,"
        + "package_watts,package_watts_delta,gpu_watts,other_watts,"
        + "thermal_state,suspect,measurement_order,samples"
    ]
    let number: (Double?) -> String = { $0.map { String(format: "%.4f", $0) } ?? "" }
    for point in points {
      lines.append(
        [
          number(point.requestedLoad),
          number(point.workerMeasuredLoad),
          number(point.observedUtilization),
          number(point.observedUtilizationDelta),
          number(point.systemWatts),
          number(point.systemWattsDelta),
          number(point.packageWatts),
          number(point.packageWattsDelta),
          number(point.gpuWatts),
          number(point.otherWatts),
          point.thermalState.rawValue,
          point.isSuspect ? "true" : "false",
          String(point.measurementOrder),
          String(point.samples),
        ].joined(separator: ","))
    }
    return lines.joined(separator: "\n") + "\n"
  }
}
