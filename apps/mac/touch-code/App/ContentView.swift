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
  let settingsStore: SettingsStore
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
          terminalEngine: terminalEngine,
          editorStore: store.scope(state: \.editor, action: \.editor)
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        if store.inspectorVisible {
          Divider()
          GitViewerView(store: store.scope(state: \.gitViewer, action: \.gitViewer))
            .frame(minWidth: 420, idealWidth: 480)
        }
      }
      .overlay(alignment: .bottom) { editorToastOverlay }
      .toolbar {
        ToolbarItem(placement: .primaryAction) {
          Button {
            store.send(.settingsSheetShown)
          } label: {
            Image(systemName: "gearshape")
              .accessibilityLabel("Settings")
          }
          .help("Settings (⌘,)")
          .keyboardShortcut(",", modifiers: [.command])
        }
        ToolbarItem(placement: .primaryAction) {
          Button {
            store.send(.inspectorVisibilityToggled)
          } label: {
            Image(systemName: store.inspectorVisible ? "sidebar.right" : "sidebar.right")
              .accessibilityLabel(store.inspectorVisible ? "Hide Inspector" : "Show Inspector")
          }
          .help("Toggle git viewer inspector")
        }
      }
      .sheet(item: $store.scope(state: \.settingsSheet, action: \.settingsSheet)) { sheetStore in
        SettingsSheetView(store: sheetStore) {
          store.send(.settingsSheet(.dismiss))
        }
      }
    }
    .environment(hierarchyManager)
    .environment(settingsStore)
    .task {
      store.send(.onLaunch)
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
