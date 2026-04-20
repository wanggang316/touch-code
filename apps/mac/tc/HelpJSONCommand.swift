import ArgumentParser
import Foundation

/// Emits a JSON tree of every `tc` subcommand. Consumed by
/// `apps/mac/scripts/skill-help-roundtrip.py` to assert that every `tc <subcommand>`
/// referenced in the skill's `references/tc-cli.md` still exists in the binary. Hidden
/// from the default `--help` output but reachable via `tc help-json`.
struct HelpJSONCommand: ParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "help-json",
    abstract: "Print a JSON tree of every tc subcommand.",
    shouldDisplay: false
  )

  func run() throws {
    let tree = Self.walk(TouchCodeCLI.self, name: "tc")
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    let data = try encoder.encode(tree)
    FileHandle.standardOutput.write(data)
    FileHandle.standardOutput.write(Data("\n".utf8))
  }

  static func walk(_ type: ParsableCommand.Type, name: String) -> Node {
    let config = type.configuration
    let children = config.subcommands.map { sub in
      walk(sub, name: sub.configuration.commandName ?? "")
    }
    return Node(
      name: name,
      abstract: config.abstract,
      subcommands: children
    )
  }

  struct Node: Codable, Equatable {
    let name: String
    let abstract: String
    let subcommands: [Node]
  }
}
