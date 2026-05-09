# Claude Code — Tier-B Smoke Test

End-to-end sanity check that a fresh Claude Code session, running inside a touch-code
Pane with the skill installed, produces `tc`-shaped answers to a `tc`-shaped prompt.

Run via `apps/mac/scripts/skill-tier-b-claude.sh` (or the `make mac-skill-tier-b`
target which orchestrates all three agents).

## Prerequisites

- touch-code.app built and the `tc` binary reachable.
- `claude` CLI installed on `$PATH` (Claude Code non-interactive mode).
- Skill installed: `tc skill install --claude-code --force`.

## Prompt

```
Using the touch-code skill, what is the exact tc command to check which agents have
the touch-code skill installed? Respond with only the command on the last line.
```

## Pass criteria

1. Claude's response includes the literal token `tc skill status` (code-spanned or
   otherwise).

The prompt deliberately targets the **currently-shipped** `tc skill` surface so this
test can gate the v0.1.0 release. Once `tc tree` / `tc pane` / `tc worktree` ship via
exec plans 0002-0003, extend this file with additional prompts that exercise those
surfaces.

## Degraded modes

- `claude` not on `$PATH` → emit a warning to `$GITHUB_STEP_SUMMARY` and exit 0. The
  release proceeds without a Claude Code gate; criterion 1 can't be checked.
- Claude produces an answer that doesn't contain `tc skill status` → FAIL. The skill
  is wrong or stale; fix and re-run.
