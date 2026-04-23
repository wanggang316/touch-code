# Claude Code — Example Prompts

These prompts are designed to exercise the skill. Commands Claude returns reference
shipped (`tc skill …`) and planned (`tc pane …`, `tc worktree …`) surfaces as
documented in [references/tc-cli.md](../../references/tc-cli.md).

## 1. Split the current pane and run a command

> Open htop in a new pane to the right.

Expected: a `tc pane split right -- htop` invocation. Claude should explain
`--in <pane>` is not needed because ambient targeting picks up the current Pane.

## 2. Create a worktree for a feature branch and open it

> Make a worktree for branch `exp/ux-polish` and open it in Cursor.

Expected:

```bash
tc worktree new --focus exp/ux-polish
tc open --in cursor
```

Or, equivalently, `tc open --in cursor --worktree <uuid>` using the UUID emitted by
`tc worktree new --json`.

## 3. Broadcast a command across a Tab

> Send `pwd` to every pane in my current Tab.

Expected: `tc broadcast --tab "$TOUCH_CODE_TAB_ID" 'pwd'` — Claude should use the
ambient env var rather than hardcoding a selector.

## 4. Wire up notifications

> I want to get a notification when my agent finishes running.

Expected: a one-liner referring to `tc agent install-hook claude` plus a pointer to
the Notification-event mechanism in
[references/agent-hooks.md](../../references/agent-hooks.md).

## 5. Upgrade the skill after a touch-code update

> Can you check if my touch-code skill is up to date?

Expected:

```bash
tc skill status
```

…then, if "Installed" lags "Bundled":

```bash
tc skill install --claude-code
```

Claude should note that `--force` is only needed if the previous install has local
edits.
