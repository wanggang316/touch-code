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
  /// Per-Worktree dirty-tree cache threaded into the sidebar so each row can decide
  /// whether to paint a pending-work dot without owning its own `git status` fetch.
  let worktreeStatusMonitor: WorktreeStatusMonitor
  @State private var columnVisibility: NavigationSplitViewVisibility = .all

  /// Transient toast for editor-open outcomes (success + failure). Non-nil = visible;
  /// auto-clears after a short window via `.task(id:)`.
  @State private var lastEditorToast: EditorToast?

  enum EditorToast: Equatable {
    case opened(String)
    case failed(String)
  }

  var body: some View {
    GhosttyColorSchemeSyncView {
      ZStack {
        mainSplit
        if store.state.gitViewerOverlayVisible(in: hierarchyManager.catalog) {
          GitViewerModalHost(
            store: store.scope(state: \.gitViewer, action: \.gitViewer),
            onDismiss: { store.send(.worktreeHeader(.gitViewerToggleTapped)) }
          )
          .zIndex(90)
          .transition(.scale(scale: 0.96).combined(with: .opacity))
        }
        if let paletteStore = store.scope(
          state: \.commandPalette, action: \.commandPalette.presented
        ) {
          CommandPaletteView(
            store: paletteStore,
            onDismiss: { store.send(.commandPaletteToggle(nil)) }
          )
          .zIndex(100)
          .transition(.opacity.combined(with: .scale(scale: 0.97)))
        }
      }
      .animation(.easeOut(duration: 0.12), value: store.commandPalette != nil)
      .animation(
        .spring(response: 0.32, dampingFraction: 0.85),
        value: store.state.gitViewerOverlayVisible(in: hierarchyManager.catalog)
      )
    }
  }

  private var mainSplit: some View {
    NavigationSplitView(columnVisibility: $columnVisibility) {
      HierarchySidebarView(
        store: store.scope(state: \.sidebar, action: \.sidebar),
        currentSelection: store.selection,
        gitHubStore: store.scope(state: \.gitHub, action: \.gitHub)
      )
      .navigationSplitViewColumnWidth(min: 220, ideal: 260, max: 320)
    } detail: {
      WorktreeDetailView(
        store: store.scope(state: \.detail, action: \.detail),
        selection: store.selection,
        editorStore: store.scope(state: \.editor, action: \.editor),
        headerStore: store.scope(state: \.worktreeHeader, action: \.worktreeHeader),
        statusBarStore: store.scope(state: \.statusBar, action: \.statusBar),
        gitHubStore: store.scope(state: \.gitHub, action: \.gitHub)
      )
      .frame(maxWidth: .infinity, maxHeight: .infinity)
      .overlay(alignment: .bottom) { editorToastOverlay }
      .sheet(
        item: $store.scope(state: \.lifecycleScriptToast, action: \.lifecycleScriptToast)
      ) { toastStore in
        LifecycleScriptToast(store: toastStore)
      }
      .sheet(
        item: $store.scope(state: \.tagManagerSheet, action: \.tagManagerSheet)
      ) { tagStore in
        TagManagerSheet(store: tagStore)
      }
    }
    .environment(hierarchyManager)
    .environment(settingsStore)
    .environment(inboxStore)
    .environment(worktreeStatusMonitor)
    .task {
      store.send(.onLaunch)
      store.send(.worktreeHeader(.onAppear))
      store.send(.gitHub(.onAppear))
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
    // When the Settings window writes `defaultEditorID`, refresh the main-window
    // EditorFeature so the Header split-button dropdown rebuilds its cached
    // descriptors + globalDefault.
    .onChange(of: settingsStore.settings.general.defaultEditorID) { _, _ in
      store.send(.editor(.onAppear))
    }
    .onDisappear {
      store.send(.onQuit)
    }
    // Project expansion is persisted on `Project.isExpanded` and pruned
    // implicitly when the Project leaves the catalog; no sidebar-side
    // expansion set to maintain.
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
