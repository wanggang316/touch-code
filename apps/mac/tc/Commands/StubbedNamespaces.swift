import ArgumentParser
import Darwin
import Foundation
import tcKit

/// Command-tree placeholders for namespaces that ship later. Each stub
/// exits with code 4 (unsupported) and a clear message so callers know
/// the verb is recognised but not yet wired.
///
/// Remaining stubs after M7:
/// - `tc skill`  — ships via exec-plan 0004 (C5).
enum StubNamespace {
  struct Skill: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
      commandName: "skill",
      abstract: "Install the touch-code Agent Skill (ships via exec-plan 0004)."
    )
    func run() throws { emitStub("tc skill") }
  }

  private static func emitStub(_ command: String) -> Never {
    FileHandle.standardError.write(
      Data(
        "error: \(command) is not yet implemented in this build\n".utf8
      ))
    Darwin.exit(CLIExitCode.unsupported.rawValue)
  }
}
