import AppKit
import SwiftUI

/// Observable that surfaces whether the `.command` modifier is currently held. Used by the
/// sidebar / tab bar / status bar to toggle hotkey hints (`⌃N`, `⌘N`, etc.) so users
/// discover the bindings without cluttering chrome in the default state.
///
/// Installs an `NSEvent` local monitor for `.flagsChanged` at init. The monitor fires on
/// the main thread, so `isCommandHeld` is mutated on the same thread SwiftUI reads from.
///
/// **Active-state coupling.** When a chord like ⌘O fires a menu action that opens an
/// external editor, the OS hands focus to that editor. Any `flagsChanged` event that fires
/// for the ⌘ release while another app is frontmost is delivered to *that* app, not ours,
/// so the local monitor never sees it and `isCommandHeld` would stay stuck at `true` even
/// after the user has long since let the modifier go. We additionally listen for
/// `NSApplication.didResignActive` and clear the flag whenever touch-code goes to the
/// background — `flagsChanged` resumes delivering once the user re-presses ⌘ inside our
/// window, restoring the hint live.
///
/// The monitor + observer tokens live in a private `@unchecked Sendable` box so the
/// observer's nonisolated `deinit` can tear them down without tripping Swift 6 strict
/// concurrency.
@Observable
final class CommandKeyObserver {
  /// `true` whenever the `.command` flag is reported by the most recent flagsChanged event.
  private(set) var isCommandHeld: Bool = false

  @ObservationIgnored
  private let storage = MonitorStorage()

  init() {
    storage.monitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
      self?.isCommandHeld = event.modifierFlags.contains(.command)
      return event
    }
    storage.resignToken = NotificationCenter.default.addObserver(
      forName: NSApplication.didResignActiveNotification,
      object: nil,
      queue: .main
    ) { [weak self] _ in
      // App lost focus: a chord that fires an external app (⌘O → editor, ⌘⇧G → browser)
      // releases its modifier in *that* app, so `flagsChanged` never reaches us. Clear
      // the held flag now so the hint chrome doesn't get stuck on.
      self?.isCommandHeld = false
    }
  }

  deinit {
    storage.teardown()
  }
}

/// Untyped holder for the `NSEvent` monitor + observer tokens. `@unchecked Sendable` is
/// safe here: the tokens are written exactly once (by `CommandKeyObserver.init`) and read
/// at teardown, so there is no concurrent access. Wrapping the `Any?` slots inside a
/// dedicated class also keeps the non-Sendable properties out of the observer's own
/// storage, which the Swift 6 deinit checker requires.
nonisolated private final class MonitorStorage: @unchecked Sendable {
  var monitor: Any?
  var resignToken: NSObjectProtocol?

  init() {}

  func teardown() {
    if let monitor = monitor {
      NSEvent.removeMonitor(monitor)
      self.monitor = nil
    }
    if let resignToken {
      NotificationCenter.default.removeObserver(resignToken)
      self.resignToken = nil
    }
  }
}
