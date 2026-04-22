# Recipes

Copy-pasteable workflows. Commands that aren't yet implemented are flagged _(planned)_.

## Start a dev server in a new Tab _(planned; exec plan 0002)_

```bash
tc tab new --focus -- npm run dev
```

`--focus` switches to the new Tab immediately. The server inherits the Worktree's cwd.

## Run an agent in a side panel _(planned; exec plan 0002)_

```bash
tc panel split right -- claude
```

Opens `claude` in a panel to the right of the current one. Use `tc agent install-hook
claude` _(planned; exec plan 0003)_ beforehand so its completion events surface as
notifications.

## Broadcast a command to every Panel in a Tab _(planned; exec plan 0003)_

```bash
tc broadcast --tab 1/2/1/3 'pwd'
```

Each Panel in Tab `1/2/1/3` receives `pwd\n` exactly as if you typed it. Use `--raw`
to suppress the newline.

## Create a worktree for a branch and open it in Cursor _(planned; exec plans 0002 + 0003)_

```bash
tc worktree new --focus exp/experiment
tc open --in cursor
```

Sequence: create the worktree, focus it (so `tc open` without `--worktree` targets the
new one), launch Cursor.

## Notify when a long command finishes _(planned; exec plan 0003)_

```bash
./deploy.sh && tc panel notify --body "deploy complete"
```

Invert the boolean to fire on failure:

```bash
./deploy.sh || tc panel notify --body "deploy failed"
```

## List idle worktrees as JSON and pick one by name _(planned; exec plans 0002 + 0003)_

```bash
tc worktree ls --json | jq -r '.[] | select(.name=="exp/experiment") | .id'
```

Feed the UUID back into any `--worktree` or `--in` flag.

## Install this skill into a fresh Claude Code session (shipped)

From inside a touch-code Panel:

```bash
tc skill status                        # confirm nothing installed
tc skill install --claude-code         # copies into ~/.claude/skills/touch-code/
tc skill status                        # verify version
```

`tc skill install` is idempotent — reruns are no-ops until `touch-code-skill/VERSION`
bumps. Pass `--force` if you've edited the installed copy and want the bundle contents
to overwrite your local edits.

## Capture Panel scrollback to a file _(planned; exec plan 0002)_

```bash
tc panel capture --scope scrollback --lines 500 > /tmp/scrollback.txt
```

Useful when an agent hits a problem you want to paste back into its context window.
