import ComposableArchitecture
import Foundation
import SwiftUI
import TouchCodeCore

@Reducer
struct RepositorySettingsFeature {
  @ObservableState
  struct State: Equatable, Identifiable {
    let projectID: ProjectID
    var hooksLoad: HooksLoad = .idle
    var lastWriteFailure: String?

    var id: ProjectID { projectID }

    enum HooksLoad: Equatable {
      case idle
      case loading
      case loaded([HookRow])
      case failed(String)
    }
  }

  enum Action: Equatable {
    case setDefaultEditorOverride(EditorID?)
    case setWorktreeBaseDirectory(String?)
    case writeFailed(String)
    case onHooksAppear
    case hooksLoaded(Result<[HookRow], LoadError>)
    case revealHooksJSONRequested
  }

  enum LoadError: Error, Equatable {
    case loadFailed(String)
    case classificationFailed(String)
  }

  @Dependency(HierarchyClient.self) var hierarchyClient
  @Dependency(HookConfigClient.self) var hookConfigClient
  @Dependency(FinderClient.self) var finderClient

  var body: some Reducer<State, Action> {
    Reduce { state, action in
      switch action {
      case .setDefaultEditorOverride(let editorID):
        return .run { [projectID = state.projectID] send in
          do {
            try await hierarchyClient.setRepositoryDefaultEditor(projectID, editorID)
            await send(.writeFailed(""))  // Clear the error on success
          } catch {
            await send(.writeFailed(String(describing: error)))
          }
        }

      case .setWorktreeBaseDirectory(let path):
        return .run { [projectID = state.projectID] send in
          do {
            try await hierarchyClient.setRepositoryWorktreeBaseDirectory(projectID, path)
            await send(.writeFailed(""))  // Clear the error on success
          } catch {
            await send(.writeFailed(String(describing: error)))
          }
        }

      case .writeFailed(let message):
        state.lastWriteFailure = message.isEmpty ? nil : message
        return .none

      case .onHooksAppear:
        state.hooksLoad = .loading
        return .run { [projectID = state.projectID] send in
          do {
            let config = try await hookConfigClient.load()
            let catalog = await hierarchyClient.snapshot()
            let classified = try classifyHooks(
              config.subscriptions,
              for: projectID,
              catalog: catalog
            )
            let rows = classified.map { subscription, source in
              HookRowBuilder.make(from: subscription, source: source)
            }
            await send(.hooksLoaded(.success(rows)))
          } catch {
            let errorMessage = String(describing: error)
            await send(.hooksLoaded(.failure(.loadFailed(errorMessage))))
          }
        }

      case .hooksLoaded(let result):
        switch result {
        case .success(let rows):
          state.hooksLoad = .loaded(rows)
        case .failure(let error):
          state.hooksLoad = .failed(String(describing: error))
        }
        return .none

      case .revealHooksJSONRequested:
        return .run { send in
          do {
            try await hookConfigClient.ensureExists()
            let path = HookConfig.defaultURL().path
            await finderClient.reveal(path)
          } catch {
            let errorMessage = String(describing: error)
            await send(.writeFailed(errorMessage))
          }
        }
      }
    }
  }
}

// MARK: - Hook Classification Helper

/// Classify each hook subscription as Global or Repository based on its scope
/// and the current project's repo root + worktree list. The caller passes a
/// pre-fetched `Catalog` snapshot so this helper stays sync (safe to call off
/// the MainActor).
///
/// Throws LoadError.classificationFailed if the project cannot be resolved in
/// the supplied catalog.
nonisolated func classifyHooks(
  _ subscriptions: [HookSubscription],
  for projectID: ProjectID,
  catalog: Catalog
) throws -> [(HookSubscription, HookSource)] {
  // Find the project in the catalog.
  var project: Project?
  for space in catalog.spaces {
    if let found = space.projects.first(where: { $0.id == projectID }) {
      project = found
      break
    }
  }

  guard let project else {
    throw RepositorySettingsFeature.LoadError.classificationFailed(
      "Project \(projectID) not found in catalog"
    )
  }

  return subscriptions.map { subscription in
    let source =
      isRepositoryScope(subscription.scope, project: project)
      ? HookSource.repository
      : HookSource.global
    return (subscription, source)
  }
}

/// Determine if a hook subscription's scope binds it to the given project.
/// - `.anyPane`, `.paneID`, `.paneLabel`, `.tabID`, `.tabLabel` are never
///   project-specific; treat as Global.
/// - `.projectID` matches when the id equals the project's id.
/// - `.projectPathGlob` matches when the glob fires against `project.rootPath`.
/// - `.worktreeID` matches when the id appears in `project.worktrees`.
/// - `.worktreePathGlob` is strictly worktree-scoped: fires when the glob
///   matches any worktree path. Project-level scoping now belongs to
///   `.projectID` / `.projectPathGlob`, so this case no longer probes
///   `project.rootPath` — a user who wants "whole Project" writes it
///   explicitly via a Project-scoped case.
nonisolated private func isRepositoryScope(_ scope: HookSubscription.Scope, project: Project) -> Bool {
  switch scope {
  case .anyPane, .paneID, .paneLabel, .tabID, .tabLabel:
    return false

  case .projectID(let pid):
    return pid == project.id

  case .projectPathGlob(let glob):
    return doesPathMatchGlob(project.rootPath, glob: glob)

  case .worktreeID(let wtID):
    return project.worktrees.contains { $0.id == wtID }

  case .worktreePathGlob(let glob):
    return project.worktrees.contains { wtree in
      doesPathMatchGlob(wtree.path, glob: glob)
    }
  }
}

/// Simple glob matching: support `*` wildcard. Full fnmatch() is overkill
/// for the common case of "match any path under a directory tree".
nonisolated private func doesPathMatchGlob(_ path: String, glob: String) -> Bool {
  // If glob has no wildcards, require exact match.
  guard glob.contains("*") else {
    return path == glob
  }

  // Convert glob to a basic regex: escape special chars except *, then
  // replace * with .*
  let escaped =
    glob
    .replacingOccurrences(of: ".", with: "\\.")
    .replacingOccurrences(of: "?", with: "\\?")
    .replacingOccurrences(of: "[", with: "\\[")
    .replacingOccurrences(of: "]", with: "\\]")
    .replacingOccurrences(of: "(", with: "\\(")
    .replacingOccurrences(of: ")", with: "\\)")
    .replacingOccurrences(of: "+", with: "\\+")
    .replacingOccurrences(of: "^", with: "\\^")
    .replacingOccurrences(of: "$", with: "\\$")
    .replacingOccurrences(of: "|", with: "\\|")
    .replacingOccurrences(of: "{", with: "\\{")
    .replacingOccurrences(of: "}", with: "\\}")
    .replacingOccurrences(of: "*", with: ".*")

  let pattern = "^\(escaped)$"
  do {
    let regex = try NSRegularExpression(pattern: pattern)
    let range = NSRange(path.startIndex..., in: path)
    return regex.firstMatch(in: path, range: range) != nil
  } catch {
    return false
  }
}
