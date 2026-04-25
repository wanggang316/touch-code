import ComposableArchitecture
import Foundation
import TouchCodeCore

/// Transient sheet feature that surfaces lifecycle-script output
/// (setup / archive / delete) on the main window. Auto-dismisses 5s
/// after a successful exit; stays open on failure until the user taps
/// Dismiss. Cancel is a hook for the SIGTERM path — not implemented in
/// Phase 2 (Risk R2 mitigation deferred).
@Reducer
struct LifecycleScriptToastFeature {
  @ObservableState
  struct State: Equatable, Identifiable {
    /// Stable id so the parent's `.sheet(item:)` binding identifies the
    /// presentation. The toast is a single-instance modal so any UUID works.
    let id: UUID
    var phase: SettingsWriter.WorktreeLifecycle
    var worktreeName: String
    var output: String
    var exitState: ExitState

    init(
      id: UUID = UUID(),
      phase: SettingsWriter.WorktreeLifecycle,
      worktreeName: String,
      output: String = "",
      exitState: ExitState = .running
    ) {
      self.id = id
      self.phase = phase
      self.worktreeName = worktreeName
      self.output = output
      self.exitState = exitState
    }

    enum ExitState: Equatable {
      case running
      case succeeded
      case failed(exitCode: Int32)
    }
  }

  enum Action: Equatable {
    /// Streams a partial chunk of stdout into the buffer. Phase 2 uses
    /// the buffered Process.run path so this is invoked once with the
    /// full string; the streaming hook is here for the future incremental
    /// implementation.
    case appendOutput(String)
    /// Final outcome — flips `exitState` and starts the auto-dismiss
    /// timer on success.
    case finished(LifecycleScriptResult)
    /// User-initiated dismiss (only enabled on failure).
    case dismissTapped
    /// Stretch goal: SIGTERM the running process. No-op in Phase 2.
    case cancelTapped
    /// Internal — fired 5s after `.finished(.success)` to close the sheet.
    case autoDismissAfterDelay
    /// Parent-driven dismiss request. Equivalent to `.dismissTapped` but
    /// distinguished so the autoDismiss schedule can target it.
    case dismiss
  }

  @Dependency(\.continuousClock) private var clock

  nonisolated enum CancelID: Hashable, Sendable { case autoDismiss }

  var body: some Reducer<State, Action> {
    Reduce { state, action in
      switch action {
      case .appendOutput(let chunk):
        state.output.append(chunk)
        return .none

      case .finished(let result):
        switch result {
        case .skipped:
          // No script ran — close the toast immediately.
          return .send(.dismiss)
        case .success(let stdout):
          state.output = stdout
          state.exitState = .succeeded
          return .run { send in
            try await clock.sleep(for: .seconds(5))
            await send(.autoDismissAfterDelay)
          }
          .cancellable(id: CancelID.autoDismiss, cancelInFlight: true)
        case .failure(let code, let stdout):
          state.output = stdout
          state.exitState = .failed(exitCode: code)
          return .none
        }

      case .autoDismissAfterDelay:
        return .send(.dismiss)

      case .dismissTapped, .dismiss:
        return .cancel(id: CancelID.autoDismiss)

      case .cancelTapped:
        // SIGTERM dispatch is a stretch goal (Risk R2). Closing the toast
        // does not actually stop the spawned process today.
        return .send(.dismiss)
      }
    }
  }
}
