import ComposableArchitecture
import Foundation

/// Lightweight TCA dependency wrapping `EnvironmentValues.openWindow` for the Settings
/// scene. Reducers that need to bring the Settings window up (e.g. the Worktree Header's
/// "+ Custom editors…" delegate) inject this instead of plumbing an `OpenWindowAction`
/// through the ViewStore. `TouchCodeApp` overrides `liveValue` inside the main scene body
/// so the closure captures the live `@Environment(\.openWindow)` value.
nonisolated struct SettingsWindowPresenter: Sendable {
  var open: @MainActor @Sendable () -> Void
}

extension SettingsWindowPresenter: DependencyKey {
  /// `liveValue` is intentionally unusable — missing wiring is a programmer error, not a
  /// silent no-op. `TouchCodeApp.body` overrides via `.withDependencies` at scene attach.
  static let liveValue: SettingsWindowPresenter = SettingsWindowPresenter(
    open: {
      fatalError(
        "SettingsWindowPresenter.liveValue not configured; wire via `.withDependencies` with { $0.settingsWindowPresenter = ... } in TouchCodeApp"
      )
    }
  )

  static let testValue: SettingsWindowPresenter = SettingsWindowPresenter(
    open: unimplemented("SettingsWindowPresenter.open")
  )
}

extension DependencyValues {
  var settingsWindowPresenter: SettingsWindowPresenter {
    get { self[SettingsWindowPresenter.self] }
    set { self[SettingsWindowPresenter.self] = newValue }
  }
}
