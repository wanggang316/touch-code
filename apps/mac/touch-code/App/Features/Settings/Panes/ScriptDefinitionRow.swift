import SwiftUI
import TouchCodeCore

/// Inline row for a single `ScriptDefinition` inside the Project Scripts
/// pane. Two visual states:
///   * Collapsed — kind icon, name, command preview, and trailing Run /
///     Edit / Delete controls.
///   * Expanded — Form-style editor (Name / Command / Kind, plus the
///     icon + tint pickers when `kind == .custom`). Save invokes
///     `onSave(draft)`; Cancel discards the local buffer.
///
/// The row owns no persistent state — the parent pane keeps the source
/// of truth and writes through `SettingsWriter.setProjectScripts`. The
/// expanded buffer (`@State draft`) is rebuilt from the current `script`
/// every time the row collapses or the upstream definition changes.
struct ScriptDefinitionRow: View {
  let script: ScriptDefinition
  @Binding var isExpanded: Bool
  let onSave: (ScriptDefinition) -> Void
  let onRun: () -> Void
  let onDelete: () -> Void
  /// When false the Run button is disabled (no resolvable worktree).
  var canRun: Bool = true

  @State private var draft: ScriptDefinition
  @State private var showDeleteConfirm = false

  init(
    script: ScriptDefinition,
    isExpanded: Binding<Bool>,
    onSave: @escaping (ScriptDefinition) -> Void,
    onRun: @escaping () -> Void,
    onDelete: @escaping () -> Void,
    canRun: Bool = true
  ) {
    self.script = script
    self._isExpanded = isExpanded
    self.onSave = onSave
    self.onRun = onRun
    self.onDelete = onDelete
    self.canRun = canRun
    self._draft = State(initialValue: script)
  }

  var body: some View {
    Group {
      if isExpanded {
        expandedView
      } else {
        collapsedView
      }
    }
    .onChange(of: script) { _, newValue in
      // When the upstream script mutates while the row is collapsed,
      // refresh the draft so a subsequent edit starts from the latest
      // state. We deliberately do NOT overwrite an in-flight expanded
      // edit — that buffer belongs to the user.
      if !isExpanded {
        draft = newValue
      }
    }
    .onChange(of: isExpanded) { _, expanded in
      if expanded {
        draft = script
      }
    }
  }

  // MARK: - Collapsed

  @ViewBuilder
  private var collapsedView: some View {
    HStack(spacing: 8) {
      Image(systemName: script.resolvedSystemImage)
        .frame(width: 18, height: 18)
        .foregroundStyle(Self.color(for: script.resolvedTintColor))
        .accessibilityHidden(true)

      VStack(alignment: .leading, spacing: 2) {
        Text(script.displayName)
          .font(.body)
        Text(script.command.isEmpty ? "—" : script.command)
          .font(.caption)
          .foregroundStyle(.secondary)
          .lineLimit(1)
          .truncationMode(.middle)
      }

      Spacer(minLength: 8)

      Button(action: onRun) {
        Image(systemName: "play.fill")
      }
      .buttonStyle(.borderless)
      .disabled(!canRun)
      .help(canRun ? "Run \(script.displayName)" : "No worktree available")

      Button {
        isExpanded = true
      } label: {
        Image(systemName: "pencil")
      }
      .buttonStyle(.borderless)
      .help("Edit")

      Button {
        showDeleteConfirm = true
      } label: {
        Image(systemName: "xmark")
      }
      .buttonStyle(.borderless)
      .help("Delete")
      .confirmationDialog(
        "Delete script \"\(script.displayName)\"?",
        isPresented: $showDeleteConfirm,
        titleVisibility: .visible
      ) {
        Button("Delete", role: .destructive) { onDelete() }
        Button("Cancel", role: .cancel) {}
      }
    }
    .padding(.vertical, 2)
  }

  // MARK: - Expanded

  @ViewBuilder
  private var expandedView: some View {
    VStack(alignment: .leading, spacing: 8) {
      LabeledContent("Name") {
        TextField(
          "",
          text: Binding(get: { draft.name }, set: { draft.name = $0 }),
          prompt: Text(draft.kind.defaultName)
        )
      }

      VStack(alignment: .leading, spacing: 4) {
        Text("Command")
        TextEditor(text: Binding(get: { draft.command }, set: { draft.command = $0 }))
          .monospaced()
          .textEditorStyle(.plain)
          .autocorrectionDisabled()
          .frame(height: 90)
      }

      LabeledContent("Kind") {
        Picker(
          "",
          selection: Binding(get: { draft.kind }, set: { draft.kind = $0 })
        ) {
          ForEach(ScriptKind.allCases, id: \.self) { kind in
            Text(kind.defaultName).tag(kind)
          }
        }
        .labelsHidden()
        .pickerStyle(.menu)
      }

      if draft.kind == .custom {
        LabeledContent("Icon (SF Symbol)") {
          TextField(
            "",
            text: Binding(
              get: { draft.systemImage ?? "" },
              set: { draft.systemImage = $0.isEmpty ? nil : $0 }
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

      HStack {
        Spacer()
        Button("Cancel") {
          draft = script
          isExpanded = false
        }
        .keyboardShortcut(.cancelAction)
        Button("Save") {
          onSave(draft)
          isExpanded = false
        }
        .keyboardShortcut(.defaultAction)
        .disabled(draft.command.isEmpty)
      }
    }
    .padding(.vertical, 4)
  }

  // MARK: - Helpers

  /// Local copy of `HeaderRunScriptSplitButton.color(for:)`. Duplicated so
  /// neither file needs to make the helper module-public; keeping a
  /// 5-line switch in two places is cheaper than the extra coupling.
  static func color(for tint: ScriptTintColor) -> Color {
    switch tint {
    case .green: return .green
    case .yellow: return .yellow
    case .red: return .red
    case .blue: return .blue
    case .teal: return .teal
    case .purple: return .purple
    case .gray: return .gray
    }
  }
}
