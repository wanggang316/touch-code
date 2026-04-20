# `tc` CLI Reference

`tc` is the command-line interface injected into every touch-code Panel. Entries flagged
"planned" document the final surface; their implementations land via the exec plans
listed in each section.

Every mutating command supports:

- `--json` — emit structured output (creation IDs, status rows, install marker, …).
- `--quiet` — suppress human-readable output; exit status only.
- `--help` — ArgumentParser's built-in usage screen.

## Listing

```bash
tc ls               # human-readable tree
tc ls --json        # full structured tree (see references/hierarchy-model.md)
tc ls --plain       # flat path list, one node per line
```

## `tc space` — Space commands _(planned; exec plan 0002)_

```bash
tc space new <name>
tc space new --focus <name>
tc space focus [space]
tc space rename <name> [space]
tc space close [space]
tc space next / prev / last
```

## `tc worktree` — Worktree commands _(planned; exec plan 0002)_

```bash
tc worktree new <branch>                   # default layout: <repo>-worktrees/<branch>/
tc worktree new --in 1/2 <branch> --focus
tc worktree ls --json
tc worktree focus [worktree]
tc worktree remove <worktree> [--keep-directory]
```

Worktrees default to `<repo>-worktrees/<branch>/` as a sibling of the repo root. Per-
Project overrides live in the app's settings.

## `tc tab` — Tab commands _(planned; exec plan 0002)_

```bash
tc tab new [--in <worktree>] [--focus] [--cwd <path>] -- <command> [args...]
tc tab new [--in <worktree>] [--focus] --script '<shell-script>'
tc tab focus <tab>
tc tab rename <name> [tab]
tc tab close [tab]
tc tab next / prev / last [space]
```

Trailing args after `--` are treated as a command and its arguments. `--script` sends
raw shell text exactly as provided.

## `tc panel` — Panel commands _(planned; exec plan 0002)_

```bash
tc panel new                               # new panel in current tab
tc panel split <direction>                 # direction: left|right|up|down
tc panel split --in <tab-or-pane> down -- tail -f /tmp/server.log
tc panel split --layout keep right         # preserve existing sizing
tc panel focus [pane]
tc panel close [pane]
tc panel resize <direction> <cells> [pane]
tc panel layout <equalize|tile|main-vertical> [tab]
tc panel capture [--scope visible|scrollback] [--lines N]
tc panel notify [pane] --body "…"
```

## `tc send` / `tc broadcast` — cross-panel messaging _(planned; exec plan 0003)_

```bash
tc panel send <pane> 'echo hello'          # defaults to text + newline
tc panel send --raw <pane> $'\x03'         # raw bytes, no newline
tc send <pane> 'pwd'                       # sugar for tc panel send
tc broadcast --tab <tab> 'echo hello'
tc broadcast --worktree <worktree> 'pwd'
```

## `tc open` — external editor handoff _(planned; exec plan 0003)_

```bash
tc open                            # opens the current Worktree in the default editor
tc open --in cursor                # explicit editor ID
tc open --in code --worktree <worktree>
```

Built-in editor IDs include `code`, `cursor`, `zed`, `xcode`, `subl`, `finder`. The
default editor is configurable globally and per-Project.

## `tc agent` — agent hook bridge _(planned; exec plan 0003)_

```bash
tc agent install-hook claude               # writes hooks into ~/.claude/settings.json
tc agent install-hook codex                # writes hooks into ~/.codex/hooks.json
tc agent remove-hook <agent>
tc agent receive-agent-hook --agent <agent>    # stdin forwarder (low-level)
```

`install-hook` is idempotent and reversible. See
[references/agent-hooks.md](agent-hooks.md) for details.

## `tc skill` — this skill (shipped — M4)

```bash
tc skill install --claude-code | --codex | --pi  [--dest <path>] [--link] [--force] [--dry-run] [--json]
tc skill uninstall --claude-code | --codex | --pi
tc skill status  [--json]
tc skill bundle-path
```

- `--claude-code` / `--codex` / `--pi` is required and mutually exclusive.
- `--dest` overrides the default install path (copy agents only); `--link` symlinks
  instead of copies (contributors only; app upgrade may break the link).
- `--force` bypasses the overwrite prompt when local edits are detected.
- `--pi` shells out to `pi install git:<mirrorURL>`; exit code 2 if `pi` isn't on
  `$PATH`.
- `tc skill bundle-path` prints the absolute path to the bundled `touch-code-skill/`
  directory inside `touch-code.app`.

## `tc help-json` — subcommand introspection (shipped)

```bash
tc help-json
```

Prints the full subcommand tree as JSON. Used by `apps/mac/scripts/skill-help-roundtrip.py`
in CI to assert that every `tc <subcmd>` backtick-wrapped in this reference directory
resolves to a real binary subcommand (or a planned-subtree prefix).
