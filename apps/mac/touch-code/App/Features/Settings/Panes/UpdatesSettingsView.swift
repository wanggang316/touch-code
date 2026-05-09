import AppKit
import ComposableArchitecture
import Sparkle
import SwiftUI
import TouchCodeCore

/// Settings → Updates pane. `settings.json` is the source of truth — every
/// toggle / picker writes to `SettingsStore` and immediately replays the
/// full preference triple through `UpdatesClient.applyPreferences(...)` so
/// the running Sparkle instance never drifts from disk. The same client
/// runs once on launch (see `AppState.bringUp`), so a relaunch reproduces
/// whatever state the user left the pane in.
///
/// Channel selection is the headline knob. `tip` opts into pre-release
/// builds via Sparkle's appcast `<sparkle:channel>` filter and tightens
/// the background-check cadence; `stable` only sees release-cut items.
struct UpdatesSettingsView: View {
  @Environment(SettingsStore.self) private var settingsStore
  @Dependency(UpdatesClient.self) private var updatesClient

  @State private var lastCheckedAt: Date?
  @State private var feedURL: URL?

  private var general: GeneralSettings { settingsStore.settings.general }

  private var updateChannelBinding: Binding<UpdateChannel> {
    Binding(
      get: { general.updateChannel },
      set: { newValue in
        settingsStore.setUpdateChannel(newValue)
        applyToSparkle(triggerBackgroundCheck: true)
      }
    )
  }

  private var automaticChecksBinding: Binding<Bool> {
    Binding(
      get: { general.updatesAutomaticallyCheckForUpdates },
      set: { newValue in
        let wasOff = !general.updatesAutomaticallyCheckForUpdates
        settingsStore.setUpdatesAutomaticallyCheckForUpdates(newValue)
        // Only fire a background probe when transitioning OFF→ON; ON→OFF
        // and OFF→OFF should never trigger a network check.
        applyToSparkle(triggerBackgroundCheck: newValue && wasOff)
      }
    )
  }

  private var automaticDownloadsBinding: Binding<Bool> {
    Binding(
      get: { general.updatesAutomaticallyDownloadUpdates },
      set: { newValue in
        settingsStore.setUpdatesAutomaticallyDownloadUpdates(newValue)
        applyToSparkle(triggerBackgroundCheck: false)
      }
    )
  }

  var body: some View {
    Form {
      channelSection
      automaticSection
      manualSection
      feedSection
    }
    .formStyle(.grouped)
    .task {
      // Capture once on appear — Sparkle owns these strings and doesn't
      // emit change notifications on a hot reconfigure.
      let updater = UpdatesEnvironment.updater
      lastCheckedAt = updater.lastUpdateCheckDate
      feedURL = updater.feedURL
    }
    .onReceive(
      NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)
    ) { _ in
      lastCheckedAt = UpdatesEnvironment.updater.lastUpdateCheckDate
    }
  }

  // MARK: - Sections

  @ViewBuilder
  private var channelSection: some View {
    Section {
      Picker(selection: updateChannelBinding) {
        ForEach(UpdateChannel.allCases, id: \.self) { channel in
          Text(channel.title).tag(channel)
        }
      } label: {
        Text("Release channel")
        Text(general.updateChannel.subtitle)
      }
    }
  }

  @ViewBuilder
  private var automaticSection: some View {
    Section("Automatic updates") {
      Toggle(isOn: automaticChecksBinding) {
        Text("Check for updates automatically")
        Text("Polls in the background while running.")
      }
      Toggle(isOn: automaticDownloadsBinding) {
        Text("Download and install in the background")
        Text("Installs on next relaunch.")
      }
      .disabled(!general.updatesAutomaticallyCheckForUpdates)
    }
  }

  @ViewBuilder
  private var manualSection: some View {
    Section("Manual check") {
      HStack(alignment: .firstTextBaseline) {
        Button("Check for Updates…") {
          updatesClient.checkNow()
          // Sparkle stamps lastUpdateCheckDate after the request completes;
          // re-read after a short delay so the relative-time label
          // refreshes without forcing the user to leave + reopen the pane.
          Task { @MainActor in
            try? await Task.sleep(for: .seconds(2))
            lastCheckedAt = UpdatesEnvironment.updater.lastUpdateCheckDate
          }
        }
        .disabled(!UpdatesEnvironment.updater.canCheckForUpdates)
        .commandKeyHint(.checkForUpdates)
        .helpWithShortcut("Check for Updates", .checkForUpdates)
        Spacer()
        Text(lastCheckedLabel)
          .font(.callout)
          .foregroundStyle(.secondary)
      }
    }
  }

  @ViewBuilder
  private var feedSection: some View {
    #if DEBUG
      if let feedURL {
        Section("Feed") {
          LabeledContent("Appcast URL") {
            Text(feedURL.absoluteString)
              .font(.callout.monospaced())
              .foregroundStyle(.secondary)
              .textSelection(.enabled)
              .lineLimit(2)
              .truncationMode(.middle)
          }
        }
      }
    #endif
  }

  // MARK: - Helpers

  private func applyToSparkle(triggerBackgroundCheck: Bool) {
    let g = settingsStore.settings.general
    updatesClient.applyPreferences(
      g.updateChannel,
      g.updatesAutomaticallyCheckForUpdates,
      g.updatesAutomaticallyDownloadUpdates,
      triggerBackgroundCheck
    )
  }

  private var lastCheckedLabel: String {
    guard let lastCheckedAt else { return "Never checked" }
    let formatter = RelativeDateTimeFormatter()
    formatter.unitsStyle = .full
    return "Last checked \(formatter.localizedString(for: lastCheckedAt, relativeTo: Date()))"
  }
}

extension UpdateChannel {
  /// Display name shown in the channel `Picker` row.
  fileprivate var title: String {
    switch self {
    case .stable: return "Stable"
    case .tip: return "Tip"
    }
  }

  /// Sub-label rendered below the picker so the difference between the
  /// channels is visible without opening release notes.
  fileprivate var subtitle: String {
    switch self {
    case .stable: return "Released versions, checked daily."
    case .tip: return "Pre-release builds, checked hourly."
    }
  }
}

#Preview {
  UpdatesSettingsView()
    .frame(width: 600, height: 500)
}
