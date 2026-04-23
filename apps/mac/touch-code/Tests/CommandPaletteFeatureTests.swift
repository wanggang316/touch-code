import ComposableArchitecture
import Foundation
import Testing
import TouchCodeCore

@testable import touch_code

/// Reducer-level coverage for `CommandPaletteFeature`: item rebuild on
/// open, filtering on each keystroke, selection arithmetic, and the
/// recency write path that RootFeature persists after activation.
@MainActor
struct CommandPaletteFeatureTests {
  private static let sampleCatalog = Catalog()
  private static let sampleSelection = HierarchySelection.empty

  // MARK: - Appeared

  @Test
  func appearedBuildsItemsAndSelectsFirst() async {
    let store = TestStore(initialState: CommandPaletteFeature.State()) {
      CommandPaletteFeature()
    }
    await store.send(.appeared(Self.sampleSelection, Self.sampleCatalog, [:])) {
      $0.items = CommandPaletteItems.build(
        selection: Self.sampleSelection, catalog: Self.sampleCatalog
      )
      $0.recency = [:]
      $0.filtered = $0.items  // empty query, same order (sorted by title within band)
        .sorted { lhs, rhs in
          // Score-tied items break by title; the M2 seed items all share
          // the same priority tier, so title ascending is the final order.
          lhs.title < rhs.title
        }
      $0.selectionID = $0.filtered.first?.id
    }
  }

  @Test
  func appearedPrunesStaleDynamicRecency() async {
    let stale: [String: TimeInterval] = [
      "worktree.select.00000000-0000-0000-0000-000000000000": 1_700_000_000,
      "app.open-settings": 1_700_000_100,
    ]
    let store = TestStore(initialState: CommandPaletteFeature.State()) {
      CommandPaletteFeature()
    }
    await store.send(.appeared(Self.sampleSelection, Self.sampleCatalog, stale)) {
      $0.items = CommandPaletteItems.build(
        selection: Self.sampleSelection, catalog: Self.sampleCatalog
      )
      // The static ID survives; the dynamic one referring to a missing
      // worktree is dropped by CommandPalettePruner.
      $0.recency = ["app.open-settings": 1_700_000_100]
      $0.filtered = $0.items.sorted { $0.title < $1.title }
      $0.selectionID = $0.filtered.first?.id
    }
  }

  // MARK: - Query

  @Test
  func queryChangedFiltersItems() async {
    let initial = CommandPaletteFeature.State()
    let store = TestStore(initialState: initial) { CommandPaletteFeature() }
    await store.send(.appeared(Self.sampleSelection, Self.sampleCatalog, [:])) {
      $0.items = CommandPaletteItems.build(
        selection: Self.sampleSelection, catalog: Self.sampleCatalog
      )
      $0.filtered = $0.items.sorted { $0.title < $1.title }
      $0.selectionID = $0.filtered.first?.id
    }
    await store.send(.queryChanged("git")) {
      $0.query = "git"
      $0.filtered = $0.items.filter { $0.title.lowercased().contains("git") }
      $0.selectionID = $0.filtered.first?.id
    }
  }

  // MARK: - Activation + recency write

  @Test
  func selectionCommittedWritesRecencyAndEmitsActivate() async {
    var state = CommandPaletteFeature.State()
    state.items = CommandPaletteItems.build(
      selection: Self.sampleSelection, catalog: Self.sampleCatalog
    )
    state.filtered = state.items.sorted { $0.title < $1.title }
    state.selectionID = "app.open-settings"
    let store = TestStore(initialState: state) { CommandPaletteFeature() }
    // Non-exhaustive: state carries a wall-clock timestamp we can't
    // predict exactly; assert the contract (key present, delegate sent)
    // rather than strict state equality.
    store.exhaustivity = .off
    await store.send(.selectionCommitted)
    #expect(store.state.recency["app.open-settings"] != nil)
    await store.receive(.delegate(.activate(.openSettings)))
  }

  @Test
  func rowTappedActivatesAndRecords() async {
    var state = CommandPaletteFeature.State()
    state.items = CommandPaletteItems.build(
      selection: Self.sampleSelection, catalog: Self.sampleCatalog
    )
    state.filtered = state.items.sorted { $0.title < $1.title }
    let store = TestStore(initialState: state) { CommandPaletteFeature() }
    store.exhaustivity = .off
    await store.send(.rowTapped("git.toggle-viewer"))
    #expect(store.state.recency["git.toggle-viewer"] != nil)
    await store.receive(.delegate(.activate(.toggleGitViewer)))
  }

  // MARK: - Selection navigation

  @Test
  func selectionMovedWrapsAtBoundaries() async {
    var state = CommandPaletteFeature.State()
    state.filtered = [
      CommandPaletteItem(id: "a", title: "A", icon: "x", kind: .openSettings),
      CommandPaletteItem(id: "b", title: "B", icon: "x", kind: .toggleGitViewer),
    ]
    state.selectionID = "a"
    let store = TestStore(initialState: state) { CommandPaletteFeature() }
    await store.send(.selectionMoved(.down)) { $0.selectionID = "b" }
    await store.send(.selectionMoved(.down)) { $0.selectionID = "a" }
    await store.send(.selectionMoved(.up)) { $0.selectionID = "b" }
  }
}
