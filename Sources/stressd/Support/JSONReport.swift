import Foundation

/// One encoder for every `--json` output, so the shape is consistent across
/// subcommands.
enum JSONReport {
  static func encode<Value: Encodable>(_ value: Value) throws -> String {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    encoder.dateEncodingStrategy = .iso8601
    let data = try encoder.encode(value)
    return String(decoding: data, as: UTF8.self)
  }
}
