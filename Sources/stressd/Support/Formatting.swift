import Foundation

/// Presentation helpers. Kept in the executable target: StressKit deliberately
/// has no opinion about how its values are rendered.
enum Formatting {

  /// Formats a byte count with binary units, e.g. `192 KiB`, `16 MiB`.
  static func bytes(_ value: Int?) -> String {
    guard let value, value > 0 else { return "-" }
    let units = ["B", "KiB", "MiB", "GiB", "TiB"]
    var magnitude = Double(value)
    var unit = 0
    while magnitude >= 1024, unit < units.count - 1 {
      magnitude /= 1024
      unit += 1
    }
    let rounded = magnitude.rounded()
    return abs(magnitude - rounded) < 0.05
      ? "\(Int(rounded)) \(units[unit])"
      : String(format: "%.1f %@", magnitude, units[unit])
  }

  static func bytes(_ value: UInt64) -> String {
    value > UInt64(Int.max) ? "-" : bytes(Int(value))
  }

  /// Formats a frequency in Hz as GHz.
  static func frequency(_ hertz: Int?) -> String? {
    guard let hertz, hertz > 0 else { return nil }
    return String(format: "%.2f GHz", Double(hertz) / 1e9)
  }

  /// Renders a list of logical CPU numbers as compact ranges: `0-5`, `0-3,8-11`.
  static func cpuRanges(_ ranges: [ClosedRange<Int>]) -> String {
    guard !ranges.isEmpty else { return "-" }
    return
      ranges
      .map {
        $0.lowerBound == $0.upperBound ? "\($0.lowerBound)" : "\($0.lowerBound)-\($0.upperBound)"
      }
      .joined(separator: ",")
  }

  /// Lays strings out in aligned columns that fit `width`.
  static func columns(_ items: [String], width: Int = 78, indent: String = "  ") -> [String] {
    guard !items.isEmpty else { return [] }
    let cellWidth = (items.map(\.count).max() ?? 0) + 2
    let perRow = max(1, (width - indent.count) / cellWidth)

    return stride(from: 0, to: items.count, by: perRow).map { start in
      let row = items[start..<min(start + perRow, items.count)]
      return indent
        + row.map { $0.padding(toLength: cellWidth, withPad: " ", startingAt: 0) }
        .joined()
        .trimmingCharacters(in: .whitespaces)
    }
  }

  /// A `key   value` line with the key padded to a fixed column.
  static func field(_ key: String, _ value: String, keyWidth: Int = 18) -> String {
    key.padding(toLength: keyWidth, withPad: " ", startingAt: 0) + value
  }
}
