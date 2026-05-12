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
  /// 0014: titlebar-center Worktree Status Bar store. Owns the toast slot; PR /
  /// motivational forms are view-level projections of other scopes (added in M4/M5).
  let statusBarStore: StoreOf<StatusBarFeature>
  /// 0014 M4: scoped GitHub feature store; read for the PR form's
  /// `snapshots[worktreeID]` lookup. Same store the sidebar badge reads so
  /// the two surfaces stay in sync by construction.
  let gitHubStore: StoreOf<GitHubFeature>
  /// M6: diff feature store — drives the Diff inspector column and the
  /// drawer overlay that fills the detail body when a file row is open.
  let diffStore: StoreOf<DiffFeature>
  /// M5: drives the inline Diff inspector column rendered to the right
  /// of the detail body. Sourced from `Worktree.diffInspectorVisible` via
  /// `RootFeature.State.diffInspectorVisible(in:)` in `ContentView`.
  let inspectorVisible: Bool
  /// Invoked from the empty-state Add Project button. Wired by `ContentView`
  /// so the detail view doesn't need to hold the sidebar's TCA scope just
  /// to fire `toolbarAddProjectTapped` — same pattern as the editor toast
  /// that surfaces sidebar outcomes without a back-channel store.
  let onAddProject: () -> Void
  /// v1 notifications: dispatches `RootFeature.focusHierarchyPath` from
  /// the InboxBellView's row-tap. Wired by `ContentView` so this view
  /// doesn't need to hold the root TCA scope just to fire one action.
  let onFocusHierarchyPath: (InboxEntry.SourcePath) -> Void
  /// Bumped by `RootFeature` when the user invokes ⌘U / the "Show Unread
  /// Notifications" menu item. Threaded down to `InboxBellView` whose
  /// `.onChange` opens the popover — same UUID-trigger pattern as
  /// `revealSelectionTrigger` for the sidebar.
  let inboxBellPopoverTrigger: UUID
  /// `RootFeature.activePendingWorktreeID` resolved to its row in
  /// `sidebar.pendingWorktrees`, plus the parent Project's display
  /// name. Non-nil → the detail pane shows `WorktreeLoadingView`
  /// regardless of `selection`; the resolver in `ContentView` already
  /// drops back to nil when the pending row leaves the array (success
  /// / cancel / discard), so this view doesn't have to track state
  /// transitions itself. Failure mode keeps the row in the array with
  /// `.failed` status and is surfaced as the `failed(message:)` kind.
  let activePendingWorktree: PendingWorktreeBinding?
  @Environment(HierarchyManager.self) private var hierarchyManager

  /// View-only projection of the in-flight pending row plus the
  /// repository-side context the loading view needs. Built by
  /// `ContentView` so this struct doesn't depend on TCA state shapes.
  struct PendingWorktreeBinding: Equatable {
    let pending: PendingWorktree
    let repositoryName: String?
  }

  var body: some View {
    if let pending = activePendingWorktree {
      WorktreeLoadingView(info: loadingInfo(for: pending))
    } else if let address = resolveAddress() {
      let info = worktreeInfo(for: address)
      HStack(spacing: 0) {
        VStack(spacing: 0) {
          tabBarRow(address: address)
          terminalRegion(address: address)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .overlay {
          if diffStore.state.presentedFilePath != nil {
            DiffDrawerView(store: diffStore)
              .zIndex(80)
              .transition(.move(edge: .trailing).combined(with: .opacity))
          }
        }
        .animation(
          .spring(response: 0.32, dampingFraction: 0.85),
          value: diffStore.state.presentedFilePath
        )

        if inspectorVisible {
          Divider()
          DiffInspectorView(store: diffStore)
            .frame(width: 280)
            .transition(.move(edge: .trailing))
        }
      }
      .animation(.easeInOut(duration: 0.18), value: inspectorVisible)
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
      // Drop the system-painted window-toolbar chrome so the macOS 26
      // floating-sidebar overlay only blends against the detail body
      // underneath it. Without this, the toolbar's full-window glass
      // repaints on every toolbar-state change (tab switch rebuilds
      // `worktreeToolbarContent`) and flickers across the area covered
      // by the translucent sidebar. Same pattern supacode uses.
      .toolbarBackground(.hidden, for: .windowToolbar)
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
    // No solid `.windowBackgroundColor` fill: with the toolbar chrome
    // hidden, the bar reads as a continuation of the titlebar region
    // (the NSWindow's natural backdrop). A solid fill across the full
    // detail width — including the area covered by the floating
    // sidebar — turns any repaint into a visible flash.
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
        // Bell is intentionally placed *immediately* after the status
        // capsule with no flexible spacer between them — keeps the
        // status / bell pair visually grouped at the window's
        // optical center.
        inboxBellToolbarItem()
        ToolbarSpacer(.flexible)
        trailingButtonsDefault(address: address, info: info)
      } else {
        if info.project.supportsWorktrees {
          branchToolbarItem(info: info)
        }
        statusBarToolbarItem(address: address)
        // Same as the modern path: bell sits adjacent to the principal
        // status item so the user reads "[status] [bell]" as one
        // cluster rather than seeing the bell in the trailing button
        // group with the action buttons.
        inboxBellToolbarItem()
        ToolbarItemGroup(placement: .primaryAction) {
          HeaderRunScriptSplitButton(
            store: headerStore,
            projectID: address.project,
            worktreeID: info.worktree.id
          )
          .buttonStyle(.plain)
          HeaderOpenSplitButton(
            store: headerStore,
            editorStore: editorStore,
            projectID: address.project,
            worktreePath: info.worktree.path
          )
          .buttonStyle(.plain)
        }
      }
    }
  }

  @ToolbarContentBuilder
  private func inboxBellToolbarItem() -> some ToolbarContent {
    ToolbarItem {
      InboxBellView(
        onFocusHierarchyPath: onFocusHierarchyPath,
        popoverTrigger: inboxBellPopoverTrigger
      )
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
      HeaderRunScriptSplitButton(
        store: headerStore,
        projectID: address.project,
        worktreeID: info.worktree.id
      )
    }
    ToolbarSpacer(.fixed)
    ToolbarItem {
      HeaderOpenSplitButton(
        store: headerStore,
        editorStore: editorStore,
        projectID: address.project,
        worktreePath: info.worktree.path
      )
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
    EmptyTerminalPaneView(message: "No terminals open")
  }

  private var placeholder: some View {
    EmptyProjectStateView(onAddProject: onAddProject)
  }

  /// Maps a `PendingWorktree` row to the view-layer struct the loading
  /// view consumes. Running rows surface the streaming git tail; failed
  /// rows surface `humanReadable(_:)` of the wrapped error so the
  /// detail view shows the same copy the sidebar tooltip already uses.
  private func loadingInfo(for binding: PendingWorktreeBinding) -> WorktreeLoadingInfo {
    let pending = binding.pending
    let kind: WorktreeLoadingInfo.Kind
    switch pending.status {
    case .running:
      kind = .creating(
        WorktreeLoadingInfo.Progress(
          statusCommand: "git worktree add",
          statusLines: pending.progressLines
        )
      )
    case .failed(let err):
      kind = .failed(message: humanReadable(err))
    }
    return WorktreeLoadingInfo(
      name: pending.displayName,
      repositoryName: binding.repositoryName,
      kind: kind
    )
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
