import ComposableArchitecture
import SwiftUI
import TouchCodeCore

/// Root SwiftUI host for the TCA shell. Holds the `StoreOf<RootFeature>`
/// that composes sidebar + detail sub-features (M3 + M4) and presents a
/// two-column `NavigationSplitView`. The `HierarchyManager` is injected
/// through `@Environment` so descendant views can read `@Observable`
/// state directly — TCA state stays focused on selection + transient UI.
///
/// Per DEC-2, the leading column swaps between `HierarchySidebarView`
/// (default) and `InboxSidebarPlaceholder` (C6 M5 replacement) based on
/// `store.sidebarMode` — instead of a third NavigationSplitView column.
struct ContentView: View {
  @Bindable var store: StoreOf<RootFeature>
  let hierarchyManager: HierarchyManager
  /// Held for the view-hierarchy lifetime; M4's `SplitViewportView` will
  /// read it via ancestor state when looking up `PanelSurface` instances.
  /// Not observed here.
  let terminalEngine: TerminalEngine
  @State private var columnVisibility: NavigationSplitViewVisibility = .all

  var body: some View {
    NavigationSplitView(columnVisibility: $columnVisibility) {
      sidebarColumn
        .navigationSplitViewColumnWidth(min: 220, ideal: 260, max: 320)
        .toolbar {
          ToolbarItem(placement: .primaryAction) {
            modeTogglePicker
          }
        }
    } detail: {
      DetailPlaceholder(selection: store.selection, lastEvent: store.lastEvent)
    }
    .environment(hierarchyManager)
    .task {
      store.send(.onLaunch)
    }
    .onDisappear {
      store.send(.onQuit)
    }
    .onChange(of: store.selection) { _, _ in
      // Prune expansion sets when the catalog changes. Using the selection
      // stream as a coarse "something structural changed" trigger — the
      // catalog is read synchronously on render, so stale expansion IDs
      // disappear next layout pass regardless; this just keeps the set
      // tidy so it doesn't grow unbounded across long sessions.
      let currentSpaceIDs = Set(hierarchyManager.catalog.spaces.map(\.id))
      let currentProjectIDs = Set(
        hierarchyManager.catalog.spaces.flatMap { $0.projects.map(\.id) }
      )
      store.send(.sidebar(.pruneExpansionSets(
        currentSpaceIDs: currentSpaceIDs,
        currentProjectIDs: currentProjectIDs
      )))
    }
  }

  @ViewBuilder
  private var sidebarColumn: some View {
    switch store.sidebarMode {
    case .hierarchy:
      HierarchySidebarView(
        store: store.scope(state: \.sidebar, action: \.sidebar),
        currentSelection: store.selection
      )
    case .inbox:
      InboxSidebarPlaceholder()
    }
  }

  private var modeTogglePicker: some View {
    Picker("Sidebar", selection: Binding(
      get: { store.sidebarMode },
      set: { store.send(.sidebarModeChanged($0)) }
    )) {
      Image(systemName: "folder")
        .accessibilityLabel("Hierarchy")
        .tag(SidebarMode.hierarchy)
      Image(systemName: "bell.badge")
        .accessibilityLabel("Inbox")
        .tag(SidebarMode.inbox)
    }
    .pickerStyle(.segmented)
    .help("Toggle sidebar: Hierarchy ↔ Inbox")
  }
}

/// Placeholder detail — M4 replaces with `WorktreeDetailView`.
private struct DetailPlaceholder: View {
  let selection: HierarchySelection
  let lastEvent: RootFeature.LastEventMarker?

  var body: some View {
    VStack(spacing: 12) {
      if selection.worktreeID == nil {
        Text("Select a Worktree")
          .font(.title2)
          .foregroundStyle(.secondary)
      } else {
        Text("Worktree Detail")
          .font(.title2)
        Text("Tab bar + split viewport land in M4.")
          .font(.caption)
          .foregroundStyle(.secondary)
      }
      if let lastEvent {
        Text("last engine event: \(String(describing: lastEvent))")
          .font(.caption.monospaced())
          .foregroundStyle(.tertiary)
      }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
  }
}
