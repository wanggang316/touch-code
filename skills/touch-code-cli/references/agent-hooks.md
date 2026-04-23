# Agent Hooks

touch-code installs event-bridge hooks into each coding agent so Pane-level events
(assistant finished responding, waiting for input, tool call denied, etc.) surface as
OS notifications and the in-app notification inbox.

All commands in this reference are _planned (exec plan 0003)_ unless noted.

## Install

```bash
tc agent install-hook claude
tc agent install-hook codex
tc agent install-hook pi
```

Effects:

- `claude` writes a `settings.json` fragment into `~/.claude/settings.json` with hook
  entries for `Notification`, `SessionStart`, `SessionEnd`, `Stop`, `PreToolUse`. Each
  fragment invokes `tc agent receive-agent-hook --agent claude` with the event payload
  on stdin.
- `codex` appends to `~/.codex/hooks.json`; same receiver contract.
- `pi` writes the equivalent configuration into pi's user config.

The install is idempotent — running it twice is a no-op. `install-hook` refuses to
overwrite a differing touch-code fragment without `--force`.

## Remove

```bash
tc agent remove-hook <agent>
```

Removes only the touch-code-managed entries; unrelated hooks the user installed are
left in place.

## Forward an event (low-level)

```bash
printf '{"hook_event_name":"Notification","message":"Claude needs your attention"}' \
  | tc agent receive-agent-hook --agent claude
```

Useful when wiring an external notification source that isn't a first-class agent
touch-code knows about. In normal operation the install-hook machinery sets this up
automatically.

## What happens inside touch-code

A received hook event is matched against the Pane that emitted it (the agent CLI sets
`TOUCH_CODE_PANE_ID` when spawned inside touch-code). Events then:

1. Trigger any user-configured hook subscriptions (per-Pane or global) — see the app's
   settings.
2. Surface as an OS notification (if the event type is `notification`-classed).
3. Get recorded in the in-app inbox with per-Pane provenance.

## Debugging

```bash
tc agent install-hook --dry-run claude   # prints the patch without writing
tc agent remove-hook --dry-run claude
```

Both subcommands are reversible and idempotent; they will not edit user sections of the
agent config file.
