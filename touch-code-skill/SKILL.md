---
name: touch-code
description: Control touch-code spaces, projects, worktrees, tabs, and panels with `tc`.
---

Use this skill when you need to control touch-code from a terminal that is already
running inside a touch-code Panel. The `tc` CLI is injected into every Panel's `PATH`;
commands act on the ambient Panel unless you pass an explicit target.

## Terminology

- **Space** — top-level workspace grouping; contains one or more Projects. Roughly one
  Space per role or context (e.g. "day job", "side project", "research"). Not to be
  confused with macOS "Spaces" (virtual desktops).
- **Project** — a single git repository tracked by touch-code; lives inside one Space.
- **Worktree** — a `git worktree` of a Project with its own directory, branch checkout,
  and Tab/Panel layout. Switching Worktrees switches directories, not just `HEAD`.
- **Tab** — a named grouping of Panels inside a Worktree; one Tab is visible at a time
  per Worktree. Roughly "one Tab per concurrent task" (dev server, agent, test watcher).
- **Panel** — a single terminal session rendered by libghostty; lives inside a Tab.
  Multiple Panels per Tab form split layouts.
- **Hook** — a programmable callback fired at Panel / Tab / Worktree lifecycle events.

## Fast Start

Discover the current hierarchy:

```bash
tc ls --json
```

Create a new worktree, drop into a tab running a command, and send text to a panel
(`tc send` is sugar for `tc panel send` — both accept a selector or UUID):

```bash
tc worktree new exp/feature-x
tc tab new --focus -- npm run dev
tc panel split right -- claude
tc send 1/2/2 'echo hello'
```

Open the current Worktree's directory in an external editor and install the agent hook:

```bash
tc open --in cursor
tc agent install-hook claude
```

Inspect / install / upgrade this skill from inside touch-code:

```bash
tc skill status
tc skill install --claude-code
tc skill bundle-path
```

Every mutating command accepts `--json` for machine-readable output and `--quiet` to
suppress human-facing text.

## Deep-Dive References

- [Hierarchy model](references/hierarchy-model.md) — Space / Project / Worktree / Tab /
  Panel with selector syntax and ambient env vars.
- [Targeting and selectors](references/targeting-and-selectors.md) — selector forms,
  UUIDs, `--in`, creation JSON.
- [`tc` CLI reference](references/tc-cli.md) — every shipped and planned subcommand
  with usage, flags, and expected output.
- [Agent hooks](references/agent-hooks.md) — wiring Claude Code / Codex / pi event
  streams into touch-code notifications.
- [Worktrees and external editors](references/worktrees-and-editors.md) — worktree
  lifecycle, default sibling layout, `tc open` handoff.
- [Recipes](references/recipes.md) — copy-pasteable multi-step workflows.

## Agent-specific notes

- [Claude Code](agents/claude-code/README.md)
- [Codex CLI](agents/codex/README.md)
- [pi](agents/pi/README.md)
