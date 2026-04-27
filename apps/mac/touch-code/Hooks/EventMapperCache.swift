import Foundation
import TouchCodeCore

/// Lazy pane / tab / worktree → anchor lookup built from a `Catalog`
/// snapshot. Replaces the per-event O(P·W·T·P) walk inside
/// `EventMapper` — the dispatcher invalidates this on
/// `.hierarchyMutated` so subsequent events hit the index instead of
/// re-walking the catalog each fire.
///
/// Non-Sendable by design: the dispatcher is `@MainActor`, and attach
/// only touches the cache from the main actor. Anything that reads from
/// another isolation domain must hop back.
@MainActor
public final class EventMapperCache {
  private var paneIndex: [PaneID: EventMapper.Anchors] = [:]
  private var tabIndex: [TabID: EventMapper.Anchors] = [:]
  private var worktreeIndex: [WorktreeID: EventMapper.Anchors] = [:]
  private var built = false

  public init() {}

  /// Mark the index stale. Next lookup triggers a fresh catalog walk.
  public func invalidate() {
    built = false
    paneIndex.removeAll(keepingCapacity: true)
    tabIndex.removeAll(keepingCapacity: true)
    worktreeIndex.removeAll(keepingCapacity: true)
  }

  public func paneAnchors(_ id: PaneID, catalog: Catalog) -> EventMapper.Anchors {
    rebuildIfNeeded(catalog)
    return paneIndex[id] ?? EventMapper.Anchors()
  }

  public func tabAnchors(_ id: TabID, catalog: Catalog) -> EventMapper.Anchors {
    rebuildIfNeeded(catalog)
    return tabIndex[id] ?? EventMapper.Anchors()
  }

  public func worktreeAnchors(_ id: WorktreeID, catalog: Catalog) -> EventMapper.Anchors {
    rebuildIfNeeded(catalog)
    return worktreeIndex[id] ?? EventMapper.Anchors()
  }

  private func rebuildIfNeeded(_ catalog: Catalog) {
    if built { return }
    for project in catalog.projects {
      let projectRef = HookEnvelope.ProjectRef(
        id: project.id, name: project.name, rootPath: project.rootPath
      )
      for worktree in project.worktrees {
        let worktreeRef = HookEnvelope.WorktreeRef(
          id: worktree.id,
          name: worktree.name,
          path: worktree.path,
          branch: worktree.branch
        )
        worktreeIndex[worktree.id] = EventMapper.Anchors(
          project: projectRef, worktree: worktreeRef
        )
        for tab in worktree.tabs {
          let tabRef = HookEnvelope.TabRef(id: tab.id, name: tab.name, selectedPaneID: nil)
          tabIndex[tab.id] = EventMapper.Anchors(
            project: projectRef, worktree: worktreeRef, tab: tabRef
          )
          for pane in tab.panes {
            let paneRef = HookEnvelope.PaneRef(
              id: pane.id,
              workingDirectory: pane.workingDirectory,
              initialCommand: pane.initialCommand,
              labels: Array(pane.labels).sorted()
            )
            paneIndex[pane.id] = EventMapper.Anchors(
              project: projectRef,
              worktree: worktreeRef,
              tab: tabRef,
              pane: paneRef
            )
          }
        }
      }
    }
    built = true
  }
}
