# Design Docs

Design docs capture the **why** and **how** behind features and systems.

## When to Write a Design Doc

- New feature or system that touches multiple domains
- Significant architectural change
- Technical decision with long-term implications
- Any work where multiple approaches exist and the choice matters

## Template

Use [_template.md](_template.md) as a starting point.

## Index

<!-- List design docs here as they are created -->
<!-- Format: [Title](filename.md) — one-line summary -->
- [0001 — Terminal Engine and Five-Level Hierarchy (C1 + C2)](0001-terminal-and-hierarchy.md) — libghostty integration boundary, Space/Project/Worktree/Tab/Panel model, SplitTree, persistence
- [C5 — Published Agent Skill](c5-agent-skill.md) — `touch-code-skill/` package shape, `tc skill install` UX, versioning, mirror-repo story
