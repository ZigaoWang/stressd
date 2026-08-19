import ArgumentParser
import Foundation
import StressKit

/// One line of `stressd sources` output, and the JSON shape.
struct SourceReport: Codable {
  let id: String
  let isContributing: Bool
  let available: Bool
  let detail: String?
  let reason: String?
  let installHint: String?
}

struct SourcesCommand: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "sources",
    abstract: "Show which load sources are available, and how to install what is missing.",
    discussion: """
      Contributing sources run real volunteer computing work. The synthetic \
      source is always available and computes nothing useful; it exists as a \
      fallback and as the precision instrument the mixer tops up with.
      """
  )

  @OptionGroup var output: OutputOptions

  func run() async throws {
    let topology = try CoreTopologyDetector().detect()

    let boinc = BOINCSource()
    let synthetic = SyntheticSource(topology: topology)

    let boincDetection = await boinc.detect()
    let syntheticDetection = await synthetic.detect()

    let reports = [
      Self.report(id: "boinc", contributing: true, detection: boincDetection),
      Self.report(id: "synthetic", contributing: false, detection: syntheticDetection),
    ]

    if output.json {
      print(try JSONReport.encode(reports))
      return
    }
    print(Self.render(reports, boincVersion: await boinc.clientVersion()))
  }

  static func report(
    id: String, contributing: Bool, detection: DetectionResult
  )
    -> SourceReport
  {
    switch detection {
    case .available(let detail):
      return SourceReport(
        id: id, isContributing: contributing, available: true, detail: detail, reason: nil,
        installHint: nil)
    case .unavailable(let reason, let hint):
      return SourceReport(
        id: id, isContributing: contributing, available: false, detail: nil, reason: reason,
        installHint: hint)
    }
  }

  static func render(_ reports: [SourceReport], boincVersion: String?) -> String {
    var lines = ["Load sources", ""]

    for report in reports {
      let marker = report.available ? "available" : "missing"
      let kind = report.isContributing ? "contributes real work" : "computes nothing"
      lines.append("  \(report.id)   [\(marker)]   \(kind)")
      if let detail = report.detail {
        lines.append("    \(detail)")
      }
      if let reason = report.reason {
        lines.append("    \(reason)")
      }
      if let hint = report.installHint {
        lines.append("")
        for line in hint.split(separator: "\n", omittingEmptySubsequences: false) {
          lines.append("    \(line)")
        }
      }
      lines.append("")
    }

    if let boincVersion {
      lines.append("  Detected BOINC client version \(boincVersion)")
      lines.append("")
    }

    lines.append(contentsOf: projectRecommendations())
    return lines.joined(separator: "\n")
  }

  /// The projects worth pointing people at on this hardware.
  static func projectRecommendations() -> [String] {
    [
      "Recommended projects with native Apple silicon applications:",
      "",
      "  Einstein@Home    https://einsteinathome.org",
      "    Gravitational wave data from LIGO, and radio pulsar searches.",
      "    Native arm64 applications including GPU apps.",
      "",
      "  PrimeGrid        https://www.primegrid.com",
      "    Distributed prime number searches.",
      "    Native arm64 applications including GPU apps.",
      "",
      "  Attach from BOINC Manager, or:",
      "    boinccmd --project_attach <url> <account_key>",
    ]
  }
}
