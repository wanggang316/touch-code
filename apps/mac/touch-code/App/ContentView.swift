import ComposableArchitecture
import SwiftUI
import TouchCodeCore

/// Root SwiftUI host for the TCA shell. Holds the `StoreOf<RootFeature>`
/// that composes sidebar + detail sub-features (M3 + M4) and presents a
/// `NavigationSplitView`. The `HierarchyManager` is injected through
/// `@Environment` so descendant views can read `@Observable` state
/// directly.
///
/// - Leading column: `HierarchySidebarView` or `InboxSidebarPlaceholder`
///   based on `store.sidebarMode` (DEC-2).
/// - Detail column: `WorktreeDetailView` (tab bar + split viewport).
/// - Trailing inspector column: reserved for C7 M3/M4 via DEC-9; hidden by
///   default, toggled via `store.inspectorVisible`.
struct ContentView: View {
  @Bindable var store: StoreOf<RootFeature>
  let hierarchyManager: HierarchyManager
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
      HStack(spacing: 0) {
        WorktreeDetailView(
          store: store.scope(state: \.detail, action: \.detail),
          selection: store.selection,
          terminalEngine: terminalEngine
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        if store.inspectorVisible {
          Divider()
          GitViewerView(store: store.scope(state: \.gitViewer, action: \.gitViewer))
            .frame(minWidth: 420, idealWidth: 480)
        }
      }
      .toolbar {
        ToolbarItem(placement: .primaryAction) {
          Button {
            store.send(.inspectorVisibilityToggled)
          } label: {
            Image(systemName: store.inspectorVisible ? "sidebar.right" : "sidebar.right")
              .accessibilityLabel(store.inspectorVisible ? "Hide Inspector" : "Show Inspector")
          }
          .help("Toggle inspector (reserved for C7)")
        }
      }
    }
    .environment(hierarchyManager)
    .task {
      store.send(.onLaunch)
    }
    .onDisappear {
      store.send(.onQuit)
    }
    .onChange(of: store.selection) { _, _ in
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

// `InspectorPlaceholder` (0007 M4, DEC-9) was replaced in 0005 M4a by
// `GitViewerView`. Previous comment documented the reservation; the live
// viewer now occupies the slot.
