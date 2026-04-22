import ComposableArchitecture
import SwiftUI
import TouchCodeCore

/// Project Options sheet body. Edits name, per-Project default editor
/// (picker populated from `EditorRegistry.builtins`), and worktrees-directory
/// override. Subsumes the previously-separate Rename Project sheet.
struct ProjectOptionsSheet: View {
  @Bindable var store: StoreOf<ProjectOptionsFeature>

  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      Text("Project Options")
        .font(.headline)

      VStack(alignment: .leading, spacing: 8) {
        Text("Name")
          .font(.subheadline.weight(.medium))
        TextField(
          "Project name",
          text: Binding(
            get: { store.nameDraft },
            set: { store.send(.nameChanged($0)) }
          )
        )
        .textFieldStyle(.roundedBorder)
      }

      VStack(alignment: .leading, spacing: 8) {
        Text("Default editor")
          .font(.subheadline.weight(.medium))
        Picker(
          "Default editor",
          selection: Binding(
            get: { store.defaultEditorDraft ?? "" },
            set: { newValue in
              store.send(.editorChanged(newValue.isEmpty ? nil : newValue))
            }
          )
        ) {
          Text("Use global default").tag("")
          // TODO(C8a Phase 4b): render only installed editors via `EditorService.describe()`.
          // For Phase 3 we enumerate the full built-in registry (ids match the legacy shape)
          // so existing per-Project overrides keep round-tripping through the sheet.
          ForEach(EditorRegistry.registry, id: \.id) { entry in
            Text(entry.displayName).tag(entry.id)
          }
        }
        .pickerStyle(.menu)
        .labelsHidden()
      }

      VStack(alignment: .leading, spacing: 8) {
        Text("Worktrees directory")
          .font(.subheadline.weight(.medium))
        TextField(
          "Use default (~/.touch-code/repos/<name>/)",
          text: Binding(
            get: { store.worktreesDirectoryDraft },
            set: { store.send(.worktreesDirectoryChanged($0)) }
          )
        )
        .textFieldStyle(.roundedBorder)
        Text("Leave blank to use the default location.")
          .font(.caption)
          .foregroundStyle(.secondary)
      }

      if let message = store.validationError {
        Text(message)
          .font(.caption)
          .foregroundStyle(.red)
      }

      HStack {
        Spacer()
        Button("Cancel") { store.send(.cancelTapped) }
          .keyboardShortcut(.cancelAction)
        Button("Save") { store.send(.saveTapped) }
          .keyboardShortcut(.defaultAction)
          .disabled(!store.canSave)
      }
    }
    .padding(24)
    .frame(width: 480)
  }
}
