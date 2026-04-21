import SwiftUI
import TouchCodeCore

/// Developer detail pane (spec M6). Three stacked sections:
/// 1. `tc` CLI status + install/uninstall (M6.1) via `CLIInstallStatusCard`.
/// 2. User hooks list (M6.2) rendered through the shared `HookMergeView`. The
///    pane holds the `[HookSubscription]` snapshot in local `@State` and
///    refreshes it from `hooks.json` on appear / Reload button press.
/// 3. Diagnostics (M6.3) via `DiagnosticsSection`.
///
/// Dependencies arrive through `@Environment` so the T1-frozen detail switch
/// in `SettingsWindowView` does not need to be touched.
struct DeveloperSettingsView: View {
  @Environment(SettingsStore.self) private var settingsStore
  @Environment(DeveloperPaneDependencies.self) private var deps

  @State private var subscriptions: [HookSubscription] = []
  @State private var hookLoadError: String?

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 28) {
        CLIInstallStatusCard(installer: deps.installer, settingsStore: settingsStore)
        hooksSection
        DiagnosticsSection()
      }
      .padding(24)
    }
    .task { reloadHooks() }
  }

  // MARK: - Hooks section

  private var hooksSection: some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack {
        Text("Hooks").font(.headline)
        Spacer(minLength: 0)
        Button {
          reloadHooks()
        } label: {
          Label("Reload from hooks.json", systemImage: "arrow.clockwise")
        }
        .buttonStyle(.borderless)
      }

      Text(
        "Read-only view of your `hooks.json`. Edit the file directly to add or change hooks."
      )
      .font(.caption)
      .foregroundStyle(.secondary)

      if let error = hookLoadError {
        HStack(alignment: .top, spacing: 6) {
          Image(systemName: "exclamationmark.circle.fill")
            .foregroundStyle(.orange)
            .accessibilityHidden(true)
          Text("Could not reload hooks.json: \(error)")
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding(8)
        .background(Color.orange.opacity(0.08), in: .rect(cornerRadius: 6))
      }

      HookMergeView(
        rows: rows,
        emptyStateTitle: "No hooks in hooks.json.",
        emptyStateMessage: "Edit the file to add one; matching happens live.",
        showsSourceTag: false,
        trailingAction: TrailingAction(title: "Reveal hooks.json", systemImage: "folder") {
          deps.revealInFinder(HookConfig.defaultURL())
        }
      )
    }
  }

  private var rows: [HookRow] {
    subscriptions.map { HookRowBuilder.make(from: $0, source: .global) }
  }

  /// On success: replace `subscriptions` and clear any prior error. The
  /// `loadHookConfig` closure swallows decode errors and returns
  /// `HookConfig.empty` on failure; the surrounding structure is kept so a
  /// future `throws`-returning variant slots in without another rewrite.
  private func reloadHooks() {
    let config = deps.loadHookConfig()
    subscriptions = config.subscriptions
    hookLoadError = nil
  }
}
