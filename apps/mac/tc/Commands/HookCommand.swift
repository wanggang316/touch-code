import ArgumentParser
import Darwin
import Foundation
import TouchCodeCore
import TouchCodeIPC
import tcKit

struct HookCommand: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "hook",
    abstract: "Install, list, fire, and tail lifecycle hooks.",
    subcommands: [
      HookList.self,
      HookInstall.self,
      HookRemove.self,
      HookEnable.self,
      HookDisable.self,
      HookReload.self,
      HookTest.self,
      HookFire.self,
      HookRecent.self,
      HookTail.self,
      HookEdit.self,
    ]
  )
}

// MARK: - tc hook list

struct HookList: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "list",
    abstract: "List installed hook subscriptions."
  )

  @OptionGroup var globals: GlobalOptions

  @Option(name: .long, help: "Filter by event name (e.g. panel.ready).")
  var event: String?

  func run() async throws {
    let client = try CLISession.connect(globals: globals)
    defer { Task { await client.shutdown() } }
    struct Params: Codable { let eventFilter: HookEvent? }
    struct Result: Codable { let subscriptions: [HookSubscription] }
    do {
      let params = Params(eventFilter: event.flatMap { HookEvent(rawValue: $0) })
      let result: Result = try await client.call(.hookList, params: params)
      try Renderer.emit(
        HookListRenderable(subscriptions: result.subscriptions),
        mode: globals.renderMode
      )
    } catch {
      CLIError.from(error).exitProcess()
    }
  }
}

/// Text-mode formatting for `tc hook list` — one line per subscription.
struct HookListRenderable: Encodable, CustomStringConvertible {
  let subscriptions: [HookSubscription]

  func encode(to encoder: Encoder) throws {
    var c = encoder.container(keyedBy: Key.self)
    try c.encode(subscriptions, forKey: .subscriptions)
  }
  private enum Key: String, CodingKey { case subscriptions }

  var description: String {
    guard !subscriptions.isEmpty else { return "(no subscriptions)" }
    return subscriptions.map { sub in
      let enabled = sub.disabled ? "disabled" : "enabled "
      let short = String(sub.id.uuidString.prefix(8))
      let pattern = sub.matchPattern.map { "  ~= /\($0)/" } ?? ""
      return
        "\(short)  \(enabled)  \(sub.event.rawValue.padding(toLength: 20, withPad: " ", startingAt: 0))  \(sub.command)\(pattern)"
    }.joined(separator: "\n")
  }
}

// MARK: - tc hook install

struct HookInstall: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "install",
    abstract: "Install a subscription from a JSON file (or stdin with '-')."
  )

  @OptionGroup var globals: GlobalOptions

  @Argument(help: "Path to a HookSubscription JSON file, or '-' for stdin.")
  var source: String

  func run() async throws {
    let client = try CLISession.connect(globals: globals)
    defer { Task { await client.shutdown() } }
    let payload = try readPayload()
    let sub: HookSubscription
    do {
      sub = try JSONDecoder().decode(HookSubscription.self, from: payload)
    } catch {
      CLIError(code: .userError, message: "invalid HookSubscription JSON: \(error)").exitProcess()
    }
    struct Params: Codable { let subscription: HookSubscription }
    struct Result: Codable { let id: String }
    do {
      let result: Result = try await client.call(
        .hookInstall,
        params: Params(subscription: sub)
      )
      try Renderer.emitObject(["id": result.id], mode: globals.renderMode) { obj in
        "installed \(obj["id"] ?? "?")"
      }
    } catch {
      CLIError.from(error).exitProcess()
    }
  }

  private func readPayload() throws -> Data {
    if source == "-" {
      // `availableData` caps at a single buffer (~64 KB on macOS); a
      // pipe bigger than that silently truncates. `readToEnd()` drains
      // the entire stream, which is what `tc hook install -` needs.
      return try FileHandle.standardInput.readToEnd() ?? Data()
    }
    return try Data(contentsOf: URL(fileURLWithPath: source))
  }
}

// MARK: - tc hook remove

struct HookRemove: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "remove",
    abstract: "Remove a subscription by id."
  )

  @OptionGroup var globals: GlobalOptions

  @Argument(help: "Subscription UUID.")
  var id: String

  func run() async throws {
    let client = try CLISession.connect(globals: globals)
    defer { Task { await client.shutdown() } }
    guard let uuid = UUID(uuidString: id) else {
      CLIError(code: .userError, message: "not a valid UUID: \(id)").exitProcess()
    }
    struct Params: Codable { let id: UUID }
    struct Result: Codable { let removed: Bool }
    do {
      let result: Result = try await client.call(.hookRemove, params: Params(id: uuid))
      try Renderer.emitObject(["removed": result.removed], mode: globals.renderMode) { obj in
        (obj["removed"] as? Bool == true) ? "removed \(id)" : "no-op"
      }
    } catch {
      CLIError.from(error).exitProcess()
    }
  }
}

// MARK: - tc hook enable / disable

struct HookEnable: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "enable",
    abstract: "Enable a subscription."
  )
  @OptionGroup var globals: GlobalOptions
  @Argument(help: "Subscription UUID.") var id: String

  func run() async throws { try await HookEnable.run(id: id, enabled: true, globals: globals) }

  static func run(id: String, enabled: Bool, globals: GlobalOptions) async throws {
    let client = try CLISession.connect(globals: globals)
    defer { Task { await client.shutdown() } }
    guard let uuid = UUID(uuidString: id) else {
      CLIError(code: .userError, message: "not a valid UUID: \(id)").exitProcess()
    }
    struct Params: Codable {
      let id: UUID
      let enabled: Bool
    }
    do {
      _ = try await client.callRaw(.hookEnable, params: Params(id: uuid, enabled: enabled))
      try Renderer.emitObject(
        ["id": id, "enabled": enabled],
        mode: globals.renderMode
      ) { obj in
        let verb = (obj["enabled"] as? Bool == true) ? "enabled" : "disabled"
        return "\(verb) \(id)"
      }
    } catch {
      CLIError.from(error).exitProcess()
    }
  }
}

struct HookDisable: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "disable",
    abstract: "Disable a subscription."
  )
  @OptionGroup var globals: GlobalOptions
  @Argument(help: "Subscription UUID.") var id: String

  func run() async throws { try await HookEnable.run(id: id, enabled: false, globals: globals) }
}

// MARK: - tc hook reload

struct HookReload: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "reload",
    abstract: "Reload hooks.json from disk."
  )
  @OptionGroup var globals: GlobalOptions

  func run() async throws {
    let client = try CLISession.connect(globals: globals)
    defer { Task { await client.shutdown() } }
    struct Result: Codable {
      let loadedCount: Int
      let errors: [String]
    }
    do {
      let result: Result = try await client.call(.hookReload, params: EmptyParams())
      try Renderer.emitObject(
        ["loadedCount": result.loadedCount, "errors": result.errors],
        mode: globals.renderMode
      ) { obj in
        "loaded \(obj["loadedCount"] ?? 0) subscription(s)"
      }
    } catch {
      CLIError.from(error).exitProcess()
    }
  }
}

// MARK: - tc hook test

struct HookTest: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "test",
    abstract: "Fire a subscription against a synthetic envelope (for handler development)."
  )
  @OptionGroup var globals: GlobalOptions

  @Argument(help: "Subscription UUID to invoke.") var id: String

  @Option(name: .long, help: "Path to a HookEnvelope JSON payload.")
  var payload: String?

  func run() async throws {
    let client = try CLISession.connect(globals: globals)
    defer { Task { await client.shutdown() } }
    guard let uuid = UUID(uuidString: id) else {
      CLIError(code: .userError, message: "not a valid UUID: \(id)").exitProcess()
    }
    let envelope: HookEnvelope
    if let payload {
      let data = try Data(contentsOf: URL(fileURLWithPath: payload))
      envelope = try HookEnvelope.decoder().decode(HookEnvelope.self, from: data)
    } else {
      CLIError(code: .userError, message: "--payload is required for tc hook test").exitProcess()
    }
    struct Params: Codable {
      let id: UUID
      let envelope: HookEnvelope
    }
    do {
      let json = try await client.callRaw(
        .hookTest,
        params: Params(id: uuid, envelope: envelope)
      )
      try Renderer.emit(JSONValueRenderable(json), mode: globals.renderMode)
    } catch {
      CLIError.from(error).exitProcess()
    }
  }
}

// MARK: - tc hook fire

struct HookFire: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "fire",
    abstract: "Manually fire a synthetic envelope through the dispatcher."
  )
  @OptionGroup var globals: GlobalOptions

  @Option(name: .long, help: "Path to a HookEnvelope JSON payload.")
  var payload: String

  func run() async throws {
    let client = try CLISession.connect(globals: globals)
    defer { Task { await client.shutdown() } }
    let data = try Data(contentsOf: URL(fileURLWithPath: payload))
    let envelope = try HookEnvelope.decoder().decode(HookEnvelope.self, from: data)
    struct Params: Codable { let envelope: HookEnvelope }
    struct Result: Codable { let handlersRun: Int }
    do {
      let result: Result = try await client.call(.hookFire, params: Params(envelope: envelope))
      try Renderer.emitObject(
        ["handlersRun": result.handlersRun],
        mode: globals.renderMode
      ) { obj in
        "fired → \(obj["handlersRun"] ?? 0) handler(s) ran"
      }
    } catch {
      CLIError.from(error).exitProcess()
    }
  }
}

// MARK: - tc hook recent

struct HookRecent: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "recent",
    abstract: "Show recent hook firings from the ring buffer."
  )
  @OptionGroup var globals: GlobalOptions

  @Option(name: .long, help: "Maximum number of entries to return.")
  var limit: Int?

  func run() async throws {
    let client = try CLISession.connect(globals: globals)
    defer { Task { await client.shutdown() } }
    struct Params: Codable { let limit: Int? }
    do {
      let json = try await client.callRaw(.hookRecent, params: Params(limit: limit))
      try Renderer.emit(JSONValueRenderable(json), mode: globals.renderMode)
    } catch {
      CLIError.from(error).exitProcess()
    }
  }
}

// MARK: - tc hook tail (streaming)

struct HookTail: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "tail",
    abstract: "Stream hook envelopes to stdout as they fire (Ctrl-C to stop)."
  )
  @OptionGroup var globals: GlobalOptions

  @Option(
    name: .long,
    help: """
      Maximum seconds without an event before the stream is considered
      dead (default: 86400 = 24h). The server does not currently send
      keepalives (TODO(M3.1) — adding keepalive frames will let this
      shrink to a few minutes without killing legit idle tails).
      """
  )
  var idleTimeout: Double = 86_400

  func run() async throws {
    let client = try CLISession.connect(globals: globals)
    defer { Task { await client.shutdown() } }
    let envelopes = client.stream(
      .hookEvents,
      params: EmptyParams(),
      elementType: HookEnvelope.self,
      idleTimeout: .seconds(idleTimeout)
    )
    // Hoist the encoder out of the loop — single allocation for the
    // tail lifetime (M5 review suggestion).
    let encoder = HookEnvelope.encoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    do {
      for try await envelope in envelopes {
        let data = try encoder.encode(envelope)
        let json = String(bytes: data, encoding: .utf8) ?? ""
        print(json)
      }
    } catch {
      CLIError.from(error).exitProcess()
    }
  }
}

// MARK: - tc hook edit

struct HookEdit: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "edit",
    abstract: "Open ~/.config/touch-code/hooks.json in $EDITOR; reload on exit."
  )
  @OptionGroup var globals: GlobalOptions

  func run() async throws {
    let url = HookConfig.defaultURL()
    try? FileManager.default.createDirectory(
      at: url.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )
    if !FileManager.default.fileExists(atPath: url.path) {
      try HookConfigJSON.empty.write(to: url, atomically: true, encoding: .utf8)
    }
    let editor = ProcessInfo.processInfo.environment["EDITOR"] ?? "/usr/bin/vi"
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    process.arguments = [editor, url.path]
    process.standardInput = FileHandle.standardInput
    process.standardOutput = FileHandle.standardOutput
    process.standardError = FileHandle.standardError
    try process.run()
    process.waitUntilExit()
    // Trigger reload on the live server (best-effort — the app may not
    // be running, in which case the next launch will pick up the new
    // file). This is the single connect used by `tc hook edit` — the
    // command deliberately does NOT pre-connect before invoking the
    // editor, because a long interactive session would hold the socket
    // open and block other `tc` invocations. `try?` collapses both the
    // no-app case and any transient reload error into a silent skip;
    // the editor side-effect (the file on disk) is what the user cares
    // about and it's already complete by this point.
    if let client = try? CLISession.connect(globals: globals) {
      defer { Task { await client.shutdown() } }
      _ = try? await client.callRaw(.hookReload, params: EmptyParams())
    }
    print("edited \(url.path)")
  }

  private enum HookConfigJSON {
    static let empty = "{\"version\":1,\"subscriptions\":[]}\n"
  }
}

// MARK: - Rendering helpers

/// Wraps a `JSONValue` so `Renderer.emit(_:mode:)` can print it both as
/// pretty JSON and as a human-readable description.
struct JSONValueRenderable: Encodable, CustomStringConvertible {
  let value: JSONValue
  init(_ value: JSONValue) { self.value = value }

  func encode(to encoder: Encoder) throws {
    try value.encode(to: encoder)
  }

  var description: String {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    let data = (try? encoder.encode(value)) ?? Data()
    return String(bytes: data, encoding: .utf8) ?? "(unprintable)"
  }
}
