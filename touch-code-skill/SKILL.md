---
name: touch-code
description: Control touch-code spaces, projects, worktrees, tabs, and panels with `tc`.
---

Use this skill when you need to control touch-code from a terminal that is
already running inside a touch-code Panel.

## Terminology

- Space: top-level workspace grouping; contains one or more Projects.
- Project: a git repository tracked by touch-code; lives inside one Space.
- Worktree: a `git worktree` of a Project; has its own directory, branch, and Tabs.
- Tab: a named grouping of Panels inside a Worktree.
- Panel: a single terminal session rendered by libghostty.

## Fast Start

<!-- STUB: filled in by exec plan 0004 M8 -->

- `tc ls --json` — discover the current tree.
- `tc worktree new <branch>` — create a new worktree.
- `tc tab new --focus -- <cmd>` — open a new tab and focus it.
- `tc panel split right` — split the current panel to the right.
- `tc panel send <id> 'echo hi'` — send text to a panel.

## Deep-Dive References

- [Hierarchy model](references/hierarchy-model.md)
- [Targeting and selectors](references/targeting-and-selectors.md)
- [`tc` CLI reference](references/tc-cli.md)
- [Agent hooks](references/agent-hooks.md)
- [Worktrees and external editors](references/worktrees-and-editors.md)
- [Recipes](references/recipes.md)
