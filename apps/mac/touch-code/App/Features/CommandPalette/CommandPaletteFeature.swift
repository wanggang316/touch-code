import ComposableArchitecture
import Foundation
import TouchCodeCore

/// Reducer for the Command Palette overlay. Owns the search query and
/// selection; rebuilds the item list on open and on each `queryChanged`
/// by running every built item through `CommandPaletteFuzzyScorer.score`.
///
/// Activation is lifted as `Delegate.activate(Kind)` for `RootFeature` to
/// pattern-match and forward to the feature action that already implements
/// the command. The palette itself executes nothing — it is pure routing.
@Reducer
struct CommandPaletteFeature {
  @ObservableState
  struct State: Equatable {
    var query: String = ""
    var selectionID: CommandPaletteItem.ID?
    var items: [CommandPaletteItem] = []
    var filtered: [CommandPaletteItem] = []
    /// Read once from the parent on `.appeared`. Held here so filtering
    /// can blend the recency bonus into each keystroke without re-reading
    /// UserDefaults on the hot path. Writes land in the parent after
    /// `.delegate(.activate(…))` completes.
    var recency: [String: TimeInterval] = [:]
    /// Source panel for Panel/Window-scoped activations. Filled from the
    /// `.appeared` payload so `RootFeature.route` can target the right
    /// panel without re-reading the catalog.
    var focusedPanelID: PanelID?
  }

  enum Action: Equatable {
    /// Parent hands in every input needed to build the list in one shot:
    /// the selection, the catalog snapshot, installed editors, the
    /// persisted recency map, the panel to treat as focused for
    /// Window/Panel-scoped actions, and a flag indicating whether that
    /// panel was derived from a real focus event (ghostty keybind) or a
    /// fallback (menu trigger — the first leaf of the selected tab).
    case appeared(
      HierarchySelection,
      Catalog,
      [EditorDescriptor],
      [String: TimeInterval],
      PanelID?,
      Bool
    )
    case queryChanged(String)
    case selectionMoved(Direction)
    case selectionCommitted
    case rowTapped(CommandPaletteItem.ID)
    case delegate(Delegate)

    enum Direction: Equatable { case up, down }
    enum Delegate: Equatable { case activate(CommandPaletteItem.Kind) }
  }

  var body: some Reducer<State, Action> {
    Reduce { state, action in
      switch action {
      case .appeared(let selection, let catalog, let descriptors, let recency, let panelID, let precise):
        state.items = CommandPaletteItems.build(
          selection: selection,
          catalog: catalog,
          editorDescriptors: descriptors,
          focusedPanelID: panelID,
          panelFocusPrecise: precise
        )
        state.focusedPanelID = panelID
        state.recency = CommandPalettePruner.prune(
          recency: recency, against: state.items
        )
        state.filtered = filter(items: state.items, query: state.query, recency: state.recency)
        state.selectionID = state.filtered.first?.id
        return .none

      case .queryChanged(let query):
        state.query = query
        state.filtered = filter(items: state.items, query: query, recency: state.recency)
        state.selectionID = state.filtered.first?.id
        return .none

      case .selectionMoved(let direction):
        moveSelection(state: &state, direction: direction)
        return .none

      case .selectionCommitted:
        guard let id = state.selectionID ?? state.filtered.first?.id,
              let item = state.filtered.first(where: { $0.id == id })
        else { return .none }
        state.recency[item.id] = Date().timeIntervalSince1970
        return .send(.delegate(.activate(item.kind)))

      case .rowTapped(let id):
        guard let item = state.filtered.first(where: { $0.id == id }) else { return .none }
        state.recency[item.id] = Date().timeIntervalSince1970
        return .send(.delegate(.activate(item.kind)))

      case .delegate:
        return .none
      }
    }
  }

  private func filter(
    items: [CommandPaletteItem],
    query: String,
    recency: [String: TimeInterval]
  ) -> [CommandPaletteItem] {
    let now = Date().timeIntervalSince1970
    let scored: [(CommandPaletteItem, Int)] = items.compactMap { item in
      guard let score = CommandPaletteFuzzyScorer.score(
        item: item, query: query, recency: recency, now: now
      ) else { return nil }
      return (item, score)
    }
    return scored
      .sorted { lhs, rhs in
        if lhs.1 != rhs.1 { return lhs.1 > rhs.1 }
        return lhs.0.title < rhs.0.title
      }
      .map(\.0)
  }

  private func moveSelection(state: inout State, direction: Action.Direction) {
    guard !state.filtered.isEmpty else {
      state.selectionID = nil
      return
    }
    let currentIndex = state.selectionID
      .flatMap { id in state.filtered.firstIndex(where: { $0.id == id }) } ?? 0
    let count = state.filtered.count
    let nextIndex: Int
    switch direction {
    case .up: nextIndex = (currentIndex - 1 + count) % count
    case .down: nextIndex = (currentIndex + 1) % count
    }
    state.selectionID = state.filtered[nextIndex].id
  }
}
