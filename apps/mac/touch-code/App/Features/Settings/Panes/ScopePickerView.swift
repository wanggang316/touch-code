import SwiftUI
import TouchCodeCore

/// On-wire-stable mirror of `HookSubscription.Scope`'s nine cases. Exists
/// because `Scope` carries associated values, so a `Picker` cannot bind to
/// it directly. The pure mapping helpers `kind(of:)` and `scope(forKind:bufferText:)`
/// keep the conversion testable without a SwiftUI view tree.
nonisolated enum ScopeKindTag: String, CaseIterable, Hashable {
  case anyPane
  case paneID
  case paneLabel
  case tabID
  case tabLabel
  case worktreeID
  case worktreePathGlob
  case projectID
  case projectPathGlob

  /// Whether this kind's value control is a free-form TextField. Glob and
  /// label scopes share the `[ScopeKindTag: String]` buffer; ID-based scopes
  /// do not because their value comes from a Picker selection.
  var usesTextBuffer: Bool {
    switch self {
    case .paneLabel, .tabLabel, .worktreePathGlob, .projectPathGlob:
      return true
    case .anyPane, .paneID, .tabID, .worktreeID, .projectID:
      return false
    }
  }

  var displayLabel: String {
    switch self {
    case .anyPane: return "Any pane"
    case .paneID: return "Pane (by id)"
    case .paneLabel: return "Pane label"
    case .tabID: return "Tab (by id)"
    case .tabLabel: return "Tab label"
    case .worktreeID: return "Worktree (by id)"
    case .worktreePathGlob: return "Worktree path glob"
    case .projectID: return "Project (by id)"
    case .projectPathGlob: return "Project path glob"
    }
  }

  static func kind(of scope: HookSubscription.Scope) -> ScopeKindTag {
    switch scope {
    case .anyPane: return .anyPane
    case .paneID: return .paneID
    case .paneLabel: return .paneLabel
    case .tabID: return .tabID
    case .tabLabel: return .tabLabel
    case .worktreeID: return .worktreeID
    case .worktreePathGlob: return .worktreePathGlob
    case .projectID: return .projectID
    case .projectPathGlob: return .projectPathGlob
    }
  }
}

/// Pane-side catalog projection for the ScopePickerView. The pane's view
/// derives this from `Catalog` once per render so the picker takes flat
/// arrays rather than walking the catalog tree on each row.
nonisolated struct ScopePickerCatalog: Equatable {
  struct PaneEntry: Equatable, Identifiable {
    let id: PaneID
    let label: String
  }
  struct TabEntry: Equatable, Identifiable {
    let id: TabID
    let label: String
  }
  struct WorktreeEntry: Equatable, Identifiable {
    let id: WorktreeID
    let label: String
  }
  struct ProjectEntry: Equatable, Identifiable {
    let id: ProjectID
    let label: String
  }

  var panes: [PaneEntry] = []
  var tabs: [TabEntry] = []
  var worktrees: [WorktreeEntry] = []
  var projects: [ProjectEntry] = []

  /// Build a projection from a `Catalog` snapshot. Panes / tabs / worktrees
  /// are restricted to the children of `currentProjectID`; projects covers
  /// all open Projects across every Space.
  static func from(catalog: Catalog, currentProjectID: ProjectID) -> ScopePickerCatalog {
    var result = ScopePickerCatalog()

    for space in catalog.spaces {
      for project in space.projects {
        result.projects.append(ProjectEntry(id: project.id, label: project.name))
        guard project.id == currentProjectID else { continue }

        for worktree in project.worktrees {
          let wtLabel = worktree.branch.map { "\(worktree.name) (\($0))" } ?? worktree.name
          result.worktrees.append(WorktreeEntry(id: worktree.id, label: wtLabel))

          for (tabIndex, tab) in worktree.tabs.enumerated() {
            let tabName = tab.name ?? "Tab \(tabIndex + 1)"
            let tabLabel = "\(wtLabel) — \(tabName)"
            result.tabs.append(TabEntry(id: tab.id, label: tabLabel))

            for (paneIndex, pane) in tab.panes.enumerated() {
              let paneLabel = "\(tabLabel) — Pane \(paneIndex + 1)"
              _ = pane.workingDirectory  // labels could include cwd; keep concise for now
              result.panes.append(PaneEntry(id: pane.id, label: paneLabel))
            }
          }
        }
      }
    }
    return result
  }
}

/// Kind-aware Scope picker for a `HookSubscription.Scope` binding. Two
/// stacked controls: a kind Picker on top, then a value control whose
/// shape depends on the chosen kind. An internal `[ScopeKindTag: String]`
/// buffer preserves typed text across kind toggles for the four text-valued
/// kinds (`paneLabel` / `tabLabel` / `worktreePathGlob` / `projectPathGlob`).
struct ScopePickerView: View {
  @Binding var scope: HookSubscription.Scope
  let catalog: ScopePickerCatalog
  let currentProjectID: ProjectID

  /// Holds typed text for the four text-valued scope kinds. Survives kind
  /// toggles so bouncing between `.paneLabel` and `.tabLabel` keeps the
  /// user's input. ID-based kinds never read or write here.
  @State private var textBuffer: [ScopeKindTag: String]

  init(
    scope: Binding<HookSubscription.Scope>,
    catalog: ScopePickerCatalog,
    currentProjectID: ProjectID
  ) {
    self._scope = scope
    self.catalog = catalog
    self.currentProjectID = currentProjectID

    var initial: [ScopeKindTag: String] = [:]
    switch scope.wrappedValue {
    case .paneLabel(let s): initial[.paneLabel] = s
    case .tabLabel(let s): initial[.tabLabel] = s
    case .worktreePathGlob(let s): initial[.worktreePathGlob] = s
    case .projectPathGlob(let s): initial[.projectPathGlob] = s
    default: break
    }
    self._textBuffer = State(initialValue: initial)
  }

  private var currentKind: ScopeKindTag {
    ScopeKindTag.kind(of: scope)
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      LabeledContent("Scope") {
        Picker(
          "",
          selection: Binding(
            get: { currentKind },
            set: { newKind in
              switchKind(to: newKind)
            }
          )
        ) {
          ForEach(ScopeKindTag.allCases, id: \.self) { tag in
            Text(tag.displayLabel).tag(tag)
          }
        }
        .labelsHidden()
        .pickerStyle(.menu)
      }

      valueControl
    }
  }

  // MARK: - Value control

  @ViewBuilder
  private var valueControl: some View {
    switch currentKind {
    case .anyPane:
      EmptyView()

    case .paneLabel:
      textValueField(placeholder: "Label", kind: .paneLabel)
    case .tabLabel:
      textValueField(placeholder: "Label", kind: .tabLabel)
    case .worktreePathGlob:
      textValueField(placeholder: "**/feature/*", kind: .worktreePathGlob)
    case .projectPathGlob:
      textValueField(placeholder: "**/repos/*", kind: .projectPathGlob)

    case .paneID:
      idPicker(
        entries: catalog.panes,
        selectedID: { if case .paneID(let id) = scope { return id } else { return nil } },
        wrap: { .paneID($0) }
      )
    case .tabID:
      idPicker(
        entries: catalog.tabs,
        selectedID: { if case .tabID(let id) = scope { return id } else { return nil } },
        wrap: { .tabID($0) }
      )
    case .worktreeID:
      idPicker(
        entries: catalog.worktrees,
        selectedID: { if case .worktreeID(let id) = scope { return id } else { return nil } },
        wrap: { .worktreeID($0) }
      )
    case .projectID:
      idPicker(
        entries: catalog.projects,
        selectedID: { if case .projectID(let id) = scope { return id } else { return nil } },
        wrap: { .projectID($0) }
      )
    }
  }

  @ViewBuilder
  private func textValueField(placeholder: String, kind: ScopeKindTag) -> some View {
    LabeledContent("Value") {
      TextField(
        placeholder,
        text: Binding(
          get: { textBuffer[kind] ?? "" },
          set: { newValue in
            textBuffer[kind] = newValue
            scope = ScopePickerView.scope(forKind: kind, value: newValue)
          }
        )
      )
    }
  }

  @ViewBuilder
  private func idPicker<E: Identifiable & Equatable>(
    entries: [E],
    selectedID: @escaping () -> E.ID?,
    wrap: @escaping (E.ID) -> HookSubscription.Scope
  ) -> some View where E.ID: Hashable {
    LabeledContent("Value") {
      if entries.isEmpty {
        Text("No entries available")
          .foregroundStyle(.secondary)
          .font(.caption)
      } else {
        Picker(
          "",
          selection: Binding<E.ID?>(
            get: { selectedID() },
            set: { newID in
              if let id = newID {
                scope = wrap(id)
              }
            }
          )
        ) {
          // Sentinel "—" for unset; the bound value can be nil after a kind
          // switch. Not selecting it is invalid (Save validates).
          Text("—").tag(Optional<E.ID>.none)
          ForEach(entries) { entry in
            Text(label(for: entry)).tag(Optional<E.ID>.some(entry.id))
          }
        }
        .labelsHidden()
        .pickerStyle(.menu)
      }
    }
  }

  // Local label accessor to avoid forcing the entry generic to expose `.label`.
  private func label<E: Identifiable>(for entry: E) -> String {
    if let pane = entry as? ScopePickerCatalog.PaneEntry { return pane.label }
    if let tab = entry as? ScopePickerCatalog.TabEntry { return tab.label }
    if let wt = entry as? ScopePickerCatalog.WorktreeEntry { return wt.label }
    if let proj = entry as? ScopePickerCatalog.ProjectEntry { return proj.label }
    return String(describing: entry.id)
  }

  // MARK: - Kind switching

  private func switchKind(to newKind: ScopeKindTag) {
    if newKind == currentKind { return }
    let result = ScopePickerView.applyKindSwitch(
      from: scope,
      to: newKind,
      buffer: textBuffer,
      currentProjectID: currentProjectID
    )
    textBuffer = result.buffer
    scope = result.scope
  }

  // MARK: - Pure helpers (testable without SwiftUI)

  /// Map `(ScopeKindTag, value)` to `Scope` for text-valued kinds.
  /// `currentProjectID` is consulted only for `.projectID` so a fresh kind
  /// switch lands on the current Project; ID-based kinds without a sensible
  /// default fall back to a fresh UUID (the Picker shows "—" until the user
  /// picks one and Save's validation fires).
  nonisolated static func scope(
    forKind kind: ScopeKindTag,
    value: String,
    currentProjectID: ProjectID? = nil
  ) -> HookSubscription.Scope {
    switch kind {
    case .anyPane: return .anyPane
    case .paneLabel: return .paneLabel(value)
    case .tabLabel: return .tabLabel(value)
    case .worktreePathGlob: return .worktreePathGlob(value)
    case .projectPathGlob: return .projectPathGlob(value)
    case .paneID: return .paneID(PaneID())
    case .tabID: return .tabID(TabID())
    case .worktreeID: return .worktreeID(WorktreeID())
    case .projectID: return .projectID(currentProjectID ?? ProjectID())
    }
  }

  /// Pure transition for the kind picker. Returns the updated `(scope, buffer)`
  /// pair for the new kind. Mirrors `switchKind(to:)`'s in-view logic so unit
  /// tests can drive the toggle without SwiftUI.
  nonisolated static func applyKindSwitch(
    from currentScope: HookSubscription.Scope,
    to newKind: ScopeKindTag,
    buffer: [ScopeKindTag: String],
    currentProjectID: ProjectID
  ) -> (scope: HookSubscription.Scope, buffer: [ScopeKindTag: String]) {
    var nextBuffer = buffer
    let outgoingKind = ScopeKindTag.kind(of: currentScope)
    if outgoingKind.usesTextBuffer {
      switch currentScope {
      case .paneLabel(let s): nextBuffer[.paneLabel] = s
      case .tabLabel(let s): nextBuffer[.tabLabel] = s
      case .worktreePathGlob(let s): nextBuffer[.worktreePathGlob] = s
      case .projectPathGlob(let s): nextBuffer[.projectPathGlob] = s
      default: break
      }
    }
    let nextScope = scope(
      forKind: newKind,
      value: nextBuffer[newKind] ?? "",
      currentProjectID: currentProjectID
    )
    return (nextScope, nextBuffer)
  }
}

#Preview("anyPane") {
  StatefulPreviewWrapper(HookSubscription.Scope.anyPane) { binding in
    ScopePickerView(
      scope: binding,
      catalog: ScopePickerCatalog(),
      currentProjectID: ProjectID()
    )
    .padding()
    .frame(width: 480)
  }
}

private struct StatefulPreviewWrapper<Value, Content: View>: View {
  @State private var value: Value
  let content: (Binding<Value>) -> Content
  init(_ initial: Value, @ViewBuilder _ content: @escaping (Binding<Value>) -> Content) {
    self._value = State(initialValue: initial)
    self.content = content
  }
  var body: some View { content($value) }
}
