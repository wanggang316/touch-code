import ArgumentParser
import Foundation
import TouchCodeCore
import TouchCodeIPC
import tcKit

struct WorktreeList: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "list",
    abstract: "List worktrees for a project."
  )

  @OptionGroup var globals: GlobalOptions
  @Option(name: .long, help: "Project id, name, or 'current'.")
  var project: String = "current"

  func run() async throws {
    await CommandRunner.run {
      let client = CLISession.connect(globals: globals)
      defer { Task { await client.shutdown() } }
      let projectUUID = try await AliasResolver.resolve(project, kind: .project, client: client)
      struct Params: Codable { let projectID: ProjectID }
      let result: WorktreeListPayload = try await client.call(
        .hierarchyListWorktrees,
        params: Params(projectID: ProjectID(raw: projectUUID))
      )
      try Renderer.emit(
        WorktreeListRenderable(worktrees: result.worktrees.filter { !$0.archived }),
        mode: globals.renderMode
      )
    }
  }
}

struct WorktreeCommand: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "worktree",
    abstract: "Create, switch, and remove worktrees.",
    subcommands: [
      WorktreeNew.self,
      WorktreeSwitch.self,
      WorktreeRemove.self,
    ]
  )
}

struct WorktreeNew: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "new",
    abstract: "Create a worktree entry."
  )

  @OptionGroup var globals: GlobalOptions
  @Argument(help: "Branch name.")
  var branch: String
  @Option(name: .long, help: "Project id, name, or 'current'.")
  var project: String = "current"
  @Option(name: .long, help: "Path for the worktree. Defaults to ./<branch>.")
  var path: String?
  @Option(name: .long, help: "Display name. Defaults to the branch name.")
  var name: String?

  func run() async throws {
    await CommandRunner.run {
      let client = CLISession.connect(globals: globals)
      defer { Task { await client.shutdown() } }
      let projectUUID = try await AliasResolver.resolve(project, kind: .project, client: client)
      let resolvedPath = path.map { PathResolver.absolute($0) } ?? PathResolver.defaultWorktreePath(branch: branch)
      let displayName = name ?? branch
      struct Params: Codable {
        let projectID: ProjectID
        let name: String
        let path: String
        let branch: String?
      }
      struct Result: Codable { let id: WorktreeID }
      let result: Result = try await client.call(
        .hierarchyCreateWorktree,
        params: Params(
          projectID: ProjectID(raw: projectUUID),
          name: displayName,
          path: resolvedPath,
          branch: branch
        )
      )
      try Renderer.emitObject(
        ["id": result.id.description, "name": displayName, "path": resolvedPath],
        mode: globals.renderMode
      ) { _ in
        "created worktree \(result.id.description)  \(displayName)"
      }
    }
  }
}

struct WorktreeSwitch: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "switch",
    abstract: "Activate a worktree."
  )

  @OptionGroup var globals: GlobalOptions
  @Argument(help: "Worktree id or 'current'.")
  var worktree: String

  func run() async throws {
    await CommandRunner.run {
      let client = CLISession.connect(globals: globals)
      defer { Task { await client.shutdown() } }
      let uuid = try await AliasResolver.resolve(worktree, kind: .worktree, client: client)
      struct Params: Codable { let id: UUID }
      _ = try await client.callRaw(.hierarchyActivateWorktree, params: Params(id: uuid))
      try Renderer.emit(
        IDMessage(id: uuid.uuidString, message: "switched worktree \(uuid.uuidString)"),
        mode: globals.renderMode
      )
    }
  }
}

struct WorktreeRemove: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "rm",
    abstract: "Remove a worktree entry."
  )

  @OptionGroup var globals: GlobalOptions
  @Argument(help: "Worktree id or 'current'.")
  var worktree: String
  @Option(name: .long, help: "Project id, name, or 'current'.")
  var project: String = "current"

  func run() async throws {
    await CommandRunner.run {
      let client = CLISession.connect(globals: globals)
      defer { Task { await client.shutdown() } }
      let projectUUID = try await AliasResolver.resolve(project, kind: .project, client: client)
      let worktreeUUID = try await AliasResolver.resolve(worktree, kind: .worktree, client: client)
      struct Params: Codable {
        let id: WorktreeID
        let projectID: ProjectID
      }
      _ = try await client.callRaw(
        .hierarchyRemoveWorktree,
        params: Params(id: WorktreeID(raw: worktreeUUID), projectID: ProjectID(raw: projectUUID))
      )
      try Renderer.emit(
        IDMessage(id: worktreeUUID.uuidString, message: "removed worktree \(worktreeUUID.uuidString)"),
        mode: globals.renderMode
      )
    }
  }
}

struct WorktreeListPayload: Codable { let worktrees: [Worktree] }

struct WorktreeListRenderable: Encodable, CustomStringConvertible {
  let worktrees: [Worktree]
  private enum Key: String, CodingKey { case worktrees }

  func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: Key.self)
    try container.encode(worktrees.map(WorktreeDTO.init(worktree:)), forKey: .worktrees)
  }

  var description: String {
    worktrees.isEmpty
      ? "(no worktrees)"
      : worktrees.map { "\($0.id)  \($0.name)  \($0.branch ?? "(no branch)")  \($0.path)" }
        .joined(separator: "\n")
  }
}

struct WorktreeDTO: Encodable {
  let id: String
  let name: String
  let path: String
  let branch: String?
  let selectedTabID: String?

  init(worktree: Worktree) {
    self.id = worktree.id.description
    self.name = worktree.name
    self.path = worktree.path
    self.branch = worktree.branch
    self.selectedTabID = worktree.selectedTabID?.description
  }
}
