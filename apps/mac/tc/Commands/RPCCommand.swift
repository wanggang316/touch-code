import ArgumentParser
import Foundation
import TouchCodeIPC
import tcKit

struct RPCCommand: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "rpc",
    abstract: "Low-level: call one raw RPC method."
  )

  @OptionGroup var globals: GlobalOptions
  @Argument(help: "Method name, for example system.ping.")
  var method: String
  @Argument(help: "JSON params. Defaults to {}.")
  var params: String = "{}"

  func run() async throws {
    await CommandRunner.run {
      guard let ipcMethod = IPC.Method(rawValue: method) else {
        throw CLIError(code: .userError, message: "unknown method: \(method)")
      }
      let json: JSONValue
      do {
        json = try JSONDecoder().decode(JSONValue.self, from: Data(params.utf8))
      } catch {
        throw CLIError(code: .userError, message: "invalid JSON params: \(error)")
      }
      let client = CLISession.connect(globals: globals)
      defer { Task { await client.shutdown() } }
      let result = try await client.callRaw(ipcMethod, params: json)
      try Renderer.emit(JSONValueRenderable(result), mode: globals.renderMode)
    }
  }
}
