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
        shortcutSection
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
        LabeledContent("Icon") {
          SymbolPickerRow(
            symbol: Binding(
              get: { draft.systemImage ?? ScriptKind.custom.defaultSystemImage },
              set: { newValue in
                let trimmed = newValue.trimmingCharacters(in: .whitespaces)
                draft.systemImage = trimmed.isEmpty ? nil : trimmed
              }
            ),
            tint: ScriptTintColorPalette.color(for: draft.tintColor ?? ScriptKind.custom.defaultTintColor)
          )
        }

        LabeledContent("Tint") {
          TintSwatchRow(
            selection: Binding(
              get: { draft.tintColor ?? ScriptKind.custom.defaultTintColor },
              set: { draft.tintColor = $0 }
            )
          )
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

  /// Optional global keyboard chord. Bindable via four modifier
  /// toggles + a single-character text field. macOS bare-key
  /// shortcuts (no modifier) collide with text input almost
  /// everywhere, so the model's `isValid` requires at least one
  /// modifier — Save below treats partial chords as no chord.
  @ViewBuilder
  private var shortcutSection: some View {
    Section {
      ShortcutEditorRow(
        shortcut: Binding(
          get: { draft.keyboardShortcut },
          set: { draft.keyboardShortcut = $0 }
        )
      )
    } header: {
      Text("Keyboard shortcut")
    } footer: {
      Text("Bound globally on the worktree-header Run menu — at least one modifier required.")
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

// MARK: - Shortcut editor

/// Inline shortcut composer. Four toggleable modifier glyphs plus a
/// single-character TextField. Live preview on the left renders the
/// macOS-conventional chord string, or "—" when the chord is empty.
/// A trailing "Clear" button wipes the chord back to nil.
///
/// Deliberately *not* a key-event recorder. Recording requires
/// installing an NSEvent local monitor, juggling first-responder
/// state, and explicitly excluding modifier-only keystrokes — all
/// fragile inside a sheet that shares focus with the surrounding
/// Form. The toggle + TextField composition is unambiguous, builds
/// in any window context, and matches the pattern Linear and a
/// few other macOS settings panes ship.
private struct ShortcutEditorRow: View {
  @Binding var shortcut: ScriptKeyboardShortcut?

  var body: some View {
    HStack(spacing: 10) {
      Text(shortcut?.isValid == true ? shortcut!.displayString : "—")
        .font(.body.monospaced())
        .foregroundStyle(shortcut?.isValid == true ? Color.primary : .secondary)
        .frame(minWidth: 64, alignment: .leading)

      Spacer(minLength: 0)

      modifierToggle("⌃", .control)
      modifierToggle("⌥", .option)
      modifierToggle("⇧", .shift)
      modifierToggle("⌘", .command)

      TextField(
        "key",
        text: keyBinding
      )
      .textFieldStyle(.roundedBorder)
      .frame(width: 56)

      Button("Clear") {
        shortcut = nil
      }
      .buttonStyle(.borderless)
      .disabled(shortcut == nil)
    }
  }

  // MARK: - Helpers

  private var keyBinding: Binding<String> {
    Binding(
      get: { shortcut?.key ?? "" },
      set: { newValue in
        // Single-character only — clamp to the first scalar so a
        // paste of "abc" stores "a". Lower-case so the displayString
        // upper-cases consistently.
        let trimmed = newValue.lowercased().prefix(1)
        update { $0.key = String(trimmed) }
      }
    )
  }

  @ViewBuilder
  private func modifierToggle(_ glyph: String, _ modifier: ScriptKeyboardShortcut.Modifier) -> some View {
    let isOn = shortcut?.modifiers.contains(modifier) == true
    Button {
      update { current in
        if current.modifiers.contains(modifier) {
          current.modifiers.remove(modifier)
        } else {
          current.modifiers.insert(modifier)
        }
      }
    } label: {
      Text(glyph)
        .font(.body.monospaced())
        .frame(width: 24, height: 22)
        .background(
          RoundedRectangle(cornerRadius: 5)
            .fill(isOn ? Color.accentColor.opacity(0.25) : Color.secondary.opacity(0.08))
        )
        .overlay(
          RoundedRectangle(cornerRadius: 5)
            .stroke(isOn ? Color.accentColor : Color.clear, lineWidth: 1)
        )
        .foregroundStyle(isOn ? Color.accentColor : Color.primary)
    }
    .buttonStyle(.plain)
    .help(glyph)
  }

  /// Edit the current chord in place; allocate a default empty
  /// chord on first edit so the toggles + key field have something
  /// to mutate.
  private func update(_ transform: (inout ScriptKeyboardShortcut) -> Void) {
    var current = shortcut ?? ScriptKeyboardShortcut(key: "", modifiers: [])
    transform(&current)
    // Drop fully-empty chords back to nil so they don't persist.
    if current.key.isEmpty && current.modifiers.isEmpty {
      shortcut = nil
    } else {
      shortcut = current
    }
  }
}

// MARK: - Symbol picker

/// `LabeledContent` value for the Icon row. Renders a live preview of
/// the current SF Symbol next to a `Choose…` button that opens a
/// popover grid of curated script-relevant symbols. A small TextField
/// inside the popover lets advanced users type any SF Symbol name
/// directly when the curated grid doesn't cover their case.
private struct SymbolPickerRow: View {
  @Binding var symbol: String
  let tint: Color

  @State private var popoverShown = false

  var body: some View {
    HStack(spacing: 10) {
      Image(systemName: symbol)
        .font(.title3)
        .foregroundStyle(tint)
        .frame(width: 24, height: 24)
        .background(
          RoundedRectangle(cornerRadius: 6)
            .fill(Color.secondary.opacity(0.08))
        )

      Button("Choose…") { popoverShown.toggle() }
        .buttonStyle(.bordered)
        .popover(isPresented: $popoverShown, arrowEdge: .bottom) {
          SymbolGridPopover(symbol: $symbol, tint: tint)
            .frame(width: 320, height: 280)
        }
    }
  }
}

private struct SymbolGridPopover: View {
  @Binding var symbol: String
  let tint: Color

  /// Curated common symbols for scripts. Covers the predefined kinds'
  /// defaults plus broadly useful action / status / tooling glyphs.
  /// Users who need anything else can type the symbol name in the
  /// TextField at the bottom.
  private static let curated: [String] = [
    "play.fill", "checkmark.seal.fill", "paperplane.fill", "ant.fill",
    "wand.and.stars", "bolt.fill", "hammer.fill", "wrench.adjustable.fill",
    "terminal.fill", "gearshape.fill", "command", "swift",
    "shippingbox.fill", "archivebox.fill", "tray.full.fill", "doc.text.fill",
    "scissors", "sparkles", "flag.fill", "tag.fill",
    "star.fill", "heart.fill", "bookmark.fill", "bell.fill",
    "exclamationmark.triangle.fill", "checkmark.circle.fill", "xmark.circle.fill", "questionmark.circle.fill",
    "arrow.clockwise", "arrow.up.circle.fill", "arrow.down.circle.fill", "trash.fill",
  ]

  private let columns = Array(repeating: GridItem(.flexible(), spacing: 6), count: 6)

  var body: some View {
    VStack(spacing: 8) {
      ScrollView {
        LazyVGrid(columns: columns, spacing: 6) {
          ForEach(Self.curated, id: \.self) { name in
            symbolCell(name)
          }
        }
        .padding(8)
      }

      Divider()

      HStack(spacing: 6) {
        Text("Custom")
          .font(.caption)
          .foregroundStyle(.secondary)
        TextField("SF Symbol name", text: $symbol)
          .textFieldStyle(.roundedBorder)
          .font(.callout)
      }
      .padding(.horizontal, 10)
      .padding(.bottom, 8)
    }
  }

  @ViewBuilder
  private func symbolCell(_ name: String) -> some View {
    let isSelected = name == symbol
    Button {
      symbol = name
    } label: {
      Image(systemName: name)
        .font(.title3)
        .foregroundStyle(isSelected ? tint : Color.primary)
        .frame(width: 36, height: 36)
        .background(
          RoundedRectangle(cornerRadius: 6)
            .fill(isSelected ? tint.opacity(0.18) : Color.clear)
            .overlay(
              RoundedRectangle(cornerRadius: 6)
                .stroke(isSelected ? tint : Color.clear, lineWidth: 1.5)
            )
        )
    }
    .buttonStyle(.plain)
    .help(name)
  }
}

// MARK: - Tint swatch row

/// Horizontal row of clickable colored circles, one per
/// `ScriptTintColor`. The selected swatch is wrapped in a slightly
/// larger ring so the choice is unambiguous without resorting to a
/// menu / dropdown.
private struct TintSwatchRow: View {
  @Binding var selection: ScriptTintColor

  var body: some View {
    HStack(spacing: 8) {
      ForEach(ScriptTintColor.allCases, id: \.self) { tint in
        swatch(tint)
      }
    }
  }

  @ViewBuilder
  private func swatch(_ tint: ScriptTintColor) -> some View {
    let isSelected = tint == selection
    Button {
      selection = tint
    } label: {
      Circle()
        .fill(ScriptTintColorPalette.color(for: tint))
        .frame(width: 18, height: 18)
        .overlay(
          Circle()
            .stroke(Color.primary.opacity(isSelected ? 0.85 : 0), lineWidth: 2)
            .padding(-3)
        )
    }
    .buttonStyle(.plain)
    .help(tint.rawValue.capitalized)
    .accessibilityLabel(tint.rawValue.capitalized)
    .accessibilityAddTraits(isSelected ? [.isSelected] : [])
  }
}
