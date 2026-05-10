# Hierarchy Model

touch-code organises terminals as a five-level tree:

```
Space
└── Project (= a git repo)
    └── Worktree (= a `git worktree` with its own directory + branch)
        └── Tab
            └── Pane (= a libghostty terminal session)
```

One Space groups related Projects. One Project maps to a git repo. Each Worktree is a
concrete directory on disk — switching Worktrees changes `pwd`, not just `HEAD`. A Tab
is the user's concurrency unit ("dev server tab", "agent tab", "test-watcher tab"). A
Pane is a single shell; multiple Panes per Tab form split layouts.

## Discovery

`tc tree --json` prints the current tree, including UUIDs and numeric selectors. Output
shape (abridged):

```json
{
  "spaces": [
    { "id": "…", "index": 1, "name": "work",
      "projects": [
        { "id": "…", "index": 1, "name": "touch-code",
          "worktrees": [
            { "id": "…", "index": 1, "name": "main", "path": "/Users/…/touch-code",
              "tabs": [
                { "id": "…", "index": 1, "name": "dev",
                  "panes": [{"id": "…", "index": 1}, {"id": "…", "index": 2}]
                }
              ]
            }
          ]
        }
      ]
    }
  ]
}
```

## Ambient context

Every Pane inherits three environment variables that let `tc` know *where* a command
was issued from, so most invocations can omit the target argument:

- `TOUCH_CODE_PANE_ID` — UUID of the current Pane.
- `TOUCH_CODE_TAB_ID` — UUID of the enclosing Tab.
- `TOUCH_CODE_WORKTREE_ID` — UUID of the enclosing Worktree.

`TOUCH_CODE_SOCKET_PATH` is also set so the CLI reaches the running app. Debug builds use
`/tmp/touch-code-dev-$UID.sock` by default; Release builds use `/tmp/touch-code-$UID.sock`.
Do not override these manually — touch-code sets them before handing the Pane to the user's shell.

## Selector forms

Short numeric selectors address nodes from the top down. They are 1-based and match the
`index` fields in `tc tree --json`:

| Target | Form |
|---|---|
| Space | `1` |
| Project (inside Space 1) | `1/2` |
| Worktree (Space 1 / Project 2) | `1/2/1` |
| Tab (…Worktree 1) | `1/2/1/3` |
| Pane (…Tab 3) | `1/2/1/3/2` |

Every command that accepts a selector also accepts a UUID. Prefer UUIDs in scripts
(stable across rearranging) and selectors in interactive work (short, easy to type).

## Invariants worth relying on

- **A Pane always belongs to exactly one Tab.** Closing a Pane never orphans it.
- **A Tab always belongs to exactly one Worktree.** The Tab goes away if its Worktree
  is removed.
- **Every mutation that creates a new node emits its UUID + selector on stdout** when
  `--json` is passed. Chain subsequent commands off that output rather than guessing.
