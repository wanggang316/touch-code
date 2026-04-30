import AppKit
import SwiftUI
import TouchCodeCore
@preconcurrency import UserNotifications

/// Settings → Notifications pane. Exposes the macOS notification
/// authorization status with the recovery surface specified in the spec
/// (PM2): a "Request permission" button when the OS hasn't been asked
/// yet, and an "Open System Settings" deep-link when permission has been
/// denied. The `requestAuthorization` button only re-fires the OS prompt
/// if status is currently `.notDetermined` — once the user has answered,
/// macOS no longer surfaces the prompt, and the only path back is via
/// System Settings.
///
/// Authorization is re-read on every appear and on `applicationDidBecomeActive`
/// so a flip in System Settings takes effect without a relaunch.
struct NotificationsSettingsView: View {
  @Environment(UserNotificationsOSNotifier.self) private var osNotifier: UserNotificationsOSNotifier?
  @State private var status: AuthorizationStatus = .notDetermined
  @State private var isRefreshing = false

  var body: some View {
    Form {
      Section("macOS notifications") {
        statusRow
        actionRow
      }

      Section("About v1") {
        Text(
          "touch-code emits a banner when a pane finishes a long task or asks for input — "
          + "OSC 9 desktop notifications, terminal bell, OSC 133 command-finished, pane "
          + "exit/crash, and post-busy idle. Banners only fire when you're not already "
          + "looking at the pane; the in-app inbox and Dock badge work regardless of "
          + "permission."
        )
        .font(.callout)
        .foregroundStyle(.secondary)
      }
    }
    .formStyle(.grouped)
    .task { await refresh() }
    .onReceive(
      NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)
    ) { _ in
      Task { await refresh() }
    }
  }

  // MARK: - Subviews

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
