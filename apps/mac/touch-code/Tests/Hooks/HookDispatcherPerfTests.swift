import Foundation
import Testing

@testable import TouchCodeCore
@testable import touch_code

@MainActor
struct HookDispatcherPerfTests {
  /// Fire 1000 pane-output events against 50 pane-output-match
  /// subscriptions. With per-fire `NSRegularExpression(pattern:)`
  /// compilation this is a 50 000-compile hot path; with the cache it
  /// drops to 50 one-time compiles. The ceiling below passes comfortably
  /// with the cache and breaks on the uncached regression.
  @Test
  func outputMatchHotPathStaysUnderCeiling() async throws {
    let executor = FakeHookExecutor()
    let dispatcher = HookDispatcherTests.makeDispatcher(executor: executor)

    var subs: [HookSubscription] = []
    for i in 0..<50 {
      subs.append(
        HookSubscription(
          event: .paneOutputMatch,
          command: "echo \(i)",
          matchPattern: "error[-_]code[-_]\(i)",
          matchFlags: .caseInsensitive
        )
      )
    }
    dispatcher.setConfig(HookConfig(subscriptions: subs))

    let base = makeOutputEnvelope()
    let start = Date()
    for _ in 0..<1000 {
      await dispatcher.fire(base)
    }
    let elapsed = Date().timeIntervalSince(start)
    #expect(elapsed < 2.0, "output-match hot path regressed: \(elapsed)s > 2s")
  }

  /// 5000 pane events after a `.hierarchyMutated` stay under a
  /// 2-second ceiling when the anchor index caches the catalog walk.
  /// The mission's ceiling fails with the old O(S·P·W·T·P) walk.
  /// Follow-up: drop `async` or add an `await` when this grows a suspension point.
  /// For T1, suppressing the lint below to unblock.
  @Test
  // swiftlint:disable:next async_without_await
  func anchorCacheHotPathStaysUnderCeiling() async throws {
    let cache = EventMapperCache()
    let catalog = Self.largeCatalog(panesPerTab: 4, tabsPerWorktree: 4, worktreesPerProject: 4)
    let paneID = Self.firstPaneID(catalog)

    let start = Date()
    for _ in 0..<5000 {
      _ = EventMapper.map(.paneReady(paneID), catalog: catalog, cache: cache)
    }
    let elapsed = Date().timeIntervalSince(start)
    #expect(elapsed < 1.0, "anchor cache hot path regressed: \(elapsed)s > 1s")
  }

  // MARK: - Fixtures

  private func makeOutputEnvelope() -> HookEnvelope {
    HookEnvelope(
      event: .paneOutput,
      project: .init(id: ProjectID(), name: "p", rootPath: "/"),
      worktree: .init(id: WorktreeID(), name: "w", path: "/"),
      tab: .init(id: TabID()),
      pane: .init(id: PaneID(), workingDirectory: "/"),
      data: .paneOutput(output: Data("hello world nothing matches here".utf8), outputBytes: 32)
    )
  }

  static func largeCatalog(
    panesPerTab: Int,
    tabsPerWorktree: Int,
    worktreesPerProject: Int
  ) -> Catalog {
    var projects: [Project] = []
    for _ in 0..<4 {
      var worktrees: [Worktree] = []
      for _ in 0..<worktreesPerProject {
        var tabs: [Tab] = []
        for _ in 0..<tabsPerWorktree {
          var panes: [Pane] = []
          for _ in 0..<panesPerTab {
            panes.append(Pane(id: PaneID(), workingDirectory: "/tmp"))
          }
          tabs.append(Tab(id: TabID(), name: "t", panes: panes))
        }
        worktrees.append(Worktree(id: WorktreeID(), name: "w", path: "/", branch: nil, tabs: tabs))
      }
      projects.append(Project(id: ProjectID(), name: "p", rootPath: "/", worktrees: worktrees))
    }
    return Catalog(projects: projects)
  }

  static func firstPaneID(_ catalog: Catalog) -> PaneID {
    catalog.projects[0].worktrees[0].tabs[0].panes[0].id
  }
}
