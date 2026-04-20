import ArgumentParser
import Foundation
import tcKit

struct TouchCodeCLI: ParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "tc",
    abstract: "Control touch-code from the terminal.",
    version: "touch-code 0.1.0 (build 1)",
    subcommands: [SkillCommand.self]
  )

  func run() throws {
    // No subcommand given: fall back to version banner.
    print(Self.configuration.version)
  }
}

TouchCodeCLI.main()
