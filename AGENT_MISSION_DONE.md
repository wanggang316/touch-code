# Agent Mission Complete — design+c3-c4-hooks-cli

**Agent:** Claude (autonomous, on behalf of Gump)
**Date:** 2026-04-20
**Branch:** `worktree-design+c3-c4-hooks-cli`

## v2 — review feedback addressed (2026-04-20)

Reviewer raised 5 critical + 5 important + 3 nit items, plus a C6-v2
contract addition for the in-process hook seam. All addressed in a
single v2 commit:

**Critical**
- C3 Hooks boundary: dropped the "module/import" framing; `Hooks/` is
  an in-app subfolder of the `touch-code` target, boundary enforced by
  folder convention + code review (aligned with architecture.md:19–33).
- C3 idle-timer: Runtime emits `.panelIdle(PanelID, duration)`
  unconditionally per exec-plan 0002; removed the `HookRuntimeBridge`
  protocol; Hooks filters client-side on `HookSubscription.idleThresholdSeconds`.
- C4 handshake ↔ D10: replaced per-request `clientVersion` header with a
  dedicated `system.hello` first-frame RPC; the handshake + first real
  request are pipelined, preserving the "fresh connection per invocation"
  invariant.
- C3/C4 stream termination: unified termination contract — either side
  may close write half; server emits a final `{id, stream: false, error?}`
  frame on graceful close; abrupt close is an implicit `.internal` error
  mapped to stderr warning + exit 0.
- C3 wire types: replaced `NSRange` with portable `HookMatchRange
  { start, length }`; added to `TouchCodeCore`.

**Important**
- C3 `HookEvent` enum gained `panel.input` (referenced by D4 recursion
  guard); payload gated on `allowRawInput: true`.
- C4 API table gained `hierarchy.resolveAlias`, `hierarchy.resolvePanelLabel`,
  `hierarchy.resolveWorktreeGlob`, `system.hello` read-only-helper rows.
- C4 exit codes split: `11` = request timeout, `12` = launch timeout.
- Canonical `Panel.labels` writer pinned in both docs:
  `HierarchyManager.setPanelLabels(_:labels:replace:)`. CLI verb and
  `HookAction.setPanelLabels` both route through it.
- C4 data-model section documents `Project.supportsWorktrees` and its
  gating behaviour for `tc worktree create/remove` on non-git projects.

**Nits**
- C3 anchor-presence clarified: wire fields optional (`encodeIfPresent`),
  per-scope non-null guarantees tabulated and asserted via
  `HookEnvelope.validateAnchors()` on encode.
- Magic `250ms` recursion window replaced with
  `HookConfig.recursionWindowMs` (default 250); C3 and C4 references
  updated.
- Test fixture path specified: `apps/mac/HooksTests/Fixtures/echo-envelope.sh`.

**New: C6 v2 contract (new DEC-16)**
- Added `HookDispatcher.internalEventStream() -> AsyncStream<HookEnvelope>`
  as the in-process peer of `hook.events` RPC (third-party tooling still
  uses the RPC; first-party consumers like C6 avoid the IPC round-trip).
- Added `InternalHookSubscriber` protocol and sentinel-prefix routing:
  subscriptions whose `command` starts with the reserved
  `__touch-code/internal:` namespace short-circuit the
  `ProcessHookExecutor` and deliver directly to the registered subscriber.
  Recursion guard, rate limits, and `hook.recent` bookkeeping still apply.
- Reserved-namespace rule enforced at `HookConfigStore.load()`: user
  subscriptions cannot claim the `__touch-code/internal:` prefix.

## v1 — initial delivery (2026-04-20)

- `docs/design-docs/c3-lifecycle-hooks.md` — 708 lines (v2). Resolves
  product-spec Open Q #4 (hook execution model): **out-of-process-first**.
  Defines `HookEvent` / `HookEnvelope` / `HookSubscription` wire types
  in `TouchCodeCore`; `Hooks/` in-app subfolder and its consumer
  relationship with `Runtime`; the `hook.*` IPC method surface including
  a streaming `hook.events` RPC and an in-process `internalEventStream()`
  peer; output-match / idle-timer integration; stdout JSON action DSL;
  concurrency cap; recursion guard; 16 tagged decisions (D1–D16) + 10
  risks (R1–R10).

- `docs/design-docs/c4-cli.md` — 626 lines (v2). Resolves product-spec
  Open Q #1 (**keep `tc`; ship `tcode` as peer fallback** with
  collision-check installer), architecture Open Q #3 (`~/.local/bin`,
  not `/usr/local/bin`), and Open Q #5 (64-deep bounded in-flight queue).
  Full command surface: `tc space|project|worktree|tab|panel|send|
  broadcast|skill|open|hook|system` — every verb anchored to a specific
  `HierarchyManager` / `TerminalEngine` / `GitWorktreeCLI` /
  `SkillInstaller` entry point; exact IPC method strings; wire types
  (`BroadcastScope`, `PanelOpenRequest`, `AliasResolveRequest`);
  exit-code table; 19 decisions (D1–D19); 13 risks (R1–R13); 7-phase
  rollout plan.

## Process notes

- No files outside `docs/design-docs/` and `AGENT_MISSION{,_DONE}.md`
  were modified — stayed inside mission guardrails across both v1 and v2.
- Product-spec text was **not** modified; no bug found that warranted
  it.
- Both docs resolve (rather than defer) every judgement call; no `TBD`
  / `TODO` / "to be determined" strings remain.
- Reference projects (supacode / supaterm) inspected via research
  subagent; each decision tagged supacode-parallel, supaterm-parallel,
  or divergent-with-reason.
- Commit cadence: v1 shipped as two commits (C3, then C4 + done marker);
  v2 ships as a single commit addressing all feedback in one pass so
  the reviewer can diff the before/after cleanly.

## For the reviewer

- Read C3's **Design → Event Taxonomy** and C4's **API Design** tables
  first — they compress the entire contract.
- The **Decisions** section of each doc is the fastest way to spot-check
  judgement calls; every entry has a one-line rationale.
- C3 DEC-16 is the new C6-v2 contract — worth re-reading once the C6
  design doc lands so the pairing stays tight.
- `/hs-planner` should be able to generate an exec plan for each doc
  without additional questions; all Swift signatures, file paths,
  module boundaries, and IPC method strings are specified.
