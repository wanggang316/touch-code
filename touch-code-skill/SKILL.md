---
name: touch-code
description: Control touch-code spaces, projects, worktrees, tabs, and panels with `tc`.
---

Use this skill when you need to control touch-code from a terminal that is
already running inside a touch-code Panel.

## Terminology

<!-- STUB: filled in by exec plan 0004 M8 -->

- Space, Project, Worktree, Tab, Panel — see
  [references/hierarchy-model.md](references/hierarchy-model.md).

## Fast Start

Install this skill into your agent (M4 surface — M8 adds the rest):

```
tc skill install --claude-code
tc skill status
tc skill bundle-path
```

## Deep-Dive References

- [Hierarchy model](references/hierarchy-model.md)
- [Targeting and selectors](references/targeting-and-selectors.md)
- [`tc` CLI reference](references/tc-cli.md)
- [Agent hooks](references/agent-hooks.md)
- [Worktrees and external editors](references/worktrees-and-editors.md)
- [Recipes](references/recipes.md)
