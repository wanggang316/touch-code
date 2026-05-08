import AppKit
import Sparkle
import SwiftUI

/// Settings → Updates pane. Mirrors the live `SPUUpdater` (owned by
/// `UpdatesEnvironment`) so toggles + the frequency picker write straight
/// through to Sparkle and the menu's "Check for Updates…" action stays in
/// sync. Local `@State` shadows the updater so SwiftUI gets stable
/// bindings; each `onChange` writes back the mutated value. Sparkle has no
/// general-purpose KVO contract for these properties, so we re-read on
/// `applicationDidBecomeActive` to catch external changes (e.g. another
/// app instance, defaults edits).
struct UpdatesSettingsView: View {
  private let updater: SPUUpdater = UpdatesEnvironment.updater

  @State private var automaticallyChecks: Bool
  @State private var automaticallyDownloads: Bool
  @State private var sendsSystemProfile: Bool
  @State private var checkInterval: CheckInterval
  @State private var lastCheckedAt: Date?

  init() {
    let updater = UpdatesEnvironment.updater
    _automaticallyChecks = State(initialValue: updater.automaticallyChecksForUpdates)
    _automaticallyDownloads = State(initialValue: updater.automaticallyDownloadsUpdates)
    _sendsSystemProfile = State(initialValue: updater.sendsSystemProfile)
    _checkInterval = State(initialValue: CheckInterval.closest(to: updater.updateCheckInterval))
    _lastCheckedAt = State(initialValue: updater.lastUpdateCheckDate)
  }

  var body: some View {
    Form {
      automaticSection
      privacySection
      manualSection
      feedSection
    }
    .formStyle(.grouped)
    .onReceive(
      NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)
    ) { _ in
      reloadFromUpdater()
    }
  }

  // MARK: - Sections

  @ViewBuilder
  private var automaticSection: some View {
    Section("Automatic updates") {
      Toggle("Automatically check for updates", isOn: $automaticallyChecks)
        .onChange(of: automaticallyChecks) { _, newValue in
          updater.automaticallyChecksForUpdates = newValue
        }
      Toggle("Download and install in the background", isOn: $automaticallyDownloads)
        .onChange(of: automaticallyDownloads) { _, newValue in
          updater.automaticallyDownloadsUpdates = newValue
        }
        .disabled(!automaticallyChecks)
      Picker("Check frequency", selection: $checkInterval) {
        ForEach(CheckInterval.allCases) { interval in
          Text(interval.label).tag(interval)
        }
      }
      .onChange(of: checkInterval) { _, newValue in
        updater.updateCheckInterval = newValue.seconds
      }
      .disabled(!automaticallyChecks)
    }
  }

  @ViewBuilder
  private var privacySection: some View {
    Section {
      Toggle("Send anonymous system profile", isOn: $sendsSystemProfile)
        .onChange(of: sendsSystemProfile) { _, newValue in
          updater.sendsSystemProfile = newValue
        }
    } header: {
      Text("Privacy")
    } footer: {
      Text("Helps prioritise testing on the OS and hardware combinations the user base actually runs.")
        .font(.caption)
        .foregroundStyle(.secondary)
    }
  }

  @ViewBuilder
  private var manualSection: some View {
    Section("Manual check") {
      HStack(alignment: .firstTextBaseline) {
        Button("Check for Updates…") {
          updater.checkForUpdates()
          // Sparkle updates lastUpdateCheckDate after the request completes;
          // re-read after a short delay so the label refreshes without
          // forcing the user to leave + re-enter the pane.
          Task { @MainActor in
            try? await Task.sleep(for: .seconds(2))
            lastCheckedAt = updater.lastUpdateCheckDate
          }
        }
        .disabled(!updater.canCheckForUpdates)
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
    if let feedURL = updater.feedURL {
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
  }

  // MARK: - Helpers

  private var lastCheckedLabel: String {
    guard let lastCheckedAt else { return "Never checked" }
    let formatter = RelativeDateTimeFormatter()
    formatter.unitsStyle = .full
    return "Last checked \(formatter.localizedString(for: lastCheckedAt, relativeTo: Date()))"
  }

  private func reloadFromUpdater() {
    automaticallyChecks = updater.automaticallyChecksForUpdates
    automaticallyDownloads = updater.automaticallyDownloadsUpdates
    sendsSystemProfile = updater.sendsSystemProfile
    checkInterval = CheckInterval.closest(to: updater.updateCheckInterval)
    lastCheckedAt = updater.lastUpdateCheckDate
  }
}

/// Discrete frequency choices presented to the user. Sparkle stores the
/// interval as an arbitrary `TimeInterval`, so we map both directions —
/// writes pick the canonical seconds value, reads snap to the nearest
/// option so values authored elsewhere (defaults, another release) still
/// surface a stable selection.
private enum CheckInterval: String, CaseIterable, Identifiable {
  case hourly
  case daily
  case weekly
  case monthly

  var id: String { rawValue }

  var seconds: TimeInterval {
    switch self {
    case .hourly: return 3600
    case .daily: return 86_400
    case .weekly: return 604_800
    case .monthly: return 2_592_000
    }
  }

  var label: String {
    switch self {
    case .hourly: return "Every hour"
    case .daily: return "Once a day"
    case .weekly: return "Once a week"
    case .monthly: return "Once a month"
    }
  }

  static func closest(to seconds: TimeInterval) -> CheckInterval {
    Self.allCases.min(by: {
      abs($0.seconds - seconds) < abs($1.seconds - seconds)
    }) ?? .daily
  }
}

#Preview {
  UpdatesSettingsView()
    .frame(width: 600, height: 500)
}
