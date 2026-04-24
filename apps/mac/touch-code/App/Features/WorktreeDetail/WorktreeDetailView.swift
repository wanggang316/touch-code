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
      let info = worktreeInfo(for: address)
      VStack(spacing: 0) {
        tabBarRow(address: address)
        Divider()
        terminalRegion(address: address)
          .overlay(alignment: .trailing) { overlayContent }
          .animation(.easeInOut(duration: 0.15), value: overlayVisible)
      }
      // Suppress the default bundle-name title ("touch_code") without
      // double-labeling the titlebar. macOS would otherwise render the
      // navigationTitle as a plain string in the leading region of the
      // detail column AND let our `.principal` ToolbarItem render the
      // branch icon + text centrally — two branch labels side by side.
      // An empty string collapses the leading slot so only the principal
      // item remains visible. `.toolbar(removing: .title)` would be
      // cleaner but requires macOS 15+.
      .navigationTitle("")
      .toolbar { worktreeToolbarContent(address: address, info: info) }
    } else {
      placeholder
    }
  }

  private struct WorktreeInfo {
    let worktree: Worktree
    let project: Project
    let branchLabel: String
  }

  private func worktreeInfo(for address: Address) -> WorktreeInfo? {
    guard
      let project = hierarchyManager.catalog
        .spaces.first(where: { $0.id == address.space })?
        .projects.first(where: { $0.id == address.project }),
      let worktree = project.worktrees.first(where: { $0.id == address.worktree })
    else { return nil }
    return WorktreeInfo(
      worktree: worktree,
      project: project,
      branchLabel: worktree.branch ?? worktree.name
    )
  }

  /// Tab bar row above the terminal region. Branch label + bell / open-in /
  /// git-viewer toggle used to live to the right of the tabs (old
  /// `unifiedHeader`); they moved into the window titlebar via
  /// `worktreeToolbarContent(address:)` so the content region gets its
  /// vertical space back, matching supacode's `.toolbar {}` layout.
  @ViewBuilder
  private func tabBarRow(address: Address) -> some View {
    TabBarView(
      store: store.scope(state: \.tabBar, action: \.tabBar),
      spaceID: address.space,
      projectID: address.project,
      worktreeID: address.worktree,
      activeTabID: address.activeTab
    )
    .padding(.horizontal, 8)
    .padding(.vertical, 4)
    .frame(maxWidth: .infinity, alignment: .leading)
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

  /// Window-titlebar toolbar content for the active Worktree. Branch label
  /// on the leading edge (`.navigation` placement), bell / open-in / git
  /// viewer toggle on the trailing edge (`.primaryAction`). Mirrors the
  /// layout that used to live as the right cluster of the content-region
  /// header; moving it into `.toolbar {}` reclaims vertical pixels above
  /// the tab bar and matches macOS native chrome (Xcode, Finder, supacode).
  ///
  /// `ContentView` contributes one additional trailing `ToolbarItem`
  /// (Settings gear) — SwiftUI merges both sources, with Settings rendered
  /// after the items declared here.
  @ToolbarContentBuilder
  private func worktreeToolbarContent(
    address: Address,
    info: WorktreeInfo?
  ) -> some ToolbarContent {
    if let info {
      if info.project.supportsWorktrees {
        branchToolbarItem(info: info)
      }
      // Three independent trailing buttons. `ToolbarItemGroup` keeps the
      // relative order while preventing SwiftUI from collapsing them into a
      // single overflow menu on narrow widths. `.buttonStyle(.plain)` on each
      // child disables the toolbar's default rounded-rect container so the
      // bell / open / git-viewer toggle read as three separate icon buttons
      // with their own hit areas.
      ToolbarItemGroup(placement: .primaryAction) {
        HeaderBellView(store: headerStore)
          .buttonStyle(.plain)
        HeaderOpenSplitButton(
          store: headerStore,
          editorStore: editorStore,
          spaceID: address.space,
          projectID: address.project,
          worktreePath: info.worktree.path
        )
        .buttonStyle(.plain)
        if info.project.supportsWorktrees {
          HeaderGitViewerToggle(
            store: headerStore,
            visible: info.worktree.gitViewerVisible
          )
          .buttonStyle(.plain)
        }
      }
    }
  }

  @ToolbarContentBuilder
  private func branchToolbarItem(info: WorktreeInfo) -> some ToolbarContent {
    let item = ToolbarItem(placement: .navigation) {
      HStack(spacing: 6) {
        Image(systemName: "arrow.trianglehead.branch")
          .foregroundStyle(.secondary)
          .accessibilityHidden(true)
        Text(info.branchLabel)
          .lineLimit(1)
      }
      .font(.headline)
      .accessibilityElement(children: .ignore)
      .accessibilityLabel("Current branch: \(info.branchLabel)")
      .accessibilityAddTraits(.isStaticText)
    }
    if #available(macOS 26.0, *) {
      item.sharedBackgroundVisibility(.hidden)
    } else {
      item
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
