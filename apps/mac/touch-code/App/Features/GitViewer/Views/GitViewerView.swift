import ComposableArchitecture
import SwiftUI
import TouchCodeCore

/// Root view for the C7 read-only git viewer. Sits in the trailing inspector slot that
/// `0007 M4` introduced (`InspectorPlaceholder` → `GitViewerView` wire-up in `ContentView`).
///
/// Layout responsibilities:
/// - Top bar: scope segmented control (working / staged / log) + refresh button + whitespace
///   toggle. The `.commit(sha:)` scope is derived — reached by clicking a commit in log, not
///   from the segmented control.
/// - Body: when scope is `.log` and a commit is selected, three columns (log + files + diff);
///   otherwise two columns (files + diff).
/// - Empty states: "No Worktree selected" when `state.worktreeID == nil`; scope-specific
///   empty messages handled by child views.
struct GitViewerView: View {
  @Bindable var store: StoreOf<GitViewerFeature>

  var body: some View {
    Group {
      if store.worktreeID == nil {
        noWorktreeSelected
      } else {
        mainBody
      }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .background(Color(nsColor: .windowBackgroundColor))
    .focusable(true)
    .modifier(GitViewerKeybindings(store: store))
  }

  // MARK: - Sub-views

  @ViewBuilder
  private var mainBody: some View {
    VStack(spacing: 0) {
      topBar
      Divider()
      bodyColumns
    }
    .toast(marker: store.lastEditorResult)
  }

  private var topBar: some View {
    HStack(spacing: 8) {
      scopePicker
      Spacer(minLength: 8)
      Button {
        store.send(.whitespaceToggled)
      } label: {
        Image(systemName: "space")
          .foregroundStyle(store.ignoreWhitespace ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
          .accessibilityLabel(store.ignoreWhitespace ? "Whitespace ignored" : "Ignore whitespace")
      }
      .buttonStyle(.borderless)
      .help(store.ignoreWhitespace ? "Whitespace ignored — click to re-enable (‘.’)" : "Ignore whitespace (‘.’)")

      Button {
        store.send(.refreshRequested)
      } label: {
        Image(systemName: "arrow.clockwise")
          .accessibilityLabel("Refresh")
      }
      .buttonStyle(.borderless)
      .help("Refresh (‘r’)")
    }
    .padding(.horizontal, 8)
    .padding(.vertical, 4)
  }

  private var scopePicker: some View {
    // Use the current state's scope via the @Bindable store's projected value to avoid the
    // `store.scope` / `store.scope(state:action:)` name clash Swift struggles with.
    let currentSelection = ScopeSelection.from(store.state.scope)
    let binding = Binding<ScopeSelection>(
      get: { currentSelection },
      set: { newValue in store.send(.scopeChanged(newValue.toDiffScope())) }
    )
    return Picker("Scope", selection: binding) {
      Text("Working").tag(ScopeSelection.working)
      Text("Staged").tag(ScopeSelection.staged)
      Text("Log").tag(ScopeSelection.log)
    }
    .pickerStyle(.segmented)
    .frame(maxWidth: 260)
  }

  /// Layout is derived directly from `state.scope` — which updates synchronously inside the
  /// reducer's `.commitSelected` branch — so the column count snaps on intent (user clicked a
  /// commit) rather than waiting for the diff to finish loading. 0005 M4a.1 review item 3.
  @ViewBuilder
  private var bodyColumns: some View {
    switch store.state.scope {
    case .log:
      // Log scope, no commit picked yet: log list on the left, preview placeholder on the
      // right. User sees the log immediately on scope switch.
      HStack(spacing: 0) {
        CommitLogView(store: store).frame(minWidth: 240)
        Divider()
        commitPreviewPlaceholder.frame(maxWidth: .infinity)
      }
    case .commit:
      // Commit picked — derived from scope, not from diffState. Three columns appear the
      // moment the user clicks a commit; the diff loads into the right column.
      HStack(spacing: 0) {
        CommitLogView(store: store).frame(minWidth: 220, idealWidth: 240)
        Divider()
        FileChangeListView(store: store).frame(minWidth: 220, idealWidth: 260)
        Divider()
        UnifiedDiffView(store: store).frame(maxWidth: .infinity)
      }
    case .working, .staged:
      HStack(spacing: 0) {
        FileChangeListView(store: store).frame(minWidth: 220, idealWidth: 280)
        Divider()
        UnifiedDiffView(store: store).frame(maxWidth: .infinity)
      }
    }
  }

  private var commitPreviewPlaceholder: some View {
    VStack(spacing: 6) {
      Image(systemName: "clock.arrow.circlepath")
        .accessibilityHidden(true)
        .font(.largeTitle)
        .foregroundStyle(.tertiary)
      Text("Select a commit to view its diff")
        .font(.caption)
        .foregroundStyle(.secondary)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
  }

  private var noWorktreeSelected: some View {
    VStack(spacing: 6) {
      Image(systemName: "text.magnifyingglass")
        .accessibilityHidden(true)
        .font(.largeTitle)
        .foregroundStyle(.tertiary)
      Text("No Worktree selected")
        .font(.headline)
      Text("Select a Worktree in the sidebar to inspect its git state.")
        .font(.caption)
        .foregroundStyle(.secondary)
        .multilineTextAlignment(.center)
    }
    .padding()
    .frame(maxWidth: .infinity, maxHeight: .infinity)
  }
}

// MARK: - Scope picker bridge

private enum ScopeSelection: Hashable {
  case working, staged, log

  static func from(_ scope: DiffScope) -> ScopeSelection {
    switch scope {
    case .working: return .working
    case .staged: return .staged
    case .log, .commit: return .log
    }
  }

  func toDiffScope() -> DiffScope {
    switch self {
    case .working: return .working
    case .staged: return .staged
    case .log: return .log
    }
  }
}

// MARK: - Toast surface for editor-open outcomes

private struct ToastModifier: ViewModifier {
  let marker: GitViewerFeature.EditorResultMarker?

  func body(content: Content) -> some View {
    content.overlay(alignment: .bottom) {
      if let marker {
        toastView(marker)
          .padding(.bottom, 16)
          .transition(.move(edge: .bottom).combined(with: .opacity))
      }
    }
    .animation(.easeOut(duration: 0.2), value: marker != nil)
  }

  @ViewBuilder
  private func toastView(_ marker: GitViewerFeature.EditorResultMarker) -> some View {
    switch marker {
    case .opened(let id):
      toastPill("Opened in \(id)", systemImage: "checkmark.circle.fill", tint: .accentColor)
    case .failed(let reason):
      toastPill(reason, systemImage: "exclamationmark.triangle.fill", tint: .orange)
    }
  }

  private func toastPill(_ text: String, systemImage: String, tint: Color) -> some View {
    HStack(spacing: 6) {
      Image(systemName: systemImage)
        .foregroundStyle(tint)
        .accessibilityHidden(true)
      Text(text).font(.callout)
    }
    .padding(.horizontal, 12)
    .padding(.vertical, 6)
    .background(.ultraThickMaterial, in: .rect(cornerRadius: 8))
    .shadow(radius: 4, y: 2)
  }
}

extension View {
  fileprivate func toast(marker: GitViewerFeature.EditorResultMarker?) -> some View {
    modifier(ToastModifier(marker: marker))
  }
}
