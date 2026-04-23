# Worktrees and External Editors

Worktrees are first-class in touch-code: each is a concrete git-worktree directory with
its own branch, Tabs, and Panes. The app orchestrates them; `tc` talks to the app.

All commands in this reference are _planned (exec plan 0002 for worktree lifecycle,
exec plan 0003 for `tc open`)_ unless noted.

## Create

```bash
tc worktree new exp/feature-x
tc worktree new --in <project> --focus exp/feature-x
tc worktree new --cwd /custom/path exp/feature-x
```

Default layout: the new worktree lives at `<repo>-worktrees/<branch>/` — a sibling of
the repo root. Per-Project overrides live in the app's settings. Under the hood the app
runs `git worktree add -b <branch> <path>`; if the branch already exists, pass an
existing name and omit `-b`.

## List

```bash
tc worktree ls
tc worktree ls --json        # includes path, branch, selector, UUID
```

## Focus / switch

```bash
tc worktree focus            # ambient (no-op unless used outside a Worktree Pane)
tc worktree focus 1/2/3
tc worktree focus <worktree-uuid>
```

Focusing a Worktree also focuses its selected Tab and Pane. Use this to jump between
worktrees in a script.

## Remove

```bash
tc worktree remove <worktree>                   # runs `git worktree remove <path>`
tc worktree remove <worktree> --keep-directory  # removes from hierarchy only
```

`--keep-directory` leaves the on-disk worktree in place (useful when a build is running
and you just want to unclutter the sidebar).

## `tc open` — external editor handoff

`tc open` hands the Worktree directory to an external editor. touch-code is deliberately
not an IDE; code reading and editing happen elsewhere.

```bash
tc open                              # default editor on the current Worktree
tc open --in cursor                  # explicit editor ID
tc open --in code --worktree <id>    # explicit worktree target
tc open --in finder                  # reveal in Finder
```

Built-in editor IDs (v1):

| ID | Invocation |
|---|---|
| `code` | `code <dir>` (VS Code) |
| `cursor` | `cursor <dir>` |
| `zed` | `zed <dir>` |
| `xcode` | `open -a Xcode <dir>` |
| `subl` | `subl <dir>` (Sublime Text) |
| `finder` | `open <dir>` |

Set a global default and per-Project override in the app's settings, or use `--in`
every time. User-defined editor templates are supported in `settings.json` for anything
outside the built-in list.

## Non-git Projects

If a Project points at a non-git directory, `tc worktree *` commands return an error
and the UI's "Add Worktree" control is disabled. The Project still has exactly one
synthetic Worktree at its root path, so `tc open`, `tc ls`, etc. continue to work.
