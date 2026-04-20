import ComposableArchitecture
import SwiftUI
import TouchCodeCore

/// Editors pane of the Settings sheet. Three sub-sections:
/// 1. Global default picker — any of the installed editors (built-in or custom).
/// 2. Built-in editors list — read-only, each row shows installed/missing state + rationale.
/// 3. Custom editors list — add / edit / remove arbitrary user templates.
struct SettingsEditorSection: View {
  @Bindable var store: StoreOf<EditorFeature>
  @State private var showingAddSheet = false

  var body: some View {
    VStack(alignment: .leading, spacing: 20) {
      Text("Editors")
        .font(.title3.bold())

      globalDefaultPicker
      builtinsList
      customEditorsList
    }
    .task { store.send(.onAppear) }
  }

  // MARK: - Global default

  private var globalDefaultPicker: some View {
    let selection = Binding<EditorID?>(
      get: { store.state.globalDefault },
      set: { newValue in store.send(.setGlobalDefault(newValue)) }
    )
    return VStack(alignment: .leading, spacing: 6) {
      Text("Default editor")
        .font(.headline)
      Text("Used when no Project-specific override is set.")
        .font(.caption)
        .foregroundStyle(.secondary)
      Picker("Default editor", selection: selection) {
        Text("Finder").tag(EditorID?.none)
        ForEach(store.state.descriptors) { descriptor in
          Text(descriptor.displayName).tag(EditorID?.some(descriptor.id))
        }
      }
      .pickerStyle(.menu)
      .labelsHidden()
      .frame(maxWidth: 280, alignment: .leading)
    }
  }

  // MARK: - Built-in list

  private var builtinsList: some View {
    let builtins = store.state.descriptors.filter { $0.origin == .builtin }
    return VStack(alignment: .leading, spacing: 6) {
      Text("Built-in editors")
        .font(.headline)
      if builtins.isEmpty {
        Text("Detecting installed editors…")
          .font(.caption)
          .foregroundStyle(.secondary)
      } else {
        VStack(alignment: .leading, spacing: 0) {
          ForEach(builtins) { entry in
            EditorRow(descriptor: entry)
            if entry.id != builtins.last?.id { Divider() }
          }
        }
        .padding(8)
        .background(Color(nsColor: .textBackgroundColor), in: .rect(cornerRadius: 6))
      }
      Button {
        store.send(.refreshRequested)
      } label: {
        Label("Refresh detection", systemImage: "arrow.clockwise")
      }
      .buttonStyle(.borderless)
    }
  }

  // MARK: - Custom editors

  private var customEditorsList: some View {
    VStack(alignment: .leading, spacing: 6) {
      HStack {
        Text("Custom editors")
          .font(.headline)
        Spacer(minLength: 0)
        Button {
          showingAddSheet = true
        } label: {
          Label("Add…", systemImage: "plus")
        }
      }
      if store.state.customEditors.isEmpty {
        Text("No custom editors yet. Add a template to point at anything on your PATH.")
          .font(.caption)
          .foregroundStyle(.secondary)
      } else {
        VStack(alignment: .leading, spacing: 0) {
          ForEach(store.state.customEditors) { editor in
            HStack {
              VStack(alignment: .leading, spacing: 2) {
                Text(editor.displayName).font(.body)
                Text("\(editor.id) — \(editor.template.binary) \(editor.template.args.joined(separator: " "))")
                  .font(.system(.caption, design: .monospaced))
                  .foregroundStyle(.secondary)
              }
              Spacer(minLength: 0)
              Button {
                store.send(.removeCustomEditor(id: editor.id))
              } label: {
                Image(systemName: "trash")
                  .accessibilityLabel("Remove \(editor.displayName)")
              }
              .buttonStyle(.borderless)
            }
            .padding(.vertical, 4)
            if editor.id != store.state.customEditors.last?.id { Divider() }
          }
        }
        .padding(8)
        .background(Color(nsColor: .textBackgroundColor), in: .rect(cornerRadius: 6))
      }
    }
    .sheet(isPresented: $showingAddSheet) {
      AddCustomEditorSheet(
        existingError: store.state.lastValidationError,
        onCancel: { showingAddSheet = false },
        onSave: { editor in
          store.send(.addCustomEditor(editor))
          showingAddSheet = false
        }
      )
    }
  }
}

// MARK: - Editor row

private struct EditorRow: View {
  let descriptor: EditorDescriptor

  var body: some View {
    HStack {
      statusIndicator
      VStack(alignment: .leading, spacing: 2) {
        Text(descriptor.displayName)
        Text(subtitle)
          .font(.system(.caption, design: .monospaced))
          .foregroundStyle(.secondary)
      }
      Spacer(minLength: 0)
      Text(descriptor.origin == .builtin ? "Built-in" : "Custom")
        .font(.caption)
        .foregroundStyle(.tertiary)
    }
    .padding(.vertical, 4)
  }

  @ViewBuilder
  private var statusIndicator: some View {
    switch descriptor.installation {
    case .installed:
      Image(systemName: "checkmark.circle.fill")
        .foregroundStyle(.green)
        .accessibilityLabel("\(descriptor.displayName) is installed")
    case .missingBinary:
      Image(systemName: "circle.dashed")
        .foregroundStyle(.secondary)
        .accessibilityLabel("\(descriptor.displayName) is not installed")
    }
  }

  private var subtitle: String {
    switch descriptor.installation {
    case .installed(let url): return url.path
    case .missingBinary(let expected): return "\(expected) not found on PATH"
    }
  }
}

// MARK: - Add custom editor sheet

private struct AddCustomEditorSheet: View {
  let existingError: EditorTemplateError?
  let onCancel: () -> Void
  let onSave: (CustomEditor) -> Void

  @State private var id: String = ""
  @State private var displayName: String = ""
  @State private var binary: String = ""
  @State private var argsText: String = "{dir}"

  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      Text("Add custom editor")
        .font(.title3.bold())
      VStack(alignment: .leading, spacing: 8) {
        field("Identifier", placeholder: "my-editor (lowercase, 2–32 chars, - or _)", text: $id)
          .font(.system(.body, design: .monospaced))
        field("Display name", placeholder: "My Editor", text: $displayName)
        field("Binary", placeholder: "code  (bare name or absolute path)", text: $binary)
          .font(.system(.body, design: .monospaced))
        field("Arguments", placeholder: "{dir}", text: $argsText)
          .font(.system(.body, design: .monospaced))
        Text("Arguments are whitespace-split. Exactly one argument must be the literal `{dir}`.")
          .font(.caption)
          .foregroundStyle(.secondary)
      }
      // Live-validate: first triggered rule as the user types. Reducer-level error from a
      // prior save attempt shown only when no local rule is firing.
      if let message = liveValidationMessage() ?? existingError.map(Self.errorMessage) {
        Label(message, systemImage: "exclamationmark.triangle.fill")
          .labelStyle(.titleAndIcon)
          .foregroundStyle(.orange)
          .font(.caption)
      }
      HStack {
        Spacer(minLength: 0)
        Button("Cancel", role: .cancel) { onCancel() }
          .keyboardShortcut(.escape)
        Button("Add") {
          onSave(CustomEditor(
            id: id,
            displayName: displayName,
            template: CommandTemplate(binary: binary, args: parsedArgs())
          ))
        }
        .buttonStyle(.borderedProminent)
        .keyboardShortcut(.return, modifiers: [.command])
        .disabled(!canSave)
      }
    }
    .padding(20)
    .frame(minWidth: 440, minHeight: 260)
  }

  private func field(_ title: String, placeholder: String, text: Binding<String>) -> some View {
    VStack(alignment: .leading, spacing: 2) {
      Text(title).font(.caption).foregroundStyle(.secondary)
      TextField(placeholder, text: text)
        .textFieldStyle(.roundedBorder)
    }
  }

  // MARK: - Live validation

  /// Splits the args text on whitespace once; used by both `canSave` and `onSave`.
  private func parsedArgs() -> [String] {
    argsText.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
  }

  /// True when every validation rule passes. Mirrors the reducer + SettingsStore checks so
  /// the Save button never dispatches a guaranteed-reject.
  private var canSave: Bool {
    guard !displayName.isEmpty else { return false }
    guard (try? CustomEditor.validatedID(id)) != nil else { return false }
    return (try? CommandTemplate(binary: binary, args: parsedArgs()).validate()) != nil
  }

  /// First-triggered rule, as a human-readable message. Nil when all rules pass.
  private func liveValidationMessage() -> String? {
    if displayName.isEmpty { return "Display name required." }
    do { _ = try CustomEditor.validatedID(id) } catch let err as EditorTemplateError {
      return Self.errorMessage(err)
    } catch {
      return "Identifier invalid."
    }
    do { try CommandTemplate(binary: binary, args: parsedArgs()).validate() } catch let err as EditorTemplateError {
      return Self.errorMessage(err)
    } catch {
      return "Template invalid."
    }
    return nil
  }

  fileprivate static func errorMessage(_ error: EditorTemplateError) -> String {
    switch error {
    case .emptyBinary: return "Binary must not be empty."
    case .missingDirPlaceholder: return "Arguments must contain exactly one `{dir}` token."
    case .duplicateDirPlaceholder: return "Arguments may contain only one `{dir}` token."
    case .invalidID(let raw): return "ID ‘\(raw)’ is invalid. Use lowercase a-z, 0-9, - or _, starting with a letter, 2-32 chars. Must not collide with a built-in."
    }
  }
}
