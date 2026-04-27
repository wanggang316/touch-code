import Foundation
import Testing
import TouchCodeCore

@testable import touch_code

/// Pane-level helpers that the Add Hook flow relies on. The drafts
/// themselves live in SwiftUI `@State`; the constructor used to seed
/// them is exposed as a static helper so we can assert the shape of
/// the new draft without instantiating the view.
struct ProjectHooksSettingsViewAddHookTests {
  @Test
  func addHookSeedsDraftWithProjectIDScope() {
    let pid = ProjectID()
    let draft = ProjectHooksSettingsView.makeDraftHook(currentProjectID: pid)
    #expect(draft.scope == .projectID(pid))
    #expect(draft.command.isEmpty)
    #expect(draft.event == .paneReady)
    #expect(!draft.disabled)
  }

  @Test
  func addHookDraftHasFreshUUID() {
    let pid = ProjectID()
    let a = ProjectHooksSettingsView.makeDraftHook(currentProjectID: pid)
    let b = ProjectHooksSettingsView.makeDraftHook(currentProjectID: pid)
    #expect(a.id != b.id)
  }

  @Test
  func scopePickerCatalogProjectionListsCurrentProjectChildrenOnly() {
    let pid = ProjectID()
    let otherPID = ProjectID()
    let wtA = Worktree(id: WorktreeID(), name: "main", path: "/wt/a", branch: "main")
    let wtB = Worktree(id: WorktreeID(), name: "feat", path: "/wt/b", branch: "feat")
    let project = Project(
      id: pid,
      name: "Mine",
      rootPath: "/mine",
      gitRoot: "/mine",
      worktrees: [wtA, wtB]
    )
    let other = Project(id: otherPID, name: "Other", rootPath: "/other")
    let catalog = Catalog(projects: [project, other])

    let projection = ScopePickerCatalog.from(
      catalog: catalog,
      currentProjectID: pid
    )

    // Worktrees only the current Project's.
    #expect(projection.worktrees.count == 2)
    #expect(projection.worktrees.contains { $0.id == wtA.id })
    #expect(projection.worktrees.contains { $0.id == wtB.id })

    // Projects covers all open Projects.
    #expect(projection.projects.count == 2)
    #expect(projection.projects.contains { $0.id == pid })
    #expect(projection.projects.contains { $0.id == otherPID })
  }
}
