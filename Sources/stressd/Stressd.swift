import ArgumentParser
import Foundation

@main
struct Stressd: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "stressd",
    abstract: "Stress test Apple silicon with real volunteer computing work.",
    discussion: """
      stressd loads your Mac with distributed computing workunits instead of \
      synthetic busy loops, so the heat you generate goes somewhere. Synthetic \
      load remains available as a fallback and for precise control.
      """,
    version: "0.1.0",
    subcommands: [
      TopologyCommand.self
    ]
  )
}

/// Options shared by every subcommand.
struct OutputOptions: ParsableArguments {
  @Flag(name: .long, help: "Emit machine readable JSON instead of formatted text.")
  var json = false
}
