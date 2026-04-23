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
  @State private var commandKeyObserver = CommandKeyObserver()

  /// Modifier set for the per-row worktree hotkey. `⌘1`–`⌘9` is already bound to Space
  /// switching (see `MainWindowCommands`), so worktree jumps get `⌃⌘N` instead.
  private static let hotkeyModifiers: EventModifiers = [.command, .control]

  /// Non-archived worktrees in sidebar render order: main checkout first (the row whose
  /// path matches the Project's rootPath), then user-pinned rows (catalog order), then
  /// the rest (catalog order). Main checkout is kept first regardless of `isPinned` so
  /// it never drops below another pin — mirrors supacode's "default" slot.
  static func orderedVisibleWorktrees(in project: Project) -> [Worktree] {
    let visible = project.worktrees.filter { !$0.archived }
    let main = visible.filter { $0.path == project.rootPath }
    let pinned = visible.filter { $0.isPinned && $0.path != project.rootPath }
    let rest = visible.filter { !$0.isPinned && $0.path != project.rootPath }
    return main + pinned + rest
  }

  var body: some View {
    let catalog = hierarchyManager.catalog
    // Build the PanelID→WorktreeID index once per render pass. Worktree rows
    // and Project headers both fold over `inbox.notifications` using this
    // shared index instead of calling `NotificationInbox.unreadCount(
    // forWorktree:in:)` / `.hasUnread(forProject:in:)` per row — those
    // helpers each rebuild the index internally (see the doc-comment in
    // `NotificationInboxAggregation.swift`), which is O(rows × panels) per
    // render. The inline fold is the deliberate amortization the T1 design
    // calls out in §View Composition / §Unread-dot index caching.
    let panelIndex = catalog.panelWorktreeIndex()
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
    treeBody(activeSpace: activeSpace, panelIndex: panelIndex, inbox: inbox)
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
      Text("Removes the Worktree from the Project and closes all its panels. This cannot be undone.")
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
      Text("Removes the Project and closes all its panels. Files on disk are not affected.")
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
    // Force-remove upgrade alert (uncommittedChanges → Force Remove).
    .alert(
      forceRemoveTitle,
      isPresented: Binding(
        get: { store.pendingForceRemove != nil },
        set: { if !$0 { store.send(.worktreeForceRemoveCancelled) } }
      )
    ) {
      Button("Force Remove", role: .destructive) {
        store.send(.worktreeForceRemoveConfirmed)
      }
      Button("Cancel", role: .cancel) {
        store.send(.worktreeForceRemoveCancelled)
      }
    } message: {
      Text(forceRemoveMessage)
    }
    // W-Q3 ladder step 2: warn before hard-killing live terminals.
    .alert(
      runningTerminalTitle,
      isPresented: Binding(
        get: { store.pendingRunningTerminalWarning != nil },
        set: { if !$0 { store.send(.worktreeRunningTerminalWarningCancelled) } }
      )
    ) {
      Button("Terminate & Remove", role: .destructive) {
        store.send(.worktreeRunningTerminalWarningConfirmed)
      }
      Button("Cancel", role: .cancel) {
        store.send(.worktreeRunningTerminalWarningCancelled)
      }
    } message: {
      Text(runningTerminalMessage)
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
    ToolbarItem(placement: .primaryAction) {
      Menu {
        // Placeholder for future sidebar-level actions. Empty Menu still
        // renders as a disabled dropdown, which is the spec-approved
        // "stub entry point".
        Text("(No actions yet)")
      } label: {
        Image(systemName: "ellipsis")
          .accessibilityLabel("Sidebar options")
      }
      .help("Sidebar options")
    }
  }

  // MARK: - Tree

  @ViewBuilder
  private func treeBody(
    activeSpace: Space?,
    panelIndex: [PanelID: WorktreeID],
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
        List {
          ForEach(activeSpace.projects) { project in
            projectSection(
              project,
              in: activeSpace,
              panelIndex: panelIndex,
              inbox: inbox,
              hotkeyIndex: hotkeyIndex
            )
          }
          .onMove { source, destination in
            store.send(
              .reorderProjects(
                from: source,
                to: destination,
                inSpace: activeSpace.id
              )
            )
          }
        }
        .listStyle(.sidebar)
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
    panelIndex: [PanelID: WorktreeID],
    inbox: NotificationInbox,
    hotkeyIndex: [WorktreeID: Int]
  ) -> some View {
    let projectHasUnread = inbox.notifications.contains { notification in
      guard notification.isUnread,
        let worktreeID = panelIndex[notification.panelID]
      else { return false }
      return project.worktrees.contains(where: { $0.id == worktreeID })
    }

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
            store.send(.projectRemoveTapped(
              projectID: project.id,
              inSpace: space.id,
              name: project.name
            ))
          }
        )
      case .loading, .ready:
        DisclosureGroup(
          isExpanded: Binding(
            get: { store.expandedProjectIDs.contains(project.id) },
            set: { _ in store.send(.toggleProjectExpansion(project.id)) }
          )
        ) {
          // Filter archived worktrees out of the main list — they surface
          // through the Archived Worktrees sheet instead.
          ForEach(Self.orderedVisibleWorktrees(in: project)) { worktree in
            worktreeRow(
              worktree,
              in: project,
              space: space,
              panelIndex: panelIndex,
              inbox: inbox,
              hotkeySlot: hotkeyIndex[worktree.id]
            )
          }
        } label: {
          ProjectHeaderRow(
            project: project,
            space: space,
            hasUnread: projectHasUnread,
            isLoading: project.loadState == .loading,
            store: store
          )
        }
        // Hide the leading disclosure chevron — the hover-revealed ellipsis on the
        // right is the only control that needs to be visible, and tapping anywhere on
        // the row toggles expansion. Matches supacode's plainer header treatment.
        .disclosureGroupStyle(HeaderOnlyDisclosureGroupStyle())
      }
    }
  }

  // MARK: - Worktree row

  private func worktreeRow(
    _ worktree: Worktree,
    in project: Project,
    space: Space,
    panelIndex: [PanelID: WorktreeID],
    inbox: NotificationInbox,
    hotkeySlot: Int?
  ) -> some View {
    let isSelected = currentSelection.worktreeID == worktree.id
    let unreadCount = inbox.notifications.reduce(into: 0) { total, notification in
      guard notification.isUnread,
        panelIndex[notification.panelID] == worktree.id
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
    // `.listRowInsets` is a no-op here because the surrounding
    // `HeaderOnlyDisclosureGroupStyle` wraps worktree rows in a plain VStack, so
    // SwiftUI does not treat them as native List rows. Use `.padding` directly.
    .padding(.vertical, 6)
    .padding(.horizontal, 12)
    .frame(maxWidth: .infinity, alignment: .leading)
    .contentShape(Rectangle())
    .background(
      isSelected
        ? Color.accentColor.opacity(0.2)
        : Color.clear
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
          store.send(.worktreeUnarchiveTapped(
            worktreeID: worktree.id, inProject: project.id, inSpace: space.id
          ))
        } label: {
          Label("Unarchive Worktree", systemImage: "tray.and.arrow.up")
        }
      } else {
        Button {
          store.send(.worktreeArchiveTapped(
            worktreeID: worktree.id, inProject: project.id, inSpace: space.id, name: worktree.name
          ))
        } label: {
          Label("Archive Worktree", systemImage: "archivebox")
        }
      }
      Button(role: .destructive) {
        store.send(.worktreeRemoveTapped(
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
      store.send(.worktreeOpenInDefaultEditorTapped(
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

  private var forceRemoveTitle: String {
    guard let pending = store.pendingForceRemove else { return "Force Remove?" }
    return "Force Remove “\(pending.displayName)”?"
  }

  private var forceRemoveMessage: String {
    guard let pending = store.pendingForceRemove else {
      return "Uncommitted changes will be discarded. This cannot be undone."
    }
    if pending.uncommittedFiles.isEmpty {
      return "Uncommitted changes will be discarded. This cannot be undone."
    }
    let shown = pending.uncommittedFiles.prefix(3).joined(separator: ", ")
    let more = pending.uncommittedFiles.count > 3
      ? " and \(pending.uncommittedFiles.count - 3) more"
      : ""
    return "\(pending.uncommittedFiles.count) file(s) have uncommitted changes: \(shown)\(more). Force remove will discard them. This cannot be undone."
  }

  private var runningTerminalTitle: String {
    guard let pending = store.pendingRunningTerminalWarning else {
      return "Running processes"
    }
    return "Terminate \(pending.count) running process\(pending.count == 1 ? "" : "es")?"
  }

  private var runningTerminalMessage: String {
    guard let pending = store.pendingRunningTerminalWarning else { return "" }
    return "Force-removing “\(pending.displayName)” will terminate \(pending.count) running terminal process\(pending.count == 1 ? "" : "es") in that Worktree."
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
  @Bindable var store: StoreOf<HierarchySidebarFeature>
  @State private var isHovering = false

  var body: some View {
    HStack(spacing: 6) {
      Text(project.name)
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
      HStack(spacing: 4) {
        // Non-git Projects (P-Q4 = a): suppress the Add Worktree affordance.
        // Worktrees are a git-only concept; a scratch folder renders with a
        // single synthetic Worktree and nothing to add.
        if project.supportsWorktrees {
          Button {
            store.send(.projectAddWorktreeTapped(projectID: project.id, inSpace: space.id))
          } label: {
            Image(systemName: "plus")
              .accessibilityLabel("Add Worktree under this Project")
          }
          .buttonStyle(.borderless)
        }
        Menu {
          Button("Project Options…") {
            store.send(
              .projectOptionsTapped(projectID: project.id, inSpace: space.id)
            )
          }
          let archivedCount = project.worktrees.filter { $0.archived }.count
          Button(archivedCount > 0
                 ? "Archived Worktrees (\(archivedCount))…"
                 : "Archived Worktrees…") {
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
          Image(systemName: "ellipsis")
            .accessibilityLabel("Project options")
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
      }
      .opacity(isHovering ? 1 : 0)
    }
    .contentShape(Rectangle())
    .onHover { isHovering = $0 }
  }
}

/// Drops the leading disclosure chevron from a `DisclosureGroup` and makes the entire
/// label tappable to toggle expansion. The expansion binding is forwarded to the parent's
/// reducer via the label's own binding, so tapping the row still animates open/closed.
private struct HeaderOnlyDisclosureGroupStyle: DisclosureGroupStyle {
  func makeBody(configuration: Configuration) -> some View {
    VStack(spacing: 0) {
      Button {
        withAnimation(.easeInOut(duration: 0.18)) {
          configuration.isExpanded.toggle()
        }
      } label: {
        configuration.label
          .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      if configuration.isExpanded {
        configuration.content
      }
    }
  }
}
