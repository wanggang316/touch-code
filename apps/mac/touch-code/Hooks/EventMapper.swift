import Foundation
import TouchCodeCore

/// Maps a `TerminalEvent` emitted by the Runtime into a fully-anchored
/// `HookEnvelope` for dispatch. Anchor enrichment (space / project /
/// worktree / tab / panel refs) walks the supplied `Catalog` snapshot.
///
/// Pure helper — no state, no side effects. The dispatcher's `attach(to:)`
/// loop calls `map(_:catalog:)` once per inbound event; a `nil` return
/// means the event has no hook-surface equivalent (e.g.
/// `.hierarchyMutated` — consumed by TCA, not by user hooks).
///
/// **Scope note:** the heavy output-match regex pass is *not* part of this
/// mapper. Output events land as `panel.output` envelopes carrying the raw
/// bytes; subscriptions with a `matchPattern` run their regex *after* the
/// fire, lifting matches into a separate `panel.outputMatch` envelope.
/// That pass lives in `HookDispatcher.fire`-path helpers (landing with the
/// remainder of M2.1 hot-path internals tracked as M2.1.1) so the mapper
/// stays pure + synchronous.
public enum EventMapper {
  public static func map(_ event: TerminalEvent, catalog: Catalog) -> HookEnvelope? {
    switch event {
    case .panelCreated(let panelID, _):
      return envelope(
        event: .panelCreated,
        data: .panelCreated(createdVia: "runtime"),
        anchors: panelAnchors(panelID, catalog: catalog)
      )

    case .panelReady(let panelID):
      return envelope(
        event: .panelReady,
        data: .panelReady(pid: nil, shell: ""),
        anchors: panelAnchors(panelID, catalog: catalog)
      )

    case .panelOutput(let panelID, let data):
      return envelope(
        event: .panelOutput,
        data: .panelOutput(output: data, outputBytes: data.count),
        anchors: panelAnchors(panelID, catalog: catalog)
      )

    case .panelIdle(let panelID, let duration):
      return envelope(
        event: .panelIdle,
        data: .panelIdle(
          idleSeconds: duration,
          sinceLastOutput: duration,
          sinceLastInput: duration
        ),
        anchors: panelAnchors(panelID, catalog: catalog)
      )

    case .panelExited(let panelID, let code, _):
      return envelope(
        event: .panelExited,
        data: .panelExited(exitCode: code),
        anchors: panelAnchors(panelID, catalog: catalog)
      )

    case .panelCrashed(let panelID, let reason):
      return envelope(
        event: .panelCrashed,
        data: .panelCrashed(reason: reason),
        anchors: panelAnchors(panelID, catalog: catalog)
      )

    case .panelClosedByTab(let panelID, let cause):
      // Surfaces as `panel.crashed` so user hooks don't treat it as a
      // clean exit. The envelope carries the auto-close cause in the
      // reason string.
      return envelope(
        event: .panelCrashed,
        data: .panelCrashed(reason: "closed by tab: \(describe(cause))"),
        anchors: panelAnchors(panelID, catalog: catalog)
      )

    case .tabActivated(let tabID):
      return envelope(
        event: .tabActivated,
        data: .tabActivated(previousTabID: nil),
        anchors: tabAnchors(tabID, catalog: catalog)
      )

    case .tabAutoClosed(let tabID, let cause):
      let (reason, count, window) = tabAutoCloseDetails(cause)
      return envelope(
        event: .tabAutoClosed,
        data: .tabAutoClosed(reason: reason, crashCount: count, windowSeconds: window),
        anchors: tabAnchors(tabID, catalog: catalog)
      )

    case .worktreeActivated(let worktreeID):
      return envelope(
        event: .worktreeActivated,
        data: .worktreeActivated(previousWorktreeID: nil),
        anchors: worktreeAnchors(worktreeID, catalog: catalog)
      )

    case .hierarchyMutated:
      // No user-facing hook surface — TCA consumes this for view refresh.
      return nil
    }
  }

  // MARK: - Anchor lookup

  public struct Anchors {
    public var space: HookEnvelope.SpaceRef?
    public var project: HookEnvelope.ProjectRef?
    public var worktree: HookEnvelope.WorktreeRef?
    public var tab: HookEnvelope.TabRef?
    public var panel: HookEnvelope.PanelRef?
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
      panel: anchors.panel,
      data: data
    )
  }

  public static func panelAnchors(_ panelID: PanelID, catalog: Catalog) -> Anchors {
    for space in catalog.spaces {
      for project in space.projects {
        for worktree in project.worktrees {
          for tab in worktree.tabs {
            for panel in tab.panels where panel.id == panelID {
              return Anchors(
                space: Self.spaceRef(space),
                project: Self.projectRef(project),
                worktree: Self.worktreeRef(worktree),
                tab: Self.tabRef(tab),
                panel: Self.panelRef(panel)
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
    // Tab does not track a selected panel directly; TabRef's field is
    // optional for exactly this reason. Left nil in M2.1.
    HookEnvelope.TabRef(id: tab.id, name: tab.name, selectedPanelID: nil)
  }

  private static func panelRef(_ panel: Panel) -> HookEnvelope.PanelRef {
    HookEnvelope.PanelRef(
      id: panel.id,
      workingDirectory: panel.workingDirectory,
      initialCommand: panel.initialCommand,
      labels: Array(panel.labels).sorted()
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
