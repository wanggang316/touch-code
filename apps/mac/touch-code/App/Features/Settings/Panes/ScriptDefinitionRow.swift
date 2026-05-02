import SwiftUI
import TouchCodeCore

/// Modal sheet for adding or editing one user-defined `ScriptDefinition`.
///
/// Body is a System-Settings-style grouped `Form` with one field per
/// row. Edits accumulate in a local `draft` buffer; Save commits the
/// buffer through the upstream closure, Cancel discards. Sheet is
/// dismissed by the parent in either case.
///
/// `kind` is fixed at script-creation time — the only place to choose
/// kind is the parent's "Add" menu — so this sheet shows it as a
/// read-only badge in the title rather than a picker. Users delete and
/// re-add to change kind.
struct ScriptEditorSheet: View {
  let initialScript: ScriptDefinition
  /// True when the script does not yet exist in the project's
  /// `[ScriptDefinition]`. Drives the sheet title (Add vs. Edit) and
  /// the Save button's enabled rule (a brand-new script with empty
  /// command shouldn't persist).
  let isNew: Bool
  let onSave: (ScriptDefinition) -> Void
  let onCancel: () -> Void

  @State private var draft: ScriptDefinition

  init(
    script: ScriptDefinition,
    isNew: Bool,
    onSave: @escaping (ScriptDefinition) -> Void,
    onCancel: @escaping () -> Void
  ) {
    self.initialScript = script
    self.isNew = isNew
    self.onSave = onSave
    self.onCancel = onCancel
    self._draft = State(initialValue: script)
  }

  var body: some View {
    NavigationStack {
      Form {
        identitySection
        commandSection
        runtimeSection
      }
      .formStyle(.grouped)
      .navigationTitle(isNew ? "Add Script" : "Edit Script")
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button("Cancel", action: onCancel)
        }
        ToolbarItem(placement: .confirmationAction) {
          Button("Save") {
            onSave(draft)
          }
          .keyboardShortcut(.defaultAction)
          .disabled(!canSave)
        }
      }
    }
    .frame(minWidth: 480, idealWidth: 540, minHeight: 420, idealHeight: 520)
  }

  // MARK: - Sections

  /// Name + (custom-only) icon + tint. Each control on its own row via
  /// `LabeledContent`, matching the System Settings layout.
  @ViewBuilder
  private var identitySection: some View {
    Section {
      LabeledContent("Name") {
        TextField(
          "",
          text: $draft.name,
          prompt: Text(draft.kind.defaultName)
        )
        .textFieldStyle(.roundedBorder)
        .frame(minWidth: 160)
      }

      if draft.kind == .custom {
        LabeledContent("Icon (SF Symbol)") {
          TextField(
            "",
            text: Binding(
              get: { draft.systemImage ?? "" },
              set: { newValue in
                draft.systemImage = newValue.isEmpty ? nil : newValue
              }
            ),
            prompt: Text(ScriptKind.custom.defaultSystemImage)
          )
          .textFieldStyle(.roundedBorder)
          .frame(minWidth: 160)
        }

        Picker(
          "Tint",
          selection: Binding(
            get: { draft.tintColor ?? ScriptKind.custom.defaultTintColor },
            set: { draft.tintColor = $0 }
          )
        ) {
          ForEach(ScriptTintColor.allCases, id: \.self) { tint in
            Text(tint.rawValue.capitalized).tag(tint)
          }
        }
      }
    } header: {
      Text(isNew ? "New \(draft.kind.defaultName) script" : "Identity")
    }
  }

  /// Multi-line command body in its own grouped Section so the
  /// PlainCommandEditor gets a full row with breathing room.
  @ViewBuilder
  private var commandSection: some View {
    Section {
      PlainCommandEditor(text: $draft.command)
        .frame(minHeight: 120)
    } header: {
      Text("Command")
    } footer: {
      Text("Runs from the project's worktree directory.")
    }
  }

  /// Target / direction / on-finished. Pickers default to `.menu`
  /// (popup) style which renders as one-field-per-row in a Form.
  @ViewBuilder
  private var runtimeSection: some View {
    Section {
      Picker("Target", selection: targetBinding) {
        Text("Focused Pane").tag(ScriptTarget.focused)
        Text("New Tab").tag(ScriptTarget.newTab)
        Text("Split").tag(ScriptTarget.split)
      }

      if draft.target == .split {
        Picker("Direction", selection: $draft.direction) {
          Text("Right").tag(ScriptSplitDirection.right)
          Text("Down").tag(ScriptSplitDirection.down)
          Text("Left").tag(ScriptSplitDirection.left)
          Text("Up").tag(ScriptSplitDirection.up)
        }
      }

      switch draft.target {
      case .newTab:
        Toggle("Close tab when finished", isOn: closeTabBinding)
      case .split:
        Toggle("Close pane when finished", isOn: closePaneBinding)
      case .focused:
        EmptyView()
      }
    } header: {
      Text("Where to run")
    }
  }

  // MARK: - Bindings

  /// Switching `target` resets `onFinished` to `.none` because the
  /// per-target valid set differs (`.newTab` admits `.closeTab` only,
  /// `.split` admits `.closePane` only, `.focused` forces `.none`).
  /// Carrying stale `onFinished` would silently produce an invalid
  /// combo until `resolvedOnFinished` validates it at dispatch time.
  private var targetBinding: Binding<ScriptTarget> {
    Binding(
      get: { draft.target },
      set: { newValue in
        draft.target = newValue
        draft.onFinished = .none
      }
    )
  }

  private var closeTabBinding: Binding<Bool> {
    Binding(
      get: { draft.onFinished == .closeTab },
      set: { isOn in draft.onFinished = isOn ? .closeTab : .none }
    )
  }

  private var closePaneBinding: Binding<Bool> {
    Binding(
      get: { draft.onFinished == .closePane },
      set: { isOn in draft.onFinished = isOn ? .closePane : .none }
    )
  }

  // MARK: - Validation

  /// Save is enabled when the draft has a non-empty command AND either
  /// the script is new (no upstream comparison meaningful) or the
  /// draft has actually diverged from the original.
  private var canSave: Bool {
    guard !draft.command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      return false
    }
    return isNew || draft != initialScript
  }
}
