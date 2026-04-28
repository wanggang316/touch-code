import ComposableArchitecture
import Foundation
import SwiftUI
import Testing
import TouchCodeCore

@testable import touch_code

/// Regression tests for the T3 main-window shortcuts
/// (`MainWindowCommands` + `RootFeature` wiring).
///
/// `Commands` structs are hard to exercise end-to-end from a unit test —
/// SwiftUI owns their body evaluation — so these tests split the contract
/// into two layers:
///
/// 1. **Structural** — `MainWindowCommands` must hold only the root store.
///    Any `@Dependency(...)` fields re-introduce the PR-#13 ⌘E crash: the
///    `Commands` struct resolves against `liveValue`, whose
///    `HierarchyClient.snapshot` is a `fatalError` stub.
///
/// 2. **Behavioural** — each shortcut's `store.send(...)` target lands in a
///    reducer branch with the expected effect. These mirror the shortcut-to-
///    action contract so a rename or action-semantics change is caught here
///    rather than in live-smoke-test territory.
@MainActor
struct MainWindowCommandsTests {
  // MARK: - Structural

  /// If this count ever exceeds 2, a `@Dependency`, `@Environment`, or other client-resolving
  /// stored property has been added to `MainWindowCommands`. `@Dependency` in particular
  /// resolves to `liveValue` inside a SwiftUI `Commands` struct (TCA's `withDependencies`
  /// injection does not scope here), so any client whose `liveValue` has a `fatalError`
  /// stub crashes on first button tap. The two allowed fields are `store` and the inert
  /// resolved-shortcut snapshot `shortcuts` — neither carries a fatalError client.
  @Test
  func mainWindowCommandsHasNoDependencyFields() {
    let store = Store(initialState: RootFeature.State()) { RootFeature() }
    let commands = MainWindowCommands(store: { store }, shortcuts: [:])
    let mirror = Mirror(reflecting: commands)
    let labels = mirror.children.compactMap(\.label)
    #expect(mirror.children.count == 2)
    #expect(Set(labels) == ["store", "shortcuts"])
  }

  // MARK: - ⌘O (Open in Default Editor)

  @Test
  func commandODispatchesOpenDefaultForCurrentWorktreeAndForwardsToEditor() async {
    // Mirrors the ⌘O button body: `store.send(.openDefaultForCurrentWorktreeRequested)`.
    // The reducer resolves the Worktree path from selection + the catalog
    // snapshot and forwards to `EditorFeature.Action.openDefaultInCurrentWorktreeRequested`.
    let projectID = ProjectID()
    let worktreeID = WorktreeID()
    let worktree = Worktree(id: worktreeID, name: "w", path: "/repo")
    let project = Project(
      id: projectID, name: "p", rootPath: "/repo", gitRoot: "/repo",
      worktrees: [worktree]
    )
    let catalog = Catalog(projects: [project])

    var initial = RootFeature.State()
    initial.selection = HierarchySelection(
      projectID: projectID, worktreeID: worktreeID
    )

    let store = TestStore(initialState: initial) {
      RootFeature()
    } withDependencies: {
      $0.terminalClient.events = { AsyncStream { $0.finish() } }
      $0.hierarchyClient.selectionChanges = { AsyncStream { $0.finish() } }
      $0.hierarchyClient.snapshot = { catalog }
      $0.editorClient = EditorClient.testValue
      // Downstream resolveDefault → .openRequested → editorClient.open fires
      // a chain this test does not care about. Stub `open` to a harmless
      // Finder-like result so the unimplemented testValue doesn't record an
      // issue. The assertion below only proves the root-to-editor hop.
      $0.editorClient.open = { _, id in
        EditorChoice(
          id: id ?? EditorFeature.finderEditorID,
          displayName: "x",
          binaryPath: nil
        )
      }
    }
    store.exhaustivity = .off

    await store.send(.openDefaultForCurrentWorktreeRequested)
    await store.receive(
      .editor(
        .openDefaultInCurrentWorktreeRequested(
          projectID: projectID,
          worktreeID: worktreeID,
          worktreePath: "/repo"
        )))
  }

  @Test
  func commandOIsNoOpWhenNoWorktreeSelected() async {
    // The ⌘O button is `.disabled(!hasActiveWorktree)` in the view, but
    // the reducer must also be defensive: a stale selection without a
    // worktreeID short-circuits to `.none`, never reaching the snapshot
    // read. Proves the reducer guard that makes ⌘O crash-proof even if
    // the view-level `disabled` drifts.
    let store = TestStore(initialState: RootFeature.State()) {
      RootFeature()
    } withDependencies: {
      $0.terminalClient.events = { AsyncStream { $0.finish() } }
      $0.hierarchyClient.selectionChanges = { AsyncStream { $0.finish() } }
      // snapshot intentionally unstubbed — a selection-less dispatch must not
      // reach it. If the reducer regresses and calls through, the test fails
      // loudly on `unimplemented`.
    }
    store.exhaustivity = .off

    await store.send(.openDefaultForCurrentWorktreeRequested)
    // No receive → no .editor(...) dispatched.
    await store.finish()
  }

  // MARK: - ⌘⇧G (Toggle Git Viewer)

  @Test
  func commandShiftGDispatchesGitViewerToggleForCurrentWorktree() async {
    // Mirrors the ⌘⇧G button body:
    // `store.send(.gitViewerToggledForCurrentWorktree)`. The reducer reads
    // current visibility from the catalog and writes the flipped value via
    // `hierarchyClient.setWorktreeGitViewerVisible`.
    let projectID = ProjectID()
    let worktreeID = WorktreeID()
    let worktree = Worktree(
      id: worktreeID, name: "w", path: "/repo",
      gitViewerVisible: false
    )
    let project = Project(
      id: projectID, name: "p", rootPath: "/repo", gitRoot: "/repo",
      worktrees: [worktree]
    )
    let catalog = Catalog(projects: [project])

    var initial = RootFeature.State()
    initial.selection = HierarchySelection(
      projectID: projectID, worktreeID: worktreeID
    )

    let recorded = LockIsolated<[(WorktreeID, Bool)]>([])
    let store = TestStore(initialState: initial) {
      RootFeature()
    } withDependencies: {
      $0.hierarchyClient.snapshot = { catalog }
      $0.hierarchyClient.setWorktreeGitViewerVisible = { wt, v in
        recorded.withValue { $0.append((wt, v)) }
      }
    }

    await store.send(.gitViewerToggledForCurrentWorktree)
    await store.finish()
    #expect(recorded.value.count == 1)
    #expect(recorded.value.first?.0 == worktreeID)
    #expect(recorded.value.first?.1 == true)
  }

}
