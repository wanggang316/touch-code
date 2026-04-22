import ComposableArchitecture
import SwiftUI
import TouchCodeCore

/// Root SwiftUI host for the TCA shell. Holds the `StoreOf<RootFeature>`
/// that composes sidebar + detail sub-features (M3 + M4) and presents a
/// two-column `NavigationSplitView`. The `HierarchyManager` is injected
/// through `@Environment` so descendant views can read `@Observable`
/// state directly — TCA state stays focused on selection + transient UI.
///
/// The leading column always renders `HierarchySidebarView` (T0 removed
/// the Hierarchy ↔ Inbox Picker; T1 removed the dead `sidebarMode` /
/// `.inbox` scope plumbing `RootFeature` carried forward). Notifications
/// are reached through the Header bell (T2), which is a fresh
/// `WorktreeHeader`-owned feature rather than a reuse of
/// `InboxSidebarFeature`.
/// `inboxStore` is injected alongside `hierarchyManager` so the sidebar
/// view can read `inbox.inbox` directly for Worktree / Project unread dots.
struct ContentView: View {
  @Bindable var store: StoreOf<RootFeature>
  let hierarchyManager: HierarchyManager
  let settingsStore: SettingsStore
  /// Injected so `HierarchySidebarView` can read `inboxStore.inbox` directly
  /// for Worktree / Project unread-dot aggregation — matches the
  /// `HierarchyManager`-through-`@Environment` pattern already in use.
  let inboxStore: InboxStore
  @Environment(\.openWindow) private var openWindow
  @State private var columnVisibility: NavigationSplitViewVisibility = .all

  /// Transient toast for editor-open outcomes (success + failure). Non-nil = visible;
  /// auto-clears after a short window via `.task(id:)`.
  @State private var lastEditorToast: EditorToast?

  enum EditorToast: Equatable {
    case opened(String)
    case failed(String)
  }

  var body: some View {
    NavigationSplitView(columnVisibility: $columnVisibility) {
      HierarchySidebarView(
        store: store.scope(state: \.sidebar, action: \.sidebar),
        currentSelection: store.selection
      )
      .navigationSplitViewColumnWidth(min: 220, ideal: 260, max: 320)
    } detail: {
      WorktreeDetailView(
        store: store.scope(state: \.detail, action: \.detail),
        selection: store.selection,
        editorStore: store.scope(state: \.editor, action: \.editor),
        headerStore: store.scope(state: \.worktreeHeader, action: \.worktreeHeader),
        gitViewerStore: store.scope(state: \.gitViewer, action: \.gitViewer),
        // Live read against the observed `hierarchyManager.catalog` — any
        // write to `Worktree.gitViewerVisible` (⌘⇧G, Header button, or
        // external API) re-renders this view without needing a reducer
        // projection to stay in sync.
        overlayVisible: store.state.gitViewerOverlayVisible(in: hierarchyManager.catalog)
      )
      .frame(maxWidth: .infinity, maxHeight: .infinity)
      .overlay(alignment: .bottom) { editorToastOverlay }
      .toolbar {
        ToolbarItem(placement: .primaryAction) {
          Button {
            openWindow(id: TouchCodeApp.settingsWindowID)
          } label: {
            Image(systemName: "gearshape")
              .accessibilityLabel("Settings")
          }
          .help("Settings (⌘,)")
        }
      }
      .sheet(item: $store.scope(state: \.spaceManagerSheet, action: \.spaceManagerSheet)) { sheetStore in
        SpaceManagerView(store: sheetStore)
      }
    }
    .environment(hierarchyManager)
    .environment(settingsStore)
    .environment(inboxStore)
    .task {
      store.send(.onLaunch)
      store.send(.worktreeHeader(.onAppear))
    }
    .onChange(of: store.editor.lastOpenResult) { _, new in
      guard let new else { return }
      switch new {
      case .opened(_, let displayName):
        lastEditorToast = .opened(displayName)
      case .failed(let reason):
        lastEditorToast = .failed(reason)
      }
    }
    .onChange(of: store.editor.lastProjectOverrideFailure) { _, new in
      if let reason = new {
        lastEditorToast = .failed("Override failed: \(reason)")
      }
    }
    // PR #22 review B9 — when the Settings window mutates `customEditors` /
    // `defaultEditorID`, refresh the main-window EditorFeature so the Header
    // split-button dropdown rebuilds its cached descriptors + globalDefault.
    // Pre-T1 the Settings sheet's dismiss action dispatched `.editor(.onAppear)`;
    // the standalone window has no matching dismiss bridge, so we observe the
    // @Observable SettingsStore directly here instead. `.onAppear` triggers both
    // describe() and the settings-snapshot read, covering both the custom-editors
    // list and the global-default picker in one action.
    .onChange(of: settingsStore.settings.general.customEditors) { _, _ in
      store.send(.editor(.onAppear))
    }
    .onChange(of: settingsStore.settings.general.defaultEditorID) { _, _ in
      store.send(.editor(.onAppear))
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
      store.send(
        .sidebar(
          .pruneExpansionSets(
            currentSpaceIDs: currentSpaceIDs,
            currentProjectIDs: currentProjectIDs
          )))
    }
  }

}

extension ContentView {
  @ViewBuilder
  fileprivate var editorToastOverlay: some View {
    if let toast = lastEditorToast {
      toastPill(toast)
        .padding(.bottom, 20)
        .transition(.move(edge: .bottom).combined(with: .opacity))
        .task(id: lastEditorToast) {
          // Auto-dismiss after 2.5 s. `.task(id:)` cancels on re-entry so a second open
          // (or navigation away) doesn't get clobbered.
          try? await Task.sleep(for: .seconds(2.5))
          if !Task.isCancelled {
            await MainActor.run { lastEditorToast = nil }
          }
        }
    }
  }

  @ViewBuilder
  fileprivate func toastPill(_ toast: EditorToast) -> some View {
    switch toast {
    case .opened(let displayName):
      HStack(spacing: 6) {
        Image(systemName: "checkmark.circle.fill")
          .accessibilityHidden(true)
          .foregroundStyle(.tint)
        Text("Opened in \(displayName)").font(.callout)
      }
      .padding(.horizontal, 12)
      .padding(.vertical, 6)
      .background(.ultraThickMaterial, in: .rect(cornerRadius: 8))
      .shadow(radius: 4, y: 2)
    case .failed(let message):
      HStack(spacing: 6) {
        Image(systemName: "exclamationmark.triangle.fill")
          .accessibilityHidden(true)
          .foregroundStyle(.orange)
        Text(message).font(.callout)
      }
      .padding(.horizontal, 12)
      .padding(.vertical, 6)
      .background(.ultraThickMaterial, in: .rect(cornerRadius: 8))
      .shadow(radius: 4, y: 2)
    }
  }

  // EditorError → user-facing reason mapping now lives in
  // `EditorFeature.editorErrorDescription` so TestStore observes the same string the UI
  // sees. ContentView just reads `store.editor.lastOpenResult` and renders.
}
