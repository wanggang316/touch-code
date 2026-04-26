import ComposableArchitecture
import SwiftUI
import TouchCodeCore

/// Native toolbar split button: primary action runs the Project's
/// primary script (first `.run`-kind entry, falling back to the first
/// script overall); the chevron half lists every script plus a
/// "Manage Scripts…" footer. Empty-state: primary click and every menu
/// item route to "Manage Scripts" so users land in a place where they
/// can create one. Uses `Menu(content:label:primaryAction:)` so macOS
/// renders the native split-button chrome — matches supacode's
/// `ScriptMenu` pattern.
///
/// Both halves dispatch through `WorktreeHeaderFeature.delegate` so
/// `RootFeature` owns the `HierarchyClient.runScript` effect.
struct HeaderRunScriptSplitButton: View {
  @Bindable var store: StoreOf<WorktreeHeaderFeature>
  let projectID: ProjectID
  let worktreeID: WorktreeID
  @Environment(SettingsStore.self) private var settingsStore

  var body: some View {
    Menu {
      caretMenu
    } label: {
      HStack(spacing: 4) {
        Image(systemName: primaryIconName)
          .frame(width: 16, height: 16)
          .foregroundStyle(primaryTint)
          .accessibilityHidden(true)
        Text(primaryLabel)
          .lineLimit(1)
      }
    } primaryAction: {
      primaryAction()
    }
    .accessibilityLabel(primaryLabel)
    .help(primaryHelp)
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

  // MARK: - Actions

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
