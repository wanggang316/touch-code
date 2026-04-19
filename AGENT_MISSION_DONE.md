# Mission complete — C6 agent notification design

**Branch:** `worktree-design+c6-agent-notifications`
**Deliverable:** `docs/design-docs/c6-agent-notifications.md` (485 lines)

## Outcome

- Drafted the C6 design doc following `_template.md`.
- Resolved product-spec Open Question #5 (DEC-1): user-configured hook rules + known-binary allowlist (`claude`, `codex`, `aider`) default; no magic detection; explicit `tc label --agent` override.
- Defined the four-state FSM (`running / completed / blockedOnInput / idle`) with trigger taxonomy (rule match, structured agent hook, idle timer, user override).
- Specified three surfaces: `UNUserNotificationCenter` OS banners, `NSApp.dockTile.badgeLabel` Dock badge, in-app inbox sidebar (320pt, filter chips, swipe-dismiss).
- Defined the detection-rule DSL (JSON grammar in `hooks.json#agent_detection`) with `applies_when` predicates, `match.contains_any | regex`, and `{…}` template placeholders including `| truncate: N`.
- Defined new `TouchCodeCore` types (`AgentState`, `AgentStateTransition`, `Notification`, `NotificationInbox`) and new in-app module `touch-code/Notifications/`.
- New persistence file `~/.config/touch-code/notifications.json` (schema v1, 500-row cap, 7-day soft-delete sweep).
- Permission handling: first-run prompt deferred to first agent-Panel creation; inbox + Dock badge act as fallback when denied (DEC-5).
- Captured 10 locked decisions (DEC-1 through DEC-10) and 9 risks with concrete mitigations.
- C3 doc in sibling worktree was still a placeholder; doc binds against the event-stream shape committed in the approved C1+C2 design and notes the minimum `AgentHookEvent` payload C6 requires (R9).
- Committed and pushed to `origin/worktree-design+c6-agent-notifications`.
