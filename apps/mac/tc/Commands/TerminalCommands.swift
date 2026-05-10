import ArgumentParser
import Foundation
import TouchCodeCore
import TouchCodeIPC
import tcKit

struct SendCommand: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "send",
    abstract: "Send text to a pane.",
    discussion: """
      With one positional argument, send it to the current pane.
      With two positional arguments, the first is the target pane and the second is text.
      Text is submitted with Enter by default; pass --no-enter to only type it.
      """
  )

  @OptionGroup var globals: GlobalOptions
  @Option(name: [.customShort("p"), .long], help: "Target pane id, @label, or 'current'.")
  var pane: String?
  @Argument(parsing: .remaining, help: "Text, or target followed by text.")
  var arguments: [String] = []
  @Flag(name: .long, help: "Read text from stdin.")
  var stdin: Bool = false
  @Flag(name: .long, help: "Do not send trailing Enter after text.")
  var noEnter: Bool = false

  func run() async throws {
    await CommandRunner.run {
      let input = try CLISendInput.resolve(
        arguments: arguments,
        explicitPane: pane,
        stdin: stdin ? try StandardInput.readString() : nil,
        readsStdin: stdin,
        noEnter: noEnter
      )
      let client = CLISession.connect(globals: globals)
      defer { Task { await client.shutdown() } }
      let uuid = try await AliasResolver.resolve(input.target, kind: .pane, client: client)
      try await activatePane(uuid, client: client)
      struct Params: Codable {
        let paneID: PaneID
        let text: String
      }
      _ = try await client.callRaw(
        .terminalSendInput,
        params: Params(paneID: PaneID(raw: uuid), text: input.text)
      )
      try Renderer.emitObject(
        ["paneID": uuid.uuidString, "bytes": input.text.utf8.count],
        mode: globals.renderMode
      ) { obj in
        "sent \(obj["bytes"] ?? 0) bytes to \(obj["paneID"] ?? "?")"
      }
    }
  }
}

struct ReadCommand: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "read",
    abstract: "Read text from a pane.",
    discussion: """
      Reads the visible viewport by default. Use --screen for the active screen
      buffer, or --selection for the current selection.
      """
  )

  enum Extent: String, ExpressibleByArgument {
    case viewport
    case screen
    case selection
  }

  @OptionGroup var globals: GlobalOptions
  @Argument(help: "Pane id, @label, or 'current'.")
  var pane: String = "current"
  @Option(name: .long, help: "Text extent to read: viewport, screen, or selection.")
  var extent: Extent = .viewport
  @Flag(name: .long, help: "Shortcut for --extent screen.")
  var screen: Bool = false
  @Flag(name: .long, help: "Shortcut for --extent selection.")
  var selection: Bool = false

  func run() async throws {
    await CommandRunner.run {
      if screen && selection {
        throw CLIError(code: .userError, message: "pass at most one of --screen or --selection")
      }
      let resolvedExtent: Extent = selection ? .selection : (screen ? .screen : extent)
      let client = CLISession.connect(globals: globals)
      defer { Task { await client.shutdown() } }
      let uuid = try await AliasResolver.resolve(pane, kind: .pane, client: client)
      try await activatePane(uuid, client: client)
      struct Params: Codable {
        let paneID: PaneID
        let extent: String
      }
      struct Result: Codable {
        let text: String
      }
      let result: Result = try await client.call(
        .terminalReadText,
        params: Params(paneID: PaneID(raw: uuid), extent: resolvedExtent.rawValue)
      )
      try Renderer.emitObject(
        ["paneID": uuid.uuidString, "extent": resolvedExtent.rawValue, "text": result.text],
        mode: globals.renderMode
      ) { obj in
        obj["text"] as? String ?? ""
      }
    }
  }
}

private func activatePane(_ uuid: UUID, client: RPCClient) async throws {
  let path = try await PaneLocatorFlow.resolvePanePath(
    paneUUID: uuid,
    project: "current",
    worktree: "current",
    tab: "current",
    client: client
  )
  _ = try await client.callRaw(
    .hierarchyFocusPane,
    params: PaneLocatorBody(
      id: path.paneID,
      tabID: path.tabID,
      worktreeID: path.worktreeID,
      projectID: path.projectID
    )
  )
}

struct BroadcastCommand: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "broadcast",
    abstract: "Send text to a tab, worktree, or label scope."
  )

  @OptionGroup var globals: GlobalOptions
  @Option(name: .long, help: "Tab id or 'current'.")
  var tab: String?
  @Option(name: .long, help: "Worktree id or 'current'.")
  var worktree: String?
  @Option(name: .long, help: "Pane label.")
  var label: String?
  @Argument(parsing: .remaining, help: "Text to send.")
  var text: [String] = []
  @Flag(name: .long, help: "Read text from stdin.")
  var stdin: Bool = false
  @Flag(name: .long, help: "Do not send trailing Enter after text.")
  var noEnter: Bool = false

  func run() async throws {
    await CommandRunner.run {
      if stdin && !text.isEmpty {
        throw CLIArgumentError.conflictingTextSources
      }
      let payload = try CLICommandText.resolve(
        pieces: text,
        stdin: stdin ? try StandardInput.readString() : nil,
        readsStdin: stdin
      )
      let submitted = CLICommandText.appendEnterIfNeeded(payload, noEnter: noEnter)
      let selected = try CLIBroadcastScopeSelection.resolve(
        tab: tab,
        worktree: worktree,
        label: label
      )
      let client = CLISession.connect(globals: globals)
      defer { Task { await client.shutdown() } }
      let scope = try await resolveScope(selected, client: client)
      struct Params: Codable {
        let scope: IPC.BroadcastScope
        let text: String
      }
      struct Result: Codable { let delivered: Int }
      let result: Result = try await client.call(
        .terminalBroadcastInput,
        params: Params(scope: scope, text: submitted)
      )
      try Renderer.emitObject(
        ["delivered": result.delivered, "bytes": submitted.utf8.count],
        mode: globals.renderMode
      ) { obj in
        "broadcast \(obj["bytes"] ?? 0) bytes to \(obj["delivered"] ?? 0) pane(s)"
      }
    }
  }

  private func resolveScope(
    _ selection: CLIBroadcastScopeSelection,
    client: RPCClient
  ) async throws -> IPC.BroadcastScope {
    switch selection {
    case .tab(let value):
      let uuid = try await AliasResolver.resolve(value, kind: .tab, client: client)
      return .tab(TabID(raw: uuid))
    case .worktree(let value):
      let uuid = try await AliasResolver.resolve(value, kind: .worktree, client: client)
      return .worktree(WorktreeID(raw: uuid))
    case .label(let value):
      return .label(value)
    }
  }
}
