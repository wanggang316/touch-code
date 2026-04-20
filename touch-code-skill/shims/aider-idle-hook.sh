#!/bin/sh
# aider idle-hook shim for touch-code's C6 agent notifications.
#
# aider runs as a long-lived python3 process; its "prompt is waiting" signal
# is the bare `>` line printed to the pty. That's detected by the default
# `aider.blocked_on_input` rule without any shim. This shim is only needed
# when aider runs inside a multiplexer (tmux, zellij) where the pty tail
# regex becomes unreliable — wire it as aider's `--lint-cmd` or a surrounding
# wrapper that invokes it whenever aider returns to an idle state.
#
# C6's `aider.idle_via_shim` rule matches the sentinel below and posts an
# "Aider is idle" notification (muted by default per DEC-7; users who want
# the signal flip notifications.surfaceIdle in settings.json).
printf '\n::touchcode:agent-idle %s\n' "${TOUCH_CODE_PANEL_ID:-unknown}"
