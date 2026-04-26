import ComposableArchitecture
import SwiftUI
import TouchCodeCore

/// Split button chip — same explicit geometry contract as
/// `HeaderOpenSplitButton`. Outer capsule is drawn here (not by macOS
/// 26's toolbar shared background) so the four-side gap to the inner
/// halves stays uniform.
///
/// Both halves dispatch through `WorktreeHeaderFeature.delegate` so
/// `RootFeature` owns the `HierarchyClient.runScript` effect.
struct HeaderRunScriptSplitButton: View {
  @Bindable var store: StoreOf<WorktreeHeaderFeature>
  let projectID: ProjectID
  let worktreeID: WorktreeID
  @Environment(SettingsStore.self) private var settingsStore

  static let innerHeight: CGFloat = HeaderOpenSplitButton.innerHeight
  static let gap: CGFloat = HeaderOpenSplitButton.gap

  var body: some View {
    HStack(spacing: 4) {
      primary
      caret
    }
    .frame(height: Self.innerHeight)
    .padding(Self.gap)
    .background(
      Capsule(style: .continuous)
        .fill(.regularMaterial)
    )
  }

  // MARK: - State derivation

  private var scripts: [ScriptDefinition] {
    settingsStore.settings.projects[projectID]?.scripts ?? []
  }

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
      .frame(height: Self.innerHeight)
    }
    .buttonStyle(.plain)
    .accessibilityLabel(primaryLabel)
    .help(primaryHelp)
    .modifier(HeaderChipHover())
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

  // MARK: - Caret

  private var caret: some View {
    Menu {
      caretMenu
    } label: {
      Image(systemName: "chevron.down")
        .font(.caption.bold())
        .accessibilityHidden(true)
        .frame(width: Self.innerHeight, height: Self.innerHeight)
    }
    .menuStyle(.button)
    .buttonStyle(.plain)
    .menuIndicator(.hidden)
    .accessibilityLabel("Choose script")
    .help("Choose script")
    .modifier(HeaderChipHover())
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
