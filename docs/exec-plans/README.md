# Execution Plans

Execution plans (ExecPlans) are **living documents** for complex work items. They track progress, record decisions, and capture surprises discovered during implementation.

## When to Create an Exec Plan

- Any task requiring more than a few hours of work
- Multi-step changes spanning multiple files or domains
- Work where the approach may need to evolve based on discoveries
- Tasks that benefit from checkpointed progress

## Creating a Plan

Create a new markdown file in this directory from [_template.md](_template.md), then fill it in before implementation starts.

## Required Sections

Every exec plan MUST contain:
1. **Purpose / Big Picture** — what someone gains after this change
2. **Context and Orientation** — current state, key files, definitions
3. **Plan of Work** — sequence of edits and additions
4. **Progress** — checkboxes with timestamps
5. **Surprises & Discoveries** — unexpected findings
6. **Decision Log** — every decision with rationale
7. **Outcomes & Retrospective** — results vs. original purpose

## Active Plans

<!-- List active plans here -->
- [0002 — Terminal Engine and Five-Level Hierarchy (C1 + C2)](0002-terminal-and-hierarchy.md) — domain model, CatalogStore, GhosttyRuntime, HierarchyManager, TCA clients, sidebar + tab bar + split view, git worktree CLI

## Completed Plans

- [0001 — Bootstrap touch-code monorepo](0001-bootstrap-monorepo.md) — Tuist + mise + ghostty submodule + empty mac app + `tc --version` CLI + CI (2026-04-19; GhosttyKit foreignBuild deferred per DEC-8)
