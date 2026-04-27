import ComposableArchitecture
import SwiftUI
import TouchCodeCore

/// Renders the sidebar per `docs/product-specs/ui-main-window-redesign.md`:
/// a sticky toolbar with "+ Add Project" and a "⋯" placeholder menu; the
/// active Space's Projects as collapsible sections with hover-revealed `+` /
/// `⋯` chrome; Worktree rows with a leading `●`/`○` selection dot and a
/// trailing unread-notification dot; a pinned Space footer whose tap opens
/// a popover for switching / creating Spaces; and empty-state + confirmation
/// / stub-sheet presentations.
///
/// Structural data is NOT held in reducer state — the view reads the active
/// `Catalog` from `HierarchyManager` and the `NotificationInbox` from
/// `InboxStore` through SwiftUI's environment, so row lists and unread dots
/// update whenever the underlying `@Observable` stores mutate. The TCA
/// reducer owns only local view state (expansion sets, popover / sheet /
/// confirmation payloads) and dispatches side effects through
/// `HierarchyClient` (plus delegate actions for Finder / editor open that
/// `RootFeature` routes).
struct HierarchySidebarView: View {
  @Bindable var store: StoreOf<HierarchySidebarFeature>
  let currentSelection: HierarchySelection
  /// Optional GitHub integration store. When non-nil, each Worktree row renders a PR
  /// badge (silent when no PR is matched) and the row hosts the PR popover. Nil in
  /// previews / tests that don't exercise the integration.
  var gitHubStore: StoreOf<GitHubFeature>?
  @Environment(HierarchyManager.self) private var hierarchyManager
  @Environment(InboxStore.self) private var inboxStore
  @Environment(SettingsStore.self) private var settingsStore
  @Environment(WorktreeStatusMonitor.self) private var worktreeStatusMonitor

  /// Tracks whether the `.command` modifier is currently pressed. When held the sidebar
  /// reveals per-row `⌃⌘N` hotkey hints (and the matching `⌃⌘1`–`⌃⌘9` bindings).
  @Environment(CommandKeyObserver.self) private var commandKeyObserver

  /// Modifier set for the per-row worktree hotkey. `⌘1`–`⌘9` is already bound to Space
  /// switching (see `MainWindowCommands`), so worktree jumps get `⌃⌘N` instead.
  private static let hotkeyModifiers: EventModifiers = [.command, .control]

  /// Flips to true once `_UnclampedClipView` has been swapped in. Until then
  /// the List renders at `opacity(0)` so the user never sees the unshifted
  /// (x=0) frames the AppKit introspection retries paper over.
  @State private var sidebarIndentReady = false

  /// Heterogeneous sidebar rows in render order: main → pinned → pending →
  /// unpinned. Per-segment rules and rationale live in
  /// docs/design-docs/worktree-sidebar-ordering.md §渲染合并. `pendings`
  /// is filtered to the given project (caller passes the full sidebar-wide
  /// list). Used by ordering tests + the hotkey enumeration shim; the
  /// production view splits the segments across separate ForEach blocks
  /// so each can own its own .onMove.
  static func orderedSidebarRows(
    project: Project,
    pendings: [PendingWorktree]
  ) -> [SidebarRow] {
    let visible = project.worktrees.filter { !$0.archived }
    let main = visible.filter { $0.path == project.rootPath }
    let pinned = visible.filter { $0.isPinned && $0.path != project.rootPath }
    let rest = visible.filter { !$0.isPinned && $0.path != project.rootPath }
    let projectPending = pendings.filter { $0.projectID == project.id }
    return main.map(SidebarRow.worktree)
      + pinned.map(SidebarRow.worktree)
      + projectPending.map(SidebarRow.pending)
      + rest.map(SidebarRow.worktree)
  }

  /// Compat shim for the hotkey-enumeration path (`treeBody.hotkeyIndex`),
  /// which only assigns slots to real worktrees. Derived from
  /// `orderedSidebarRows` so the segment ordering stays in one place; the
  /// `pendings: []` argument is correct for hotkey purposes — pending rows
  /// never claim a `⌃⌘N` slot per design doc §pending 段 用户操作.
  static func orderedVisibleWorktrees(in project: Project) -> [Worktree] {
    orderedSidebarRows(project: project, pendings: []).compactMap { row in
      if case .worktree(let w) = row { return w } else { return nil }
    }
  }

  var body: some View {
    let catalog = hierarchyManager.catalog
    // Build the PaneID→WorktreeID index once per render pass. Worktree rows
    // and Project headers both fold over `inbox.notifications` using this
    // shared index instead of calling `NotificationInbox.unreadCount(
    // forWorktree:in:)` / `.hasUnread(forProject:in:)` per row — those
    // helpers each rebuild the index internally (see the doc-comment in
    // `NotificationInboxAggregation.swift`), which is O(rows × panes) per
    // render. The inline fold is the deliberate amortization the T1 design
    // calls out in §View Composition / §Unread-dot index caching.
    let paneIndex = catalog.paneWorktreeIndex()
    let inbox = inboxStore.inbox
    let activeSpace = catalog.spaces.first { $0.id == catalog.selectedSpaceID }

    // Sidebar body is the List directly (no VStack wrapper). This matches
    // supacode's shape and lets SwiftUI's `List(.sidebar)` cover the full
    // column with the system sidebar material — when toolbar/footer lived
    // inside a VStack above/below the List, those strips were NOT tagged as
    // sidebar content and showed the column's base color through as a dark
    // band in light mode. `.safeAreaInset` attaches the Space footer at the
    // bottom edge with proper material continuity, and `.toolbar` promotes
    // the add-project / options actions into the window titlebar over the
    // sidebar column (same as Finder / Xcode).
    treeBody(activeSpace: activeSpace, paneIndex: paneIndex, inbox: inbox)
      .safeAreaInset(edge: .bottom, spacing: 0) {
        VStack(spacing: 0) {
          Divider()
          spaceFooter(activeSpace: activeSpace)
            .popover(
              isPresented: Binding(
                get: { store.isSpacePopoverPresented },
                set: { isPresented in
                  if !isPresented { store.send(.spacePopoverDismissed) }
                }
              ),
              attachmentAnchor: .rect(.bounds),
              arrowEdge: .top
            ) {
              spacePopover(catalog: catalog)
            }
        }
        // `safeAreaInset` places its content outside the `List(.sidebar)`
        // material, so without an explicit background the Ghostty-stained
        // window color showed through. `.bar` is macOS's standard bottom-bar
        // material (Finder / Xcode / Notes sidebar footers), and it still
        // blends with the window tint for visual continuity with the list.
        .background(.bar)
      }
      .toolbar { sidebarToolbarContent }
      .sheet(
        item: $store.scope(state: \.addProject, action: \.addProject)
      ) { childStore in
        AddProjectSheet(store: childStore)
      }
      .sheet(
        isPresented: Binding(
          get: { store.createWorktreeSheet != nil },
          set: { isPresented in
            if !isPresented {
              store.send(.createWorktreeSheet(.cancelButtonTapped))
            }
          }
        )
      ) {
        if let childStore = store.scope(
          state: \.createWorktreeSheet,
          action: \.createWorktreeSheet
        ) {
          CreateWorktreeSheet(store: childStore)
        }
      }
      .sheet(
        item: $store.scope(state: \.projectOptions, action: \.projectOptions)
      ) { childStore in
        ProjectOptionsSheet(store: childStore)
      }
      .confirmationDialog(
        worktreeRemovalTitle,
        isPresented: Binding(
          get: { store.pendingWorktreeRemoval != nil },
          set: { if !$0 { store.send(.worktreeRemoveCancelled) } }
        ),
        titleVisibility: .visible
      ) {
        Button("Remove Worktree", role: .destructive) {
          store.send(.worktreeRemoveConfirmed)
        }
        Button("Cancel", role: .cancel) {
          store.send(.worktreeRemoveCancelled)
        }
      } message: {
        Text("Closes all panes and deletes the Worktree directory, including any uncommitted changes. This cannot be undone.")
      }
      .confirmationDialog(
        projectRemovalTitle,
        isPresented: Binding(
          get: { store.pendingProjectRemoval != nil },
          set: { if !$0 { store.send(.projectRemoveCancelled) } }
        ),
        titleVisibility: .visible
      ) {
        Button("Remove Project", role: .destructive) {
          store.send(.projectRemoveConfirmed)
        }
        Button("Cancel", role: .cancel) {
          store.send(.projectRemoveCancelled)
        }
      } message: {
        Text("Removes the Project and closes all its panes. Files on disk are not affected.")
      }
      // Archived Worktrees sheet (opened from Project ⋯ menu).
      .sheet(
        isPresented: Binding(
          get: { store.archivedWorktreesSheet != nil },
          set: { if !$0 { store.send(.archivedWorktreesSheetDismissed) } }
        )
      ) {
        if let childStore = store.scope(
          state: \.archivedWorktreesSheet,
          action: \.archivedWorktreesSheet
        ) {
          ArchivedWorktreesSheet(store: childStore)
        }
      }
      // First-archive explainer (once per session).
      .confirmationDialog(
        "Archive this Worktree?",
        isPresented: Binding(
          get: { store.pendingArchiveExplainer != nil },
          set: { if !$0 { store.send(.worktreeArchiveCancelled) } }
        ),
        titleVisibility: .visible
      ) {
        Button("Archive") {
          store.send(.worktreeArchiveConfirmed)
        }
        Button("Cancel", role: .cancel) {
          store.send(.worktreeArchiveCancelled)
        }
      } message: {
        Text("Files and branch are kept. Find it later under “Archived Worktrees” in the Project menu.")
      }
      // Prune toast.
      .alert(
        "Prune complete",
        isPresented: Binding(
          get: { store.pruneToast != nil },
          set: { if !$0 { store.send(.pruneToastDismissed) } }
        )
      ) {
        Button("OK") { store.send(.pruneToastDismissed) }
      } message: {
        Text(store.pruneToast ?? "")
      }
  }

  // MARK: - Toolbar

  @ToolbarContentBuilder
  private var sidebarToolbarContent: some ToolbarContent {
    ToolbarItem(placement: .primaryAction) {
      Button {
        store.send(.toolbarAddProjectTapped)
      } label: {
        Label("Add Project", systemImage: "plus")
      }
      .help("Add Project to the active Space")
    }
  }

  // MARK: - Tree

  @ViewBuilder
  private func treeBody(
    activeSpace: Space?,
    paneIndex: [PaneID: WorktreeID],
    inbox: NotificationInbox
  ) -> some View {
    if let activeSpace {
      if activeSpace.projects.isEmpty {
        emptySpaceState
      } else {
        // Top-down flat enumeration of visible worktrees across projects, following the
        // same main → pinned → others partition the rows themselves render in. Used to
        // assign `⌃⌘1`…`⌃⌘9` and reveal matching hints while ⌘ is held. Archived rows
        // live in a separate sheet and never claim a hotkey slot.
        let hotkeyIndex: [WorktreeID: Int] = {
          var map: [WorktreeID: Int] = [:]
          var slot = 0
          for project in activeSpace.projects {
            for worktree in Self.orderedVisibleWorktrees(in: project) {
              if slot >= 9 { return map }
              map[worktree.id] = slot
              slot += 1
            }
          }
          return map
        }()
        // List + .listStyle(.sidebar) with NO `.scrollIndicators(.*)` modifier.
        // On macOS 26 / NavigationSplitView sidebar columns, both `.hidden` and
        // `.never` silently collapse the List's top titlebar safe area — the
        // first row then draws at y=0, overlapping with the traffic lights.
        // Accepting the scroller-when-needed trade-off; supacode + Prowl both
        // tolerate the default indicator posture here.
        List {
          ForEach(activeSpace.projects) { project in
            projectSection(
              project,
              in: activeSpace,
              paneIndex: paneIndex,
              inbox: inbox,
              hotkeyIndex: hotkeyIndex
            )
          }
        }
        .listStyle(.sidebar)
        .opacity(sidebarIndentReady ? 1 : 0)
        .background(SidebarIndentZeroer(onReady: { sidebarIndentReady = true }))
      }
    } else {
      noSpacesState
    }
  }

  private var noSpacesState: some View {
    VStack(spacing: 8) {
      Spacer()
      Image(systemName: "folder.badge.plus")
        .font(.title)
        .foregroundStyle(.secondary)
        .accessibilityHidden(true)
      Text("No Spaces yet.")
        .font(.callout)
        .foregroundStyle(.secondary)
      Spacer()
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .padding()
  }

  private var emptySpaceState: some View {
    VStack(spacing: 10) {
      Spacer()
      Image(systemName: "tray")
        .font(.title)
        .foregroundStyle(.secondary)
        .accessibilityHidden(true)
      Text("No projects yet.")
        .font(.callout)
        .foregroundStyle(.secondary)
      Button {
        store.send(.toolbarAddProjectTapped)
      } label: {
        Label("Add Project", systemImage: "plus")
      }
      .buttonStyle(.borderedProminent)
      Spacer()
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .padding()
  }

  // MARK: - Project section

  private func projectSection(
    _ project: Project,
    in space: Space,
    paneIndex: [PaneID: WorktreeID],
    inbox: NotificationInbox,
    hotkeyIndex: [WorktreeID: Int]
  ) -> some View {
    let projectHasUnread = inbox.notifications.contains { notification in
      guard notification.isUnread,
        let worktreeID = paneIndex[notification.paneID]
      else { return false }
      return project.worktrees.contains(where: { $0.id == worktreeID })
    }

    let isExpanded = project.isExpanded
    return Group {
      switch project.loadState {
      case .failed(let reason):
        FailedProjectRow(
          name: project.name,
          rootPath: project.rootPath,
          reason: reason,
          retry: {
            store.send(.retryProjectTapped(projectID: project.id, inSpace: space.id))
          },
          remove: {
            store.send(
              .projectRemoveTapped(
                projectID: project.id,
                inSpace: space.id,
                name: project.name
              ))
          }
        )
      case .loading, .ready:
        // Header is its own List row. DisclosureGroup used to nest the worktree rows
        // inside the header row — that made AppKit animate the single wrapping row's
        // height on every expand / collapse, visibly jittering the Project name.
        // Emitting header + each worktree as SIBLING rows lets NSTableView handle
        // expansion as plain row insert / remove instead.
        Button {
          var txn = Transaction()
          txn.disablesAnimations = true
          withTransaction(txn) {
            store.send(.toggleProjectExpansion(project.id))
          }
        } label: {
          ProjectHeaderRow(
            project: project,
            space: space,
            hasUnread: projectHasUnread,
            isLoading: project.loadState == .loading,
            isExpanded: isExpanded,
            store: store
          )
        }
        .buttonStyle(.plain)
        .listRowInsets(EdgeInsets(top: 10, leading: 0, bottom: 4, trailing: 0))
        .listRowBackground(Color.clear)
        .listRowSeparator(.hidden)
        if isExpanded {
          // Render the four segments individually so pinned and unpinned
          // each own their own ForEach + .onMove (per design doc §渲染合并
          // / 拖拽). Pending rows render in source order between pinned
          // and unpinned; main and pending segments do not admit reorder.
          let visible = project.worktrees.filter { !$0.archived }
          let mainRows = visible.filter { $0.path == project.rootPath }
          let pinnedRows = visible.filter { $0.isPinned && $0.path != project.rootPath }
          let unpinnedRows = visible.filter { !$0.isPinned && $0.path != project.rootPath }
          let pendingRows = store.pendingWorktrees.filter { $0.projectID == project.id }
          ForEach(mainRows) { worktree in
            worktreeRow(
              worktree, in: project, space: space, paneIndex: paneIndex, inbox: inbox,
              hotkeySlot: hotkeyIndex[worktree.id]
            )
          }
          ForEach(pinnedRows) { worktree in
            worktreeRow(
              worktree, in: project, space: space, paneIndex: paneIndex, inbox: inbox,
              hotkeySlot: hotkeyIndex[worktree.id]
            )
          }
          .onMove { source, destination in
            store.send(
              .reorderWorktrees(
                projectID: project.id, inSpace: space.id,
                segment: .pinned, from: source, to: destination
              )
            )
          }
          ForEach(pendingRows) { pending in
            pendingRow(pending)
          }
          ForEach(unpinnedRows) { worktree in
            worktreeRow(
              worktree, in: project, space: space, paneIndex: paneIndex, inbox: inbox,
              hotkeySlot: hotkeyIndex[worktree.id]
            )
          }
          .onMove { source, destination in
            store.send(
              .reorderWorktrees(
                projectID: project.id, inSpace: space.id,
                segment: .unpinned, from: source, to: destination
              )
            )
          }
        }
      }
    }
  }

  // MARK: - Pending row

  /// Wires task03's `PendingWorktreeRow` into the segment ForEach with
  /// Cancel / Retry / Discard handlers dispatched to the lifecycle reducer.
  @ViewBuilder
  private func pendingRow(_ pending: PendingWorktree) -> some View {
    PendingWorktreeRow(
      pending: pending,
      onCancel: { store.send(.pendingWorktreeCancelTapped(pending.id)) },
      onRetry: { store.send(.pendingWorktreeRetryTapped(pending.id)) },
      onDiscard: { store.send(.pendingWorktreeDiscardTapped(pending.id)) }
    )
    .listRowSeparator(.hidden)
  }

  // MARK: - Worktree row

  private func worktreeRow(
    _ worktree: Worktree,
    in project: Project,
    space: Space,
    paneIndex: [PaneID: WorktreeID],
    inbox: NotificationInbox,
    hotkeySlot: Int?
  ) -> some View {
    let isSelected = currentSelection.worktreeID == worktree.id
    let unreadCount = inbox.notifications.reduce(into: 0) { total, notification in
      guard notification.isUnread,
        paneIndex[notification.paneID] == worktree.id
      else { return }
      total += 1
    }
    let snapshot = gitHubStore?.snapshots[worktree.id]
    let rollup: PullRequestBadge.CheckRollup = {
      // 0013 M5: rollup data travels with the snapshot now (filled by the batched
      // `gh api graphql` path in `parseBatchedPullRequests`). The v1 per-PR
      // `state.checks[prNumber]` map is no longer populated on the fetch side —
      // reading `snapshot.checkRollup` keeps the overlay working without the
      // extra gh subprocess v1 used to spawn.
      guard let snapshot else { return .noChecks }
      return PullRequestBadge.CheckRollup.from(checks: snapshot.checkRollup)
    }()
    let hotkeyNumber = hotkeySlot.map { $0 + 1 }

    // Row and GitHub badge are siblings rather than nested, so the badge's own Button
    // doesn't live inside the row's Button.label. Tapping the badge opens the PR popover
    // without also firing the row-selection action. The leading portion of the row is
    // the Button; the trailing badge sits beside it.
    return HStack(spacing: 6) {
      rowSelectionButton(
        worktree: worktree, project: project, space: space,
        snapshot: snapshot, rollup: rollup,
        unreadCount: unreadCount, hotkeyNumber: hotkeyNumber,
        isSelected: isSelected
      )
      gitHubBadge(for: worktree, in: project, space: space)
    }
    // Worktree rows are now real List children (header + worktrees emitted as
    // sibling rows from `projectSection`), so `.listRowInsets` + `.listRowBackground`
    // are the right knobs. The rounded-pill selection lives in the row background so
    // the selection wash does not paint into the list's trailing gutter.
    // Leading 14 and pill leading 18 compensate the +6pt clip-view shift in
    // `_UnclampedClipView` and add a +8pt visual indent so worktree content
    // reads as a child level under the (left-aligned) project header.
    .listRowInsets(EdgeInsets(top: 3, leading: 14, bottom: 3, trailing: 0))
    .listRowSeparator(.hidden)
    .listRowBackground(
      RoundedRectangle(cornerRadius: 10, style: .continuous)
        .fill(isSelected ? Color(nsColor: .selectedContentBackgroundColor) : Color.clear)
        .padding(.vertical, 2)
        .padding(.leading, 18)
        .padding(.trailing, 4)
    )
    .contextMenu { worktreeContextMenu(worktree: worktree, project: project, space: space) }
    .task(id: worktree.path) {
      // Refresh the "dirty" dot on mount / path change. The monitor enforces a 30 s
      // freshness window internally so list-rerenders don't spawn redundant fetches.
      await worktreeStatusMonitor.refresh(
        worktreeID: worktree.id,
        path: URL(fileURLWithPath: worktree.path)
      )
    }
  }

  /// The selection-tappable portion of a Worktree row. Extracted so `worktreeRow` fits
  /// under swiftlint's `function_body_length` and so the hotkey-hint + keyboard shortcut
  /// wiring stays close to the button those bindings drive.
  @ViewBuilder
  private func rowSelectionButton(
    worktree: Worktree, project: Project, space: Space,
    snapshot: PullRequestSnapshot?, rollup: PullRequestBadge.CheckRollup,
    unreadCount: Int, hotkeyNumber: Int?,
    isSelected: Bool
  ) -> some View {
    let isMainCheckout = worktree.path == project.rootPath
    let roleTint: Color = {
      if isMainCheckout { return .yellow }
      if worktree.isPinned { return .orange }
      return .secondary
    }()
    let button = Button {
      store.send(.worktreeRowTapped(worktree.id, inProject: project.id, inSpace: space.id))
    } label: {
      HStack(spacing: 6) {
        WorktreeRowIcon(
          snapshot: snapshot, rollup: rollup, isSelected: isSelected, roleTint: roleTint
        )
        VStack(alignment: .leading, spacing: 0) {
          HStack(spacing: 2) {
            Text(worktree.name)
            // Explicit pinned marker — keeps the "this row is pinned" signal visible
            // even when the row-icon's role tint is overridden by a PR-state color.
            if worktree.isPinned && !isMainCheckout {
              Image(systemName: "pin.fill")
                .font(.caption2)
                .foregroundStyle(.orange)
                .accessibilityLabel("Pinned")
            }
          }
          // Suppress the secondary branch line when it restates the worktree name —
          // the common case (main/main, test0003/test0003) otherwise doubles every
          // row height for zero information.
          if let branch = worktree.branch, branch != worktree.name {
            Text(branch)
              .font(.caption.monospaced())
              .foregroundStyle(.secondary)
          }
        }
        Spacer()
        if unreadCount > 0 {
          Circle()
            .fill(Color.orange)
            .frame(width: 6, height: 6)
            .accessibilityLabel("Has \(unreadCount) unread notifications")
        }
        if let hotkeyNumber, commandKeyObserver.isCommandHeld {
          Text("⌃⌘\(hotkeyNumber)")
            .font(.caption2.monospaced())
            .foregroundStyle(.secondary)
            .padding(.horizontal, 4)
            .padding(.vertical, 1)
            .overlay(
              RoundedRectangle(cornerRadius: 3)
                .stroke(Color.secondary.opacity(0.35), lineWidth: 1)
            )
            .accessibilityHidden(true)
        }
      }
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)

    if let hotkeyNumber {
      button.keyboardShortcut(
        KeyEquivalent(Character("\(hotkeyNumber)")),
        modifiers: Self.hotkeyModifiers
      )
    } else {
      button
    }
  }

  // Main-checkout guard: the row whose path is the Project's rootPath is the main checkout
  // and cannot be archived or removed from the app (spec W-Q3 guard). Extracted so the row
  // body stays under swiftlint's function_body_length limit.
  @ViewBuilder
  private func worktreeContextMenu(
    worktree: Worktree, project: Project, space: Space
  ) -> some View {
    let isMainCheckout = worktree.path == project.rootPath
    if !isMainCheckout {
      Button {
        store.send(.worktreePinToggleTapped(worktreeID: worktree.id, current: worktree.isPinned))
      } label: {
        Label(
          worktree.isPinned ? "Unpin Worktree" : "Pin Worktree",
          systemImage: worktree.isPinned ? "pin.slash" : "pin"
        )
      }
      if worktree.archived {
        Button {
          store.send(
            .worktreeUnarchiveTapped(
              worktreeID: worktree.id, inProject: project.id, inSpace: space.id
            ))
        } label: {
          Label("Unarchive Worktree", systemImage: "tray.and.arrow.up")
        }
      } else {
        Button {
          store.send(
            .worktreeArchiveTapped(
              worktreeID: worktree.id, inProject: project.id, inSpace: space.id, name: worktree.name
            ))
        } label: {
          Label("Archive Worktree", systemImage: "archivebox")
        }
      }
      Button(role: .destructive) {
        store.send(
          .worktreeRemoveTapped(
            worktreeID: worktree.id, inProject: project.id, inSpace: space.id, name: worktree.name
          ))
      } label: {
        Label("Remove Worktree", systemImage: "trash")
      }
    }
    Button {
      store.send(.worktreeRevealInFinderTapped(path: worktree.path))
    } label: {
      Label("Reveal in Finder", systemImage: "folder")
    }
    Button {
      store.send(
        .worktreeOpenInDefaultEditorTapped(
          worktreeID: worktree.id, projectID: project.id, path: worktree.path
        ))
    } label: {
      Label("Open in Default Editor", systemImage: "square.and.pencil")
    }
  }

  // MARK: - Space footer + popover

  private func spaceFooter(activeSpace: Space?) -> some View {
    Button {
      store.send(.spaceFooterTapped)
    } label: {
      HStack(spacing: 8) {
        Image(systemName: "square.stack.3d.up")
          .foregroundStyle(.secondary)
          .accessibilityHidden(true)
        Text(activeSpace?.name ?? "No Space")
          .lineLimit(1)
        Spacer()
        Image(systemName: "chevron.down")
          .foregroundStyle(.secondary)
          .accessibilityHidden(true)
      }
      .padding(.horizontal, 12)
      .padding(.vertical, 10)
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .help("Switch Space")
  }

  @ViewBuilder
  private func spacePopover(catalog: Catalog) -> some View {
    let activeID = catalog.selectedSpaceID
    VStack(alignment: .leading, spacing: 0) {
      ForEach(catalog.spaces) { space in
        Button {
          store.send(.spacePopoverSpaceSelected(space.id))
        } label: {
          HStack(spacing: 8) {
            Image(systemName: space.id == activeID ? "checkmark" : "")
              .frame(width: 14)
              .foregroundStyle(.primary)
              .accessibilityHidden(true)
            Text(space.name)
            Spacer()
          }
          .padding(.horizontal, 12)
          .padding(.vertical, 6)
          .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
      }
      Divider()
      Button {
        store.send(.spacePopoverNewSpaceTapped)
      } label: {
        HStack(spacing: 8) {
          Image(systemName: "plus")
            .frame(width: 14)
            .accessibilityHidden(true)
          Text("New Space")
          Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      Button {
        store.send(.spacePopoverManageSpacesTapped)
      } label: {
        HStack(spacing: 8) {
          Image(systemName: "slider.horizontal.3")
            .frame(width: 14)
            .accessibilityHidden(true)
          Text("Manage Spaces…")
          Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
    }
    .padding(.vertical, 4)
    .frame(minWidth: 220)
  }

  // MARK: - Stub sheets

  private func stubSheet(
    title: String,
    body: String,
    dismiss: HierarchySidebarFeature.Action
  ) -> some View {
    VStack(alignment: .leading, spacing: 12) {
      Text(title).font(.headline)
      Text(body)
        .font(.callout)
        .foregroundStyle(.secondary)
      HStack {
        Spacer()
        Button("Done") { store.send(dismiss) }
          .keyboardShortcut(.defaultAction)
      }
    }
    .padding(24)
    .frame(width: 360)
  }

  // MARK: - Confirmation titles

  private var worktreeRemovalTitle: String {
    if let name = store.pendingWorktreeRemoval?.displayName {
      return "Remove Worktree “\(name)”?"
    }
    return "Remove Worktree?"
  }

  private var projectRemovalTitle: String {
    if let name = store.pendingProjectRemoval?.displayName {
      return "Remove Project “\(name)”?"
    }
    return "Remove Project?"
  }

  // MARK: - GitHub badge + popover

  @ViewBuilder
  fileprivate func gitHubBadge(for worktree: Worktree, in project: Project, space: Space) -> some View {
    if let gitHubStore, let branch = worktree.branch {
      let path = URL(fileURLWithPath: worktree.path)
      WorktreeGitHubBadge(
        store: gitHubStore,
        worktreeID: worktree.id,
        branch: branch,
        worktreePath: path,
        popoverContent: {
          gitHubPopoverContent(
            store: gitHubStore,
            worktreeID: worktree.id,
            branch: branch,
            worktreePath: path
          )
        }
      )
    } else {
      EmptyView()
    }
  }

  @ViewBuilder
  private func gitHubPopoverContent(
    store: StoreOf<GitHubFeature>,
    worktreeID: WorktreeID,
    branch: String,
    worktreePath: URL
  ) -> some View {
    let snapshot = store.snapshots[worktreeID]
    let error = store.lastError[worktreeID]
    let isLoading = store.loading.contains(worktreeID)

    let content: PullRequestPopover.Content = {
      if let error { return .error(error) }
      if let snapshot {
        // 0013 M5: checks now travel inside the snapshot (see the comment on
        // `snapshot.checkRollup`). `latestWorkflowRuns` remains a separately-fetched
        // lazy load on popover-open — the batched query does not include workflow-run
        // IDs yet (Open Question 4 in the design doc).
        let run = store.latestWorkflowRuns[snapshot.number]
        return .loaded(snapshot, checks: snapshot.checkRollup, workflowRun: run)
      }
      if isLoading { return .loading }
      return .noPullRequest(branch: branch)
    }()

    let defaultStrategy = settingsStore.settings.general.defaultMergeStrategy ?? .squash

    let isMutating = store.mutating.contains(worktreeID)

    PullRequestPopover(
      content: content,
      defaultMergeStrategy: defaultStrategy,
      canMerge: !isMutating
        && snapshot?.mergeable == .mergeable
        && snapshot?.state == .open
        && snapshot?.isDraft == false,
      mergeDisabledReason: isMutating
        ? "Another GitHub operation is in flight"
        : Self.mergeDisabledReason(for: snapshot),
      onMerge: { strategy in
        if let pr = snapshot {
          store.send(
            .mergeRequested(worktreeID, prNumber: pr.number, strategy: strategy, worktreePath: worktreePath)
          )
        }
      },
      onClose: {
        if let pr = snapshot {
          store.send(.closeRequested(worktreeID, prNumber: pr.number, worktreePath: worktreePath))
        }
      },
      onMarkReady: {
        if let pr = snapshot {
          store.send(.markReadyRequested(worktreeID, prNumber: pr.number, worktreePath: worktreePath))
        }
      },
      onRerunFailedJobs: {
        if let pr = snapshot, let run = store.latestWorkflowRuns[pr.number] {
          store.send(
            .rerunFailedJobsRequested(worktreeID, runID: run.databaseID, worktreePath: worktreePath)
          )
        }
      },
      onOpenOnWeb: {
        if let url = snapshot?.url {
          store.send(.delegate(.openURL(url)))
        }
      },
      onOpenCheckLog: { url in store.send(.delegate(.openURL(url))) },
      onSetProjectDefaultStrategy: { [settingsStore] strategy in
        // Per-Project override UI is deferred to a follow-up; writing to the *global*
        // default is a useful intermediate behavior — "Set as default" means "use this
        // strategy everywhere". When per-Project lands, this callback splits into two.
        settingsStore.mutateGeneral { $0.defaultMergeStrategy = strategy }
      },
      onRetry: {
        store.send(.refreshRequested(worktreeID, branch: branch, worktreePath: worktreePath))
      }
    )
  }

  private static func mergeDisabledReason(for snapshot: PullRequestSnapshot?) -> String? {
    guard let snapshot else { return "No pull request for this Worktree" }
    if snapshot.state == .merged { return "Pull request already merged" }
    if snapshot.state == .closed { return "Pull request closed" }
    if snapshot.isDraft { return "Pull request is a draft" }
    if snapshot.mergeable == .conflicting { return "Pull request has merge conflicts" }
    if snapshot.mergeable == .unknown { return "Merge status unknown — try refresh" }
    return nil
  }

}

// MARK: - Project header (hover chrome)

/// Dedicated subview so `@State var isHovering` is per-row. Hovering is a
/// view-local concern — not worth promoting to reducer state.
private struct ProjectHeaderRow: View {
  let project: Project
  let space: Space
  let hasUnread: Bool
  /// When `true`, a small inline `ProgressView` replaces the unread dot so
  /// the user can see a reconcile pass is in flight without blocking the
  /// window (P-Q3: inline spinner, never modal).
  var isLoading: Bool = false
  /// Drives the leading disclosure chevron (`chevron.right` collapsed, `chevron.down`
  /// expanded). The parent Button still owns the tap, so this is display-only.
  var isExpanded: Bool = false
  @Bindable var store: StoreOf<HierarchySidebarFeature>
  @State private var isHovering = false
  @State private var isPlusHovering = false
  @State private var isMenuHovering = false

  var body: some View {
    HStack(spacing: 6) {
      Image(systemName: "chevron.right")
        .font(.caption2.weight(.semibold))
        .foregroundStyle(.secondary)
        .rotationEffect(.degrees(isExpanded ? 90 : 0))
        .frame(width: 10, alignment: .center)
        .accessibilityHidden(true)
      Text(project.name)
        .font(.callout)
        .foregroundStyle(isHovering ? .primary : .secondary)
      Spacer()
      if isLoading {
        ProgressView()
          .scaleEffect(0.5)
          .frame(width: 12, height: 12)
          .accessibilityLabel("Loading Project")
      } else if hasUnread {
        Circle()
          .fill(Color.accentColor)
          .frame(width: 6, height: 6)
          .accessibilityLabel("Has unread notifications")
      }
      // Keep the hover chrome from collapsing row width when hidden —
      // use opacity, not conditional rendering.
      HStack(spacing: 2) {
        // Non-git Projects (P-Q4 = a): suppress the Add Worktree affordance.
        // Worktrees are a git-only concept; a scratch folder renders with a
        // single synthetic Worktree and nothing to add.
        if project.supportsWorktrees {
          Button {
            store.send(.projectAddWorktreeTapped(projectID: project.id, inSpace: space.id))
          } label: {
            iconLabel(systemName: "plus", isHovering: isPlusHovering)
              .accessibilityLabel("Add Worktree under this Project")
          }
          .buttonStyle(.plain)
          .onHover { isPlusHovering = $0 }
        }
        Menu {
          Button("Project Options…") {
            store.send(
              .projectOptionsTapped(projectID: project.id, inSpace: space.id)
            )
          }
          let archivedCount = project.worktrees.filter { $0.archived }.count
          Button(
            archivedCount > 0
              ? "Archived Worktrees (\(archivedCount))…"
              : "Archived Worktrees…"
          ) {
            store.send(
              .projectShowArchivedTapped(projectID: project.id, inSpace: space.id)
            )
          }
          Button("Prune Stale Worktrees") {
            store.send(
              .projectPruneTapped(projectID: project.id, inSpace: space.id)
            )
          }
          Divider()
          Button("Remove Project", role: .destructive) {
            store.send(
              .projectRemoveTapped(
                projectID: project.id,
                inSpace: space.id,
                name: project.name
              )
            )
          }
        } label: {
          iconLabel(systemName: "ellipsis", isHovering: isMenuHovering)
            .accessibilityLabel("Project options")
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .onHover { isMenuHovering = $0 }
      }
      .opacity(isHovering ? 1 : 0)
    }
    .contentShape(Rectangle())
    .onHover { isHovering = $0 }
  }

  /// 22×22 hit target with a subtle hover background. Used by the trailing
  /// "+" and "..." affordances so both share the same affordance footprint
  /// and so the click target is comfortably larger than the underlying SF
  /// Symbol glyph.
  @ViewBuilder
  private func iconLabel(systemName: String, isHovering: Bool) -> some View {
    Image(systemName: systemName)
      .font(.system(size: 11, weight: .medium))
      .foregroundStyle(isHovering ? .primary : .secondary)
      .frame(width: 22, height: 22)
      .background(
        Circle().fill(Color.primary.opacity(isHovering ? 0.08 : 0))
      )
      .contentShape(Circle())
  }
}

/// Transparent helper that hunts down the AppKit `NSOutlineView` backing
/// `List(.sidebar)` and applies two leading-edge adjustments:
///
///   1. Zero `NSOutlineView`'s built-in indentation / intercell spacing, so
///      rows have no per-level offset on top of the scroll-view gutter.
///   2. Swap the scroll view's clip view for `_UnclampedClipView`, which pins
///      `bounds.origin.x` at a fixed offset — visually shifting all row
///      content leftward by that amount (defeats SwiftUI sidebar style's
///      internal leading padding without losing hit-testing).
///
/// Retries a few times because the List may not be attached when
/// `viewDidMoveToWindow` first fires. Fires `onReady` once any outline has
/// been patched so the SwiftUI parent can gate visibility on install — the
/// 6pt clip-view shift would otherwise visibly snap rows left mid-launch.
private struct SidebarIndentZeroer: NSViewRepresentable {
  var onReady: () -> Void = {}
  func makeNSView(context: Context) -> NSView {
    let view = _IndentZeroerView()
    view.onReady = onReady
    return view
  }
  func updateNSView(_ nsView: NSView, context: Context) {
    (nsView as? _IndentZeroerView)?.onReady = onReady
  }
}

private final class _IndentZeroerView: NSView {
  var onReady: (() -> Void)?
  private var attempts = 0
  private var didFireReady = false

  override func viewDidMoveToWindow() {
    super.viewDidMoveToWindow()
    attempts = 0
    patch()
  }

  private func patch() {
    guard let root = window?.contentView else { return }
    let outlines = findOutlineViews(in: root)
    if outlines.isEmpty, attempts < 60 {
      attempts += 1
      // First handful of retries fire next-runloop (≈1 frame) so the gate
      // flips before the user can perceive the unshifted rows; fall back
      // to 100ms after that in case the List takes longer than expected.
      let delay: DispatchTime = attempts < 10 ? .now() : .now() + 0.1
      DispatchQueue.main.asyncAfter(deadline: delay) { [weak self] in
        self?.patch()
      }
      return
    }
    for outline in outlines {
      outline.indentationPerLevel = 0
      outline.intercellSpacing = NSSize(width: 0, height: outline.intercellSpacing.height)
      outline.outlineTableColumn?.minWidth = 0
      installUnclampedClipView(for: outline, leadingOffset: 6)
    }
    if !outlines.isEmpty, !didFireReady {
      didFireReady = true
      onReady?()
    }
  }

  /// Replaces the scroll view's clip view with `_UnclampedClipView` (idempotent)
  /// and pins its `leadingOffset`. Preserves the original clip view's
  /// background / cursor / copy-on-scroll state so the visual stays identical
  /// apart from the horizontal shift.
  ///
  /// `constrainBoundsRect:` only fires on AppKit-initiated bounds proposals
  /// (scroll, resize, animation), so on first install we drive `setBoundsOrigin`
  /// + `tile()` ourselves — otherwise the leading shift only "kicks in" after
  /// the first user interaction.
  private func installUnclampedClipView(for outline: NSOutlineView, leadingOffset: CGFloat) {
    guard let scrollView = outline.enclosingScrollView else { return }
    // `bounds.origin.y` on the original clip view encodes the top
    // content-inset / safe-area offset AppKit sets during initial layout
    // (titlebar gutter on a sidebar column). A freshly allocated
    // _UnclampedClipView starts at y=0, so we must carry that y forward —
    // otherwise rows render visibly lower than the eventual steady-state.
    let preservedY = scrollView.contentView.bounds.origin.y
    if !(scrollView.contentView is _UnclampedClipView) {
      let oldClip = scrollView.contentView
      let newClip = _UnclampedClipView()
      newClip.drawsBackground = oldClip.drawsBackground
      newClip.backgroundColor = oldClip.backgroundColor
      newClip.copiesOnScroll = oldClip.copiesOnScroll
      newClip.documentCursor = oldClip.documentCursor
      scrollView.contentView = newClip
      if scrollView.documentView !== outline { scrollView.documentView = outline }
    }
    guard let clip = scrollView.contentView as? _UnclampedClipView else { return }
    clip.leadingOffset = leadingOffset
    clip.setBoundsOrigin(NSPoint(x: leadingOffset, y: preservedY))
    scrollView.tile()
    scrollView.reflectScrolledClipView(clip)
  }

  private func findOutlineViews(in root: NSView) -> [NSOutlineView] {
    var result: [NSOutlineView] = []
    var queue: [NSView] = [root]
    while let v = queue.first {
      queue.removeFirst()
      if let outline = v as? NSOutlineView { result.append(outline) }
      queue.append(contentsOf: v.subviews)
    }
    return result
  }
}

/// `NSClipView` subclass that pins horizontal `bounds.origin.x` to a fixed
/// offset (`leadingOffset`) so the documentView visually shifts left by that
/// amount — bypassing super's clamp that snaps `x` back to 0 for a non-
/// horizontally-scrollable clip view.
///
/// Why pin instead of returning the proposed rect verbatim: AppKit calls
/// `constrainBoundsRect:` during animation / momentum scroll with values
/// that include `±infinity` (legitimate intermediates that super would
/// normally sanitize). Returning identity for those crashes the geometry
/// pipeline (`Invalid view geometry: x is -infinity`). Calling super first
/// hands us a finite, sensible rect; we only override the axis we control.
///
/// Per the AppKit 10.9 release notes and WWDC 2013 §215, `constrainBoundsRect:`
/// is the sanctioned override point for custom positioning; this does NOT
/// disable responsive scrolling (that requires overriding `scrollWheel:`,
/// which we do not do) or elastic scrolling (governed by independent
/// `verticalScrollElasticity`/`horizontalScrollElasticity` properties).
private final class _UnclampedClipView: NSClipView {
  /// Target `bounds.origin.x` — positive shifts documentView visually left
  /// by that many points (we're "scrolling right" without horizontal scroll).
  var leadingOffset: CGFloat = 0

  override func constrainBoundsRect(_ proposedBounds: NSRect) -> NSRect {
    var rect = super.constrainBoundsRect(proposedBounds)
    rect.origin.x = leadingOffset
    return rect
  }
}
