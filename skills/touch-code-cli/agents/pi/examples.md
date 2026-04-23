# pi — Example Prompts

pi-specific sketches; the underlying `tc` commands are the same as the Claude Code
and Codex examples.

## 1. Install into a fresh pi cache

From inside a touch-code Pane, with pi already installed and on `$PATH`:

```bash
tc skill install --pi
pi list | grep touch-code-skill
```

## 2. Ask pi what command to use

> What command opens a new tab in touch-code?

Expected: `tc tab new`, with pi referencing `--focus` and `--in` as options per
[references/tc-cli.md](../../references/tc-cli.md).

## 3. Send a command to the current Pane via pi

> Send `clear` to the pane I'm in.

Expected: `tc pane send "$TOUCH_CODE_PANE_ID" 'clear'` — pi should use the ambient
env var rather than hardcoding a UUID.

## 4. Get the skill bundle path

> Where is the touch-code skill installed?

Expected: `tc skill bundle-path` (source), and `pi list touch-code-skill` (pi's cache
entry).

## 5. Upgrade the skill

> Refresh the touch-code skill to the latest version.

Expected: `pi update` (since pi owns the cache), or `tc skill install --pi` which
delegates back to `pi install git:…`.
