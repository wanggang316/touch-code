import ComposableArchitecture
import SwiftUI
import TouchCodeCore

/// Project Options sheet body. Edits name, per-Project default editor (picker populated
/// from `EditorService.describe()`, C8a Phase 4b), and worktrees-directory override.
/// Subsumes the previously-separate Rename Project sheet.
struct ProjectOptionsSheet: View {
  @Bindable var store: StoreOf<ProjectOptionsFeature>

  /// Selection binding: `nil` means "use the global default". The sentinel-tagged row
  /// below uses the same `nil` tag so SwiftUI resolves the selection correctly.
  private var editorSelection: Binding<EditorID?> {
    Binding(
      get: { resolvedSelection() },
      set: { store.send(.editorChanged($0)) }
    )
  }

  /// Maps the raw draft into a selection that the picker can display. If the stored
  /// override points at an editor that is not in the current `descriptors` list (stale
  /// value / uninstalled) we show "Use global default" as selected; the next save or
  /// startup migration zeroes it out.
  private func resolvedSelection() -> EditorID? {
    guard let draft = store.defaultEditorDraft else { return nil }
    return store.descriptors.contains(where: { $0.id == draft }) ? draft : nil
  }

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
        Text("Editor")
          .font(.subheadline.weight(.medium))
        Picker("Editor", selection: editorSelection) {
          editorPickerContent
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
    .task { store.send(.onAppear) }
  }

  /// Picker items: sentinel "Use global default" row on top, then the flat priority-
  /// ordered descriptor list shared with every other Open-in dropdown in the app. The
  /// sentinel shares a nil-tag with the "stale override" visualization so both render
  /// as selected in that state.
  @ViewBuilder
  private var editorPickerContent: some View {
    HStack(spacing: 6) {
      Image(systemName: "return")
        .resizable()
        .aspectRatio(contentMode: .fit)
        .frame(width: 16, height: 16)
        .foregroundStyle(.secondary)
        .accessibilityHidden(true)
      Text("Use global default")
    }
    .tag(EditorID?(nil))

    ForEach(EditorPickerRow.sorted(store.descriptors), id: \.id) { descriptor in
      EditorPickerRow.row(for: descriptor)
        .tag(EditorID?(descriptor.id))
    }
  }
}
