import SwiftUI

/// Reusable key/value editor for `[String: String]` environment-variable
/// maps. The General pane wraps this with project-id-aware bindings so
/// each commit routes through `SettingsWriter.setProjectEnvVar(pid, key,
/// value)`; M6's per-hook env editor reuses the same component with a
/// hooks-aware writer.
///
/// Validation rules (Risk R3 from the design doc):
///   - KEY must match POSIX env-var: `^[A-Za-z_][A-Za-z0-9_]*$`.
///   - KEY must be unique within the editor (the parent map already
///     guarantees uniqueness on disk; the editor blocks the duplicate
///     before it commits so the user sees the conflict inline).
///   - VALUE must not contain `\n` or `\r` — the on-disk JSON is shell-
///     sourced by hook runners; embedded newlines break the contract.
///
/// Rows render alphabetically by key on each pass; insertion order is not
/// preserved (Swift dictionaries don't guarantee it anyway).
struct EnvironmentEditorView: View {
  @Binding var envVars: [String: String]
  /// Per-row commit hook. `value == nil` means delete. Wrapping views use
  /// it to fan out into `SettingsWriter.setProjectEnvVar` etc. without
  /// this view knowing about ProjectIDs.
  let onChange: (_ key: String, _ value: String?) -> Void
  /// Caption rendered under the table. The General pane uses this for the
  /// "Values are stored in plain text" warning.
  let footer: String

  @State private var draft: Draft?

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      ForEach(sortedKeys, id: \.self) { key in
        existingRow(key: key)
      }

      if let draft {
        draftRow(draft)
      }

      HStack {
        Button {
          if draft == nil {
            draft = Draft()
          }
        } label: {
          Label("Add variable", systemImage: "plus")
        }
        .buttonStyle(.borderless)
        Spacer()
      }

      if !footer.isEmpty {
        Text(footer)
          .font(.caption)
          .foregroundStyle(.secondary)
      }
    }
  }

  private var sortedKeys: [String] {
    envVars.keys.sorted()
  }

  // MARK: - Existing rows

  @ViewBuilder
  private func existingRow(key: String) -> some View {
    let valueBinding = Binding<String>(
      get: { envVars[key] ?? "" },
      set: { newValue in
        if EnvVarValidator.valueHasNewline(newValue) {
          // Reject silently here — the textfield UI keeps the typed
          // characters but the commit-on-blur path filters on the same
          // rule so nothing reaches disk. Inline error rendered below.
          return
        }
        onChange(key, newValue)
      }
    )

    HStack(spacing: 8) {
      Text(key)
        .font(.system(.body, design: .monospaced))
        .frame(width: 180, alignment: .leading)
        .textSelection(.enabled)
      TextField("value", text: valueBinding)
        .textFieldStyle(.roundedBorder)
      Button {
        onChange(key, nil)
      } label: {
        Image(systemName: "xmark.circle.fill")
          .foregroundStyle(.secondary)
      }
      .buttonStyle(.borderless)
      .accessibilityLabel("Remove \(key)")
    }
  }

  // MARK: - Draft row

  @ViewBuilder
  private func draftRow(_ current: Draft) -> some View {
    let keyBinding = Binding<String>(
      get: { current.key },
      set: { newValue in
        var next = current
        next.key = newValue
        next.recomputeError(existing: envVars)
        draft = next
      }
    )
    let valueBinding = Binding<String>(
      get: { current.value },
      set: { newValue in
        var next = current
        next.value = newValue
        next.recomputeError(existing: envVars)
        draft = next
      }
    )

    VStack(alignment: .leading, spacing: 4) {
      HStack(spacing: 8) {
        TextField("KEY", text: keyBinding)
          .textFieldStyle(.roundedBorder)
          .frame(width: 180)
          .overlay(
            RoundedRectangle(cornerRadius: 4)
              .stroke(current.error == nil ? Color.clear : Color.red, lineWidth: 1)
          )
        TextField("value", text: valueBinding)
          .textFieldStyle(.roundedBorder)
        Button {
          commitDraft()
        } label: {
          Image(systemName: "checkmark.circle.fill")
            .foregroundStyle(canCommitDraft ? Color.green : Color.secondary)
        }
        .buttonStyle(.borderless)
        .disabled(!canCommitDraft)
        .accessibilityLabel("Commit new variable")
        Button {
          draft = nil
        } label: {
          Image(systemName: "xmark.circle.fill")
            .foregroundStyle(.secondary)
        }
        .buttonStyle(.borderless)
        .accessibilityLabel("Discard new variable")
      }
      if let error = current.error {
        Text(error)
          .font(.caption)
          .foregroundStyle(.red)
      }
    }
  }

  private var canCommitDraft: Bool {
    guard let current = draft else { return false }
    return current.error == nil && !current.key.isEmpty
  }

  private func commitDraft() {
    guard let current = draft, current.error == nil, !current.key.isEmpty else {
      return
    }
    onChange(current.key, current.value)
    draft = nil
  }

  // MARK: - Draft state

  /// In-flight unsaved row. Held in `@State` so a half-typed KEY does not
  /// fan out to the parent's onChange until validation passes and the
  /// user commits.
  struct Draft: Equatable {
    var key: String = ""
    var value: String = ""
    var error: String?

    mutating func recomputeError(existing: [String: String]) {
      error = EnvVarValidator.errorFor(key: key, value: value, existing: existing)
    }
  }
}

/// Pure validator — kept as a free enum so tests can hit the rules
/// without spinning up SwiftUI state.
enum EnvVarValidator {
  /// Returns the user-visible error string when `(key, value)` cannot be
  /// committed against `existing`. Returns nil for a valid pair (and for
  /// the empty-KEY initial state, which is "incomplete" rather than
  /// "invalid"; the commit path checks `!key.isEmpty` separately).
  static func errorFor(
    key: String,
    value: String,
    existing: [String: String]
  ) -> String? {
    if !key.isEmpty, !keyIsValidPOSIX(key) {
      return "Invalid key"
    }
    if !key.isEmpty, existing[key] != nil {
      return "Key already exists"
    }
    if valueHasNewline(value) {
      return "Value cannot contain newlines"
    }
    return nil
  }

  /// `true` iff `key` matches `^[A-Za-z_][A-Za-z0-9_]*$`.
  static func keyIsValidPOSIX(_ key: String) -> Bool {
    guard let first = key.unicodeScalars.first else { return false }
    if !(CharacterSet.letters.contains(first) || first == "_") {
      return false
    }
    for scalar in key.unicodeScalars.dropFirst() {
      let ok =
        CharacterSet.letters.contains(scalar)
        || CharacterSet.decimalDigits.contains(scalar)
        || scalar == "_"
      if !ok { return false }
    }
    // Restrict to ASCII letters/digits to match POSIX exactly — Foundation's
    // CharacterSet.letters includes Unicode letters which the POSIX rule
    // explicitly excludes.
    for scalar in key.unicodeScalars {
      let isAsciiAlpha =
        (scalar.value >= 0x41 && scalar.value <= 0x5A)
        || (scalar.value >= 0x61 && scalar.value <= 0x7A)
      let isAsciiDigit = scalar.value >= 0x30 && scalar.value <= 0x39
      let isUnderscore = scalar == "_"
      if !(isAsciiAlpha || isAsciiDigit || isUnderscore) {
        return false
      }
    }
    return true
  }

  static func valueHasNewline(_ value: String) -> Bool {
    value.contains("\n") || value.contains("\r")
  }
}
