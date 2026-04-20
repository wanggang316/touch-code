# Codex CLI

## Installation

```bash
tc skill install --codex
```

Writes into `~/.codex/skills/touch-code/`. Codex picks it up at next launch (or
reload); no explicit registration step.

Uninstall:

```bash
tc skill uninstall --codex
```

## Verify

Inside a touch-code Panel, run Codex in non-interactive mode with a `tc`-shaped
question. The skill's `SKILL.md` should steer Codex toward the `tc` CLI rather than
shell workarounds.

## Hook installation _(planned; exec plan 0003)_

```bash
tc agent install-hook codex
```

Writes touch-code hook entries into `~/.codex/hooks.json`. Reversible via
`tc agent remove-hook codex`. The installation is idempotent — running twice is a
no-op.

## Differences vs. Claude Code

| Aspect | Claude Code | Codex CLI |
|---|---|---|
| Install path | `~/.claude/skills/touch-code/` | `~/.codex/skills/touch-code/` |
| Hook config | `~/.claude/settings.json` | `~/.codex/hooks.json` |
| Invocation | `claude` | `codex` |

Command content and references are identical; the skill directory is the same shape
across agents.

## Troubleshooting

| Symptom | Fix |
|---|---|
| Codex doesn't see the skill | confirm `~/.codex/skills/` exists; reinstall |
| Stale answers | `tc skill status`; upgrade via `tc skill install --codex` |
| Local edits preserved | use `tc skill install --codex --force` to discard |

See [examples.md](examples.md) for scripted prompts.
