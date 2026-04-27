import ComposableArchitecture
import Foundation
import SwiftUI
import TouchCodeCore

@Reducer
struct ProjectSettingsFeature {
  @ObservableState
  struct State: Equatable, Identifiable {
    let projectID: ProjectID
    /// Derived from `Project.gitRoot` at pane-materialise time. Views consult this to
    /// gate git-specific controls; the sidebar uses it to decide which sub-rows render.
    /// Seeded from `HierarchyClient.kind(of:)` by `SettingsWindowFeature.ensureProjectPane`;
    /// re-seeded when `.projectsChanged` delta reveals a kind flip on an existing pane.
    var kind: ProjectKind = .gitRepo
    var hooksLoad: HooksLoad = .idle
    /// Underlying subscriptions paired with the rows in `hooksLoad`. The
    /// Hooks pane edits these (`HookEditorRow` needs the full model, not
    /// the display-only `HookRow` projection). Refreshed every time
    /// `.onHooksAppear` succeeds.
    var hookSubscriptions: [HookSubscription] = []
    var lastWriteFailure: String?
    /// Worktree the Scripts pane targets when the user clicks Run. The
    /// parent feature (`SettingsWindowFeature`) populates this from the
    /// most-recently focused worktree of the selected Project; when nil
    /// the pane falls back to the catalog's first worktree, and disables
    /// Run when neither resolves.
    var lastFocusedWorktreeID: WorktreeID?

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
    case hooksLoaded(Result<HooksLoadPayload, LoadError>)
    case revealHooksJSONRequested
    /// Replace the entire `scripts` array. The Scripts pane writes
    /// after every edit / reorder / delete; full-array semantics match
    /// `ForEach.onMove` and `SettingsWriter.setProjectScripts`.
    case setProjectScripts([ScriptDefinition])
    /// Write a single worktree-lifecycle script (setup/archive/delete).
    case setLifecycleScript(SettingsWriter.WorktreeLifecycle, String)
    /// Run a script in the resolved worktree. On `RunScriptError` the
    /// reducer surfaces the message via `.writeFailed` so the pane's
    /// existing failure banner displays it.
    case runScriptTapped(scriptID: UUID, worktreeID: WorktreeID)
    /// Insert-or-replace a HookSubscription via `HookConfigClient.upsert`.
    /// On success re-loads via `.onHooksAppear` so the merged list refreshes.
    /// On failure dispatches `.writeFailed` with the underlying error.
    case upsertHook(HookSubscription)
    /// Delete a HookSubscription by id via `HookConfigClient.delete`. On
    /// success re-loads the merged list; on failure dispatches `.writeFailed`.
    case deleteHook(UUID)
  }

  enum LoadError: Error, Equatable {
    case loadFailed(String)
    case classificationFailed(String)
  }

  /// Combined payload returned to `.hooksLoaded`. Carries both the
  /// display-only `HookRow` projections and the editable
  /// `HookSubscription` models the Hooks pane needs to seed
  /// `HookEditorRow` drafts.
  struct HooksLoadPayload: Equatable {
    var rows: [HookRow]
    var subscriptions: [HookSubscription]
  }

  @Dependency(HierarchyClient.self) var hierarchyClient
  @Dependency(HookConfigClient.self) var hookConfigClient
  @Dependency(FinderClient.self) var finderClient
  @Dependency(SettingsWriter.self) var settingsWriter

  var body: some Reducer<State, Action> {
    Reduce { state, action in
      switch action {
      case .setDefaultEditorOverride(let editorID):
        let writer = settingsWriter.setProjectDefaultEditor
        return .run { [projectID = state.projectID] send in
          await writer(projectID, editorID)
          await send(.writeFailed(""))  // Clear the error on success
        }

      case .setWorktreeBaseDirectory(let path):
        let writer = settingsWriter.setProjectWorktreesDirectory
        return .run { [projectID = state.projectID] send in
          await writer(projectID, path)
          await send(.writeFailed(""))  // Clear the error on success
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
            let payload = HooksLoadPayload(
              rows: rows,
              subscriptions: classified.map(\.0)
            )
            await send(.hooksLoaded(.success(payload)))
          } catch {
            let errorMessage = String(describing: error)
            await send(.hooksLoaded(.failure(.loadFailed(errorMessage))))
          }
        }

      case .hooksLoaded(let result):
        switch result {
        case .success(let payload):
          state.hooksLoad = .loaded(payload.rows)
          state.hookSubscriptions = payload.subscriptions
        case .failure(let error):
          state.hooksLoad = .failed(String(describing: error))
          state.hookSubscriptions = []
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

      case .setProjectScripts(let scripts):
        let writer = settingsWriter.setProjectScripts
        return .run { [projectID = state.projectID] send in
          await writer(projectID, scripts)
          await send(.writeFailed(""))
        }

      case .setLifecycleScript(let phase, let command):
        let writer = settingsWriter.setProjectLifecycleScript
        return .run { [projectID = state.projectID] send in
          await writer(projectID, phase, command)
          await send(.writeFailed(""))
        }

      case .upsertHook(let subscription):
        let upsert = hookConfigClient.upsert
        return .run { send in
          do {
            try await upsert(subscription)
            await send(.onHooksAppear)
          } catch {
            await send(.writeFailed("Hook save failed: \(error.localizedDescription)"))
          }
        }

      case .deleteHook(let subscriptionID):
        let deleter = hookConfigClient.delete
        return .run { send in
          do {
            try await deleter(subscriptionID)
            await send(.onHooksAppear)
          } catch {
            await send(.writeFailed("Hook delete failed: \(error.localizedDescription)"))
          }
        }

      case .runScriptTapped(let scriptID, let worktreeID):
        let runner = hierarchyClient.runScript
        return .run { [projectID = state.projectID] send in
          do {
            try await runner(scriptID, projectID, worktreeID)
          } catch let error as RunScriptError {
            await send(.writeFailed(Self.runScriptErrorMessage(error)))
          } catch {
            await send(.writeFailed("Run script failed: \(error.localizedDescription)"))
          }
        }
      }
    }
  }

  /// Human-friendly mapping for the failure banner. Mirrors
  /// `RootFeature.runScriptErrorMessage` so both surfaces phrase
  /// identical errors identically.
  static func runScriptErrorMessage(_ error: RunScriptError) -> String {
    switch error {
    case .unknownScript:
      return "That script no longer exists."
    case .missingWorktree:
      return "The worktree for this script is no longer available."
    case .missingProject:
      return "The Project for this script is no longer available."
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
  let project = catalog.projects.first(where: { $0.id == projectID })

  guard let project else {
    throw ProjectSettingsFeature.LoadError.classificationFailed(
      "Project \(projectID) not found in catalog"
    )
  }

  return subscriptions.map { subscription in
    let source =
      isProjectScope(subscription.scope, project: project)
      ? HookSource.project
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
nonisolated private func isProjectScope(_ scope: HookSubscription.Scope, project: Project) -> Bool {
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
