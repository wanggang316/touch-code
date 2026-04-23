# Mission: Design docs for C3 (Lifecycle hooks) + C4 (CLI)

You are an autonomous agent working in git worktree `design+c3-c4-hooks-cli` (branch `worktree-design+c3-c4-hooks-cli`). The user is asleep and will not answer questions — make your best-judgement decisions and document them.

## Your deliverables

Two design documents, thorough enough that `/hs-planner` can generate an exec plan from each:

1. **`docs/design-docs/c3-lifecycle-hooks.md`** (~300–600 lines)
2. **`docs/design-docs/c4-cli.md`** (~300–600 lines)

Placeholders already exist — overwrite them with full content.

## Authoritative sources (read these first)

- `docs/product-spec.md` — especially the C3, C4 rows, Capability Dependencies, Open Questions #1/#4/#5
- `docs/architecture.md` — repo structure, domains, layers
- `docs/exec-plans/0002-terminal-and-hierarchy.md` — C2 (HierarchyManager, CatalogStore) interfaces you'll integrate with
- `apps/mac/TouchCodeCore/` + `apps/mac/TouchCodeIPC/` — already-written Swift domain types + RPC wire protocol
- `apps/mac/tc/` — existing CLI skeleton (ArgumentParser)

## Reference projects (when something is ambiguous)

Read these before asking yourself "what should the API look like?":

- `/Users/wanggang/dev/opensource/supacode` — nearest analogue to touch-code
- `/Users/wanggang/dev/opensource/supaterm` — terminal layer reference

Look at how they define hooks, IPC, CLI command surface, event dispatch.

## Process

1. Run `/hs-design` for C3 first. Resolve **Open Question #4** (hook execution model) inside the doc — recommend out-of-process-first (spawn user binary with env + JSON stdin) and explain why. Reference ghostty event hooks + supacode hooks if they exist.
2. Run `/hs-design` for C4. Resolve **Open Question #1** (CLI name) — keep `tc`, fallback `tcode` — and document collision check plan. Define the full command surface: `tc space|project|worktree|tab|pane|send|broadcast|skill|open|hook`. Anchor every command to an HierarchyManager/CatalogStore operation in TouchCodeCore.
3. Each doc must include:
   - Scope & non-goals (align with product-spec exclusions)
   - Public interfaces (Swift types, exact signatures, IPC wire protocol additions)
   - Data model changes (`TouchCodeCore` types to add)
   - Dependency direction (no cycles with Runtime / Ghostty / IPC)
   - Error handling model
   - Rollout plan (flag gates, back-compat)
   - **Decisions** section: every judgement call with rationale (supacode-parallel or not)
   - Testing strategy
   - Open risks

4. Commit progress in small increments (one commit per doc is fine, more is better).
5. On completion: `git push -u origin worktree-design+c3-c4-hooks-cli`.
6. When done, write `AGENT_MISSION_DONE.md` in this worktree with a 20-line summary so the reviewer can find your work fast.

## Guardrails

- **Do not** leave TBD/TODO/"to be determined" in the docs. Resolve or note as Open Risk.
- **Do not** write implementation code yet. This is design only.
- **Do not** modify files outside `docs/design-docs/` and this mission file unless you find a concrete bug in the product-spec.
- Follow repo conventions: markdown, English content in docs, matches existing `docs/design-docs/_template.md` (read it).
- If the `/hs-design` skill isn't available, produce output matching the template in `docs/design-docs/_template.md`.

Start now.
