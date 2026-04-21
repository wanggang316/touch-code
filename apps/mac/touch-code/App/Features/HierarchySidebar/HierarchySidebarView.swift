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
  @Environment(HierarchyManager.self) private var hierarchyManager
  @Environment(InboxStore.self) private var inboxStore

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

    VStack(spacing: 0) {
      sidebarToolbar
      Divider()
      treeBody(activeSpace: activeSpace, panelIndex: panelIndex, inbox: inbox)
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

  @ViewBuilder
  private var sidebarToolbar: some View {
    HStack(spacing: 8) {
      Button {
        store.send(.toolbarAddProjectTapped)
      } label: {
        Label("Add Project", systemImage: "plus")
      }
      .buttonStyle(.borderless)
      .help("Add Project to the active Space")
      Spacer()
      Menu {
        // Placeholder for future sidebar-level actions. Empty Menu still
        // renders as a disabled dropdown, which is the spec-approved
        // "stub entry point".
        Text("(No actions yet)")
      } label: {
        Image(systemName: "ellipsis")
          .accessibilityLabel("Sidebar options")
      }
      .menuStyle(.borderlessButton)
      .fixedSize()
      .help("Sidebar options")
    }
    .padding(.horizontal, 12)
    .padding(.vertical, 8)
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
        List {
          ForEach(activeSpace.projects) { project in
            projectSection(project, in: activeSpace, panelIndex: panelIndex, inbox: inbox)
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
    inbox: NotificationInbox
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
          ForEach(project.worktrees.filter { !$0.archived }) { worktree in
            worktreeRow(worktree, in: project, space: space, panelIndex: panelIndex, inbox: inbox)
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
      }
    }
  }

  // MARK: - Worktree row

  private func worktreeRow(
    _ worktree: Worktree,
    in project: Project,
    space: Space,
    panelIndex: [PanelID: WorktreeID],
    inbox: NotificationInbox
  ) -> some View {
    let isSelected = currentSelection.worktreeID == worktree.id
    let unreadCount = inbox.notifications.reduce(into: 0) { total, notification in
      guard notification.isUnread,
            panelIndex[notification.panelID] == worktree.id
      else { return }
      total += 1
    }

    return Button {
      store.send(.worktreeRowTapped(worktree.id, inProject: project.id, inSpace: space.id))
    } label: {
      HStack(spacing: 6) {
        Image(systemName: isSelected ? "circle.fill" : "circle")
          .font(.caption2)
          .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)
          .accessibilityLabel(isSelected ? "Active worktree" : "Inactive worktree")
        VStack(alignment: .leading, spacing: 1) {
          Text(worktree.name)
          if let branch = worktree.branch {
            Text(branch)
              .font(.caption.monospaced())
              .foregroundStyle(.secondary)
          }
        }
        Spacer()
        if unreadCount > 0 {
          Circle()
            .fill(Color.accentColor)
            .frame(width: 6, height: 6)
            .accessibilityLabel("Has \(unreadCount) unread notifications")
        }
      }
    }
    .buttonStyle(.plain)
    .listRowBackground(
      isSelected
        ? Color.accentColor.opacity(0.2)
        : Color.clear
    )
    .contextMenu {
      // Main-checkout guard: the row whose path is the Project's
      // rootPath is the main checkout and cannot be archived or
      // removed from the app (spec W-Q3 guard).
      let isMainCheckout = worktree.path == project.rootPath
      if !isMainCheckout {
        if worktree.archived {
          Button {
            store.send(
              .worktreeUnarchiveTapped(
                worktreeID: worktree.id,
                inProject: project.id,
                inSpace: space.id
              )
            )
          } label: {
            Label("Unarchive Worktree", systemImage: "tray.and.arrow.up")
          }
        } else {
          Button {
            store.send(
              .worktreeArchiveTapped(
                worktreeID: worktree.id,
                inProject: project.id,
                inSpace: space.id,
                name: worktree.name
              )
            )
          } label: {
            Label("Archive Worktree", systemImage: "archivebox")
          }
        }
        Button(role: .destructive) {
          store.send(
            .worktreeRemoveTapped(
              worktreeID: worktree.id,
              inProject: project.id,
              inSpace: space.id,
              name: worktree.name
            )
          )
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
            worktreeID: worktree.id,
            projectID: project.id,
            path: worktree.path
          )
        )
      } label: {
        Label("Open in Default Editor", systemImage: "square.and.pencil")
      }
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
      Image(systemName: "square.stack.3d.up")
        .foregroundStyle(.secondary)
        .accessibilityHidden(true)
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
