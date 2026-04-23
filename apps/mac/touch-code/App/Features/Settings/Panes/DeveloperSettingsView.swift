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
    Form {
      Section("CLI") {
        CLIInstallStatusCard(installer: deps.installer, settingsStore: settingsStore)
      }
      hooksSection
      Section("Diagnostics") {
        DiagnosticsSection()
      }
    }
    .formStyle(.grouped)
    .task { reloadHooks() }
  }

  // MARK: - Hooks section

  private var hooksSection: some View {
    Section {
      if let error = hookLoadError {
        HStack(alignment: .top, spacing: 6) {
          Image(systemName: "exclamationmark.circle.fill")
            .foregroundStyle(.orange)
            .accessibilityHidden(true)
          Text("Could not reload hooks.json: \(error)")
            .font(.caption)
            .foregroundStyle(.secondary)
        }
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
    } header: {
      HStack {
        Text("Hooks")
        Spacer(minLength: 0)
        Button {
          reloadHooks()
        } label: {
          Label("Reload from hooks.json", systemImage: "arrow.clockwise")
            .labelStyle(.iconOnly)
        }
        .buttonStyle(.borderless)
      }
    } footer: {
      Text(
        "Read-only view of your `hooks.json`. Edit the file directly to add or change hooks."
      )
    }
  }

  private var rows: [HookRow] {
    subscriptions.map { HookRowBuilder.make(from: $0, source: .global) }
  }

  /// Delegate to `HookReloader` so the "keep previous snapshot on failure"
  /// rule stays in one place and can be unit-tested without SwiftUI.
  private func reloadHooks() {
    let outcome = HookReloader.reload(previous: subscriptions) {
      try deps.loadHookConfig()
    }
    subscriptions = outcome.subscriptions
    hookLoadError = outcome.error
  }
}
