#!/bin/sh
# Claude Code Stop-hook shim for touch-code's C6 agent notifications.
#
# Install path (Claude Code):
#   Add to ~/.claude/settings.json:
#     { "hooks": { "Stop": [{ "type": "command", "command": "~/.config/touch-code/shims/claude-stop-hook.sh" }] } }
#
# The app's C3 panel.outputMatch subscription (installed by C6's RuleStore)
# matches the sentinel line below and routes it to the notification
# coordinator, which posts an "Claude finished" banner for the originating
# Panel. See docs/design-docs/c6-agent-notifications.md §Bridging Agent-Internal
# Signals + DEC-14.
printf '\n::touchcode:agent-complete %s\n' "${TOUCH_CODE_PANEL_ID:-unknown}"
