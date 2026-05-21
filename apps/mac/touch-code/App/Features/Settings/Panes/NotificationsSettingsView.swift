import AppKit
import SwiftUI
import TouchCodeCore
@preconcurrency import UserNotifications

/// Settings → Notifications pane (v1.1). Surfaces every user-visible knob
/// consumed by `NotificationCoordinator` plus the v1.0 macOS authorization
/// recovery surface:
///
/// 1. Per-surface toggles (in-app inbox, system banners, sound, dock badge).
///    Writes go through `SettingsStore.mutateNotifications(_:)`, which the
///    coordinator reads via `NotificationSettingsReader` at decision time —
///    every flip therefore takes effect on the next event without further
///    plumbing.
/// 2. Command-finished detector — master toggle plus the minimum-duration
///    threshold. The threshold field clamps writes to
///    `NotificationsSettings.thresholdRange` so hand-typed extremes never
///    reach the persisted JSON.
/// 3. Mute summary + Reveal in Finder for `~/.config/touch-code/detection-rules.json`.
///    Rule editing happens in the JSON file directly (v1.1 scope keeps the
///    UI read-only); the button bootstraps an empty default if the file is
///    missing so the user always lands on something openable.
/// 4. macOS permission status (PM2 recovery surface from v1.0) — kept verbatim,
///    just relocated below the new sections so the toggles are the primary
///    affordance.
/// 5. About blurb describing what the toggles gate.
///
/// Permission alert (D1 in the v1.1 design doc): flipping System notifications
/// on while macOS authorization is `.denied` shows an alert that deep-links
/// into System Settings. The toggle's persisted value is preserved regardless
/// of the user's alert choice — we only inform; we don't roll back state.
///
/// Authorization is re-read on every appear and on `applicationDidBecomeActive`
/// so a flip in System Settings takes effect without a relaunch.
struct NotificationsSettingsView: View {
  @Environment(SettingsStore.self) private var settingsStore
  @Environment(UserNotificationsOSNotifier.self) private var osNotifier: UserNotificationsOSNotifier?
  @State private var status: AuthorizationStatus = .notDetermined
  @State private var isRefreshing = false
  @State private var showPermissionAlert = false

  var body: some View {
    Form {
      Section("Notifications") {
        Toggle("In-app notifications", isOn: inAppBinding)
        Text("Gates the bell unread list and the Dock badge.")
          .font(.callout)
          .foregroundStyle(.secondary)

        Toggle("System notifications", isOn: systemBinding)

        Toggle("Sound", isOn: soundBinding)
          .disabled(!settingsStore.settings.notifications.systemEnabled)
          .help("Sound requires System notifications to be on.")

        Toggle("Dock badge", isOn: dockBadgeBinding)
        Text("Shows the unread notification count on the app icon.")
          .font(.callout)
          .foregroundStyle(.secondary)
      }

      Section("Command-finished notifications") {
        Toggle("Notify when a command finishes", isOn: commandFinishedBinding)

        HStack {
          Text("Minimum duration")
          Spacer()
          TextField("Seconds", value: thresholdBinding, format: .number)
            .frame(width: 60)
            .textFieldStyle(.roundedBorder)
            .disabled(!settingsStore.settings.notifications.commandFinishedEnabled)
          Text("seconds")
        }
        Text(
          "Commands shorter than this are silent. Cancelled commands (Ctrl-C) are always "
            + "silent. Notifications are also suppressed for 1 second after you type in the pane."
        )
        .font(.callout)
        .foregroundStyle(.secondary)
      }

      Section("Mute rules") {
        HStack {
          Text(muteSummary)
            .foregroundStyle(.secondary)
          Spacer()
        }
        Button("Reveal rules.json in Finder…") { revealRulesFile() }
      }

      Section("macOS permission") {
        statusRow
        actionRow
      }
    }
    .formStyle(.grouped)
    .alert("Notifications are blocked", isPresented: $showPermissionAlert) {
      Button("Open System Settings…") { openSystemNotificationsPane() }
      Button("Cancel", role: .cancel) {}
    } message: {
      Text(
        "macOS is currently blocking notifications for touch-code. "
          + "Open System Settings to allow them."
      )
    }
    .task { await refresh() }
    .onReceive(
      NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)
    ) { _ in
      Task { await refresh() }
    }
  }

  // MARK: - Bindings

  private var inAppBinding: Binding<Bool> {
    Binding(
      get: { settingsStore.settings.notifications.inAppEnabled },
      set: { newValue in
        settingsStore.mutateNotifications { $0.inAppEnabled = newValue }
      }
    )
  }

  private var systemBinding: Binding<Bool> {
    Binding(
      get: { settingsStore.settings.notifications.systemEnabled },
      set: { newValue in
        settingsStore.mutateNotifications { $0.systemEnabled = newValue }
        // D1 — when the user enables System notifications while macOS has
        // already denied authorization, the toggle alone has no runtime
        // effect. Surface the alert so they know to flip the OS-level switch
        // too. The persisted value is intentionally NOT rolled back; the
        // setting reflects user intent, the alert reflects current reality.
        guard newValue, let notifier = osNotifier else { return }
        Task {
          let current = await notifier.currentAuthorizationStatus()
          if current == .denied {
            showPermissionAlert = true
          }
        }
      }
    )
  }

  private var soundBinding: Binding<Bool> {
    Binding(
      get: { settingsStore.settings.notifications.soundEnabled },
      set: { newValue in
        settingsStore.mutateNotifications { $0.soundEnabled = newValue }
      }
    )
  }

  private var dockBadgeBinding: Binding<Bool> {
    Binding(
      get: { settingsStore.settings.notifications.dockBadgeEnabled },
      set: { newValue in
        settingsStore.mutateNotifications { $0.dockBadgeEnabled = newValue }
      }
    )
  }

  private var commandFinishedBinding: Binding<Bool> {
    Binding(
      get: { settingsStore.settings.notifications.commandFinishedEnabled },
      set: { newValue in
        settingsStore.mutateNotifications { $0.commandFinishedEnabled = newValue }
      }
    )
  }

  /// Threshold binding that clamps writes to `NotificationsSettings.thresholdRange`
  /// before persistence so a hand-typed `0` or `99999` never reaches `settings.json`.
  /// `get` returns the stored value verbatim — clamping on read would mask
  /// any drift introduced by other writers.
  private var thresholdBinding: Binding<Int> {
    Binding(
      get: { settingsStore.settings.notifications.commandFinishedThresholdSec },
      set: { newValue in
        let range = NotificationsSettings.thresholdRange
        let clamped = max(range.lowerBound, min(range.upperBound, newValue))
        settingsStore.mutateNotifications { $0.commandFinishedThresholdSec = clamped }
      }
    )
  }

  // MARK: - Mute summary + reveal

  private var muteSummary: String {
    let mute = settingsStore.settings.notifications.mute
    if mute.mutedRuleIDs.isEmpty && mute.mutedPaneIDs.isEmpty {
      return "No mute rules"
    }
    return "\(mute.mutedRuleIDs.count) rule(s), \(mute.mutedPaneIDs.count) pane(s) muted"
  }

  /// Opens `~/.config/touch-code/detection-rules.json` in Finder, creating
  /// the file (and its parent directory) with an empty default ruleset if
  /// it does not already exist. The atomic write means partial files never
  /// surface even if the process is killed mid-write.
  private func revealRulesFile() {
    let url = FileManager.default.homeDirectoryForCurrentUser
      .appendingPathComponent(".config/touch-code/detection-rules.json", isDirectory: false)

    if !FileManager.default.fileExists(atPath: url.path) {
      let parent = url.deletingLastPathComponent()
      try? FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
      let defaultContent = Data("{\"version\":1,\"rules\":[]}".utf8)
      try? defaultContent.write(to: url, options: .atomic)
    }

    NSWorkspace.shared.activateFileViewerSelecting([url])
  }

  /// Deep-links into System Settings → Notifications → touch-code if the
  /// per-app anchor is supported; otherwise falls back to the top-level
  /// Notifications pane. The fallback covers older macOS releases and the
  /// rare case where `NSWorkspace.open` declines the anchored URL.
  private func openSystemNotificationsPane() {
    let bundleID = Bundle.main.bundleIdentifier ?? "com.gumpw.touch-agent-mac"
    let withID = URL(string: "x-apple.systempreferences:com.apple.preference.notifications?id=\(bundleID)")
    let fallback = URL(string: "x-apple.systempreferences:com.apple.preference.notifications")!
    if let withID, NSWorkspace.shared.open(withID) { return }
    NSWorkspace.shared.open(fallback)
  }

  // MARK: - Permission status subviews (v1.0, relocated)

  @ViewBuilder
  private var statusRow: some View {
    HStack(spacing: 8) {
      Image(systemName: statusIcon)
        .foregroundStyle(statusTint)
      Text(statusLabel)
      Spacer()
      if isRefreshing {
        ProgressView().controlSize(.small)
      }
    }
  }

  @ViewBuilder
  private var actionRow: some View {
    switch status {
    case .notDetermined:
      Button("Request permission…") {
        Task {
          guard let notifier = osNotifier else { return }
          status = await notifier.requestAuthorization()
        }
      }
      .disabled(osNotifier == nil)
    case .denied:
      Button("Open System Settings…") {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.notifications") {
          NSWorkspace.shared.open(url)
        }
      }
    case .authorized:
      Text("Banners are enabled. The app will only fire one when the originating pane is not your current focus.")
        .font(.callout)
        .foregroundStyle(.secondary)
    }
  }

  // MARK: - State

  private var statusIcon: String {
    switch status {
    case .authorized: return "checkmark.circle.fill"
    case .denied: return "exclamationmark.triangle.fill"
    case .notDetermined: return "questionmark.circle.fill"
    }
  }

  private var statusTint: Color {
    switch status {
    case .authorized: return .green
    case .denied: return .orange
    case .notDetermined: return .yellow
    }
  }

  private var statusLabel: String {
    switch status {
    case .authorized: return "Authorized"
    case .denied: return "Denied"
    case .notDetermined: return "Not yet asked"
    }
  }

  private func refresh() async {
    guard let notifier = osNotifier else { return }
    isRefreshing = true
    status = await notifier.currentAuthorizationStatus()
    isRefreshing = false
  }
}
