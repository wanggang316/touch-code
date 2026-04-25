import ComposableArchitecture
import SwiftUI
import TouchCodeCore

/// Split button: left half runs the Project's primary script (first `.run`
/// kind, falling back to first script overall); right half (caret) lists
/// every script plus a "Manage Scripts…" footer that opens the Settings
/// window. Empty-state: primary click and every menu item route to
/// "Manage Scripts" so users land in a place where they can create one.
///
/// Both halves dispatch through `WorktreeHeaderFeature.delegate` so
/// `RootFeature` owns the `HierarchyClient.runScript` effect — matches the
/// pattern of `HeaderOpenSplitButton` for the editor open path.
struct HeaderRunScriptSplitButton: View {
  @Bindable var store: StoreOf<WorktreeHeaderFeature>
  let projectID: ProjectID
  let worktreeID: WorktreeID
  @Environment(SettingsStore.self) private var settingsStore

  var body: some View {
    HStack(spacing: 0) {
      primary
      caret
    }
  }

  // MARK: - State derivation

  /// Scripts attached to this Project, in array order.
  private var scripts: [ScriptDefinition] {
    settingsStore.settings.projects[projectID]?.scripts ?? []
  }

  /// Default script for the primary click. First `.run`-kind entry, falling
  /// back to the array's first entry. `nil` when the Project has no scripts.
  private var primaryScript: ScriptDefinition? {
    scripts.first { $0.kind == .run } ?? scripts.first
  }

  // MARK: - Primary

  @ViewBuilder
  private var primary: some View {
    Button(action: primaryAction) {
      HStack(spacing: 4) {
        Image(systemName: primaryIconName)
          .frame(width: 16, height: 16)
          .foregroundStyle(primaryTint)
          .accessibilityHidden(true)
        Text(primaryLabel)
          .lineLimit(1)
      }
      .padding(.horizontal, 6)
      .padding(.vertical, 3)
    }
    .buttonStyle(.borderless)
    .accessibilityLabel(primaryLabel)
    .help(primaryHelp)
  }

  private func primaryAction() {
    if let script = primaryScript {
      store.send(.runScriptTapped(scriptID: script.id, projectID: projectID, worktreeID: worktreeID))
    } else {
      store.send(.manageScriptsTapped)
    }
  }

  private var primaryLabel: String {
    primaryScript?.displayName ?? "Run"
  }

  private var primaryHelp: String {
    primaryScript == nil ? "Manage Scripts…" : "Run \(primaryLabel)"
  }

  private var primaryIconName: String {
    primaryScript?.resolvedSystemImage ?? ScriptKind.run.defaultSystemImage
  }

  private var primaryTint: Color {
    Self.color(for: primaryScript?.resolvedTintColor ?? .green)
  }

  // MARK: - Caret menu

  private var caret: some View {
    Menu {
      caretMenu
    } label: {
      Image(systemName: "chevron.down")
        .font(.caption.bold())
        .accessibilityHidden(true)
        .padding(.horizontal, 4)
        .padding(.vertical, 3)
    }
    .menuStyle(.borderlessButton)
    .menuIndicator(.hidden)
    .accessibilityLabel("Choose script")
    .help("Choose script")
  }

  @ViewBuilder
  private var caretMenu: some View {
    ForEach(scripts) { script in
      Button {
        store.send(
          .runScriptTapped(scriptID: script.id, projectID: projectID, worktreeID: worktreeID))
      } label: {
        Label(script.displayName, systemImage: script.resolvedSystemImage)
      }
    }
    if !scripts.isEmpty {
      Divider()
    }
    Button {
      store.send(.manageScriptsTapped)
    } label: {
      Label("Manage Scripts…", systemImage: "gearshape")
    }
  }

  // MARK: - Helpers

  /// Maps the model-layer `ScriptTintColor` to SwiftUI `Color`. Lives view-side
  /// so `TouchCodeCore` stays UI-framework-free.
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
