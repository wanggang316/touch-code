import SwiftUI
import TouchCodeCore

/// Body of a single user-defined `ScriptDefinition` Section in the
/// Project Scripts pane. Always expanded — each script lives in its own
/// grouped Section, mirroring the lifecycle script layout. The header
/// already shows the script's name + kind, so neither is repeated here.
///
/// Edits accumulate in a local `draft` buffer so the `TextEditor`'s
/// cursor position is preserved across keystrokes (binding the editor
/// directly through to the upstream model would force a re-render and
/// snap the caret to the end). The Save button commits the buffer to
/// the writer; the buffer adopts upstream changes that arrive while the
/// row is clean.
///
/// `kind` is fixed at script-creation time (chosen from the `+` menu)
/// and intentionally not editable here; users delete and re-add to
/// change kind. The `.custom` kind exposes optional icon + tint
/// overrides because that's the kind whose contract permits them.
struct UserScriptEditor: View {
  let script: ScriptDefinition
  let onSave: (ScriptDefinition) -> Void
  let onRun: () -> Void
  let onDelete: () -> Void
  /// When false the Run button is disabled (no resolvable worktree).
  var canRun: Bool = true

  @State private var draft: ScriptDefinition
  @State private var showDeleteConfirm = false

  init(
    script: ScriptDefinition,
    onSave: @escaping (ScriptDefinition) -> Void,
    onRun: @escaping () -> Void,
    onDelete: @escaping () -> Void,
    canRun: Bool = true
  ) {
    self.script = script
    self.onSave = onSave
    self.onRun = onRun
    self.onDelete = onDelete
    self.canRun = canRun
    self._draft = State(initialValue: script)
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      TextEditor(text: $draft.command)
        .monospaced()
        .textEditorStyle(.plain)
        .autocorrectionDisabled()
        .frame(height: 90)

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
        }

        LabeledContent("Tint") {
          Picker(
            "",
            selection: Binding(
              get: { draft.tintColor ?? ScriptKind.custom.defaultTintColor },
              set: { draft.tintColor = $0 }
            )
          ) {
            ForEach(ScriptTintColor.allCases, id: \.self) { tint in
              Text(tint.rawValue.capitalized).tag(tint)
            }
          }
          .labelsHidden()
          .pickerStyle(.menu)
        }
      }

      LabeledContent("Target") {
        Picker("", selection: targetBinding) {
          Text("Focused").tag(ScriptTarget.focused)
          Text("New Tab").tag(ScriptTarget.newTab)
          Text("Split").tag(ScriptTarget.split)
        }
        .labelsHidden()
        .pickerStyle(.segmented)
      }

      if draft.target == .split {
        LabeledContent("Direction") {
          Picker("", selection: $draft.direction) {
            Text("Right").tag(ScriptSplitDirection.right)
            Text("Down").tag(ScriptSplitDirection.down)
            Text("Left").tag(ScriptSplitDirection.left)
            Text("Up").tag(ScriptSplitDirection.up)
          }
          .labelsHidden()
          .pickerStyle(.segmented)
        }
      }

      switch draft.target {
      case .newTab:
        Toggle("Close tab when finished", isOn: closeTabBinding)
      case .split:
        Toggle("Close pane when finished", isOn: closePaneBinding)
      case .focused:
        // sendInput has no observable "command finished" boundary.
        EmptyView()
      }

      actionRow
    }
    .padding(.vertical, 4)
    .onChange(of: script) { _, newScript in
      // Adopt upstream changes when our draft is clean (matches the
      // prior upstream value). When the user has unsaved edits
      // (`draft != script` already, before the upstream change), we
      // keep the in-flight buffer rather than clobbering it. The
      // single-writer settings model makes external mutations during
      // editing unlikely — this is a defensive guard, not a primary
      // path.
      if newScript != draft {
        draft = newScript
      }
    }
  }

  // MARK: - Action row

  @ViewBuilder
  private var actionRow: some View {
    HStack {
      Button(role: .destructive) {
        showDeleteConfirm = true
      } label: {
        Image(systemName: "trash")
      }
      .buttonStyle(.borderless)
      .foregroundStyle(.red)
      .help("Delete script")
      .confirmationDialog(
        "Delete script \"\(script.displayName)\"?",
        isPresented: $showDeleteConfirm,
        titleVisibility: .visible
      ) {
        Button("Delete", role: .destructive) { onDelete() }
        Button("Cancel", role: .cancel) {}
      }

      Spacer()

      Button {
        onRun()
      } label: {
        Label("Run", systemImage: "play.fill")
      }
      .disabled(!canRun)
      .help(canRun ? "Run \(script.displayName)" : "No worktree available")

      Button("Save") {
        onSave(draft)
      }
      .keyboardShortcut("s", modifiers: .command)
      .disabled(draft == script || draft.command.isEmpty)
    }
  }

  // MARK: - Bindings

  /// Switching `target` resets `onFinished` to `.none` because the
  /// per-target valid set differs (`.newTab` admits `.closeTab` only,
  /// `.split` admits `.closePane` only, `.focused` forces `.none`).
  /// Carrying stale `onFinished` would silently produce an invalid
  /// combo until `resolvedOnFinished` validates it at dispatch time.
  /// Lives on the binding (not on `.onChange(of: draft.target)`) so
  /// programmatic upstream-sync that swaps target does not clobber a
  /// validly-paired `onFinished`.
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
}
