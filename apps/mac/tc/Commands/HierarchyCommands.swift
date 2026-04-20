import ArgumentParser
import Foundation
import tcKit
import TouchCodeCore
import TouchCodeIPC

// MARK: - tc space

struct SpaceCommand: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "space",
    abstract: "Space-level verbs.",
    subcommands: [SpaceList.self, SpaceCreate.self, SpaceActivate.self]
  )
}

struct SpaceList: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "list",
    abstract: "List all spaces."
  )
  @OptionGroup var globals: GlobalOptions

  func run() async throws {
    let client = try CLISession.connect(globals: globals)
    defer { Task { await client.shutdown() } }
    struct Result: Codable { let spaces: [Space] }
    do {
      let result: Result = try await client.call(.hierarchyListSpaces, params: EmptyParams())
      try Renderer.emit(
        SpaceListRenderable(spaces: result.spaces),
        mode: globals.renderMode
      )
    } catch {
      CLIError.from(error).exitProcess()
    }
  }
}

struct SpaceListRenderable: Encodable, CustomStringConvertible {
  let spaces: [Space]
  private enum Key: String, CodingKey { case spaces }
  func encode(to encoder: Encoder) throws {
    var c = encoder.container(keyedBy: Key.self)
    try c.encode(spaces, forKey: .spaces)
  }
  var description: String {
    spaces.isEmpty
      ? "(no spaces)"
      : spaces.map { "\($0.id)  \($0.name)  (\($0.projects.count) project(s))" }.joined(separator: "\n")
  }
}

struct SpaceCreate: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "create",
    abstract: "Create a new space."
  )
  @OptionGroup var globals: GlobalOptions
  @Argument var name: String
  @Flag(name: .long, help: "Activate the new space immediately.")
  var activate: Bool = false

  func run() async throws {
    let client = try CLISession.connect(globals: globals)
    defer { Task { await client.shutdown() } }
    struct Params: Codable { let name: String; let activate: Bool }
    struct Result: Codable { let id: SpaceID }
    do {
      let result: Result = try await client.call(
        .hierarchyCreateSpace,
        params: Params(name: name, activate: activate)
      )
      try Renderer.emitObject(["id": result.id.description], mode: globals.renderMode) { obj in
        "created \(obj["id"] ?? "?")"
      }
    } catch {
      CLIError.from(error).exitProcess()
    }
  }
}

struct SpaceActivate: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "activate",
    abstract: "Activate a space by id or 'current'."
  )
  @OptionGroup var globals: GlobalOptions
  @Argument var id: String

  func run() async throws {
    let client = try CLISession.connect(globals: globals)
    defer { Task { await client.shutdown() } }
    do {
      let uuid = try await AliasResolver.resolve(id, kind: .space, client: client)
      struct Params: Codable { let id: UUID }
      _ = try await client.callRaw(.hierarchyActivateSpace, params: Params(id: uuid))
      try Renderer.emitObject(["id": uuid.uuidString], mode: globals.renderMode) { obj in
        "activated \(obj["id"] ?? "?")"
      }
    } catch {
      CLIError.from(error).exitProcess()
    }
  }
}

// MARK: - tc project

struct ProjectCommand: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "project",
    abstract: "Project-level verbs.",
    subcommands: [ProjectAdd.self]
  )
}

struct ProjectAdd: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "add",
    abstract: "Add an existing directory as a project in a space."
  )
  @OptionGroup var globals: GlobalOptions
  @Option(name: .long, help: "Space id (UUID or 'current').")
  var space: String = "current"
  @Option(name: .long, help: "Display name.")
  var name: String
  @Option(name: .long, help: "Path on disk to use as the project root.")
  var path: String

  func run() async throws {
    let client = try CLISession.connect(globals: globals)
    defer { Task { await client.shutdown() } }
    do {
      let spaceID = try await AliasResolver.resolve(space, kind: .space, client: client)
      struct Params: Codable {
        let spaceID: SpaceID
        let name: String
        let rootPath: String
        let gitRoot: String?
      }
      struct Result: Codable { let id: ProjectID }
      let result: Result = try await client.call(
        .hierarchyAddProject,
        params: Params(
          spaceID: SpaceID(raw: spaceID),
          name: name,
          rootPath: path,
          gitRoot: nil
        )
      )
      try Renderer.emitObject(["id": result.id.description], mode: globals.renderMode) { obj in
        "added project \(obj["id"] ?? "?")"
      }
    } catch {
      CLIError.from(error).exitProcess()
    }
  }
}

// MARK: - tc worktree

struct WorktreeCommand: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "worktree",
    abstract: "Worktree-level verbs.",
    subcommands: [WorktreeActivate.self]
  )
}

struct WorktreeActivate: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "activate",
    abstract: "Activate a worktree by id or 'current'."
  )
  @OptionGroup var globals: GlobalOptions
  @Argument var id: String

  func run() async throws {
    let client = try CLISession.connect(globals: globals)
    defer { Task { await client.shutdown() } }
    do {
      let uuid = try await AliasResolver.resolve(id, kind: .worktree, client: client)
      struct Params: Codable { let id: UUID }
      _ = try await client.callRaw(.hierarchyActivateWorktree, params: Params(id: uuid))
      try Renderer.emitObject(["id": uuid.uuidString], mode: globals.renderMode) { obj in
        "activated worktree \(obj["id"] ?? "?")"
      }
    } catch {
      CLIError.from(error).exitProcess()
    }
  }
}

// MARK: - tc tab

struct TabCommand: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "tab",
    abstract: "Tab-level verbs.",
    subcommands: [TabActivate.self]
  )
}

struct TabActivate: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "activate",
    abstract: "Activate a tab by id or 'current'."
  )
  @OptionGroup var globals: GlobalOptions
  @Argument var id: String

  func run() async throws {
    let client = try CLISession.connect(globals: globals)
    defer { Task { await client.shutdown() } }
    do {
      let uuid = try await AliasResolver.resolve(id, kind: .tab, client: client)
      struct Params: Codable { let id: UUID }
      _ = try await client.callRaw(.hierarchyActivateTab, params: Params(id: uuid))
      try Renderer.emitObject(["id": uuid.uuidString], mode: globals.renderMode) { obj in
        "activated tab \(obj["id"] ?? "?")"
      }
    } catch {
      CLIError.from(error).exitProcess()
    }
  }
}

// MARK: - tc panel

struct PanelCommand: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "panel",
    abstract: "Panel-level verbs.",
    subcommands: [PanelLabel.self]
  )
}

struct PanelLabel: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "label",
    abstract: "Apply labels to a panel (by UUID or @label alias)."
  )
  @OptionGroup var globals: GlobalOptions
  @Argument(help: "Panel id (UUID, 'current', or @label).")
  var panel: String
  @Argument(help: "Labels to apply (whitespace-separated).")
  var labels: [String]
  @Flag(name: .long, help: "Replace the panel's label set instead of union-merging.")
  var replace: Bool = false

  func run() async throws {
    let client = try CLISession.connect(globals: globals)
    defer { Task { await client.shutdown() } }
    do {
      let uuid = try await AliasResolver.resolve(panel, kind: .panel, client: client)
      struct Params: Codable {
        let id: PanelID
        let labels: [String]
        let replace: Bool
      }
      _ = try await client.callRaw(
        .hierarchySetPanelLabels,
        params: Params(id: PanelID(raw: uuid), labels: labels, replace: replace)
      )
      try Renderer.emitObject(
        ["id": uuid.uuidString, "labels": labels],
        mode: globals.renderMode
      ) { obj in
        "labeled \(obj["id"] ?? "?") with \(labels.joined(separator: ","))"
      }
    } catch {
      CLIError.from(error).exitProcess()
    }
  }
}

// MARK: - tc send / tc broadcast

struct SendCommand: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "send",
    abstract: "Send text input to a specific panel (by UUID, @label, or 'current')."
  )
  @OptionGroup var globals: GlobalOptions
  @Argument var target: String
  @Argument(parsing: .remaining) var textPieces: [String]

  func run() async throws {
    let client = try CLISession.connect(globals: globals)
    defer { Task { await client.shutdown() } }
    let text = textPieces.joined(separator: " ")
    do {
      let uuid = try await AliasResolver.resolve(target, kind: .panel, client: client)
      struct Params: Codable { let panelID: PanelID; let text: String }
      _ = try await client.callRaw(
        .terminalSendInput,
        params: Params(panelID: PanelID(raw: uuid), text: text)
      )
      try Renderer.emitObject(
        ["panelID": uuid.uuidString, "bytes": text.utf8.count],
        mode: globals.renderMode
      ) { obj in
        "sent \(obj["bytes"] ?? 0) bytes → \(obj["panelID"] ?? "?")"
      }
    } catch {
      CLIError.from(error).exitProcess()
    }
  }
}

struct BroadcastCommand: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "broadcast",
    abstract: "Fan-out text to a tab, worktree, space, or label scope."
  )
  @OptionGroup var globals: GlobalOptions
  @Option(name: .long, help: "Tab id.")           var tab: String?
  @Option(name: .long, help: "Worktree id.")      var worktree: String?
  @Option(name: .long, help: "Space id.")         var space: String?
  @Option(name: .long, help: "Label string.")     var label: String?
  @Argument(parsing: .remaining) var textPieces: [String]

  func run() async throws {
    let scopeCount = [tab, worktree, space, label].compactMap { $0 }.count
    if scopeCount != 1 {
      CLIError(
        code: .userError,
        message: "broadcast requires exactly one of --tab / --worktree / --space / --label"
      ).exitProcess()
    }
    let client = try CLISession.connect(globals: globals)
    defer { Task { await client.shutdown() } }
    let text = textPieces.joined(separator: " ")
    do {
      let scope = try await resolveScope(client: client)
      struct Params: Codable { let scope: IPC.BroadcastScope; let text: String }
      struct Result: Codable { let delivered: Int }
      let result: Result = try await client.call(
        .terminalBroadcastInput,
        params: Params(scope: scope, text: text)
      )
      try Renderer.emitObject(
        ["delivered": result.delivered, "bytes": text.utf8.count],
        mode: globals.renderMode
      ) { obj in
        "broadcast \(obj["bytes"] ?? 0) bytes → \(obj["delivered"] ?? 0) panel(s)"
      }
    } catch {
      CLIError.from(error).exitProcess()
    }
  }

  private func resolveScope(client: RPCClient) async throws -> IPC.BroadcastScope {
    if let tab {
      let uuid = try await AliasResolver.resolve(tab, kind: .tab, client: client)
      return .tab(TabID(raw: uuid))
    }
    if let worktree {
      let uuid = try await AliasResolver.resolve(worktree, kind: .worktree, client: client)
      return .worktree(WorktreeID(raw: uuid))
    }
    if let space {
      let uuid = try await AliasResolver.resolve(space, kind: .space, client: client)
      return .space(SpaceID(raw: uuid))
    }
    if let label {
      return .label(label)
    }
    fatalError("unreachable — scope count validated above")
  }
}

// MARK: - tc rpc — C4 D9 debug escape hatch

struct RPCCommand: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "rpc",
    abstract: "Low-level: invoke an arbitrary RPC method. Parses JSON params from argv."
  )
  @OptionGroup var globals: GlobalOptions
  @Argument(help: "Method name (e.g. system.ping, hierarchy.listSpaces).")
  var method: String
  @Argument(help: "Params as JSON (default: {}).")
  var params: String = "{}"

  func run() async throws {
    guard let ipcMethod = IPC.Method(rawValue: method) else {
      CLIError(code: .userError, message: "unknown method: \(method)").exitProcess()
    }
    let data = Data(params.utf8)
    let json: JSONValue
    do {
      json = try JSONDecoder().decode(JSONValue.self, from: data)
    } catch {
      CLIError(code: .userError, message: "invalid JSON params: \(error)").exitProcess()
    }
    let client = try CLISession.connect(globals: globals)
    defer { Task { await client.shutdown() } }
    do {
      let result = try await client.callRaw(ipcMethod, params: json)
      try Renderer.emit(JSONValueRenderable(result), mode: globals.renderMode)
    } catch {
      CLIError.from(error).exitProcess()
    }
  }
}
