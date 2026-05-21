import AppKit
import SwiftUI
import TouchCodeCore
@preconcurrency import UserNotifications

/// Settings → Notifications pane (v1.1). Surfaces every user-visible knob
/// consumed by `NotificationCoordinator` plus the v1.0 macOS authorization
/// recovery surface:
///
/// 1. Per-surface toggles grouped as parent/child:
///    - In-app notifications (parent) — gates every surface inside the app:
///      bell popover, Dock badge, and the unread roll-up counts on projects,
///      worktrees, tabs, and panes. Implementation: when off, no entries
///      reach the inbox, so RollupIndex naturally reports 0 across the
///      hierarchy.
///      - Dock badge (child) — auto-disabled when In-app is off; lets users
///        suppress just the icon overlay while keeping the in-window
///        roll-up badges visible.
///    - System notifications (parent) — gates macOS banner + Notification
///      Center entries.
///      - Sound (child) — auto-disabled when System is off.
///    Writes go through `SettingsStore.mutateNotifications(_:)`, which the
///    coordinator reads via `NotificationSettingsReader` at decision time —
///    every flip therefore takes effect on the next event.
/// 2. macOS authorization status + recovery action live inside the System
///    section because the permission is specifically for posting
///    UNNotifications — it gates System banners and nothing else.
/// 3. Command-finished detector — master toggle plus the minimum-duration
///    threshold. The threshold field clamps writes to
///    `NotificationsSettings.thresholdRange` so hand-typed extremes never
///    reach the persisted JSON.
///
/// Permission alert (D1 in the v1.1 design doc): flipping System notifications
/// on while macOS authorization is `.denied` shows an alert that deep-links
/// into System Settings. The toggle's persisted value is preserved regardless
/// of the user's alert choice — we only inform; we don't roll back state.
///
/// Authorization is re-read on every appear and on `applicationDidBecomeActive`
/// so a flip in System Settings takes effect without a relaunch.
///
/// The Mute rules section is intentionally absent until the rule editor
/// lands; the underlying `NotificationsSettings.mute` fields persist but
/// nothing currently writes them (per-pane mute uses `Pane.labels` directly
/// — see `PaneContextMenu`).
struct NotificationsSettingsView: View {
  @Environment(SettingsStore.self) private var settingsStore
  @Environment(UserNotificationsOSNotifier.self) private var osNotifier: UserNotificationsOSNotifier?
  @State private var status: AuthorizationStatus = .notDetermined
  @State private var isRefreshing = false
  @State private var showPermissionAlert = false

  var body: some View {
    Form {
      Section("In-app") {
        Toggle(isOn: inAppBinding) {
          SettingLabel(
            title: "In-app notifications",
            caption: "Show notifications inside touch-code — the bell popover, the Dock badge, "
              + "and unread counts on projects, worktrees, tabs, and panes."
          )
        }

        Toggle(isOn: dockBadgeBinding) {
          SettingLabel(
            title: "Dock badge",
            caption: "Show the unread count on the app icon."
          )
        }
        .disabled(!settingsStore.settings.notifications.inAppEnabled)
        .help("Dock badge requires In-app notifications to be on.")
      }

      Section("System") {
        Toggle(isOn: systemBinding) {
          SettingLabel(
            title: "System notifications",
            caption: "Show banners in macOS Notification Center."
          )
        }

        Toggle("Sound", isOn: soundBinding)
          .disabled(!settingsStore.settings.notifications.systemEnabled)
          .help("Sound requires System notifications to be on.")

        // macOS authorization is a per-app permission specifically for posting
        // UNNotifications. It gates System banners regardless of the toggle
        // above, so the status + recovery action live inside the System
        // section rather than as a separate concept.
        statusRow
        actionRow
      }

      Section("Command Finished") {
        Toggle(isOn: commandFinishedBinding) {
          SettingLabel(
            title: "Notify when a command finishes",
            caption: "Commands shorter than the minimum duration are silent. Cancelled "
              + "commands (Ctrl-C) are always silent. Notifications are also suppressed for "
              + "1 second after you type in the pane."
          )
        }

        HStack {
          Text("Minimum duration")
          Spacer()
          TextField("", value: thresholdBinding, format: .number)
            .textFieldStyle(.plain)
            .multilineTextAlignment(.trailing)
            .frame(width: 48)
            .disabled(!settingsStore.settings.notifications.commandFinishedEnabled)
          Text("seconds")
            .foregroundStyle(.secondary)
        }
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

/// Title + secondary caption that fits inside a `Toggle`'s label slot so
/// the caption rides on the same Form row as its control instead of being
/// rendered as a separate row (which would force a divider between them).
private struct SettingLabel: View {
  let title: String
  let caption: String

  var body: some View {
    VStack(alignment: .leading, spacing: 2) {
      Text(title)
      Text(caption)
        .font(.callout)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
    }
  }
}
