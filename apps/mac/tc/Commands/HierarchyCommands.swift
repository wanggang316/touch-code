import ArgumentParser
import Foundation
import TouchCodeCore
import TouchCodeIPC
import tcKit

// MARK: - tc project

struct ProjectCommand: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "project",
    abstract: "Project-level verbs.",
    subcommands: [ProjectAdd.self, ProjectList.self, ProjectRemove.self]
  )
}

struct ProjectList: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "list",
    abstract: "List all projects."
  )
  @OptionGroup var globals: GlobalOptions

  func run() async throws {
    let client = try CLISession.connect(globals: globals)
    defer { Task { await client.shutdown() } }
    do {
      struct Result: Codable { let projects: [Project] }
      let result: Result = try await client.call(.hierarchyListProjects, params: EmptyParams())
      try Renderer.emit(
        ProjectListRenderable(projects: result.projects),
        mode: globals.renderMode
      )
    } catch {
      CLIError.from(error).exitProcess()
    }
  }
}

struct ProjectListRenderable: Encodable, CustomStringConvertible {
  let projects: [Project]
  private enum Key: String, CodingKey { case projects }
  func encode(to encoder: Encoder) throws {
    var c = encoder.container(keyedBy: Key.self)
    try c.encode(projects, forKey: .projects)
  }
  var description: String {
    projects.isEmpty
      ? "(no projects)"
      : projects.map { "\($0.id)  \($0.name)  \($0.rootPath)" }.joined(separator: "\n")
  }
}

struct ProjectRemove: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "remove",
    abstract: "Remove a project."
  )
  @OptionGroup var globals: GlobalOptions
  @Argument var id: String

  func run() async throws {
    let client = try CLISession.connect(globals: globals)
    defer { Task { await client.shutdown() } }
    do {
      let projectUUID = try await AliasResolver.resolve(id, kind: .project, client: client)
      struct Params: Codable {
        let id: ProjectID
      }
      _ = try await client.callRaw(
        .hierarchyRemoveProject,
        params: Params(id: ProjectID(raw: projectUUID))
      )
      try Renderer.emitObject(["id": projectUUID.uuidString], mode: globals.renderMode) { _ in
        "removed project \(projectUUID.uuidString)"
      }
    } catch {
      CLIError.from(error).exitProcess()
    }
  }
}

struct ProjectAdd: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "add",
    abstract: "Add an existing directory as a project."
  )
  @OptionGroup var globals: GlobalOptions
  @Option(name: .long, help: "Display name.")
  var name: String
  @Option(name: .long, help: "Path on disk to use as the project root.")
  var path: String

  func run() async throws {
    let client = try CLISession.connect(globals: globals)
    defer { Task { await client.shutdown() } }
    do {
      struct Params: Codable {
        let name: String
        let rootPath: String
        let gitRoot: String?
      }
      struct Result: Codable { let id: ProjectID }
      let result: Result = try await client.call(
        .hierarchyAddProject,
        params: Params(
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
    subcommands: [WorktreeActivate.self, WorktreeList.self, WorktreeRemove.self]
  )
}

struct WorktreeList: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "list",
    abstract: "List worktrees in a project."
  )
  @OptionGroup var globals: GlobalOptions
  @Option(name: .long, help: "Project id (UUID or 'current').")
  var project: String = "current"

  func run() async throws {
    let client = try CLISession.connect(globals: globals)
    defer { Task { await client.shutdown() } }
    do {
      let projectUUID = try await AliasResolver.resolve(project, kind: .project, client: client)
      struct Params: Codable {
        let projectID: ProjectID
      }
      struct Result: Codable { let worktrees: [Worktree] }
      let result: Result = try await client.call(
        .hierarchyListWorktrees,
        params: Params(projectID: ProjectID(raw: projectUUID))
      )
      try Renderer.emit(
        WorktreeListRenderable(worktrees: result.worktrees),
        mode: globals.renderMode
      )
    } catch {
      CLIError.from(error).exitProcess()
    }
  }
}

struct WorktreeListRenderable: Encodable, CustomStringConvertible {
  let worktrees: [Worktree]
  private enum Key: String, CodingKey { case worktrees }
  func encode(to encoder: Encoder) throws {
    var c = encoder.container(keyedBy: Key.self)
    try c.encode(worktrees, forKey: .worktrees)
  }
  var description: String {
    worktrees.isEmpty
      ? "(no worktrees)"
      : worktrees.map { "\($0.id)  \($0.name)  \($0.branch ?? "(no branch)")  \($0.path)" }
        .joined(separator: "\n")
  }
}

struct WorktreeRemove: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "remove",
    abstract: "Remove a worktree (clears the hierarchy entry; does not delete on-disk files)."
  )
  @OptionGroup var globals: GlobalOptions
  @Option(name: .long, help: "Project id (UUID or 'current').")
  var project: String = "current"
  @Argument var id: String

  func run() async throws {
    let client = try CLISession.connect(globals: globals)
    defer { Task { await client.shutdown() } }
    do {
      let projectUUID = try await AliasResolver.resolve(project, kind: .project, client: client)
      let worktreeUUID = try await AliasResolver.resolve(id, kind: .worktree, client: client)
      struct Params: Codable {
        let id: WorktreeID
        let projectID: ProjectID
      }
      _ = try await client.callRaw(
        .hierarchyRemoveWorktree,
        params: Params(
          id: WorktreeID(raw: worktreeUUID),
          projectID: ProjectID(raw: projectUUID)
        )
      )
      try Renderer.emitObject(["id": worktreeUUID.uuidString], mode: globals.renderMode) { _ in
        "removed worktree \(worktreeUUID.uuidString)"
      }
    } catch {
      CLIError.from(error).exitProcess()
    }
  }
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
    subcommands: [TabActivate.self, TabList.self, TabClose.self]
  )
}

struct TabList: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "list",
    abstract: "List tabs in a worktree."
  )
  @OptionGroup var globals: GlobalOptions
  @Option(name: .long) var project: String = "current"
  @Option(name: .long) var worktree: String = "current"

  func run() async throws {
    let client = try CLISession.connect(globals: globals)
    defer { Task { await client.shutdown() } }
    do {
      let projectUUID = try await AliasResolver.resolve(project, kind: .project, client: client)
      let worktreeUUID = try await AliasResolver.resolve(worktree, kind: .worktree, client: client)
      struct Params: Codable {
        let worktreeID: WorktreeID
        let projectID: ProjectID
      }
      struct Result: Codable { let tabs: [Tab] }
      let result: Result = try await client.call(
        .hierarchyListTabs,
        params: Params(
          worktreeID: WorktreeID(raw: worktreeUUID),
          projectID: ProjectID(raw: projectUUID)
        )
      )
      try Renderer.emit(TabListRenderable(tabs: result.tabs), mode: globals.renderMode)
    } catch {
      CLIError.from(error).exitProcess()
    }
  }
}

struct TabListRenderable: Encodable, CustomStringConvertible {
  let tabs: [Tab]
  private enum Key: String, CodingKey { case tabs }
  func encode(to encoder: Encoder) throws {
    var c = encoder.container(keyedBy: Key.self)
    try c.encode(tabs, forKey: .tabs)
  }
  var description: String {
    tabs.isEmpty
      ? "(no tabs)"
      : tabs.map { "\($0.id)  \($0.name ?? "(untitled)")  (\($0.panes.count) panes)" }
        .joined(separator: "\n")
  }
}

struct TabClose: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "close",
    abstract: "Close a tab."
  )
  @OptionGroup var globals: GlobalOptions
  @Option(name: .long) var project: String = "current"
  @Option(name: .long) var worktree: String = "current"
  @Argument var id: String

  func run() async throws {
    let client = try CLISession.connect(globals: globals)
    defer { Task { await client.shutdown() } }
    do {
      let projectUUID = try await AliasResolver.resolve(project, kind: .project, client: client)
      let worktreeUUID = try await AliasResolver.resolve(worktree, kind: .worktree, client: client)
      let tabUUID = try await AliasResolver.resolve(id, kind: .tab, client: client)
      struct Params: Codable {
        let id: TabID
        let worktreeID: WorktreeID
        let projectID: ProjectID
      }
      _ = try await client.callRaw(
        .hierarchyCloseTab,
        params: Params(
          id: TabID(raw: tabUUID),
          worktreeID: WorktreeID(raw: worktreeUUID),
          projectID: ProjectID(raw: projectUUID)
        )
      )
      try Renderer.emitObject(["id": tabUUID.uuidString], mode: globals.renderMode) { _ in
        "closed tab \(tabUUID.uuidString)"
      }
    } catch {
      CLIError.from(error).exitProcess()
    }
  }
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

// MARK: - tc pane

struct PaneCommand: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "pane",
    abstract: "Pane-level verbs.",
    subcommands: [PaneLabel.self, PaneList.self, PaneClose.self, PaneFocus.self]
  )
}

struct PaneList: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "list",
    abstract: "List panes in a tab."
  )
  @OptionGroup var globals: GlobalOptions
  @Option(name: .long) var project: String = "current"
  @Option(name: .long) var worktree: String = "current"
  @Option(name: .long) var tab: String = "current"

  func run() async throws {
    let client = try CLISession.connect(globals: globals)
    defer { Task { await client.shutdown() } }
    do {
      let projectUUID = try await AliasResolver.resolve(project, kind: .project, client: client)
      let worktreeUUID = try await AliasResolver.resolve(worktree, kind: .worktree, client: client)
      let tabUUID = try await AliasResolver.resolve(tab, kind: .tab, client: client)
      struct Params: Codable {
        let tabID: TabID
        let worktreeID: WorktreeID
        let projectID: ProjectID
      }
      struct Result: Codable { let panes: [Pane] }
      let result: Result = try await client.call(
        .hierarchyListPanes,
        params: Params(
          tabID: TabID(raw: tabUUID),
          worktreeID: WorktreeID(raw: worktreeUUID),
          projectID: ProjectID(raw: projectUUID)
        )
      )
      try Renderer.emit(PaneListRenderable(panes: result.panes), mode: globals.renderMode)
    } catch {
      CLIError.from(error).exitProcess()
    }
  }
}

struct PaneListRenderable: Encodable, CustomStringConvertible {
  let panes: [Pane]
  private enum Key: String, CodingKey { case panes }
  func encode(to encoder: Encoder) throws {
    var c = encoder.container(keyedBy: Key.self)
    try c.encode(panes, forKey: .panes)
  }
  var description: String {
    panes.isEmpty
      ? "(no panes)"
      : panes.map { pane in
        let labels = pane.labels.sorted().joined(separator: ",")
        let labelCol = labels.isEmpty ? "" : " [\(labels)]"
        return "\(pane.id)  \(pane.workingDirectory)\(labelCol)"
      }.joined(separator: "\n")
  }
}

struct PaneLocatorArgs: ParsableArguments {
  @Option(name: .long) var project: String = "current"
  @Option(name: .long) var worktree: String = "current"
  @Option(name: .long) var tab: String = "current"
  @Argument var id: String
}

struct PaneClose: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "close",
    abstract: "Close a pane."
  )
  @OptionGroup var globals: GlobalOptions
  @OptionGroup var args: PaneLocatorArgs

  func run() async throws {
    try await PaneLocatorFlow.run(
      globals: globals,
      args: args,
      method: .hierarchyClosePane,
      verbLabel: "closed"
    )
  }
}

struct PaneFocus: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "focus",
    abstract: "Focus a pane within its tab."
  )
  @OptionGroup var globals: GlobalOptions
  @OptionGroup var args: PaneLocatorArgs

  func run() async throws {
    try await PaneLocatorFlow.run(
      globals: globals,
      args: args,
      method: .hierarchyFocusPane,
      verbLabel: "focused"
    )
  }
}

struct PaneLocatorBody: Codable, Sendable {
  let id: PaneID
  let tabID: TabID
  let worktreeID: WorktreeID
  let projectID: ProjectID
}

enum PaneLocatorFlow {
  /// Shared pane-locator flow — resolves 4 aliases then dispatches
  /// the supplied method with a `{id, tabID, worktreeID, projectID}` body.
  static func run(
    globals: GlobalOptions,
    args: PaneLocatorArgs,
    method: IPC.Method,
    verbLabel: String
  ) async throws {
    let client = try CLISession.connect(globals: globals)
    defer { Task { await client.shutdown() } }
    do {
      let projectUUID = try await AliasResolver.resolve(args.project, kind: .project, client: client)
      let worktreeUUID = try await AliasResolver.resolve(args.worktree, kind: .worktree, client: client)
      let tabUUID = try await AliasResolver.resolve(args.tab, kind: .tab, client: client)
      let paneUUID = try await AliasResolver.resolve(args.id, kind: .pane, client: client)
      _ = try await client.callRaw(
        method,
        params: PaneLocatorBody(
          id: PaneID(raw: paneUUID),
          tabID: TabID(raw: tabUUID),
          worktreeID: WorktreeID(raw: worktreeUUID),
          projectID: ProjectID(raw: projectUUID)
        )
      )
      try Renderer.emitObject(["id": paneUUID.uuidString], mode: globals.renderMode) { _ in
        "\(verbLabel) pane \(paneUUID.uuidString)"
      }
    } catch {
      CLIError.from(error).exitProcess()
    }
  }
}

struct PaneLabel: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "label",
    abstract: "Apply labels to a pane (by UUID or @label alias)."
  )
  @OptionGroup var globals: GlobalOptions
  @Argument(help: "Pane id (UUID, 'current', or @label).")
  var pane: String
  @Argument(help: "Labels to apply (whitespace-separated).")
  var labels: [String]
  @Flag(name: .long, help: "Replace the pane's label set instead of union-merging.")
  var replace: Bool = false

  func run() async throws {
    let client = try CLISession.connect(globals: globals)
    defer { Task { await client.shutdown() } }
    do {
      let uuid = try await AliasResolver.resolve(pane, kind: .pane, client: client)
      struct Params: Codable {
        let id: PaneID
        let labels: [String]
        let replace: Bool
      }
      _ = try await client.callRaw(
        .hierarchySetPaneLabels,
        params: Params(id: PaneID(raw: uuid), labels: labels, replace: replace)
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
    abstract: "Send text input to a specific pane (by UUID, @label, or 'current')."
  )
  @OptionGroup var globals: GlobalOptions
  @Argument var target: String
  @Argument(parsing: .remaining) var textPieces: [String]

  func run() async throws {
    let client = try CLISession.connect(globals: globals)
    defer { Task { await client.shutdown() } }
    let text = textPieces.joined(separator: " ")
    do {
      let uuid = try await AliasResolver.resolve(target, kind: .pane, client: client)
      struct Params: Codable {
        let paneID: PaneID
        let text: String
      }
      _ = try await client.callRaw(
        .terminalSendInput,
        params: Params(paneID: PaneID(raw: uuid), text: text)
      )
      try Renderer.emitObject(
        ["paneID": uuid.uuidString, "bytes": text.utf8.count],
        mode: globals.renderMode
      ) { obj in
        "sent \(obj["bytes"] ?? 0) bytes → \(obj["paneID"] ?? "?")"
      }
    } catch {
      CLIError.from(error).exitProcess()
    }
  }
}

struct BroadcastCommand: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "broadcast",
    abstract: "Fan-out text to a tab, worktree, or label scope."
  )
  @OptionGroup var globals: GlobalOptions
  @Option(name: .long, help: "Tab id.") var tab: String?
  @Option(name: .long, help: "Worktree id.") var worktree: String?
  @Option(name: .long, help: "Label string.") var label: String?
  @Argument(parsing: .remaining) var textPieces: [String]

  func run() async throws {
    let scopeCount = [tab, worktree, label].compactMap { $0 }.count
    if scopeCount != 1 {
      CLIError(
        code: .userError,
        message: "broadcast requires exactly one of --tab / --worktree / --label"
      ).exitProcess()
    }
    let client = try CLISession.connect(globals: globals)
    defer { Task { await client.shutdown() } }
    let text = textPieces.joined(separator: " ")
    do {
      let scope = try await resolveScope(client: client)
      struct Params: Codable {
        let scope: IPC.BroadcastScope
        let text: String
      }
      struct Result: Codable { let delivered: Int }
      let result: Result = try await client.call(
        .terminalBroadcastInput,
        params: Params(scope: scope, text: text)
      )
      try Renderer.emitObject(
        ["delivered": result.delivered, "bytes": text.utf8.count],
        mode: globals.renderMode
      ) { obj in
        "broadcast \(obj["bytes"] ?? 0) bytes → \(obj["delivered"] ?? 0) pane(s)"
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
  @Argument(help: "Method name (e.g. system.ping, hierarchy.listProjects).")
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
