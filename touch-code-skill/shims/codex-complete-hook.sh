#!/bin/sh
# Codex CLI completion-hook shim for touch-code's C6 agent notifications.
#
# Install path (Codex CLI):
#   Add to ~/.codex/settings.json (or Codex's equivalent hook config):
#     { "hooks": { "on_complete": "~/.config/touch-code/shims/codex-complete-hook.sh" } }
#
# C6's Codex rule bundle matches this sentinel and routes it to the
# NotificationCoordinator for a "Codex finished" banner on the originating
# Panel. See c6 DEC-14 for the pty-sentinel bridge rationale.
printf '\n::touchcode:agent-complete %s\n' "${TOUCH_CODE_PANEL_ID:-unknown}"
