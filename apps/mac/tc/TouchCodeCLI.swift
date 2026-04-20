import ArgumentParser
import Foundation
import tcKit
import TouchCodeCore
import TouchCodeIPC

@main
struct TouchCodeCLI: AsyncParsableCommand {
  static let version = "0.3.0"

  static let configuration = CommandConfiguration(
    commandName: "tc",
    abstract: "Control touch-code from the terminal.",
    version: "touch-code \(TouchCodeCLI.version)",
    subcommands: [
      SystemCommand.self,
      StubNamespace.Space.self,
      StubNamespace.Project.self,
      StubNamespace.Worktree.self,
      StubNamespace.Tab.self,
      StubNamespace.Panel.self,
      StubNamespace.Send.self,
      StubNamespace.Broadcast.self,
      HookCommand.self,
      StubNamespace.Skill.self,
      StubNamespace.Open.self,
    ]
  )
}

// Global options shared across subcommands via composition — ArgumentParser's
// `@OptionGroup` pattern.
struct GlobalOptions: ParsableArguments {
  @Flag(name: .long, help: "Emit JSON on stdout instead of human-readable text.")
  var json: Bool = false

  @Option(name: .long, help: "Override the socket path (default: $TOUCH_CODE_SOCKET_PATH → /tmp/touch-code-<uid>.sock).")
  var socket: String?

  @Option(name: .long, help: "Client-side timeout in seconds for a single unary call.")
  var timeout: Double = 10

  var renderMode: RenderMode {
    json ? .json : .text(useColor: true)
  }

  var resolvedSocketPath: String {
    SocketDiscovery.resolve(override: socket)
  }
}
