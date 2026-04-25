import Foundation
import TouchCodeCore

/// Maps a `TerminalEvent` emitted by the Runtime into a fully-anchored
/// `HookEnvelope` for dispatch. Anchor enrichment (space / project /
/// worktree / tab / pane refs) walks the supplied `Catalog` snapshot.
///
/// Pure helper — no state, no side effects. The dispatcher's `attach(to:)`
/// loop calls `map(_:catalog:)` once per inbound event; a `nil` return
/// means the event has no hook-surface equivalent (e.g.
/// `.hierarchyMutated` — consumed by TCA, not by user hooks).
///
/// **Scope note:** the heavy output-match regex pass is *not* part of this
/// mapper. Output events land as `pane.output` envelopes carrying the raw
/// bytes; subscriptions with a `matchPattern` run their regex *after* the
/// fire, lifting matches into a separate `pane.outputMatch` envelope.
/// That pass lives in `HookDispatcher.fire`-path helpers (landing with the
/// remainder of M2.1 hot-path internals tracked as M2.1.1) so the mapper
/// stays pure + synchronous.
public enum EventMapper {
  public static func map(_ event: TerminalEvent, catalog: Catalog) -> HookEnvelope? {
    map(
      event, pane: { paneAnchors($0, catalog: catalog) },
      tab: { tabAnchors($0, catalog: catalog) },
      worktree: { worktreeAnchors($0, catalog: catalog) })
  }

  /// Cache-backed variant. The dispatcher feeds an `EventMapperCache` so
  /// repeated events re-use the index and skip the O(S·P·W·T·P) walk.
  /// Invalidation is the caller's job — the dispatcher does it on
  /// `.hierarchyMutated`.
  @MainActor
  public static func map(
    _ event: TerminalEvent,
    catalog: Catalog,
    cache: EventMapperCache
  ) -> HookEnvelope? {
    map(
      event,
      pane: { cache.paneAnchors($0, catalog: catalog) },
      tab: { cache.tabAnchors($0, catalog: catalog) },
      worktree: { cache.worktreeAnchors($0, catalog: catalog) })
  }

  private static func map(
    _ event: TerminalEvent,
    pane: (PaneID) -> Anchors,
    tab: (TabID) -> Anchors,
    worktree: (WorktreeID) -> Anchors
  ) -> HookEnvelope? {
    switch event {
    case .paneCreated(let paneID, _):
      return envelope(
        event: .paneCreated,
        data: .paneCreated(createdVia: "runtime"),
        anchors: pane(paneID)
      )

    case .paneReady(let paneID):
      return envelope(
        event: .paneReady,
        data: .paneReady(pid: nil, shell: ""),
        anchors: pane(paneID)
      )

    case .paneOutput(let paneID, let data):
      return envelope(
        event: .paneOutput,
        data: .paneOutput(output: data, outputBytes: data.count),
        anchors: pane(paneID)
      )

    case .paneIdle(let paneID, let duration):
      return envelope(
        event: .paneIdle,
        data: .paneIdle(
          idleSeconds: duration,
          sinceLastOutput: duration,
          sinceLastInput: duration
        ),
        anchors: pane(paneID)
      )

    case .paneExited(let paneID, let code, _):
      return envelope(
        event: .paneExited,
        data: .paneExited(exitCode: code),
        anchors: pane(paneID)
      )

    case .paneCrashed(let paneID, let reason):
      return envelope(
        event: .paneCrashed,
        data: .paneCrashed(reason: reason),
        anchors: pane(paneID)
      )

    case .paneClosedByTab(let paneID, let cause):
      return envelope(
        event: .paneCrashed,
        data: .paneCrashed(reason: "closed by tab: \(describe(cause))"),
        anchors: pane(paneID)
      )

    case .tabActivated(let tabID):
      return envelope(
        event: .tabActivated,
        data: .tabActivated(previousTabID: nil),
        anchors: tab(tabID)
      )

    case .tabAutoClosed(let tabID, let cause):
      let (reason, count, window) = tabAutoCloseDetails(cause)
      return envelope(
        event: .tabAutoClosed,
        data: .tabAutoClosed(reason: reason, crashCount: count, windowSeconds: window),
        anchors: tab(tabID)
      )

    case .worktreeActivated(let worktreeID):
      return envelope(
        event: .worktreeActivated,
        data: .worktreeActivated(previousWorktreeID: nil),
        anchors: worktree(worktreeID)
      )

    case .hierarchyMutated,
      .paneInfoChanged,
      .paneActionRequested,
      .windowActionRequested,
      .configChanged:
      return nil
    }
  }

  // MARK: - Anchor lookup

  public struct Anchors {
    public var space: HookEnvelope.SpaceRef?
    public var project: HookEnvelope.ProjectRef?
    public var worktree: HookEnvelope.WorktreeRef?
    public var tab: HookEnvelope.TabRef?
    public var pane: HookEnvelope.PaneRef?
  }

  private static func envelope(
    event: HookEvent,
    data: HookEventData,
    anchors: Anchors
  ) -> HookEnvelope {
    HookEnvelope(
      event: event,
      space: anchors.space,
      project: anchors.project,
      worktree: anchors.worktree,
      tab: anchors.tab,
      pane: anchors.pane,
      data: data
    )
  }

  public static func paneAnchors(_ paneID: PaneID, catalog: Catalog) -> Anchors {
    for space in catalog.spaces {
      for project in space.projects {
        for worktree in project.worktrees {
          for tab in worktree.tabs {
            for pane in tab.panes where pane.id == paneID {
              return Anchors(
                space: Self.spaceRef(space),
                project: Self.projectRef(project),
                worktree: Self.worktreeRef(worktree),
                tab: Self.tabRef(tab),
                pane: Self.paneRef(pane)
              )
            }
          }
        }
      }
    }
    return Anchors()
  }

  public static func tabAnchors(_ tabID: TabID, catalog: Catalog) -> Anchors {
    for space in catalog.spaces {
      for project in space.projects {
        for worktree in project.worktrees {
          for tab in worktree.tabs where tab.id == tabID {
            return Anchors(
              space: Self.spaceRef(space),
              project: Self.projectRef(project),
              worktree: Self.worktreeRef(worktree),
              tab: Self.tabRef(tab)
            )
          }
        }
      }
    }
    return Anchors()
  }

  public static func worktreeAnchors(_ worktreeID: WorktreeID, catalog: Catalog) -> Anchors {
    for space in catalog.spaces {
      for project in space.projects {
        for worktree in project.worktrees where worktree.id == worktreeID {
          return Anchors(
            space: Self.spaceRef(space),
            project: Self.projectRef(project),
            worktree: Self.worktreeRef(worktree)
          )
        }
      }
    }
    return Anchors()
  }

  // MARK: - Ref builders

  private static func spaceRef(_ space: Space) -> HookEnvelope.SpaceRef {
    HookEnvelope.SpaceRef(id: space.id, name: space.name)
  }

  private static func projectRef(_ project: Project) -> HookEnvelope.ProjectRef {
    HookEnvelope.ProjectRef(id: project.id, name: project.name, rootPath: project.rootPath)
  }

  private static func worktreeRef(_ worktree: Worktree) -> HookEnvelope.WorktreeRef {
    HookEnvelope.WorktreeRef(
      id: worktree.id,
      name: worktree.name,
      path: worktree.path,
      branch: worktree.branch
    )
  }

  private static func tabRef(_ tab: Tab) -> HookEnvelope.TabRef {
    // Tab does not track a selected pane directly; TabRef's field is
    // optional for exactly this reason. Left nil in M2.1.
    HookEnvelope.TabRef(id: tab.id, name: tab.name, selectedPaneID: nil)
  }

  private static func paneRef(_ pane: Pane) -> HookEnvelope.PaneRef {
    HookEnvelope.PaneRef(
      id: pane.id,
      workingDirectory: pane.workingDirectory,
      initialCommand: pane.initialCommand,
      labels: Array(pane.labels).sorted()
    )
  }

  // MARK: - Cause decoders

  private static func describe(_ cause: TabAutoCloseCause) -> String {
    switch cause {
    case .crashLoop(let count, let window):
      return "crashLoop(count=\(count), window=\(window)s)"
    case .other(let reason):
      return reason
    }
  }

  private static func tabAutoCloseDetails(_ cause: TabAutoCloseCause) -> (String, Int, Int) {
    switch cause {
    case .crashLoop(let count, let window):
      return ("crashLoop", count, Int(window.rounded()))
    case .other(let reason):
      return (reason, 0, 0)
    }
  }
}
