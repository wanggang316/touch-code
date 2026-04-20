# Codex CLI — Example Prompts

Same shape as the Claude Code examples, adapted to Codex's conventions. Commands are
shipped (`tc skill …`) or planned per [references/tc-cli.md](../../references/tc-cli.md).

## 1. List panels and report the count

> How many panels am I running across all tabs?

Expected:

```bash
tc ls --json | jq '[.spaces[].projects[].worktrees[].tabs[].panels[]] | length'
```

## 2. Start a new tab with the test watcher

> Run `npm test -- --watch` in a new tab and focus it.

Expected: `tc tab new --focus -- npm test -- --watch`.

## 3. Send a command to a specific panel

> Send `git status` to panel 1/2/1/3/2.

Expected: `tc panel send 1/2/1/3/2 'git status'`. Codex should note the default newline.

## 4. Remove a worktree, keeping the directory

> Remove worktree `exp/abandoned` but keep the directory on disk.

Expected: `tc worktree remove exp/abandoned --keep-directory`.

## 5. Reinstall the skill after upgrading touch-code

> I just updated touch-code; refresh the skill.

Expected: `tc skill install --codex` (Codex noting it's idempotent + `--force` only
matters if local edits exist).
