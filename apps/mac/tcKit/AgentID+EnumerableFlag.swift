import ArgumentParser

/// Pins the `--claude-code | --codex | --pi` CLI contract (DEC-7). Without the explicit
/// `.customLong` mapping, ArgumentParser would emit `--claudeCode` for `AgentID.claudeCode`
/// because the default derivation strips the raw value and uses the case name.
extension AgentID: EnumerableFlag {
  public static func name(for value: AgentID) -> NameSpecification {
    switch value {
    case .claudeCode: return .customLong("claude-code")
    case .codex:      return .customLong("codex")
    case .pi:         return .customLong("pi")
    }
  }

  public static func help(for value: AgentID) -> ArgumentHelp? {
    switch value {
    case .claudeCode: return "Claude Code (~/.claude/skills/touch-code/)"
    case .codex:      return "Codex CLI (~/.codex/skills/touch-code/)"
    case .pi:         return "pi (via `pi install` against the mirror repo)"
    }
  }
}
