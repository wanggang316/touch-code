import Foundation
import TouchCodeCore
import TouchCodeIPC
import os

/// Handlers for `hierarchy.*` — both reads (list / describe /
/// resolveAlias) and mutations (create / activate / close / label).
///
/// Ships in M6 as the primary consumer of `HierarchyManager`'s mutation
/// surface. Extended verbs (rename / remove / split / resize / zoom /
/// prune) land in M6.1 when the corresponding CLI commands arrive.
@MainActor
final class HierarchyHandlers {
  private let manager: HierarchyManager
  private let logger = Logger(subsystem: "com.touch-code.ipc", category: "hierarchy")

  init(manager: HierarchyManager) {
    self.manager = manager
  }

  // MARK: - Error mapping

  /// Funnel every mutation catch through here so `HierarchyError` maps
  /// to the right `IPCError` variant (and therefore the right
  /// `CLIExitCode` per DEC-8) — previously every catch hardcoded
  /// `.notFound`, which masked conflict / invariant-violation cases
  /// behind exit code 2.
  private func failure(for error: Error, fallbackKind: String, fallbackID: String) -> RouterOutcome {
    if let h = error as? HierarchyError {
      switch h {
      case .notFound(let message):
        return .failed(.notFound(kind: fallbackKind, id: fallbackID.isEmpty ? message : fallbackID))
      case .invariantViolation(let message):
        return .failed(.conflict(reason: message))
      }
    }
    return .failed(.internal("\(error)"))
  }

  // MARK: - Reads

  public func listSpaces(_ params: JSONValue) async -> RouterOutcome {
    await Task.yield()
    do {
      return .unary(try JSONValue.encoded(ListSpacesPayload(spaces: manager.catalog.spaces)))
    } catch {
      return .failed(.internal("encode listSpaces: \(error)"))
    }
  }

  public func describeSpace(_ params: JSONValue) async -> RouterOutcome {
    await Task.yield()
    struct Params: Codable, Sendable { let id: SpaceID }
    let req: Params
    do {
      req = try params.decoded(as: Params.self)
    } catch {
      return .failed(.invalidParams(message: "describeSpace requires {id}", path: nil))
    }
    guard let space = manager.catalog.spaces.first(where: { $0.id == req.id }) else {
      return .failed(.notFound(kind: "space", id: req.id.description))
    }
    do {
      return .unary(try JSONValue.encoded(space))
    } catch {
      return .failed(.internal("encode describeSpace: \(error)"))
    }
  }

  /// `hierarchy.resolveAlias` — turn a string identifier (index /
  /// label / glob) into the canonical UUID for `kind`. M6 supports the
  /// minimum set the CLI drives: `current` / `.` (handled client-side by
  /// `AliasResolver`, but the server still accepts it as a defensive
  /// fallback), and panel labels. Extended forms (path glob, index) land
  /// in M6.1.
  public func resolveAlias(_ params: JSONValue) async -> RouterOutcome {
    await Task.yield()
    let request: IPC.AliasResolveRequest
    do {
      request = try params.decoded(as: IPC.AliasResolveRequest.self)
    } catch {
      return .failed(.invalidParams(message: "resolveAlias requires {kind, value}", path: nil))
    }
    if let uuid = UUID(uuidString: request.value) {
      let result = IPC.AliasResolveResult(kind: request.kind, id: uuid)
      return (try? JSONValue.encoded(result)).map(RouterOutcome.unary)
        ?? .failed(.internal("encode resolveAlias result"))
    }
    if request.kind == .panel, request.value.hasPrefix("@") {
      let label = String(request.value.dropFirst())
      let matches = Self.panelsMatchingLabel(label: label, catalog: manager.catalog)
      if matches.count == 1 {
        let result = IPC.AliasResolveResult(kind: .panel, id: matches[0])
        return (try? JSONValue.encoded(result)).map(RouterOutcome.unary)
          ?? .failed(.internal("encode resolveAlias result"))
      }
      if matches.count > 1 {
        return .failed(.conflict(reason: "label @\(label) matches \(matches.count) panels"))
      }
      return .failed(.notFound(kind: "panel", id: "@\(label)"))
    }
    return .failed(.unsupported(reason: "alias form not yet supported: \(request.value)"))
  }

  private static func panelsMatchingLabel(label: String, catalog: Catalog) -> [UUID] {
    var matches: [UUID] = []
    for space in catalog.spaces {
      for project in space.projects {
        for worktree in project.worktrees {
          for tab in worktree.tabs {
            for panel in tab.panels where panel.labels.contains(label) {
              matches.append(panel.id.raw)
            }
          }
        }
      }
    }
    return matches
  }

  // MARK: - Mutations

  public struct CreateSpaceParams: Codable, Sendable {
    public let name: String
    public let activate: Bool
  }
  public func createSpace(_ params: JSONValue) async -> RouterOutcome {
    await Task.yield()
    let request: CreateSpaceParams
    do {
      request = try params.decoded(as: CreateSpaceParams.self)
    } catch {
      return .failed(.invalidParams(message: "createSpace requires {name}", path: nil))
    }
    let id = manager.createSpace(name: request.name)
    if request.activate {
      try? manager.activateSpace(id)
    }
    do {
      return .unary(try JSONValue.encoded(SpaceIDPayload(id: id)))
    } catch {
      return .failed(.internal("encode createSpace: \(error)"))
    }
  }

  public struct ActivateParams: Codable, Sendable { public let id: UUID }
  public func activateSpace(_ params: JSONValue) async -> RouterOutcome {
    await runActivate(params) { id in
      try manager.activateSpace(SpaceID(raw: id))
    }
  }
  public func activateWorktree(_ params: JSONValue) async -> RouterOutcome {
    await runActivate(params) { id in
      try manager.activateWorktree(WorktreeID(raw: id))
    }
  }
  public func activateTab(_ params: JSONValue) async -> RouterOutcome {
    await runActivate(params) { id in
      try manager.activateTab(TabID(raw: id))
    }
  }

  private func runActivate(
    _ params: JSONValue,
    apply: (UUID) throws -> Void
  ) async -> RouterOutcome {
    await Task.yield()
    let req: ActivateParams
    do {
      req = try params.decoded(as: ActivateParams.self)
    } catch {
      return .failed(.invalidParams(message: "activate requires {id}", path: nil))
    }
    do {
      try apply(req.id)
      return .unary(.object([:]))
    } catch {
      return failure(for: error, fallbackKind: "entity", fallbackID: req.id.uuidString)
    }
  }

  public struct AddProjectParams: Codable, Sendable {
    public let spaceID: SpaceID
    public let name: String
    public let rootPath: String
    public let gitRoot: String?
  }
  public func addProject(_ params: JSONValue) async -> RouterOutcome {
    await Task.yield()
    let req: AddProjectParams
    do {
      req = try params.decoded(as: AddProjectParams.self)
    } catch {
      return .failed(.invalidParams(message: "addProject requires {spaceID, name, rootPath}", path: nil))
    }
    do {
      let id = try manager.addProject(
        to: req.spaceID,
        name: req.name,
        rootPath: req.rootPath,
        gitRoot: req.gitRoot
      )
      return .unary(try JSONValue.encoded(ProjectIDPayload(id: id)))
    } catch {
      return failure(for: error, fallbackKind: "space", fallbackID: req.spaceID.description)
    }
  }

  public struct CreateWorktreeParams: Codable, Sendable {
    public let spaceID: SpaceID
    public let projectID: ProjectID
    public let name: String
    public let path: String
    public let branch: String?
  }
  public func createWorktree(_ params: JSONValue) async -> RouterOutcome {
    await Task.yield()
    let req: CreateWorktreeParams
    do {
      req = try params.decoded(as: CreateWorktreeParams.self)
    } catch {
      return .failed(.invalidParams(message: "createWorktree requires {spaceID, projectID, name, path}", path: nil))
    }
    do {
      let id = try manager.createWorktree(
        in: req.projectID,
        in: req.spaceID,
        name: req.name,
        path: req.path,
        branch: req.branch
      )
      return .unary(try JSONValue.encoded(WorktreeIDPayload(id: id)))
    } catch {
      return failure(for: error, fallbackKind: "project", fallbackID: req.projectID.description)
    }
  }

  public struct CreateTabParams: Codable, Sendable {
    public let spaceID: SpaceID
    public let projectID: ProjectID
    public let worktreeID: WorktreeID
    public let name: String?
  }
  public func createTab(_ params: JSONValue) async -> RouterOutcome {
    await Task.yield()
    let req: CreateTabParams
    do {
      req = try params.decoded(as: CreateTabParams.self)
    } catch {
      return .failed(.invalidParams(message: "createTab requires {spaceID, projectID, worktreeID}", path: nil))
    }
    do {
      let id = try manager.createTab(
        in: req.worktreeID,
        in: req.projectID,
        in: req.spaceID,
        name: req.name
      )
      return .unary(try JSONValue.encoded(TabIDPayload(id: id)))
    } catch {
      return failure(for: error, fallbackKind: "worktree", fallbackID: req.worktreeID.description)
    }
  }

  public struct OpenPanelParams: Codable, Sendable {
    public let spaceID: SpaceID
    public let projectID: ProjectID
    public let worktreeID: WorktreeID
    public let tabID: TabID
    public let workingDirectory: String
    public let initialCommand: String?
    public let labels: [String]
  }
  public func openPanel(_ params: JSONValue) async -> RouterOutcome {
    await Task.yield()
    let req: OpenPanelParams
    do {
      req = try params.decoded(as: OpenPanelParams.self)
    } catch {
      return .failed(
        .invalidParams(
          message: "openPanel requires {spaceID, projectID, worktreeID, tabID, workingDirectory}", path: nil))
    }
    do {
      let id = try manager.openPanel(
        in: req.tabID,
        in: req.worktreeID,
        in: req.projectID,
        in: req.spaceID,
        workingDirectory: req.workingDirectory,
        initialCommand: req.initialCommand
      )
      if !req.labels.isEmpty {
        // Propagate label-apply failure rather than silently dropping —
        // a caller passing labels on create expects them to stick, and
        // .unsupported / .conflict gives the CLI an actionable error
        // through CLIExitCode.from(_:).
        do {
          try manager.setPanelLabels(id, labels: Set(req.labels), replace: true)
        } catch {
          return .failed(.internal("panel created (id=\(id)) but setPanelLabels failed: \(error)"))
        }
      }
      return .unary(try JSONValue.encoded(PanelIDPayload(id: id)))
    } catch {
      return failure(for: error, fallbackKind: "tab", fallbackID: req.tabID.description)
    }
  }

  public struct SetPanelLabelsParams: Codable, Sendable {
    public let id: PanelID
    public let labels: [String]
    public let replace: Bool
  }
  public func setPanelLabels(_ params: JSONValue) async -> RouterOutcome {
    await Task.yield()
    let req: SetPanelLabelsParams
    do {
      req = try params.decoded(as: SetPanelLabelsParams.self)
    } catch {
      return .failed(.invalidParams(message: "setPanelLabels requires {id, labels}", path: nil))
    }
    do {
      try manager.setPanelLabels(req.id, labels: Set(req.labels), replace: req.replace)
      return .unary(.object([:]))
    } catch {
      return failure(for: error, fallbackKind: "panel", fallbackID: req.id.description)
    }
  }

  // MARK: - Extended mutations (M6.1)

  public struct RenameSpaceParams: Codable, Sendable {
    public let id: SpaceID
    public let name: String
  }
  public func renameSpace(_ params: JSONValue) async -> RouterOutcome {
    await Task.yield()
    let req: RenameSpaceParams
    do { req = try params.decoded(as: RenameSpaceParams.self) } catch {
      return .failed(.invalidParams(message: "renameSpace requires {id, name}", path: nil))
    }
    do {
      try manager.renameSpace(req.id, name: req.name)
      return .unary(.object([:]))
    } catch {
      return failure(for: error, fallbackKind: "space", fallbackID: req.id.description)
    }
  }

  public struct SpaceIDParams: Codable, Sendable { public let id: SpaceID }
  public func removeSpace(_ params: JSONValue) async -> RouterOutcome {
    await Task.yield()
    let req: SpaceIDParams
    do { req = try params.decoded(as: SpaceIDParams.self) } catch {
      return .failed(.invalidParams(message: "removeSpace requires {id}", path: nil))
    }
    do {
      try manager.removeSpace(req.id)
      return .unary(.object([:]))
    } catch {
      return failure(for: error, fallbackKind: "space", fallbackID: req.id.description)
    }
  }

  public struct RemoveProjectParams: Codable, Sendable {
    public let id: ProjectID
    public let spaceID: SpaceID
  }
  public func removeProject(_ params: JSONValue) async -> RouterOutcome {
    await Task.yield()
    let req: RemoveProjectParams
    do { req = try params.decoded(as: RemoveProjectParams.self) } catch {
      return .failed(.invalidParams(message: "removeProject requires {id, spaceID}", path: nil))
    }
    do {
      try manager.removeProject(req.id, from: req.spaceID)
      return .unary(.object([:]))
    } catch {
      return failure(for: error, fallbackKind: "project", fallbackID: req.id.description)
    }
  }

  public struct RemoveWorktreeParams: Codable, Sendable {
    public let id: WorktreeID
    public let projectID: ProjectID
    public let spaceID: SpaceID
  }
  public func removeWorktree(_ params: JSONValue) async -> RouterOutcome {
    await Task.yield()
    let req: RemoveWorktreeParams
    do { req = try params.decoded(as: RemoveWorktreeParams.self) } catch {
      return .failed(.invalidParams(message: "removeWorktree requires {id, projectID, spaceID}", path: nil))
    }
    do {
      try manager.removeWorktree(req.id, from: req.projectID, in: req.spaceID)
      return .unary(.object([:]))
    } catch {
      return failure(for: error, fallbackKind: "worktree", fallbackID: req.id.description)
    }
  }

  public struct CloseTabParams: Codable, Sendable {
    public let id: TabID
    public let worktreeID: WorktreeID
    public let projectID: ProjectID
    public let spaceID: SpaceID
  }
  public func closeTab(_ params: JSONValue) async -> RouterOutcome {
    await Task.yield()
    let req: CloseTabParams
    do { req = try params.decoded(as: CloseTabParams.self) } catch {
      return .failed(
        .invalidParams(
          message: "closeTab requires {id, worktreeID, projectID, spaceID}",
          path: nil
        ))
    }
    do {
      try manager.closeTab(req.id, in: req.worktreeID, in: req.projectID, in: req.spaceID)
      return .unary(.object([:]))
    } catch {
      return failure(for: error, fallbackKind: "tab", fallbackID: req.id.description)
    }
  }

  public struct PanelLocatorParams: Codable, Sendable {
    public let id: PanelID
    public let tabID: TabID
    public let worktreeID: WorktreeID
    public let projectID: ProjectID
    public let spaceID: SpaceID
  }
  public func closePanel(_ params: JSONValue) async -> RouterOutcome {
    await Task.yield()
    let req: PanelLocatorParams
    do { req = try params.decoded(as: PanelLocatorParams.self) } catch {
      return .failed(
        .invalidParams(
          message: "closePanel requires {id, tabID, worktreeID, projectID, spaceID}",
          path: nil
        ))
    }
    do {
      try manager.closePanel(
        req.id,
        in: req.tabID,
        in: req.worktreeID,
        in: req.projectID,
        in: req.spaceID
      )
      return .unary(.object([:]))
    } catch {
      return failure(for: error, fallbackKind: "panel", fallbackID: req.id.description)
    }
  }

  public func focusPanel(_ params: JSONValue) async -> RouterOutcome {
    await Task.yield()
    let req: PanelLocatorParams
    do { req = try params.decoded(as: PanelLocatorParams.self) } catch {
      return .failed(
        .invalidParams(
          message: "focusPanel requires {id, tabID, worktreeID, projectID, spaceID}",
          path: nil
        ))
    }
    do {
      try manager.focusPanel(
        req.id,
        in: req.tabID,
        in: req.worktreeID,
        in: req.projectID,
        in: req.spaceID
      )
      return .unary(.object([:]))
    } catch {
      return failure(for: error, fallbackKind: "panel", fallbackID: req.id.description)
    }
  }

  // MARK: - Extended reads (M6.1 list-at-deeper-levels)

  public struct ListProjectsParams: Codable, Sendable { public let spaceID: SpaceID }
  public func listProjects(_ params: JSONValue) async -> RouterOutcome {
    await Task.yield()
    let req: ListProjectsParams
    do { req = try params.decoded(as: ListProjectsParams.self) } catch {
      return .failed(.invalidParams(message: "listProjects requires {spaceID}", path: nil))
    }
    guard let space = manager.catalog.spaces.first(where: { $0.id == req.spaceID }) else {
      return .failed(.notFound(kind: "space", id: req.spaceID.description))
    }
    do {
      return .unary(try JSONValue.encoded(ListProjectsPayload(projects: space.projects)))
    } catch {
      return .failed(.internal("encode listProjects: \(error)"))
    }
  }

  public struct ListWorktreesParams: Codable, Sendable {
    public let projectID: ProjectID
    public let spaceID: SpaceID
  }
  public func listWorktrees(_ params: JSONValue) async -> RouterOutcome {
    await Task.yield()
    let req: ListWorktreesParams
    do { req = try params.decoded(as: ListWorktreesParams.self) } catch {
      return .failed(.invalidParams(message: "listWorktrees requires {projectID, spaceID}", path: nil))
    }
    guard let space = manager.catalog.spaces.first(where: { $0.id == req.spaceID }),
      let project = space.projects.first(where: { $0.id == req.projectID })
    else {
      return .failed(.notFound(kind: "project", id: req.projectID.description))
    }
    do {
      return .unary(try JSONValue.encoded(ListWorktreesPayload(worktrees: project.worktrees)))
    } catch {
      return .failed(.internal("encode listWorktrees: \(error)"))
    }
  }

  public struct ListTabsParams: Codable, Sendable {
    public let worktreeID: WorktreeID
    public let projectID: ProjectID
    public let spaceID: SpaceID
  }
  public func listTabs(_ params: JSONValue) async -> RouterOutcome {
    await Task.yield()
    let req: ListTabsParams
    do { req = try params.decoded(as: ListTabsParams.self) } catch {
      return .failed(
        .invalidParams(
          message: "listTabs requires {worktreeID, projectID, spaceID}",
          path: nil
        ))
    }
    guard let space = manager.catalog.spaces.first(where: { $0.id == req.spaceID }),
      let project = space.projects.first(where: { $0.id == req.projectID }),
      let worktree = project.worktrees.first(where: { $0.id == req.worktreeID })
    else {
      return .failed(.notFound(kind: "worktree", id: req.worktreeID.description))
    }
    do {
      return .unary(try JSONValue.encoded(ListTabsPayload(tabs: worktree.tabs)))
    } catch {
      return .failed(.internal("encode listTabs: \(error)"))
    }
  }

  public struct ListPanelsParams: Codable, Sendable {
    public let tabID: TabID
    public let worktreeID: WorktreeID
    public let projectID: ProjectID
    public let spaceID: SpaceID
  }
  public func listPanels(_ params: JSONValue) async -> RouterOutcome {
    await Task.yield()
    let req: ListPanelsParams
    do { req = try params.decoded(as: ListPanelsParams.self) } catch {
      return .failed(
        .invalidParams(
          message: "listPanels requires {tabID, worktreeID, projectID, spaceID}",
          path: nil
        ))
    }
    guard let space = manager.catalog.spaces.first(where: { $0.id == req.spaceID }),
      let project = space.projects.first(where: { $0.id == req.projectID }),
      let worktree = project.worktrees.first(where: { $0.id == req.worktreeID }),
      let tab = worktree.tabs.first(where: { $0.id == req.tabID })
    else {
      return .failed(.notFound(kind: "tab", id: req.tabID.description))
    }
    do {
      return .unary(try JSONValue.encoded(ListPanelsPayload(panels: tab.panels)))
    } catch {
      return .failed(.internal("encode listPanels: \(error)"))
    }
  }
}

// MARK: - Response payload types (shared with CLI tcKit)

struct ListSpacesPayload: Codable, Sendable {
  let spaces: [Space]
}
struct ListProjectsPayload: Codable, Sendable { let projects: [Project] }
struct ListWorktreesPayload: Codable, Sendable { let worktrees: [Worktree] }
struct ListTabsPayload: Codable, Sendable { let tabs: [Tab] }
struct ListPanelsPayload: Codable, Sendable { let panels: [Panel] }
struct SpaceIDPayload: Codable, Sendable { let id: SpaceID }
struct ProjectIDPayload: Codable, Sendable { let id: ProjectID }
struct WorktreeIDPayload: Codable, Sendable { let id: WorktreeID }
struct TabIDPayload: Codable, Sendable { let id: TabID }
struct PanelIDPayload: Codable, Sendable { let id: PanelID }
