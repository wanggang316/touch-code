import Foundation
import Testing
import TouchCodeCore

@testable import touch_code

/// Verifies that the move-to-Global tooltip predicate
/// (`scopeBindsToCurrentProject`) correctly classifies every `Scope`
/// case against a synthetic catalog. The inline Delete confirmation
/// dialog itself lives entirely in SwiftUI; the `onDelete` callback is
/// already covered by the pane's add-hook tests via the draft-cancel
/// path. This file pins the move-tooltip helper that drives the Save-
/// time UX so future scope changes don't silently flip the tag.
struct HookEditorRowDeleteRouteTests {
  private func makeCatalog(
    paneIDs: [PaneID] = [],
    tabIDs: [TabID] = [],
    worktreeIDs: [WorktreeID] = []
  ) -> ScopePickerCatalog {
    ScopePickerCatalog(
      panes: paneIDs.map { .init(id: $0, label: "P") },
      tabs: tabIDs.map { .init(id: $0, label: "T") },
      worktrees: worktreeIDs.map { .init(id: $0, label: "W") },
      projects: []
    )
  }

  @Test
  func projectIDScopeMatchingCurrentProjectBindsToProject() {
    let pid = ProjectID()
    let result = HookEditorRow.scopeBindsToCurrentProject(
      .projectID(pid),
      currentProjectID: pid,
      catalog: makeCatalog()
    )
    #expect(result)
  }

  @Test
  func projectIDScopeMatchingDifferentProjectDoesNotBind() {
    let result = HookEditorRow.scopeBindsToCurrentProject(
      .projectID(ProjectID()),
      currentProjectID: ProjectID(),
      catalog: makeCatalog()
    )
    #expect(result == false)
  }

  @Test
  func anyPaneScopeNeverBindsToCurrentProject() {
    let result = HookEditorRow.scopeBindsToCurrentProject(
      .anyPane,
      currentProjectID: ProjectID(),
      catalog: makeCatalog()
    )
    #expect(result == false)
  }

  @Test
  func paneIDInsideCatalogBindsToProject() {
    let paneID = PaneID()
    let result = HookEditorRow.scopeBindsToCurrentProject(
      .paneID(paneID),
      currentProjectID: ProjectID(),
      catalog: makeCatalog(paneIDs: [paneID])
    )
    #expect(result)
  }

  @Test
  func worktreeIDOutsideCatalogDoesNotBind() {
    let result = HookEditorRow.scopeBindsToCurrentProject(
      .worktreeID(WorktreeID()),
      currentProjectID: ProjectID(),
      catalog: makeCatalog(worktreeIDs: [WorktreeID()])
    )
    #expect(result == false)
  }

  @Test
  func globScopesAreTreatedAsNonProject() {
    let nonProjectGlob = HookEditorRow.scopeBindsToCurrentProject(
      .projectPathGlob("**/repos/*"),
      currentProjectID: ProjectID(),
      catalog: makeCatalog()
    )
    #expect(nonProjectGlob == false)
  }
}
