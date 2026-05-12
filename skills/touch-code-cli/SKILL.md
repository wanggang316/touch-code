---
name: touch-code
description: Drive the touch-code Mac app from a terminal with the `tc` CLI — inspect the Project / Worktree / Tab / Pane hierarchy, create and switch worktrees, spawn tabs and panes, send keystrokes or text to a pane, read back its rendered output, broadcast input across panes, and check app health. Use this skill whenever the user is operating inside a touch-code Pane, references the `tc` command, asks how to script touch-code, or wants to coordinate panes / worktrees / agents from the shell. Prefer `tc tree` to discover state before issuing any other command.
---

# touch-code CLI (`tc`)

## What is touch-code?

**touch-code** is a macOS desktop app built for the next generation of
agent-based parallel development. At its core it is a parallel-development
tool on top of **git worktree + terminals**, organised as
**Project → Worktree → Tab → Pane**. Terminals are rendered natively via
**libghostty**.

`tc` is the command-line client that drives the app over a local Unix
domain socket — the same things the GUI does, scriptable from any shell.
The binary is installed as `tc` (with an alias `tcode`).

## Before you run anything: check it's installed

Before suggesting any `tc` command, verify the app is installed and
reachable:

```bash
tc doctor
```

Three outcomes:

- **Prints `socketReachable   true`** — app is installed and running.
  Proceed.
- **Prints `socketReachable   false`** — app is installed but not running.
  Run `tc launch` (or open TouchCode from `/Applications`) and retry.
- **`tc: command not found`** — TouchCode is not installed. Stop and tell
  the user to install it from the releases page:

  > TouchCode is not installed. Download the latest `.dmg` from
  > <https://github.com/wanggang316/touch-code/releases/>, drag
  > **TouchCode.app** into `/Applications`, launch it once so `tc` lands
  > on `PATH`, then retry.

  Do not invent fallback commands or try to install it via Homebrew / npm
  / pip — there is no such package today; the GitHub releases page is the
  only distribution channel.

## When to use

- The user is inside a touch-code Pane and wants to script some action.
- The user mentions "tc ..." or asks how to do something in touch-code from
  the terminal.
- An agent (Claude Code, Codex, custom) wants to read a sibling pane's
  output, send input to it, or spawn new panes / tabs / worktrees.
- The user wants to inspect the touch-code app's state without opening the
  GUI.

## Hierarchy in 60 seconds

```
Project       a tracked git repo (one Project per repo)
 └── Worktree a git worktree of that repo (own dir + branch + tab layout)
      └── Tab one named grouping of panes in a worktree (one Tab visible)
           └── Pane a single libghostty terminal session
```

`tc` is on `PATH` automatically inside every touch-code Pane, and the app
auto-detects which Project / Worktree / Tab / Pane that Pane belongs to —
so most commands default to the surrounding context and you rarely need
to pass IDs.

## Targeting model

Most subcommands accept identifiers in any of these forms:

- **`current` or `.`** — the ambient Project / Worktree / Tab / Pane of
  the shell you're running `tc` from. This is the default for nearly every
  `--project`, `--worktree`, `--tab`, and `--pane` flag, so you usually
  don't have to type anything.
- **Literal UUID** — passed through unchanged; fast path for scripts.
- **`@label`** (panes only) — server-side lookup against pane labels
  applied with `tc pane label`.
- **Anything else** — sent to the server's alias resolver (e.g. a project
  name or a worktree alias the app knows about).

If you run `tc` from a shell that is *not* inside a touch-code Pane,
`current` has no meaning and you'll get a `noContext` error — pass an
explicit UUID, or use `tc tree` to discover one.

## Global flags

These work on every subcommand (mounted via `@OptionGroup`):

- `--json` — machine-readable output instead of text.
- `--socket <path>` — talk to a non-default socket (rarely needed; the
  default points at the running app automatically).
- `--timeout <seconds>` — RPC client timeout (default 10s).

Use `tc <subcommand> --help` for the exact flag list of any command.

## Quick start

```bash
tc doctor                # confirm the app is reachable
tc tree                  # see every Project / Worktree / Tab / Pane
tc pane send 'pwd'       # type 'pwd\n' into the current pane
tc pane read             # read back what's on screen
```

## Command reference

### App & diagnostics

```bash
tc status                # server, uptime, connected clients
tc launch [--wait 10]    # start touch-code and block until the socket is up
tc doctor                # print socket path, reachability, client version
```

`tc launch` is idempotent — if the app is already up it just prints the
existing socket path.

### `tc tree` — discover state

```bash
tc tree                          # full hierarchy as text
tc tree --json                   # same, machine-readable
tc tree --project current        # restrict to one project
```

Always run `tc tree` first when you don't know what's around. The text
form marks the selected worktree/tab with `*` and prints pane labels as
`@label`.

### `tc project` — manage projects

```bash
tc project list                          # all projects
tc project add ~/code/api                # register an existing directory
tc project add --name "API" ~/code/api   # custom display name
tc project rm <project>                  # remove (id, name, or 'current')
```

Adding a project just registers it with touch-code; it does not move
files. Removing only de-registers — no files are deleted.

### `tc worktree` — manage git worktrees

```bash
tc worktree list                                   # for current project
tc worktree list --project <project>
tc worktree new <branch>                           # path defaults to ./<branch>
tc worktree new --path /abs/path --name "Hotfix" <branch>
tc worktree switch <worktree>                      # activate it in the GUI
tc worktree rm <worktree>                          # de-register
```

`<branch>` is required for `new`. `--path` accepts a relative path
(resolved against `$PWD`) or an absolute one. `--name` overrides the
display label (defaults to the branch).

### `tc tab` — manage tabs inside a worktree

```bash
tc tab list                              # tabs in current worktree
tc tab new                               # untitled tab
tc tab new "dev server"                  # named tab
tc tab switch <tab>                      # activate
tc tab close <tab>                       # close
```

`tc tab new` creates the tab but does not spawn a pane inside it — use
`tc pane new` for that, or rely on the GUI's auto-pane behavior.

### `tc pane` — manage and drive panes

Creation / lifecycle:

```bash
tc pane list                                     # panes in current tab
tc pane new                                      # default shell
tc pane new --label agent --label claude -- claude   # initial command + labels
tc pane new --cwd /tmp -- htop                   # explicit cwd
tc pane focus <pane>                             # bring to front
tc pane close <pane>
tc pane reset <pane>                             # clear scrollback + reinit terminal
tc pane label <pane> agent debug                 # add labels
tc pane label <pane> agent --replace             # replace existing label set
```

Terminal I/O (also accessible as `tc pane send`, `tc pane send-key`,
`tc pane read`, `tc pane capture`):

```bash
# Send text (Enter appended by default — use --no-enter to suppress)
tc pane send 'echo hi'
tc pane send <pane> 'echo hi'         # explicit target
tc pane send -p @agent 'status'        # target by label
tc pane send --stdin <<<'long blob'    # read text from stdin
tc pane send --no-enter 'partial '     # type without submitting
tc pane send --focus <pane> 'cmd'      # focus the pane after sending

# Send a named key (no text channel)
tc pane send-key escape
tc pane send-key <pane> ctrl_c
# Supported: escape, up, down, left, right, tab, enter, backspace,
# delete, home, end, pgup, pgdn, f1..f12, ctrl_c, ctrl_d, ctrl_l, ctrl_z

# Send raw bytes (e.g. CSI sequences) — exclusive of text/--stdin/--no-enter
tc pane send --raw 1b5b41        # ESC [ A (cursor up)

# Read what's on the pane
tc pane read                     # visible viewport (default)
tc pane read --screen            # whole active screen buffer
tc pane read --selection         # current text selection

# Capture rendered text (same data as read, plus trimming)
tc pane capture --lines 50       # keep only the last 50 non-empty lines
tc pane capture --scope screen   # capture the full screen, not just viewport
```

Notes:

- `tc pane send` appends `\n` by default. Use `--no-enter` to leave the
  shell prompt waiting for more input.
- `--raw` ships hex bytes directly (e.g. `1b` = ESC); control bytes ride a
  key-event path, printable bytes ride the text channel.
- Pane I/O is rendered-text only — touch-code does not expose the raw PTY
  byte stream, so OSC / CSI / APC sequences are not visible via `read` or
  `capture`. Track app-level state via `tc tree` instead.

### `tc broadcast` — fan out input

```bash
tc broadcast --tab current 'pwd'
tc broadcast --worktree <wt> 'git status'
tc broadcast --label agent 'reload'
tc broadcast --tab current --no-enter '#!comment'
tc broadcast --label deploy --stdin <<<'rolling restart'
```

Exactly one of `--tab`, `--worktree`, or `--label` must be given. The
returned `delivered` count tells you how many panes received the input.

## Common patterns

### Read a sibling pane (agent A inspecting agent B)

```bash
tc pane list --json | jq -r '.panes[].id'           # find the pane uuid
tc pane read <uuid>                                  # read its viewport
tc pane capture <uuid> --lines 200 > /tmp/log.txt    # snapshot trailing output
```

If both panes share a tab, label the target once (`tc pane label <uuid> agent`)
and refer to it as `@agent` thereafter.

### Drive a REPL from a script

```bash
tc pane new --label repl -- python3
tc pane send -p @repl 'import math'
tc pane send -p @repl 'print(math.pi)'
tc pane capture -p @repl --lines 3
```

### Spin up a worktree and a tab for it

```bash
tc worktree new exp/feature-x
# Switch to the new worktree (its UUID is in the create output, or use jq):
tc worktree switch "$(tc tree --json | jq -r '.projects[0].worktrees[-1].id')"
tc tab new "dev"
tc pane new -- npm run dev
```

### JSON-driven scripting

Every command supports `--json`. Pipe through `jq` to extract IDs without
parsing the human format:

```bash
PANE=$(tc pane list --json | jq -r '.panes[0].id')
tc pane send "$PANE" 'echo hello from script'
```

### Verify before you act

`tc pane send` is fire-and-forget — the RPC reports bytes shipped, not the
receiving program's reaction. When coordinating agents across panes, read
back after sending:

```bash
tc pane send -p @worker 'run-task'
sleep 1
tc pane read -p @worker | tail -20
```

(This mirrors the project memory note "prowl send 后 read-back 验证" — the
same idea applies to `tc`.)

## Troubleshooting

| Symptom                                             | Likely cause / fix                                                        |
|-----------------------------------------------------|---------------------------------------------------------------------------|
| `socket /tmp/touch-code-*.sock did not become reachable` | App isn't running. Run `tc launch` or open touch-code from the GUI.       |
| `noContext(kind: .pane)` (or project/worktree/tab)  | You used `current` / `.` outside a touch-code Pane. Pass an explicit ID.  |
| `pane <uuid> not found`                             | The pane was closed, or the UUID came from a different app instance.     |
| `unknown key "..."`                                 | `tc pane send-key` only knows the keys listed above. Use `--raw` for the rest. |
| `--raw is exclusive of ...`                         | `tc pane send --raw` cannot combine with positional text, `--stdin`, or `--no-enter`. |
| Help shows fewer commands than expected             | Some legacy docs reference unimplemented commands (e.g. `tc open`, `tc skill`, `tc agent`). Trust `tc --help` over external docs. |

## What this CLI does *not* do (yet)

To prevent suggesting commands that don't exist:

- No `tc send` / `tc read` / `tc send-key` / `tc capture` at top level —
  they live under `tc pane`.
- No `tc open` (external editor handoff).
- No `tc skill ...` (skill installation lives outside the CLI).
- No `tc agent ...` (agent hook installation lives outside the CLI).
- No `tc space ...` — touch-code does not expose a Space concept via `tc`
  today; the hierarchy is rooted at Project.

If a user asks for any of these, surface the gap rather than fabricating a
command.
