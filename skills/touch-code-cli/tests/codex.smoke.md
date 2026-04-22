# Codex CLI — Tier-B Smoke Test

End-to-end sanity check that a fresh Codex session, running inside a touch-code Panel
with the skill installed, produces `tc`-shaped answers.

Run via `apps/mac/scripts/skill-tier-b-codex.sh` (or `make mac-skill-tier-b`).

## Prerequisites

- touch-code.app built and the `tc` binary reachable.
- `codex` CLI installed on `$PATH` with non-interactive mode configured.
- Skill installed: `tc skill install --codex --force`.

## Prompt

```
Using the touch-code skill, what is the tc command to install this skill into Codex?
Respond with only the command on the last line.
```

## Pass criteria

1. Codex's response includes both `tc skill install` and `--codex`.

The prompt targets the currently-shipped surface so the v0.1.0 release can gate on a
real PASS. Once `tc tab` / `tc worktree` ship, extend with additional prompts.

## Degraded modes

- `codex` not on `$PATH` → warn + exit 0 per DEC-5.
- Non-interactive flag changed between releases → the harness emits the tried
  invocation + pointer to `codex --help`; operator updates the script.
