import AppKit
import SwiftUI
import TouchCodeCore
import os.log

/// Notifications detail pane. Five controls per spec M5 — read through
/// `SettingsStore`'s `NotificationSettingsReader` conformance, writes routed
/// via `mutateNotifications`. Matches `SettingsGeneralView`'s direct-store
/// pattern so no TCA reducer sits between the toggles and persistence.
struct NotificationsSettingsView: View {
  let settingsStore: SettingsStore
  @State private var showPermissionAlert = false

  var body: some View {
    Form {
      masterSection
      inAppSection
      systemSection
      soundSection
      dockBadgeSection
      muteRulesSection
    }
    .formStyle(.grouped)
    .alert("Notifications blocked", isPresented: $showPermissionAlert) {
      Button("Open System Settings") { Self.openSystemNotificationsPreferences() }
      Button("Cancel", role: .cancel) {}
    } message: {
      Text(
        "macOS is blocking notifications for touch-code. "
          + "Open System Settings and allow notifications, then return here."
      )
    }
  }

  // MARK: - Master toggle (v2 D5)

  private var masterSection: some View {
    let binding = Binding<Bool>(
      get: { settingsStore.settings.notifications.enabled },
      set: { newValue in
        settingsStore.mutateNotifications { $0.enabled = newValue }
      }
    )
    return Section {
      Toggle("Notifications enabled", isOn: binding)
    } header: {
      Text("Master")
    } footer: {
      Text(
        "When off, no notifications are produced — no inbox row, no banner, no Dock badge. "
          + "Distinct from Mute rules, which still record notifications for later review."
      )
    }
  }

  /// Master master kill switch is the source of truth for whether the
  /// rest of the controls have any effect. Disabling them visually when
  /// off makes the relationship obvious without hiding rows.
  private var masterEnabled: Bool {
    settingsStore.settings.notifications.enabled
  }

  // MARK: - In-app notifications

  private var inAppSection: some View {
    let binding = Binding<Bool>(
      get: { settingsStore.settings.notifications.inAppEnabled },
      set: { newValue in
        settingsStore.mutateNotifications { $0.inAppEnabled = newValue }
      }
    )
    return Section {
      Toggle("Show notifications inside touch-code", isOn: binding)
        .disabled(!masterEnabled)
    } header: {
      Text("In-app notifications")
    } footer: {
      Text("Also gates the bell unread list and Dock badge.")
    }
  }

  // MARK: - System notifications

  private var systemSection: some View {
    let binding = Binding<Bool>(
      get: { settingsStore.settings.notifications.systemEnabled },
      set: { newValue in
        settingsStore.mutateNotifications { $0.systemEnabled = newValue }
        // Surface the permission block after the write lands so the toggle state
        // reflects user intent regardless of OS authorization.
        if newValue, settingsStore.settings.notifications.authStatus == .denied {
          showPermissionAlert = true
        }
      }
    )
    return Section {
      Toggle("Show macOS banners", isOn: binding)
        .disabled(!masterEnabled)
    } header: {
      Text("System notifications")
    } footer: {
      Text("Delivered by the macOS Notification Center.")
    }
  }

  // MARK: - Sound

  private var soundSection: some View {
    let binding = Binding<Bool>(
      get: { settingsStore.settings.notifications.soundEnabled },
      set: { newValue in
        settingsStore.mutateNotifications { $0.soundEnabled = newValue }
      }
    )
    let systemOn = settingsStore.settings.notifications.systemEnabled
    return Section {
      Toggle("Play the default notification sound", isOn: binding)
        .disabled(!masterEnabled || !systemOn)
        .help(systemOn ? "" : "Enable System notifications to play a sound.")
    } header: {
      Text("Sound")
    } footer: {
      Text("Applies to macOS banners only.")
    }
  }

  // MARK: - Dock badge

  private var dockBadgeSection: some View {
    let binding = Binding<Bool>(
      get: { settingsStore.settings.notifications.dockBadgeEnabled },
      set: { newValue in
        settingsStore.mutateNotifications { $0.dockBadgeEnabled = newValue }
      }
    )
    let inAppOn = settingsStore.settings.notifications.inAppEnabled
    return Section {
      Toggle("Show the unread count on the app icon", isOn: binding)
        .disabled(!masterEnabled || !inAppOn)
        .help(inAppOn ? "" : "No unread count available while in-app notifications are off.")
    } header: {
      Text("Dock badge")
    } footer: {
      Text("Badge value mirrors the bell unread count.")
    }
  }

  // MARK: - Mute rules summary

  private var muteRulesSection: some View {
    let mute = settingsStore.settings.notifications.mute
    return Section {
      LabeledContent("Summary") {
        Text(Self.muteSummary(for: mute))
      }
      Button {
        Self.revealDetectionRules()
      } label: {
        Label("Reveal rules.json in Finder", systemImage: "folder")
      }
    } header: {
      Text("Mute rules")
    } footer: {
      Text("Rules live in ~/.config/touch-code/detection-rules.json — edit there for now.")
    }
  }

  // MARK: - Helpers

  private static func muteSummary(for mute: MuteSettings) -> String {
    let ruleCount = mute.mutedRuleIDs.count
    let paneCount = mute.mutedPaneIDs.count
    if ruleCount == 0 && paneCount == 0 { return "No mute rules" }
    return "\(ruleCount) rule(s), \(paneCount) pane(s) muted"
  }

  private static func revealDetectionRules() {
    let url = ConfigPaths.detectionRules()
    // Ensure the target exists so Finder doesn't open on nothing.
    try? DefaultRules.installIfMissing(at: url)
    NSWorkspace.shared.activateFileViewerSelecting([url])
  }

  private static func openSystemNotificationsPreferences() {
    let bundleID = Bundle.main.bundleIdentifier ?? ""
    let anchored = URL(
      string: "x-apple.systempreferences:com.apple.preference.notifications?id=\(bundleID)")
    let bare = URL(string: "x-apple.systempreferences:com.apple.preference.notifications")
    if let anchored, NSWorkspace.shared.open(anchored) { return }
    if let bare, NSWorkspace.shared.open(bare) { return }
    Logger(subsystem: "com.touch-code.ui", category: "notifications-pane")
      .error("Could not open System Settings notifications pane; both URLs rejected.")
  }
}

#Preview {
  NotificationsSettingsView(
    settingsStore: SettingsStore(
      fileURL: FileManager.default.temporaryDirectory.appending(component: "\(UUID()).json"),
      debounceWindow: .seconds(3600)
    )
  )
  .frame(width: 560, height: 520)
}
