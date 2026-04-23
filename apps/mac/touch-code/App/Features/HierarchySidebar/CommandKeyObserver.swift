import AppKit
import SwiftUI

/// Observable that surfaces whether the `.command` modifier is currently held. Used by the
/// sidebar to toggle per-row hotkey hints (`⌃⌘N`) so the user discovers the binding
/// without cluttering the row in the default state.
///
/// Installs a single `NSEvent` local monitor for `.flagsChanged` at init. The monitor fires
/// on the main thread, so `isCommandHeld` is mutated on the same thread SwiftUI reads from.
/// The monitor token lives in a private `@unchecked Sendable` box so the observer's nonisolated
/// `deinit` can tear it down without tripping Swift 6 strict-concurrency checks.
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
  }

  deinit {
    storage.teardown()
  }
}

/// Untyped holder for the `NSEvent` monitor token. `@unchecked Sendable` is safe here:
/// the token is written exactly once (by `CommandKeyObserver.init`) and read at teardown,
/// so there is no concurrent access. Wrapping the `Any?` inside a dedicated class also
/// keeps the non-Sendable property out of the observer's own storage, which the Swift 6
/// deinit checker requires.
nonisolated private final class MonitorStorage: @unchecked Sendable {
  var monitor: Any?

  init() {}

  func teardown() {
    if let monitor = monitor {
      NSEvent.removeMonitor(monitor)
      self.monitor = nil
    }
  }
}
