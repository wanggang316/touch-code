import ComposableArchitecture
import SwiftUI
import TouchCodeCore

/// Root SwiftUI host for the TCA shell. Holds the `StoreOf<RootFeature>`
/// that composes sidebar + detail sub-features (M3 + M4) and presents a
/// two-column `NavigationSplitView`. The `HierarchyManager` and
/// `TerminalEngine` are injected through `@Environment` so descendant
/// views can read `@Observable` state directly — TCA state stays focused
/// on selection + transient UI.
///
/// Inspector column is deliberately out of the initial topology. DEC-2
/// (M3 kickoff) will decide whether C6 inbox ships as a mode-swap of the
/// leading column or a trailing inspector panel.
struct ContentView: View {
  @Bindable var store: StoreOf<RootFeature>
  let hierarchyManager: HierarchyManager
  let terminalEngine: TerminalEngine
  @State private var columnVisibility: NavigationSplitViewVisibility = .all

  var body: some View {
    NavigationSplitView(columnVisibility: $columnVisibility) {
      SidebarPlaceholder(selection: store.selection)
        .navigationSplitViewColumnWidth(min: 220, ideal: 260, max: 320)
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
  }
}

/// Placeholder sidebar — M3 replaces with `HierarchySidebarView` reading
/// `HierarchyManager.catalog` from the environment.
private struct SidebarPlaceholder: View {
  let selection: HierarchySelection

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      Text("Sidebar")
        .font(.headline)
      Text("Sidebar renders Space → Project → Worktree in M3.")
        .font(.caption)
        .foregroundStyle(.secondary)
      Divider()
      VStack(alignment: .leading, spacing: 4) {
        Text("Selection").font(.caption.bold())
        Text("Space:    \(selection.spaceID?.description ?? "—")")
          .font(.caption.monospaced())
        Text("Project:  \(selection.projectID?.description ?? "—")")
          .font(.caption.monospaced())
        Text("Worktree: \(selection.worktreeID?.description ?? "—")")
          .font(.caption.monospaced())
      }
      Spacer()
    }
    .padding()
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
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
