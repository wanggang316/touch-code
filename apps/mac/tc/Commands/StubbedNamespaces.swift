import ArgumentParser
import Darwin
import Foundation
import tcKit

/// Command-tree placeholders for namespaces that land in M5–M7. Each
/// stub exits with code 4 (unsupported) and a clear message so callers
/// know the verb is recognised but not yet wired.
enum StubNamespace {
  struct Space: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
      commandName: "space",
      abstract: "Space-level verbs (ships M6)."
    )
    func run() throws { emitStub("tc space") }
  }

  struct Project: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
      commandName: "project",
      abstract: "Project-level verbs (ships M6)."
    )
    func run() throws { emitStub("tc project") }
  }

  struct Worktree: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
      commandName: "worktree",
      abstract: "Worktree-level verbs (ships M6)."
    )
    func run() throws { emitStub("tc worktree") }
  }

  struct Tab: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
      commandName: "tab",
      abstract: "Tab-level verbs (ships M6)."
    )
    func run() throws { emitStub("tc tab") }
  }

  struct Panel: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
      commandName: "panel",
      abstract: "Panel-level verbs (ships M6)."
    )
    func run() throws { emitStub("tc panel") }
  }

  struct Send: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
      commandName: "send",
      abstract: "Send text to a specific panel (ships M6)."
    )
    func run() throws { emitStub("tc send") }
  }

  struct Broadcast: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
      commandName: "broadcast",
      abstract: "Fan-out text to a tab/worktree/label scope (ships M6)."
    )
    func run() throws { emitStub("tc broadcast") }
  }

  struct Skill: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
      commandName: "skill",
      abstract: "Install the touch-code Agent Skill (ships via exec-plan 0004)."
    )
    func run() throws { emitStub("tc skill") }
  }

  struct Open: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
      commandName: "open",
      abstract: "Open the current Worktree in an external editor (ships M7)."
    )
    func run() throws { emitStub("tc open") }
  }

  private static func emitStub(_ command: String) -> Never {
    FileHandle.standardError.write(Data(
      "error: \(command) is not yet implemented in this build\n".utf8
    ))
    Darwin.exit(CLIExitCode.unsupported.rawValue)
  }
}
