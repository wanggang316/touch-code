import ArgumentParser
import Foundation

@main
struct TouchCodeCLI: ParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "tc",
    abstract: "Control touch-code from the terminal.",
    version: "touch-code 0.1.0 (build 1)"
  )

  func run() throws {
    print(Self.configuration.version ?? "unknown")
  }
}
