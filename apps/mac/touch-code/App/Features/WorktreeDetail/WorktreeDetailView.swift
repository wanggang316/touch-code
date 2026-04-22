import ComposableArchitecture
import SwiftUI
import TouchCodeCore

/// Renders the detail column for the selected Worktree: tab bar on top,
/// split viewport underneath. Both reach into the environment
/// `HierarchyManager` for catalog reads; neither duplicates state.
///
/// If `selection` does not resolve to a live Worktree (nil IDs, or IDs
/// that no longer exist after a prune), renders a neutral "Select a
/// Worktree" prompt.
struct WorktreeDetailView: View {
  @Bindable var store: StoreOf<WorktreeDetailFeature>
  let selection: HierarchySelection
  /// Scoped editor-feature store; passed in by `ContentView` so the Worktree-header
  /// dropdown shares a single editor-state source of truth with the Settings sheet.
  /// Open-result toasts are driven by `editorStore.state.lastOpenResult` directly from
  /// `ContentView`, so this view no longer accepts a callback (0005 M6c).
  let editorStore: StoreOf<EditorFeature>
  /// T2 Header feature — scoped by `ContentView` from the root. Drives the bell
  /// badge, the Open-in split button's delegate routing, and the Git Viewer toggle.
  let headerStore: StoreOf<WorktreeHeaderFeature>
  /// T3: scoped Git Viewer store, hosted as a right-edge overlay on the terminal region
  /// when `overlayVisible == true` AND the terminal has enough width to keep the
  /// overlay + the minimum terminal gutter side-by-side.
  let gitViewerStore: StoreOf<GitViewerFeature>
  /// T3: derived from `RootFeature.State.gitViewerOverlayVisible`; never assigned locally.
  let overlayVisible: Bool
  @Environment(HierarchyManager.self) private var hierarchyManager

  var body: some View {
    if let address = resolveAddress() {
      VStack(spacing: 0) {
        unifiedHeader(address: address)
        Divider()
        terminalRegion(address: address)
          .overlay(alignment: .trailing) { overlayContent }
          .animation(.easeInOut(duration: 0.15), value: overlayVisible)
      }
    } else {
      placeholder
    }
  }

  /// Unified top bar: tabs on the left, branch label + action cluster on the
  /// right. Replaces the previous two-row layout (separate WorktreeHeader and
  /// TabBar) so the right pane has a single visual Header.
  @ViewBuilder
  private func unifiedHeader(address: Address) -> some View {
    HStack(spacing: 8) {
      TabBarView(
        store: store.scope(state: \.tabBar, action: \.tabBar),
        spaceID: address.space,
        projectID: address.project,
        worktreeID: address.worktree,
        activeTabID: address.activeTab
      )
      Spacer(minLength: 8)
      worktreeHeader(address: address)
    }
    .padding(.horizontal, 8)
    .padding(.vertical, 4)
    .background(Color(nsColor: .windowBackgroundColor))
  }

  @ViewBuilder
  private func terminalRegion(address: Address) -> some View {
    if let tabID = address.activeTab {
      SplitViewportView(
        store: store.scope(state: \.splitViewport, action: \.splitViewport),
        spaceID: address.space,
        projectID: address.project,
        worktreeID: address.worktree,
        tabID: tabID
      )
    } else {
      emptyTab
    }
  }

  /// T3 overlay content: the Git Viewer occupies a fixed-width slot on the trailing edge
  /// when there's room, otherwise a compact suppressed-hint badge nudges the user to
  /// widen the window. Width clamp logic lives in `shouldShowOverlay(totalWidth:)` so
  /// the threshold is unit-testable independently of SwiftUI layout.
  @ViewBuilder
  private var overlayContent: some View {
    if overlayVisible {
      GeometryReader { proxy in
        if Self.shouldShowOverlay(totalWidth: proxy.size.width) {
          GitViewerView(store: gitViewerStore)
            .frame(width: MainWindowConstants.gvOverlayWidth)
            .frame(maxWidth: .infinity, alignment: .trailing)
            .transition(.move(edge: .trailing).combined(with: .opacity))
        } else {
          overlaySuppressedHint
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
            .padding(8)
        }
      }
    }
  }

  private var overlaySuppressedHint: some View {
    Text("Widen window to show Git Viewer")
      .font(.caption)
      .foregroundStyle(.secondary)
      .padding(.horizontal, 10)
      .padding(.vertical, 5)
      .background(.thinMaterial, in: .capsule)
  }

  /// Pure width-clamp helper. The overlay only renders when the host has room to keep
  /// the overlay at its fixed width AND leave at least `gvOverlayMinTerminalWidth` for
  /// the terminal. Equivalence with `>=` keeps the exact threshold inclusive — matches
  /// the paired unit tests in `WorktreeDetailViewLayoutTests`.
  static func shouldShowOverlay(totalWidth: CGFloat) -> Bool {
    totalWidth >= MainWindowConstants.gvOverlayMinTerminalWidth
      + MainWindowConstants.gvOverlayWidth
  }

  /// Worktree Header row (T2): branch label + bell + Open-in split button +
  /// GV toggle. Delegates to `WorktreeHeaderView`; path string is no longer
  /// rendered per the redesign spec (path visibility moves to hover/tooltip
  /// surfaces if reintroduced).
  @ViewBuilder
  private func worktreeHeader(address: Address) -> some View {
    let project = hierarchyManager.catalog
      .spaces.first(where: { $0.id == address.space })?
      .projects.first(where: { $0.id == address.project })
    let worktree = project?.worktrees.first(where: { $0.id == address.worktree })
    if let worktree, let project {
      WorktreeHeaderView(
        store: headerStore,
        editorStore: editorStore,
        spaceID: address.space,
        projectID: address.project,
        worktreePath: worktree.path,
        branchLabel: worktree.branch ?? worktree.name,
        gitViewerVisible: worktree.gitViewerVisible,
        supportsWorktrees: project.supportsWorktrees
      )
    }
  }

  private struct Address {
    let space: SpaceID
    let project: ProjectID
    let worktree: WorktreeID
    let activeTab: TabID?
  }

  private func resolveAddress() -> Address? {
    guard
      let spaceID = selection.spaceID,
      let projectID = selection.projectID,
      let worktreeID = selection.worktreeID,
      let space = hierarchyManager.catalog.spaces.first(where: { $0.id == spaceID }),
      let project = space.projects.first(where: { $0.id == projectID }),
      let worktree = project.worktrees.first(where: { $0.id == worktreeID })
    else {
      return nil
    }
    return Address(
      space: spaceID,
      project: projectID,
      worktree: worktreeID,
      activeTab: worktree.selectedTabID
    )
  }

  private var emptyTab: some View {
    VStack(spacing: 12) {
      Text("No Tab selected")
        .font(.title3)
        .foregroundStyle(.secondary)
      Text("Use the tab bar above to create a Tab.")
        .font(.caption)
        .foregroundStyle(.tertiary)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
  }

  private var placeholder: some View {
    Text("Select a Worktree")
      .font(.title2)
      .foregroundStyle(.secondary)
      .frame(maxWidth: .infinity, maxHeight: .infinity)
  }
}
