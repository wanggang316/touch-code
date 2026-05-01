import SwiftUI
import TouchCodeCore

/// Body of a single user-defined `ScriptDefinition` Section in the
/// Project Scripts pane. Always expanded — there is no collapsed mode
/// because each script lives in its own grouped Section, mirroring the
/// lifecycle script layout. Every control writes through `onUpdate` on
/// each change; `SettingsStore.scheduleSave` debounces the disk write.
///
/// `kind` is fixed at script-creation time (chosen from the `+` menu)
/// and intentionally not editable here; users delete and re-add to
/// change kind. The `.custom` kind exposes optional icon + tint
/// overrides because that's the kind whose contract permits them.
struct UserScriptEditor: View {
  let script: ScriptDefinition
  let onUpdate: (ScriptDefinition) -> Void
  let onRun: () -> Void
  let onDelete: () -> Void
  /// When false the Run button is disabled (no resolvable worktree).
  var canRun: Bool = true

  @State private var showDeleteConfirm = false

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      LabeledContent("Name") {
        TextField(
          "",
          text: bindingFor(\.name),
          prompt: Text(script.kind.defaultName)
        )
      }

      VStack(alignment: .leading, spacing: 4) {
        Text("Command")
        TextEditor(text: bindingFor(\.command))
          .monospaced()
          .textEditorStyle(.plain)
          .autocorrectionDisabled()
          .frame(height: 90)
      }

      if script.kind == .custom {
        LabeledContent("Icon (SF Symbol)") {
          TextField(
            "",
            text: Binding(
              get: { script.systemImage ?? "" },
              set: { newValue in
                var updated = script
                updated.systemImage = newValue.isEmpty ? nil : newValue
                onUpdate(updated)
              }
            ),
            prompt: Text(ScriptKind.custom.defaultSystemImage)
          )
        }

        LabeledContent("Tint") {
          Picker(
            "",
            selection: Binding(
              get: { script.tintColor ?? ScriptKind.custom.defaultTintColor },
              set: { newValue in
                var updated = script
                updated.tintColor = newValue
                onUpdate(updated)
              }
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

      if script.target == .split {
        LabeledContent("Direction") {
          Picker("", selection: bindingFor(\.direction)) {
            Text("Right").tag(ScriptSplitDirection.right)
            Text("Down").tag(ScriptSplitDirection.down)
            Text("Left").tag(ScriptSplitDirection.left)
            Text("Up").tag(ScriptSplitDirection.up)
          }
          .labelsHidden()
          .pickerStyle(.segmented)
        }
      }

      switch script.target {
      case .newTab:
        Toggle("Close tab when finished", isOn: closeTabBinding)
      case .split:
        Toggle("Close pane when finished", isOn: closePaneBinding)
      case .focused:
        // sendInput has no observable "command finished" boundary.
        EmptyView()
      }

      HStack {
        Button {
          onRun()
        } label: {
          Label("Run", systemImage: "play.fill")
        }
        .disabled(!canRun)
        .help(canRun ? "Run \(script.displayName)" : "No worktree available")

        Spacer()

        Button(role: .destructive) {
          showDeleteConfirm = true
        } label: {
          Label("Delete", systemImage: "trash")
        }
        .confirmationDialog(
          "Delete script \"\(script.displayName)\"?",
          isPresented: $showDeleteConfirm,
          titleVisibility: .visible
        ) {
          Button("Delete", role: .destructive) { onDelete() }
          Button("Cancel", role: .cancel) {}
        }
      }
    }
    .padding(.vertical, 4)
  }

  // MARK: - Bindings

  /// Generic upstream-binding helper: read the field off the live
  /// `script`, write a mutated copy back through `onUpdate`. No local
  /// `@State` buffer — each keystroke goes through the writer, and
  /// `SettingsStore.scheduleSave` coalesces persistence.
  private func bindingFor<T>(
    _ keyPath: WritableKeyPath<ScriptDefinition, T>
  ) -> Binding<T> {
    Binding(
      get: { script[keyPath: keyPath] },
      set: { newValue in
        var updated = script
        updated[keyPath: keyPath] = newValue
        onUpdate(updated)
      }
    )
  }

  /// Switching `target` resets `onFinished` to `.none` because the
  /// per-target valid set differs (`.newTab` admits `.closeTab` only,
  /// `.split` admits `.closePane` only, `.focused` forces `.none`).
  /// Carrying stale `onFinished` would silently produce an invalid
  /// combo until `resolvedOnFinished` validates it at dispatch time.
  private var targetBinding: Binding<ScriptTarget> {
    Binding(
      get: { script.target },
      set: { newValue in
        var updated = script
        updated.target = newValue
        updated.onFinished = .none
        onUpdate(updated)
      }
    )
  }

  private var closeTabBinding: Binding<Bool> {
    Binding(
      get: { script.onFinished == .closeTab },
      set: { isOn in
        var updated = script
        updated.onFinished = isOn ? .closeTab : .none
        onUpdate(updated)
      }
    )
  }

  private var closePaneBinding: Binding<Bool> {
    Binding(
      get: { script.onFinished == .closePane },
      set: { isOn in
        var updated = script
        updated.onFinished = isOn ? .closePane : .none
        onUpdate(updated)
      }
    )
  }
}
