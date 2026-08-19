import Foundation
import StressKit

/// Renders a measured power curve as a table and a rough plot.
enum CurveRenderer {

  static func summary(_ curve: PowerCurve, plot: Bool) -> String {
    var lines: [String] = []
    lines.append("Power curve  \(curve.chipName ?? curve.machineModel)")
    lines.append(Formatting.field("  Source", curve.powerSource.explanation, keyWidth: 20))
    lines.append(
      Formatting.field(
        "  Baseline",
        "\(TelemetryRenderer.percent(curve.baselineUtilization)) utilization"
          + (curve.baselineWatts.map { String(format: ", %.2f W", $0) } ?? ""),
        keyWidth: 20))
    lines.append(
      Formatting.field(
        "  Dwell / settle",
        "\(Int(curve.dwellSeconds))s / \(Int(curve.settleSeconds))s, "
          + "\(Int(curve.cooldownSeconds))s cooldown",
        keyWidth: 20))

    if curve.hasNoisyBaseline {
      lines.append("")
      lines.append(
        "  WARNING  Baseline utilization is "
          + "\(TelemetryRenderer.percent(curve.baselineUtilization)), above the "
          + "\(TelemetryRenderer.percent(PowerCurve.noisyBaselineThreshold)) threshold.")
      lines.append(
        "           The machine's own work moves independently of the sweep, so the")
      lines.append("           curve is noisier than it would be on an idle machine.")
    }

    lines.append("")
    lines.append(contentsOf: table(curve))

    let marginals = curve.marginalWattsPerPoint
    if !marginals.isEmpty {
      lines.append("")
      lines.append("Marginal cost (watts per percentage point of load)")
      for entry in marginals {
        lines.append(
          String(
            format: "  %3.0f%% -> %3.0f%%   %+.3f W/pt", entry.from * 100, entry.to * 100,
            entry.wattsPerPoint))
      }
      if let knee = curve.efficiencyKnee {
        lines.append("")
        lines.append(
          String(
            format: "  Sharpest change near %.0f%% load, at %+.3f W/pt.", knee.load * 100,
            knee.wattsPerPoint))
        lines.append(
          "  A flat column means power scales linearly with load; a step is the knee.")
      }
    }

    if plot, let plotted = asciiPlot(curve) {
      lines.append("")
      lines.append(contentsOf: plotted)
    }

    let suspect = curve.suspectPoints
    if !suspect.isEmpty {
      lines.append("")
      lines.append("Suspect points, not measured entirely at nominal thermal state:")
      for point in suspect {
        lines.append(
          "  \(TelemetryRenderer.percent(point.requestedLoad)) "
            + "(\(point.thermalState.rawValue)) - throttling may have suppressed this")
      }
    }
    return lines.joined(separator: "\n")
  }

  private static func table(_ curve: PowerCurve) -> [String] {
    var lines = [
      "  load   worker    obs     delta      watts   d-watts   package     other  thermal"
    ]
    let number: (Double?, String) -> String = { value, format in
      value.map { String(format: format, $0) } ?? "       -"
    }
    for point in curve.points {
      lines.append(
        "  "
          + String(format: "%4.0f%%", point.requestedLoad * 100)
          + number(point.workerMeasuredLoad.map { $0 * 100 }, "  %5.1f%%")
          + String(format: "  %5.1f%%", point.observedUtilization * 100)
          + String(format: "  %+6.1f%%", point.observedUtilizationDelta * 100)
          + number(point.systemWatts, "  %7.2f")
          + number(point.systemWattsDelta, "  %+8.2f")
          + number(point.packageWatts, "  %8.2f")
          + number(point.otherWatts, "  %8.2f")
          + "  " + point.thermalState.rawValue
          + (point.isSuspect ? " *" : ""))
    }
    return lines
  }

  /// A rough plot of incremental watts against load. Rough on purpose: it is
  /// for spotting a knee at a glance, not for reading values off.
  private static func asciiPlot(_ curve: PowerCurve) -> [String]? {
    let usable = curve.points.compactMap { point -> (Double, Double)? in
      guard let watts = point.incrementalWatts else { return nil }
      return (point.requestedLoad, watts)
    }
    guard usable.count >= 2 else { return nil }

    let maxWatts = usable.map(\.1).max() ?? 0
    let minWatts = min(0, usable.map(\.1).min() ?? 0)
    guard maxWatts > minWatts else { return nil }

    let height = 12
    let width = 50
    var grid = [[Character]](
      repeating: [Character](repeating: " ", count: width), count: height)

    for (load, watts) in usable {
      let column = Int((Double(width - 1) * load).rounded())
      let normalised = (watts - minWatts) / (maxWatts - minWatts)
      let row = height - 1 - Int((Double(height - 1) * normalised).rounded())
      grid[min(max(row, 0), height - 1)][min(max(column, 0), width - 1)] = "*"
    }

    var lines = ["Incremental watts over baseline vs requested load"]
    for (index, row) in grid.enumerated() {
      let value = maxWatts - (maxWatts - minWatts) * Double(index) / Double(height - 1)
      lines.append(String(format: "  %6.1f W |", value) + String(row))
    }
    lines.append("           +" + String(repeating: "-", count: width))
    lines.append("            0%" + String(repeating: " ", count: width - 8) + "100%")
    return lines
  }
}
