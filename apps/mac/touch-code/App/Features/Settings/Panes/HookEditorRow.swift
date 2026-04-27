import SwiftUI
import TouchCodeCore

/// Inline-expandable editor for a single `HookSubscription`. Collapsed
/// shows event + scope-kind summary + command preview; expanded shows
/// every editable field (event, scope, command, matchPattern + flags,
/// mode, timeout, cwd, env, disabled) with Save / Cancel / Delete.
///
/// The row owns no persistent state — the parent pane writes through
/// `HookConfigClient.upsert` / `delete` after `onSave` / `onDelete`. A
/// local `@State draft` carries in-flight edits; Save validates first
/// and only fires `onSave` on success. Validation errors render inline
/// red text under the offending field and the row stays expanded.
struct HookEditorRow: View {
  let subscription: HookSubscription
  let catalog: ScopePickerCatalog
  let currentProjectID: ProjectID
  let onSave: (HookSubscription) -> Void
  let onDelete: () -> Void
  /// `true` when the row should render expanded on first paint. The Add
  /// Hook flow seeds drafts already expanded; existing rows start collapsed.
  var startExpanded: Bool = false

  @State private var isExpanded: Bool
  @State private var draft: Draft
  @State private var showDeleteConfirm = false
  @State private var validationErrors: ValidationErrors = .init()

  init(
    subscription: HookSubscription,
    catalog: ScopePickerCatalog,
    currentProjectID: ProjectID,
    onSave: @escaping (HookSubscription) -> Void,
    onDelete: @escaping () -> Void,
    startExpanded: Bool = false
  ) {
    self.subscription = subscription
    self.catalog = catalog
    self.currentProjectID = currentProjectID
    self.onSave = onSave
    self.onDelete = onDelete
    self.startExpanded = startExpanded
    self._isExpanded = State(initialValue: startExpanded)
    self._draft = State(initialValue: Draft(from: subscription))
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      if isExpanded {
        expanded
      } else {
        collapsed
      }
    }
    .padding(.vertical, 4)
    .onChange(of: subscription) { _, newValue in
      if !isExpanded {
        draft = Draft(from: newValue)
      }
    }
  }

  // MARK: - Collapsed

  @ViewBuilder
  private var collapsed: some View {
    HStack(alignment: .top, spacing: 10) {
      Circle()
        .fill(subscription.disabled ? Color.secondary : Color.green)
        .frame(width: 8, height: 8)
        .padding(.top, 6)

      VStack(alignment: .leading, spacing: 2) {
        Text(subscription.command.isEmpty ? "—" : subscription.command)
          .font(.system(.body, design: .monospaced))
          .lineLimit(1)
          .truncationMode(.tail)
        Text("\(subscription.event.rawValue) — scope: \(scopeSummary)")
          .font(.caption)
          .foregroundStyle(.secondary)
      }
      Spacer(minLength: 8)
      Button {
        draft = Draft(from: subscription)
        validationErrors = .init()
        isExpanded = true
      } label: {
        Image(systemName: "pencil")
      }
      .buttonStyle(.borderless)
      .help("Edit")
    }
  }

  private var scopeSummary: String {
    ScopeKindTag.kind(of: subscription.scope).rawValue
  }

  // MARK: - Expanded

  @ViewBuilder
  private var expanded: some View {
    VStack(alignment: .leading, spacing: 10) {
      LabeledContent("Event") {
        Picker(
          "",
          selection: Binding(
            get: { draft.event },
            set: { draft.event = $0 }
          )
        ) {
          ForEach(HookEvent.allCases, id: \.self) { event in
            Text(event.rawValue).tag(event)
          }
        }
        .labelsHidden()
        .pickerStyle(.menu)
      }

      ScopePickerView(
        scope: Binding(
          get: { draft.scope },
          set: { draft.scope = $0 }
        ),
        catalog: catalog,
        currentProjectID: currentProjectID
      )
      if let err = validationErrors.scope {
        errorText(err)
      }

      VStack(alignment: .leading, spacing: 4) {
        Text("Command")
        TextEditor(text: Binding(get: { draft.command }, set: { draft.command = $0 }))
          .font(.system(.body, design: .monospaced))
          .frame(minHeight: 70)
          .overlay(
            RoundedRectangle(cornerRadius: 4)
              .stroke(
                validationErrors.command == nil
                  ? Color.secondary.opacity(0.3) : Color.red,
                lineWidth: 1
              )
          )
        if let err = validationErrors.command {
          errorText(err)
        }
      }

      LabeledContent("Match pattern") {
        TextField(
          "",
          text: Binding(
            get: { draft.matchPattern },
            set: { draft.matchPattern = $0 }
          ),
          prompt: Text("optional regex")
        )
      }
      HStack(spacing: 16) {
        Toggle("caseInsensitive", isOn: flagBinding(.caseInsensitive))
        Toggle("multiline", isOn: flagBinding(.multiline))
        Toggle("dotAll", isOn: flagBinding(.dotAll))
        Spacer()
      }
      .toggleStyle(.checkbox)
      .font(.caption)

      LabeledContent("Mode") {
        Picker(
          "",
          selection: Binding(
            get: { draft.mode },
            set: { draft.mode = $0 }
          )
        ) {
          Text("fireAndForget").tag(HookSubscription.Mode.fireAndForget)
          Text("awaitActions").tag(HookSubscription.Mode.awaitActions)
        }
        .labelsHidden()
        .pickerStyle(.menu)
      }

      LabeledContent("Timeout") {
        HStack(spacing: 6) {
          Stepper(
            value: Binding(
              get: { draft.timeoutSeconds },
              set: { draft.timeoutSeconds = $0 }
            ),
            in: 0...600,
            step: 1
          ) {
            Text("\(Int(draft.timeoutSeconds)) seconds")
          }
        }
      }
      if let err = validationErrors.timeout {
        errorText(err)
      }

      LabeledContent("Working directory") {
        TextField(
          "",
          text: Binding(
            get: { draft.cwd },
            set: { draft.cwd = $0 }
          ),
          prompt: Text("optional, defaults to pane cwd")
        )
      }

      VStack(alignment: .leading, spacing: 4) {
        Text("Environment")
          .font(.caption)
          .foregroundStyle(.secondary)
        EnvironmentEditorView(
          envVars: Binding(
            get: { draft.env },
            set: { draft.env = $0 }
          ),
          onChange: { key, value in
            if let value {
              draft.env[key] = value
            } else {
              draft.env.removeValue(forKey: key)
            }
          },
          footer: ""
        )
      }

      Toggle("Disabled", isOn: Binding(get: { draft.disabled }, set: { draft.disabled = $0 }))

      if showsMoveTooltip {
        Text("This hook will move to the Global list.")
          .font(.caption)
          .foregroundStyle(.orange)
      }

      HStack {
        Button(role: .destructive) {
          showDeleteConfirm = true
        } label: {
          Text("Delete")
        }
        .confirmationDialog(
          "Delete this hook?",
          isPresented: $showDeleteConfirm,
          titleVisibility: .visible
        ) {
          Button("Delete", role: .destructive) { onDelete() }
          Button("Cancel", role: .cancel) {}
        }

        Spacer()

        Button("Cancel") {
          draft = Draft(from: subscription)
          validationErrors = .init()
          isExpanded = false
        }
        .keyboardShortcut(.cancelAction)

        Button("Save") {
          let result = HookEditorRow.validate(draft)
          if result.isValid,
            let payload = HookEditorRow.makeSubscription(
              from: draft,
              existingID: subscription.id
            )
          {
            validationErrors = .init()
            onSave(payload)
            isExpanded = false
          } else {
            validationErrors = result
          }
        }
        .keyboardShortcut(.defaultAction)
      }
    }
  }

  // MARK: - Helpers

  private var showsMoveTooltip: Bool {
    !HookEditorRow.scopeBindsToCurrentProject(
      draft.scope,
      currentProjectID: currentProjectID,
      catalog: catalog
    )
  }

  private func flagBinding(_ flag: HookSubscription.RegexFlags) -> Binding<Bool> {
    Binding(
      get: { draft.matchFlags.contains(flag) },
      set: { newValue in
        if newValue {
          draft.matchFlags.insert(flag)
        } else {
          draft.matchFlags.remove(flag)
        }
      }
    )
  }

  @ViewBuilder
  private func errorText(_ message: String) -> some View {
    Text(message)
      .font(.caption)
      .foregroundStyle(.red)
  }

  // MARK: - Pure helpers

  /// Mutable buffer mirroring the editable fields of `HookSubscription`.
  /// `Equatable` so unit tests can compare drafts; SwiftUI re-binds on
  /// every render anyway. `nonisolated` because the validator and the
  /// `makeSubscription` builder are pure helpers driven from tests.
  nonisolated struct Draft: Equatable {
    var event: HookEvent
    var scope: HookSubscription.Scope
    var command: String
    var matchPattern: String
    var matchFlags: HookSubscription.RegexFlags
    var mode: HookSubscription.Mode
    var timeoutSeconds: Double
    var cwd: String
    var env: [String: String]
    var disabled: Bool

    init(from sub: HookSubscription) {
      self.event = sub.event
      self.scope = sub.scope
      self.command = sub.command
      self.matchPattern = sub.matchPattern ?? ""
      self.matchFlags = sub.matchFlags
      self.mode = sub.mode
      self.timeoutSeconds = sub.timeoutSeconds
      self.cwd = sub.cwd ?? ""
      self.env = sub.env
      self.disabled = sub.disabled
    }
  }

  nonisolated struct ValidationErrors: Equatable {
    var command: String?
    var scope: String?
    var timeout: String?

    var isValid: Bool {
      command == nil && scope == nil && timeout == nil
    }
  }

  /// Pure validator. Surfaces all field-level errors at once so the row
  /// flags every problem on a single Save attempt.
  nonisolated static func validate(_ draft: Draft) -> ValidationErrors {
    var errors = ValidationErrors()

    let trimmedCommand = draft.command.trimmingCharacters(in: .whitespacesAndNewlines)
    if trimmedCommand.isEmpty {
      errors.command = "Command is required."
    }

    if draft.timeoutSeconds < 0 || draft.timeoutSeconds > 600 {
      errors.timeout = "Timeout must be between 0 and 600 seconds."
    }

    switch draft.scope {
    case .anyPane:
      break
    case .paneLabel(let s), .tabLabel(let s):
      if s.trimmingCharacters(in: .whitespaces).isEmpty {
        errors.scope = "Label is required for this scope."
      }
    case .worktreePathGlob(let s), .projectPathGlob(let s):
      if s.trimmingCharacters(in: .whitespaces).isEmpty {
        errors.scope = "Glob pattern is required for this scope."
      }
    case .paneID, .tabID, .worktreeID, .projectID:
      // Picker selection is required; the picker's "—" sentinel does not
      // bind a fresh ID into `scope`. We additionally treat a synthesized
      // (kind-switch default) UUID as invalid only when the catalog cannot
      // resolve it. The picker view sets a real ID on selection.
      // Validation here is intentionally permissive: any non-nil UUID
      // passes — the catalog membership check happens in the picker
      // setter. See `scopeBindsToCurrentProject` for the project-binding
      // rule used for the move tooltip (separate concern).
      break
    }

    return errors
  }

  /// Build the persisted `HookSubscription` from the draft. Returns nil
  /// only when `validate(...)` would also fail; callers should validate
  /// first and then call this.
  nonisolated static func makeSubscription(
    from draft: Draft,
    existingID: UUID
  ) -> HookSubscription? {
    let trimmedCommand = draft.command.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmedCommand.isEmpty else { return nil }
    let trimmedPattern = draft.matchPattern.trimmingCharacters(in: .whitespacesAndNewlines)
    let trimmedCwd = draft.cwd.trimmingCharacters(in: .whitespacesAndNewlines)
    return HookSubscription(
      id: existingID,
      event: draft.event,
      command: trimmedCommand,
      matchPattern: trimmedPattern.isEmpty ? nil : trimmedPattern,
      matchFlags: draft.matchFlags,
      scope: draft.scope,
      timeoutSeconds: draft.timeoutSeconds,
      mode: draft.mode,
      cwd: trimmedCwd.isEmpty ? nil : trimmedCwd,
      env: draft.env,
      allowRawOutput: false,
      allowRawInput: false,
      idleThresholdSeconds: nil,
      disabled: draft.disabled
    )
  }

  /// Approximate "does this scope bind to the current Project?" check.
  /// Drives the Save-time tooltip ("This hook will move to the Global
  /// list"). Mirrors the rule in `ProjectSettingsFeature.classifyHooks`
  /// for ID-based scopes; glob scopes are pessimistically treated as
  /// non-project so the tooltip nudges the user to a stricter scope.
  nonisolated static func scopeBindsToCurrentProject(
    _ scope: HookSubscription.Scope,
    currentProjectID: ProjectID,
    catalog: ScopePickerCatalog
  ) -> Bool {
    switch scope {
    case .anyPane, .paneLabel, .tabLabel:
      return false
    case .projectID(let id):
      return id == currentProjectID
    case .projectPathGlob:
      return false
    case .worktreeID(let id):
      return catalog.worktrees.contains { $0.id == id }
    case .worktreePathGlob:
      return false
    case .paneID(let id):
      return catalog.panes.contains { $0.id == id }
    case .tabID(let id):
      return catalog.tabs.contains { $0.id == id }
    }
  }
}
