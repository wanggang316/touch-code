import SwiftUI
import TouchCodeCore

/// Settings → Shortcuts pane. Lists every entry in `ShortcutSchema.app` grouped by
/// category, lets the user record a new chord, disable a chord, reset one row, or restore
/// every row to its default. Conflict feedback during recording surfaces inline; cascading
/// resets present a confirmation dialog before applying.
struct ShortcutsSettingsView: View {
  @Bindable var store: ShortcutsStore
  @State private var query: String = ""
  @State private var recordingID: CommandID?
  @State private var rejectionMessage: String?
  @State private var pendingConflict: PendingConflict?
  @State private var pendingReset: ShortcutResetPlan?
  @State private var showRestoreAllConfirmation: Bool = false

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 0) {
        header
          .padding(.horizontal, 24)
          .padding(.top, 18)
          .padding(.bottom, 12)

        if let rejectionMessage {
          Text(rejectionMessage)
            .font(.callout)
            .foregroundStyle(.red)
            .padding(.horizontal, 24)
            .padding(.bottom, 8)
        }

        ForEach(visibleCategories, id: \.self) { category in
          section(for: category)
        }
      }
      .padding(.bottom, 24)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    .confirmationDialog(
      restoreAllTitle,
      isPresented: $showRestoreAllConfirmation,
      titleVisibility: .visible
    ) {
      Button("Restore Defaults", role: .destructive) {
        store.resetAll()
      }
      Button("Cancel", role: .cancel) {}
    } message: {
      Text("This clears every custom keyboard shortcut and disabled flag.")
    }
    .confirmationDialog(
      resetDialogTitle,
      isPresented: resetDialogBinding,
      titleVisibility: .visible
    ) {
      Button("Reset", role: .destructive) {
        if let plan = pendingReset {
          store.applyResetPlan(plan)
        }
        pendingReset = nil
      }
      Button("Cancel", role: .cancel) {
        pendingReset = nil
      }
    } message: {
      Text(resetDialogMessage)
    }
    .confirmationDialog(
      conflictDialogTitle,
      isPresented: conflictDialogBinding,
      titleVisibility: .visible
    ) {
      Button("Replace", role: .destructive) {
        if let pending = pendingConflict {
          store.resolveConflict(
            disabling: pending.conflictingID,
            assigning: pending.target,
            to: pending.binding
          )
        }
        pendingConflict = nil
      }
      Button("Cancel", role: .cancel) {
        pendingConflict = nil
      }
    } message: {
      Text(conflictDialogMessage)
    }
  }

  // MARK: - Sections

  @ViewBuilder
  private var header: some View {
    HStack(alignment: .firstTextBaseline) {
      TextField("Search shortcuts", text: $query)
        .textFieldStyle(.roundedBorder)
        .frame(maxWidth: 320)
      Spacer()
      Button("Restore All Defaults") {
        showRestoreAllConfirmation = true
      }
      .disabled(store.overrides.overrides.isEmpty)
    }
  }

  @ViewBuilder
  private func section(for category: ShortcutSchema.Category) -> some View {
    let entries = filteredEntries(for: category)
    if !entries.isEmpty {
      VStack(alignment: .leading, spacing: 0) {
        Text(category.title.uppercased())
          .font(.caption.weight(.semibold))
          .foregroundStyle(.secondary)
          .padding(.horizontal, 24)
          .padding(.top, 18)
          .padding(.bottom, 6)

        VStack(spacing: 0) {
          ForEach(entries, id: \.id) { entry in
            row(for: entry)
              .padding(.horizontal, 24)
              .padding(.vertical, 8)
            Divider().padding(.leading, 24)
          }
        }
      }
    }
  }

  @ViewBuilder
  private func row(for entry: ShortcutSchema.Entry) -> some View {
    let resolved = store.resolved[entry.id]
    HStack(spacing: 12) {
      VStack(alignment: .leading, spacing: 2) {
        Text(entry.title).font(.body)
        Text(scopeDescription(entry.scope))
          .font(.caption)
          .foregroundStyle(.secondary)
      }
      Spacer(minLength: 12)

      sourcePill(resolved)

      chordCell(entry: entry, resolved: resolved)
        .frame(width: 140)

      if entry.scope == .configurable, resolved?.source == .userOverride {
        Button {
          requestReset(for: entry.id)
        } label: {
          Image(systemName: "arrow.uturn.backward.circle")
            .help("Restore default")
        }
        .buttonStyle(.borderless)
      } else {
        // Reserve space so rows align even when the reset glyph is hidden.
        Color.clear.frame(width: 24, height: 1)
      }
    }
    .contextMenu {
      if entry.scope == .configurable, let resolved {
        if resolved.isEnabled {
          Button("Disable Shortcut") { store.disable(entry.id) }
        } else {
          Button("Enable Shortcut") { restoreEnabled(for: entry.id) }
        }
        if resolved.source == .userOverride {
          Button("Restore Default") { requestReset(for: entry.id) }
        }
      }
    }
  }

  /// The recorder NSView captures `keyDown` only; the SwiftUI button overlaid on top is
  /// what receives mouse clicks and drives `recordingID`. The recorder's mouse-handling
  /// paths are therefore intentionally unused.
  @ViewBuilder
  private func chordCell(entry: ShortcutSchema.Entry, resolved: ResolvedShortcut?) -> some View {
    if entry.scope == .configurable {
      let isThisRowRecording = recordingID == entry.id
      HotkeyRecorderView(
        isRecording: Binding(
          get: { isThisRowRecording },
          set: { newValue in
            if newValue {
              recordingID = entry.id
              rejectionMessage = nil
            } else if recordingID == entry.id {
              recordingID = nil
            }
          }
        ),
        onCapture: { binding in
          handleCapture(binding, for: entry.id)
        },
        onReject: { reason in
          rejectionMessage = rejectionText(reason)
        },
        onCancel: {
          rejectionMessage = nil
        }
      )
      .overlay(alignment: .leading) {
        Button {
          if recordingID == entry.id {
            recordingID = nil
          } else {
            recordingID = entry.id
            rejectionMessage = nil
          }
        } label: {
          chordLabel(resolved: resolved, isRecording: isThisRowRecording)
            .frame(maxWidth: .infinity, alignment: .center)
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
      }
      .frame(height: 24)
    } else {
      // System-fixed: render the chord as a non-interactive label.
      HStack {
        chordLabel(resolved: resolved, isRecording: false)
        Spacer()
      }
      .padding(.horizontal, 8)
      .padding(.vertical, 3)
      .overlay(
        RoundedRectangle(cornerRadius: 5)
          .stroke(Color.secondary.opacity(0.25), lineWidth: 1)
      )
    }
  }

  @ViewBuilder
  private func chordLabel(resolved: ResolvedShortcut?, isRecording: Bool) -> some View {
    if isRecording {
      Text("Type a chord…")
        .font(.system(size: 11, design: .monospaced))
        .foregroundStyle(.secondary)
    } else if let resolved, let binding = resolved.binding {
      Text(ShortcutDisplay.chord(for: binding))
        .font(.system(size: 12, design: .monospaced))
        .foregroundStyle(resolved.isEnabled ? .primary : .secondary)
        .strikethrough(!resolved.isEnabled)
    } else {
      Text("Unassigned")
        .font(.system(size: 11))
        .foregroundStyle(.secondary)
    }
  }

  @ViewBuilder
  private func sourcePill(_ resolved: ResolvedShortcut?) -> some View {
    let label = sourceLabel(resolved)
    Text(label.text)
      .font(.caption2.weight(.medium))
      .padding(.horizontal, 6)
      .padding(.vertical, 2)
      .background(
        RoundedRectangle(cornerRadius: 4).fill(label.color.opacity(0.18))
      )
      .foregroundStyle(label.color)
  }

  // MARK: - Mutations

  private func handleCapture(_ binding: ShortcutBinding, for id: CommandID) {
    let symbolicHotkeyDefaults = UserDefaults(suiteName: "com.apple.symbolichotkeys") ?? .standard
    if SystemReservedDetector.isReserved(
      keyCode: binding.keyCode,
      modifiers: binding.modifiers,
      in: symbolicHotkeyDefaults
    ) {
      rejectionMessage = "That chord is claimed by a macOS system shortcut."
      return
    }
    if AppKitReservedDetector.isReserved(keyCode: binding.keyCode, modifiers: binding.modifiers) {
      rejectionMessage = "That chord is reserved by macOS standard menus."
      return
    }
    if let conflictingID = InternalConflictDetector.conflicts(
      in: store.resolved, candidate: binding, excluding: id
    ) {
      pendingConflict = PendingConflict(
        target: id, binding: binding, conflictingID: conflictingID
      )
      recordingID = nil
      return
    }
    rejectionMessage = nil
    recordingID = nil
    store.update(id, to: binding)
  }

  private func requestReset(for id: CommandID) {
    let plan = ShortcutResetPlanner.plan(
      resetting: id, schema: .app, overrides: store.overrides
    )
    pendingReset = plan
  }

  private func restoreEnabled(for id: CommandID) {
    guard let resolved = store.resolved[id], let binding = resolved.binding else { return }
    let enabled = ShortcutBinding(
      keyCode: binding.keyCode, modifiers: binding.modifiers, isEnabled: true
    )
    if resolved.source == .userOverride {
      store.update(id, to: enabled)
    } else {
      store.clear(id)
    }
  }

  // MARK: - Filtering

  private var visibleCategories: [ShortcutSchema.Category] {
    ShortcutSchema.Category.allCases.filter { !filteredEntries(for: $0).isEmpty }
  }

  private func filteredEntries(for category: ShortcutSchema.Category) -> [ShortcutSchema.Entry] {
    let trimmed = query.trimmingCharacters(in: .whitespaces).lowercased()
    return ShortcutSchema.app.entries
      .filter { $0.category == category }
      .filter { entry in
        guard !trimmed.isEmpty else { return true }
        if entry.title.lowercased().contains(trimmed) { return true }
        if let binding = store.resolved[entry.id]?.binding,
           ShortcutDisplay.chord(for: binding).lowercased().contains(trimmed) { return true }
        return false
      }
  }

  // MARK: - Dialogs

  private struct PendingConflict: Equatable {
    let target: CommandID
    let binding: ShortcutBinding
    let conflictingID: CommandID
  }

  private var conflictDialogBinding: Binding<Bool> {
    Binding(
      get: { pendingConflict != nil },
      set: { presented in
        if !presented { pendingConflict = nil }
      }
    )
  }

  private var conflictDialogTitle: String { "Replace Existing Shortcut?" }
  private var conflictDialogMessage: String {
    guard let pending = pendingConflict,
          let conflictingTitle = ShortcutSchema.app.entry(for: pending.conflictingID)?.title
    else { return "" }
    return "This chord is currently bound to ‘\(conflictingTitle)’. Replacing will disable that shortcut."
  }

  private var resetDialogBinding: Binding<Bool> {
    Binding(
      get: { pendingReset != nil },
      set: { presented in
        if !presented { pendingReset = nil }
      }
    )
  }

  private var resetDialogTitle: String { "Restore Default?" }
  private var resetDialogMessage: String {
    guard let plan = pendingReset else { return "" }
    if plan.cascadingResets.isEmpty {
      let title = ShortcutSchema.app.entry(for: plan.target)?.title ?? plan.target.rawValue
      return "Restore the default chord for ‘\(title)’."
    }
    let titles = plan.cascadingResets
      .compactMap { ShortcutSchema.app.entry(for: $0)?.title }
      .map { "‘\($0)’" }
      .joined(separator: ", ")
    let target = ShortcutSchema.app.entry(for: plan.target)?.title ?? plan.target.rawValue
    return "Resetting ‘\(target)’ will also reset \(titles) so the chords no longer collide."
  }

  private var restoreAllTitle: String { "Restore All Defaults?" }

  // MARK: - Display helpers

  private func scopeDescription(_ scope: ShortcutScope) -> String {
    switch scope {
    case .configurable: return "Customizable"
    case .systemFixed: return "System default"
    case .localOnly: return "Context-specific"
    }
  }

  private func sourceLabel(_ resolved: ResolvedShortcut?) -> (text: String, color: Color) {
    guard let resolved else { return ("—", .secondary) }
    if !resolved.isEnabled { return ("Disabled", .gray) }
    switch resolved.source {
    case .schemaDefault: return ("Default", .secondary)
    case .userOverride: return ("Custom", .accentColor)
    }
  }

  private func rejectionText(_ reason: HotkeyRecorderNSView.RejectionReason) -> String {
    switch reason {
    case .missingPrimaryModifier: return "Add a ⌘, ⌥, or ⌃ modifier."
    case .modifierOnly: return "Press a non-modifier key."
    }
  }
}

extension ShortcutSchema.Category {
  fileprivate var title: String {
    switch self {
    case .general: return "General"
    case .tabs: return "Tabs"
    case .sidebar: return "Sidebar"
    case .system: return "System"
    }
  }
}
