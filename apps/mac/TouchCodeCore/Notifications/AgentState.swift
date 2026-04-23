import Foundation

/// The four states an agent-hosted Pane can be in.
///
/// See `docs/design-docs/c6-agent-notifications.md` §API Design for the full
/// transition table. The FSM itself lives in `apps/mac/touch-code/Notifications/`
/// and is built in M2 of exec plan 0006; this enum is the persisted vocabulary
/// every layer — transition records, notifications, CLI, settings — agrees on.
public enum AgentState: String, Codable, Sendable, CaseIterable {
  case running
  case completed
  case blockedOnInput
  case idle
}
