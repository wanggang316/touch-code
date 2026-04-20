# Claude Code

## Installation

```bash
tc skill install --claude-code
```

Writes into `~/.claude/skills/touch-code/`. Claude Code auto-discovers every directory
under `~/.claude/skills/`; no restart required. `tc skill install` is idempotent and
safe to re-run after a touch-code upgrade.

Uninstall:

```bash
tc skill uninstall --claude-code
```

## Verify

Open Claude Code inside a touch-code Panel. The skill appears in `/skills` and any
`tc`-shaped question routes through it. Sanity-check:

```
> how do I split this panel?
```

Claude should answer with `tc panel split …` rather than shell scripting from memory.

## Hook installation _(planned; exec plan 0003)_

```bash
tc agent install-hook claude
```

Writes hook entries into `~/.claude/settings.json` so `SessionEnd`, `Notification`,
`Stop`, and `PreToolUse` events reach touch-code's notification inbox. Reversible via
`tc agent remove-hook claude`.

## Troubleshooting

| Symptom | Cause | Fix |
|---|---|---|
| Skill missing from `/skills` | install didn't complete or Claude was started before the install | re-run `tc skill install --claude-code`; restart Claude if needed |
| Stale answers | installed version lags the bundle | `tc skill status`; if "Installed" < "Bundled", `tc skill install --claude-code` |
| "install refused — local edits" | user edited the copy since install | `tc skill install --claude-code --force` (discards edits) |
| `tc skill status` shows `-` for claude-code | wrong default path or HOME override | confirm `~/.claude/skills/` exists; re-run install with `--dest` if Claude uses a non-default path |

## What Claude Code sees

The install materialises these files under `~/.claude/skills/touch-code/`:

- `SKILL.md` — the top-level prompt Claude Code reads on skill discovery.
- `references/*.md` — deep-dive primers Claude consults when the user asks a specific
  question.
- `.touch-code-skill.json` — install marker (private; Claude ignores it).

See [examples.md](examples.md) for scripted prompts.
