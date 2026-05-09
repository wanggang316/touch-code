import ArgumentParser
import Darwin
import Foundation
import TouchCodeIPC
import tcKit

struct StatusCommand: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "status",
    abstract: "Show the running touch-code app status."
  )

  @OptionGroup var globals: GlobalOptions

  func run() async throws {
    await CommandRunner.run {
      let client = CLISession.connect(globals: globals)
      defer { Task { await client.shutdown() } }
      struct Status: Codable {
        let server: String
        let uptimeSeconds: Double
        let connectedClients: Int
      }
      let s: Status = try await client.call(.systemStatus, params: EmptyParams())
      try Renderer.emitObject(
        [
          "server": s.server,
          "uptimeSeconds": s.uptimeSeconds,
          "connectedClients": s.connectedClients,
        ],
        mode: globals.renderMode
      ) { obj in
        let uptime = obj["uptimeSeconds"] as? Double ?? 0
        return """
          server             \(obj["server"] ?? "?")
          uptime             \(String(format: "%.1f", uptime))s
          connectedClients   \(obj["connectedClients"] ?? 0)
          """
      }
    }
  }
}

struct LaunchCommand: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "launch",
    abstract: "Start touch-code and wait for its command socket."
  )

  @OptionGroup var globals: GlobalOptions
  @Option(name: .long, help: "Seconds to wait for the socket after launching.")
  var wait: Double = 10
  @Option(name: .long, help: "Bundle name to pass to `open -ga`.")
  var app: String = "touch-code"

  func run() async throws {
    await CommandRunner.run {
      let path = globals.resolvedSocketPath
      if SocketDiscovery.isReachable(path: path) {
        try Renderer.emitObject(
          ["path": path, "alreadyRunning": true],
          mode: globals.renderMode,
          textRender: { _ in "already running at \(path)" }
        )
        return
      }

      let process = Process()
      process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
      process.arguments = ["-ga", app]
      do {
        try process.run()
        process.waitUntilExit()
      } catch {
        throw CLIError(code: .launchTimeout, message: "failed to invoke /usr/bin/open: \(error)")
      }
      guard process.terminationStatus == 0 else {
        throw CLIError(
          code: .launchTimeout,
          message: "open -ga \(app) exited with status \(process.terminationStatus)"
        )
      }

      let deadline = Date(timeIntervalSinceNow: wait)
      while Date() < deadline {
        if SocketDiscovery.isReachable(path: path) {
          try Renderer.emitObject(
            ["path": path, "alreadyRunning": false],
            mode: globals.renderMode,
            textRender: { _ in "launched; socket up at \(path)" }
          )
          return
        }
        try await Task.sleep(for: .milliseconds(100))
      }
      throw CLIError(
        code: .launchTimeout,
        message: "socket \(path) did not become reachable within \(wait)s"
      )
    }
  }
}

struct DoctorCommand: ParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "doctor",
    abstract: "Check local CLI configuration and app reachability."
  )

  @OptionGroup var globals: GlobalOptions

  func run() throws {
    let path = globals.resolvedSocketPath
    let reachable = SocketDiscovery.isReachable(path: path)
    try Renderer.emitObject(
      [
        "socketPath": path,
        "socketReachable": reachable,
        "socketFromEnvironment": ProcessInfo.processInfo.environment["TOUCH_CODE_SOCKET_PATH"] != nil,
        "clientVersion": TouchCodeCLI.version,
      ],
      mode: globals.renderMode
    ) { obj in
      """
      tc                \(obj["clientVersion"] ?? "?")
      socket            \(obj["socketPath"] ?? "?")
      socketReachable   \(obj["socketReachable"] ?? false)
      """
    }
  }
}

struct CompletionCommand: ParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "completion",
    abstract: "Print shell completion script for bash, zsh, or fish."
  )

  @Argument(help: "Shell name: bash, zsh, or fish.")
  var shell: String

  func run() throws {
    let kind: CompletionShell
    switch shell.lowercased() {
    case "bash": kind = .bash
    case "zsh": kind = .zsh
    case "fish": kind = .fish
    default:
      CLIError(code: .userError, message: "unknown shell '\(shell)'").exitProcess()
    }
    print(TouchCodeCLI.completionScript(for: kind))
  }
}
