import Foundation

/// Detection-rule defaults bundled with touch-code.
///
/// Ships coverage for the three known-agent rule-template set per design
/// DEC-1 (claude, codex, aider) plus an `aider.idle_via_shim` rule that
/// pairs with an `aider-idle-hook.sh` shim for multiplexer use.
///
/// The JSON literal below is **the wire shape** — it must match whatever
/// `AgentDetectionRules` emits through Swift's synthesised Codable once
/// that type lands in TouchCodeCore (blocked on C3 exec plan 0003 M1 →
/// M1b of this plan). M6b adds a Codable round-trip test wiring this
/// literal through `AgentDetectionRules.decode`; until M6b lands the
/// shape check is by-eye against `docs/design-docs/c6-agent-notifications.md`
/// §Detection Rule DSL.
///
/// Key convention is camelCase per DEC-P6 (matches the rest of the
/// project's JSON files — `catalog.json`, `notifications.json`,
/// `settings.json`).
nonisolated enum DefaultRules {
  /// The bundled rule set as a pretty-printed JSON string. Stable across
  /// app updates except through an explicit schema bump; a user's on-disk
  /// `detection-rules.json` is never overwritten by these defaults
  /// (see `installIfMissing(at:)`).
  static let json: String = #"""
    {
      "version": 1,
      "idleThresholdSeconds": 120,
      "rules": [
        {
          "id": "claude.blocked_on_input",
          "agent": "claude",
          "appliesWhen": {
            "panelLabelledAgent": "claude",
            "hookEvent": "panel.outputMatch"
          },
          "match": {
            "containsAny": ["Do you want to proceed?", "Approve tool call?"]
          },
          "transitionTo": "blockedOnInput",
          "title": "Claude is waiting for your approval",
          "body": "{data.output | firstLine | truncate: 140}"
        },
        {
          "id": "claude.completed",
          "agent": "claude",
          "appliesWhen": {
            "panelLabelledAgent": "claude",
            "hookEvent": "panel.outputMatch"
          },
          "match": {
            "regex": "::touchcode:agent-complete(?:\\s|$)",
            "on": "lastNonEmptyLine"
          },
          "transitionTo": "completed",
          "title": "Claude finished",
          "body": "Worktree {worktree.branch} · Tab {tab.name}"
        },
        {
          "id": "codex.completed",
          "agent": "codex",
          "appliesWhen": {
            "panelLabelledAgent": "codex",
            "hookEvent": "panel.outputMatch"
          },
          "match": {
            "regex": "::touchcode:agent-complete(?:\\s|$)",
            "on": "lastNonEmptyLine"
          },
          "transitionTo": "completed",
          "title": "Codex finished",
          "body": "Worktree {worktree.branch} · Tab {tab.name}"
        },
        {
          "id": "aider.blocked_on_input",
          "agent": "aider",
          "appliesWhen": {
            "panelLabelledAgent": "aider",
            "hookEvent": "panel.outputMatch"
          },
          "match": {
            "regex": "^>\\s*$",
            "on": "lastNonEmptyLine"
          },
          "transitionTo": "blockedOnInput",
          "title": "Aider is waiting",
          "body": "aider prompt ready"
        },
        {
          "id": "aider.idle_via_shim",
          "agent": "aider",
          "appliesWhen": {
            "panelLabelledAgent": "aider",
            "hookEvent": "panel.outputMatch"
          },
          "match": {
            "regex": "::touchcode:agent-idle(?:\\s|$)",
            "on": "lastNonEmptyLine"
          },
          "transitionTo": "idle",
          "title": "Aider is idle",
          "body": "{data.output | firstLine | truncate: 140}"
        }
      ]
    }
    """#

  /// Write the bundled defaults to `fileURL` iff no file exists at that path.
  /// Never overwrites a user-authored rules file; per M6 reload policy the
  /// regenerate-on-missing behaviour fires only when the user has explicitly
  /// deleted the file.
  static func installIfMissing(at fileURL: URL) throws {
    if FileManager.default.fileExists(atPath: fileURL.path) { return }
    let directory = fileURL.deletingLastPathComponent()
    if !FileManager.default.fileExists(atPath: directory.path) {
      try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }
    try Data(json.utf8).write(to: fileURL, options: .atomic)
  }
}
