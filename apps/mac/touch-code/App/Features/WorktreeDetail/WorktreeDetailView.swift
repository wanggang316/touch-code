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
  /// 0014: titlebar-center Worktree Status Bar store. Owns the toast slot; PR /
  /// motivational forms are view-level projections of other scopes (added in M4/M5).
  let statusBarStore: StoreOf<StatusBarFeature>
  /// 0014 M4: scoped GitHub feature store; read for the PR form's
  /// `snapshots[worktreeID]` lookup. Same store the sidebar badge reads so
  /// the two surfaces stay in sync by construction.
  let gitHubStore: StoreOf<GitHubFeature>
  /// T3: derived from `RootFeature.State.gitViewerOverlayVisible`; never assigned locally.
  let overlayVisible: Bool
  @Environment(HierarchyManager.self) private var hierarchyManager

  var body: some View {
    if let address = resolveAddress() {
      let info = worktreeInfo(for: address)
      VStack(spacing: 0) {
        tabBarRow(address: address)
        terminalRegion(address: address)
          .overlay { overlayContent }
          .animation(.spring(response: 0.32, dampingFraction: 0.85), value: overlayVisible)
      }
      // On macOS 15+ remove the title slot entirely so default-placement
      // toolbar items can flow leading-to-trailing with `ToolbarSpacer`
      // controlling the layout (same pattern supacode uses).
      // `.navigationTitle("")` still reserves a leading region and would
      // push default-placement items toward the trailing edge — which is
      // why earlier centering attempts collapsed onto the right side.
      // macOS 14 keeps `.navigationTitle("")` + the older `.principal`
      // zoning since `.toolbar(removing:)` is 15+.
      .modifier(SuppressTitleModifier())
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
      projectID: address.project,
      worktreeID: address.worktree,
      activeTabID: address.activeTab
    )
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(Color(nsColor: .windowBackgroundColor))
  }

  @ViewBuilder
  private func terminalRegion(address: Address) -> some View {
    if let tabID = address.activeTab {
      SplitViewportView(
        store: store.scope(state: \.splitViewport, action: \.splitViewport),
        projectID: address.project,
        worktreeID: address.worktree,
        tabID: tabID
      )
    } else {
      emptyTab
    }
  }

  /// Centered modal overlay for Git Viewer. When `overlayVisible` is true, mounts
  /// `GitViewerModalHost` with a spring animation. Dismissal (scrim tap, ESC, or
  /// ⌘⇧G from header) dispatches the toggle action to close the modal.
  @ViewBuilder
  private var overlayContent: some View {
    if overlayVisible {
      GitViewerModalHost(
        store: gitViewerStore,
        onDismiss: { headerStore.send(.gitViewerToggleTapped) }
      )
      .transition(.scale(scale: 0.96).combined(with: .opacity))
    }
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
      // macOS 26 follows supacode's pattern: every item in default
      // placement, ordering plus ToolbarSpacer(.flexible) splits
      // horizontal space evenly so the status capsule sits visually
      // equidistant between the branch label and the trailing buttons.
      // Pre-26 keeps the older `.navigation` / `.principal` /
      // `.primaryAction` zoning since ToolbarSpacer is macOS 26+.
      if #available(macOS 26.0, *) {
        if info.project.supportsWorktrees {
          branchToolbarItemDefault(info: info)
        }
        ToolbarSpacer(.flexible)
        centeredStatusBarToolbarItem(address: address)
        ToolbarSpacer(.flexible)
        trailingButtonsDefault(address: address, info: info)
      } else {
        if info.project.supportsWorktrees {
          branchToolbarItem(info: info)
        }
        statusBarToolbarItem(address: address)
        ToolbarItemGroup(placement: .primaryAction) {
          HeaderOpenSplitButton(
            store: headerStore,
            editorStore: editorStore,
            projectID: address.project,
            worktreePath: info.worktree.path
          )
          .buttonStyle(.plain)
          HeaderRunScriptSplitButton(
            store: headerStore,
            projectID: address.project,
            worktreeID: info.worktree.id
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
  }

  /// Branch glyph that mirrors `WorktreeRowIcon`'s no-PR rendering — same
  /// `git-branch` asset, template mode, 14×14 — so the toolbar reads as
  /// the same icon family the sidebar uses.
  private var branchGlyph: some View {
    Image("git-branch")
      .renderingMode(.template)
      .resizable()
      .aspectRatio(contentMode: .fit)
      .frame(width: 14, height: 14)
      .foregroundStyle(.secondary)
      .accessibilityHidden(true)
  }

  /// macOS 26 leading branch item. Default placement so it sits before
  /// the leading `ToolbarSpacer(.flexible)` and reads as the leftmost
  /// chip. `.sharedBackgroundVisibility(.hidden)` opts the branch label
  /// out of the toolbar's glass capsule so it reads as plain text
  /// alongside the trailing action chips.
  @available(macOS 26.0, *)
  @ToolbarContentBuilder
  private func branchToolbarItemDefault(info: WorktreeInfo) -> some ToolbarContent {
    ToolbarItem {
      HStack(spacing: 6) {
        branchGlyph
        Text(info.branchLabel)
          .lineLimit(1)
      }
      .font(.headline)
      .accessibilityElement(children: .ignore)
      .accessibilityLabel("Current branch: \(info.branchLabel)")
      .accessibilityAddTraits(.isStaticText)
    }
    .sharedBackgroundVisibility(.hidden)
  }

  /// macOS 26 trailing buttons. Each lives in its own `ToolbarItem` so
  /// the system wraps it in a separate glass capsule — three discrete
  /// chips instead of one shared cluster background. `ToolbarSpacer(.fixed)`
  /// between siblings keeps them visually distinct without collapsing
  /// the gap. Default placement; ordering after the trailing flexible
  /// spacer pins the row to the right edge.
  @available(macOS 26.0, *)
  @ToolbarContentBuilder
  private func trailingButtonsDefault(
    address: Address, info: WorktreeInfo
  ) -> some ToolbarContent {
    // No `.buttonStyle` / no manual padding — each ToolbarItem gets
    // the toolbar's native glass capsule + hover state. Same pattern as
    // supacode's openMenu / ScriptMenu.
    ToolbarItem {
      HeaderOpenSplitButton(
        store: headerStore,
        editorStore: editorStore,
        projectID: address.project,
        worktreePath: info.worktree.path
      )
    }
    ToolbarSpacer(.fixed)
    ToolbarItem {
      HeaderRunScriptSplitButton(
        store: headerStore,
        projectID: address.project,
        worktreeID: info.worktree.id
      )
    }
    if info.project.supportsWorktrees {
      ToolbarSpacer(.fixed)
      ToolbarItem {
        HeaderGitViewerToggle(
          store: headerStore,
          visible: info.worktree.gitViewerVisible
        )
      }
    }
  }

  @ToolbarContentBuilder
  private func branchToolbarItem(info: WorktreeInfo) -> some ToolbarContent {
    let item = ToolbarItem(placement: .navigation) {
      HStack(spacing: 6) {
        branchGlyph
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

  @ToolbarContentBuilder
  private func statusBarToolbarItem(address: Address) -> some ToolbarContent {
    // No `.sharedBackgroundVisibility(.hidden)` — let macOS 26's toolbar
    // provide the standard glass capsule so the status slot reads as a
    // peer of the trailing button cluster instead of a hand-rolled chip.
    // Used as the pre-26 fallback when `ToolbarSpacer` is unavailable.
    ToolbarItem(placement: .principal) {
      StatusBarView(
        store: statusBarStore,
        gitHubStore: gitHubStore,
        headerStore: headerStore,
        worktreeID: address.worktree
      )
    }
  }

  /// macOS 26+ variant. Uses default placement so the surrounding
  /// `ToolbarSpacer(.flexible)` pair distributes free horizontal space
  /// equally on both sides — making the status capsule visually
  /// equidistant from the branch label and the trailing button cluster
  /// (instead of pinned to the title-bar's geometric center).
  @available(macOS 26.0, *)
  @ToolbarContentBuilder
  private func centeredStatusBarToolbarItem(address: Address) -> some ToolbarContent {
    ToolbarItem {
      StatusBarView(
        store: statusBarStore,
        gitHubStore: gitHubStore,
        headerStore: headerStore,
        worktreeID: address.worktree
      )
    }
  }

  private struct Address {
    let project: ProjectID
    let worktree: WorktreeID
    let activeTab: TabID?
  }

  private func resolveAddress() -> Address? {
    guard
      let projectID = selection.projectID,
      let worktreeID = selection.worktreeID,
      let project = hierarchyManager.catalog.projects.first(where: { $0.id == projectID }),
      let worktree = project.worktrees.first(where: { $0.id == worktreeID })
    else {
      return nil
    }
    return Address(
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

/// Wraps `.toolbar(removing: .title)` (macOS 15+) with a
/// `.navigationTitle("")` fallback for macOS 14. Both suppress the
/// bundle-name title; only the modern API also frees the leading slot
/// so default-placement items + ToolbarSpacers lay out predictably.
private struct SuppressTitleModifier: ViewModifier {
  func body(content: Content) -> some View {
    if #available(macOS 15.0, *) {
      content.toolbar(removing: .title)
    } else {
      content.navigationTitle("")
    }
  }
}
