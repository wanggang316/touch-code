import ArgumentParser
import Foundation
import TouchCodeCore
import TouchCodeIPC
import tcKit

struct ListCommand: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "ls",
    abstract: "List projects, worktrees, tabs, and panes.",
    discussion: """
      Use 'tc ls' as the first discovery command. It prints the full hierarchy so
      you do not have to walk projects, worktrees, tabs, and panes one command at
      a time.
      """
  )

  @OptionGroup var globals: GlobalOptions
  @Option(name: .long, help: "Restrict output to one project id, name, or 'current'.")
  var project: String?

  func run() async throws {
    await CommandRunner.run {
      let client = CLISession.connect(globals: globals)
      defer { Task { await client.shutdown() } }
      let tree = try await HierarchyTree.load(client: client)
      let projects: [Project]
      if let project {
        let uuid = try await AliasResolver.resolve(project, kind: .project, client: client)
        projects = tree.projects.filter { $0.id.raw == uuid }
        if projects.isEmpty {
          throw CLIError(code: .notFound, message: "project \(uuid.uuidString) not found")
        }
      } else {
        projects = tree.projects
      }
      try Renderer.emit(HierarchyTreeRenderable(projects: projects), mode: globals.renderMode)
    }
  }
}

struct HierarchyTree: Codable, Sendable {
  let projects: [Project]

  static func load(client: RPCClient) async throws -> HierarchyTree {
    let payload: ProjectListPayload = try await client.call(
      .hierarchyListProjects,
      params: EmptyParams()
    )
    return HierarchyTree(projects: payload.projects)
  }

  func locatePane(_ paneID: PaneID) -> PanePath? {
    for project in projects {
      for worktree in project.worktrees {
        for tab in worktree.tabs where tab.panes.contains(where: { $0.id == paneID }) {
          return PanePath(projectID: project.id, worktreeID: worktree.id, tabID: tab.id, paneID: paneID)
        }
      }
    }
    return nil
  }
}

struct PanePath: Sendable {
  let projectID: ProjectID
  let worktreeID: WorktreeID
  let tabID: TabID
  let paneID: PaneID
}

struct HierarchyTreeRenderable: Encodable, CustomStringConvertible {
  let projects: [Project]

  private enum Key: String, CodingKey { case projects }

  func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: Key.self)
    try container.encode(projects.map(HierarchyProjectDTO.init(project:)), forKey: .projects)
  }

  var description: String {
    guard !projects.isEmpty else { return "(no projects)" }
    var lines: [String] = []
    for project in projects {
      let projectMark = project.selectedWorktreeID == nil ? " " : "*"
      lines.append("\(projectMark) project \(project.name)  \(project.id)")
      lines.append("  path \(project.rootPath)")
      for worktree in project.worktrees where !worktree.archived {
        let worktreeMark = worktree.id == project.selectedWorktreeID ? "*" : " "
        let branch = worktree.branch ?? "(no branch)"
        lines.append("  \(worktreeMark) worktree \(worktree.name)  \(branch)  \(worktree.id)")
        lines.append("    path \(worktree.path)")
        for tab in worktree.tabs {
          let tabMark = tab.id == worktree.selectedTabID ? "*" : " "
          let title = tab.name ?? tab.cachedDisplayTitle ?? "(untitled)"
          lines.append("    \(tabMark) tab \(title)  \(tab.id)")
          for pane in tab.panes {
            let labels = pane.labels.sorted()
            let labelSuffix = labels.isEmpty ? "" : "  @\(labels.joined(separator: ",@"))"
            lines.append("        pane \(pane.id)  \(pane.workingDirectory)\(labelSuffix)")
          }
        }
      }
    }
    return lines.joined(separator: "\n")
  }
}

struct HierarchyProjectDTO: Encodable {
  let id: String
  let name: String
  let rootPath: String
  let gitRoot: String?
  let selectedWorktreeID: String?
  let worktrees: [HierarchyWorktreeDTO]

  init(project: Project) {
    self.id = project.id.description
    self.name = project.name
    self.rootPath = project.rootPath
    self.gitRoot = project.gitRoot
    self.selectedWorktreeID = project.selectedWorktreeID?.description
    self.worktrees = project.worktrees.filter { !$0.archived }.map(HierarchyWorktreeDTO.init(worktree:))
  }
}

struct HierarchyWorktreeDTO: Encodable {
  let id: String
  let name: String
  let path: String
  let branch: String?
  let selectedTabID: String?
  let tabs: [HierarchyTabDTO]

  init(worktree: Worktree) {
    self.id = worktree.id.description
    self.name = worktree.name
    self.path = worktree.path
    self.branch = worktree.branch
    self.selectedTabID = worktree.selectedTabID?.description
    self.tabs = worktree.tabs.map(HierarchyTabDTO.init(tab:))
  }
}

struct HierarchyTabDTO: Encodable {
  let id: String
  let name: String?
  let cachedDisplayTitle: String?
  let panes: [HierarchyPaneDTO]

  init(tab: Tab) {
    self.id = tab.id.description
    self.name = tab.name
    self.cachedDisplayTitle = tab.cachedDisplayTitle
    self.panes = tab.panes.map(HierarchyPaneDTO.init(pane:))
  }
}

struct HierarchyPaneDTO: Encodable {
  let id: String
  let workingDirectory: String
  let labels: [String]

  init(pane: Pane) {
    self.id = pane.id.description
    self.workingDirectory = pane.workingDirectory
    self.labels = pane.labels.sorted()
  }
}
