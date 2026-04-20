import ArgumentParser
import Darwin
import Foundation
import tcKit
import TouchCodeCore
import TouchCodeIPC

struct SystemCommand: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "system",
    abstract: "Utility verbs for talking to the running touch-code app.",
    subcommands: [
      PingCommand.self,
      VersionCommand.self,
      StatusCommand.self,
      QuitCommand.self,
      SocketsCommand.self,
    ]
  )
}

// MARK: - system ping

struct PingCommand: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "ping",
    abstract: "Probe the running app; prints 'pong' on exit 0."
  )

  @OptionGroup var globals: GlobalOptions

  func run() async throws {
    let client = try CLISession.connect(globals: globals)
    struct Pong: Codable { let pong: Bool }
    do {
      let response: Pong = try await client.call(.systemPing, params: EmptyParams())
      _ = response
      switch globals.renderMode {
      case .json:
        print(#"{"ok":true}"#)
      case .text:
        print("pong")
      }
    } catch {
      CLIError.from(error).exitProcess()
    }
  }
}

// MARK: - system version

struct VersionCommand: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "version",
    abstract: "Show tc and server versions."
  )

  @OptionGroup var globals: GlobalOptions

  func run() async throws {
    let client = try CLISession.connect(globals: globals)
    struct ServerVersion: Codable {
      let server: String
      let appBundle: String
      let protocolMajor: Int
      let protocolMinor: Int
    }
    do {
      let v: ServerVersion = try await client.call(.systemVersion, params: EmptyParams())
      try Renderer.emitObject(
        [
          "client": TouchCodeCLI.version,
          "server": v.server,
          "appBundle": v.appBundle,
          "protocol": "\(v.protocolMajor).\(v.protocolMinor)",
        ],
        mode: globals.renderMode,
        textRender: { obj in
          "tc        \(obj["client"] ?? "?")\napp       \(obj["server"] ?? "?") (\(obj["appBundle"] ?? "?"))\nprotocol  \(obj["protocol"] ?? "?")"
        }
      )
    } catch {
      CLIError.from(error).exitProcess()
    }
  }
}

// MARK: - system status

struct StatusCommand: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "status",
    abstract: "Show app runtime status (version, uptime, clients)."
  )

  @OptionGroup var globals: GlobalOptions

  func run() async throws {
    let client = try CLISession.connect(globals: globals)
    struct Status: Codable {
      let server: String
      let uptimeSeconds: Double
      let connectedClients: Int
    }
    do {
      let s: Status = try await client.call(.systemStatus, params: EmptyParams())
      try Renderer.emitObject(
        [
          "server": s.server,
          "uptimeSeconds": s.uptimeSeconds,
          "connectedClients": s.connectedClients,
        ],
        mode: globals.renderMode,
        textRender: { obj in
          let uptime = obj["uptimeSeconds"] as? Double ?? 0
          return """
          server             \(obj["server"] ?? "?")
          uptime             \(String(format: "%.1f", uptime))s
          connectedClients   \(obj["connectedClients"] ?? 0)
          """
        }
      )
    } catch {
      CLIError.from(error).exitProcess()
    }
  }
}

// MARK: - system quit

struct QuitCommand: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "quit",
    abstract: "Ask the running app to quit gracefully."
  )

  @OptionGroup var globals: GlobalOptions

  func run() async throws {
    let client = try CLISession.connect(globals: globals)
    do {
      _ = try await client.callRaw(.systemQuit, params: EmptyParams())
      print("quitting")
    } catch {
      CLIError.from(error).exitProcess()
    }
  }
}

// MARK: - system sockets

/// Local-only — does not round-trip to the app. Prints the resolved
/// socket path plus whether it is currently reachable.
struct SocketsCommand: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "sockets",
    abstract: "List discovered socket paths and reachability."
  )

  @OptionGroup var globals: GlobalOptions

  func run() throws {
    let path = globals.resolvedSocketPath
    let reachable = SocketDiscovery.isReachable(path: path)
    try Renderer.emitObject(
      [
        "path": path,
        "reachable": reachable,
        "envOverride": ProcessInfo.processInfo.environment["TOUCH_CODE_SOCKET_PATH"] ?? "",
      ],
      mode: globals.renderMode,
      textRender: { obj in
        let reach = (obj["reachable"] as? Bool == true) ? "reachable" : "not reachable"
        return "\(obj["path"] ?? "?")  \(reach)"
      }
    )
  }
}

// MARK: - Helpers

/// Empty params for methods whose request body is `{}`.
struct EmptyParams: Codable, Sendable {}

/// Shared session helper — opens a transport + builds the `RPCClient`
/// with the correct client-version info.
enum CLISession {
  static func connect(globals: GlobalOptions) throws -> RPCClient {
    let path = globals.resolvedSocketPath
    let transport: Transport
    do {
      transport = try UnixSocketTransport(path: path)
    } catch {
      throw CLIError(code: .noSocket, message: "touch-code is not running at \(path)")
    }
    return RPCClient(
      transport: transport,
      versions: RPCClient.Versions(
        clientVersion: TouchCodeCLI.version,
        clientBinary: "tc"
      )
    )
  }
}

/// CLI-layer error carrying a process exit code. Subcommands catch this
/// in their `run()` body, write the message to stderr, and call
/// `Darwin.exit(code)` directly — keeps exit-code semantics out of
/// ArgumentParser's default "ValidationError → 64, everything else → 1"
/// mapping.
struct CLIError: Error, CustomStringConvertible {
  let code: CLIExitCode
  let message: String
  var description: String { "\(message)" }

  static func from(_ error: Error) -> CLIError {
    if let cli = error as? CLIError { return cli }
    if let rpc = error as? RPCClient.RPCError {
      switch rpc {
      case .ipc(let ipc):
        return CLIError(code: CLIExitCode.from(ipc), message: ipc.displayMessage)
      case .timeout:
        return CLIError(code: .requestTimeout, message: "request timed out")
      case .noResponse:
        return CLIError(code: .internal, message: "server closed before sending a result")
      case .streamClosed:
        return CLIError(code: .internal, message: "transport stream closed")
      case .decodeFailed(let reason):
        return CLIError(code: .internal, message: "response decode failed: \(reason)")
      }
    }
    return CLIError(code: .internal, message: "\(error)")
  }

  /// Print to stderr and exit with the carried code. Subcommands call
  /// this in their top-level catch so exit codes survive
  /// ArgumentParser's default handling.
  func exitProcess() -> Never {
    FileHandle.standardError.write(Data("error: \(message)\n".utf8))
    Darwin.exit(code.rawValue)
  }
}
