# Mission complete — C6 agent notification design

**Branch:** `worktree-design+c6-agent-notifications`
**Deliverable:** `docs/design-docs/c6-agent-notifications.md`

## v1 (initial draft, 485 lines)

- Drafted the C6 design doc following `_template.md`.
- Resolved product-spec Open Question #5 (DEC-1): user-configured hook rules + known-binary allowlist (`claude`, `codex`, `aider`) default; no magic detection.
- Defined the four-state FSM (`running / completed / blockedOnInput / idle`).
- Specified three surfaces: `UNUserNotificationCenter`, `NSApp.dockTile.badgeLabel`, in-app inbox sidebar.
- Defined a detection-rule DSL (in `hooks.json#agent_detection`).
- Initial commit: `ea0daca`.

## v2 (post-review, 670 lines — aligned with landed C3)

C3 landed on sibling branch `origin/worktree-design+c3-c4-hooks-cli` with concrete wire types. v2 fixes the four critical alignment blockers plus the important/nits from review.

### Critical (resolved)

1. **Schema rebind.** Replaced the fictional `AgentHookEvent` / `structuredPayload` references with C3's concrete `HookEvent`, `HookEnvelope`, `HookEventData`, `HookSubscription`. R9 closed.
2. **Claude Code Stop bridge.** No `Stop` case in C3's enum. Designed a pty-sentinel bridge (`::touchcode:agent-complete <panel-id>`): the agent's own Stop hook prints the sentinel; C3's `panel.outputMatch` catches it; C6 converts to `Completed`. Shim ships via `touch-code-skill` (C5). Documented in new § Bridging Agent-Internal Signals and locked as DEC-14.
3. **hooks.json ownership.** C3 owns `hooks.json`. Detection rules moved to C6-owned `~/.config/touch-code/detection-rules.json`; DEC-12. At startup C6 materialises rules into C3 `HookSubscription`s via a new `InternalHookSubscriber` protocol with a `__touch-code/internal:notifications:<rule.id>` sentinel command that the C3 dispatcher routes in-process (no shell fork).
4. **In-process vs RPC.** C6 consumes `HookDispatcher.internalEventStream()` in-process (AsyncStream); DEC-11. C3's `hook.events` streaming RPC is retained for third-party tools; C6 is not its consumer.

### Important (resolved)

- Added **full FSM transition table** (4 states × 6 input kinds including `rule`, `panel.exited(0)`, `panel.exited(≠0)`, `panel.crashed`, `idleTimer`, `activity`, `userOverride`).
- **Dropped auto-labelling.** The known-agent list is a rule-template library; detection is user-driven via `tc label <panel> --agent`. Aligns with product-spec Q5 and avoids `aider = python3` argv inspection.
- **Template filter grammar** now enumerates per-`HookEventData`-case field sets; unknown keys rejected at `DetectionRulesStore.load()`. Filters: `truncate`, `firstLine`, `default`, `upper`, `lower`.
- **Permission flow** deduplicated into one non-contradictory path: first-run prompt deferred to first agent-Panel creation (DEC-4); launch only re-queries `getNotificationSettings()` and caches status; no automatic prompting.
- **Dock badge** unified (DEC-13) — counts all unread, non-dismissed notifications regardless of OS mute status, matching the inbox's "Unread" filter.

### Nits (resolved)

- Renamed `Notification` → `AgentNotification` (avoids Foundation collision).
- `TimeInterval` throughout (aligned with C3's `HookSubscription.timeoutSeconds: Double`); removed `Duration` drift.
- Persistence routed through `TouchCodeCore/Persistence.swift` + `AtomicFileStore<T>`; dropped the `defaultURL` sugar API.
- DEC-1 note: the allowlist is a rule-template library; `aider = python3` is explicitly why v2 does not attempt argv-basename detection.

### Commits

- `ea0daca` — v1 initial draft + push.
- `1f35f4c` — v2 schema alignment (HookEnvelope / FSM table / sentinel bridge / rule relocation).

## v2.1 (tiny follow-up — InternalHookSubscriber direction fix)

C3 v2 DEC-16 landed. C6 v2 had the protocol inverted: it defined
`InternalHookSubscriber` as a registration API on C3's side. Authoritative
shape per C3 DEC-16: subscriber is the callback C6 implements
(`func handle(envelope: HookEnvelope) async`); registration lives on
`HookDispatcher.register(subscriber:for:) / unregister(prefix:)`.

Realigned:
- § Consumer contract with C3 — replaced the fictional `registerInternal` /
  `unregisterInternal` shape with C3's authoritative protocol + the
  extension methods on `HookDispatcher`. Spelled out the three-step C6
  startup flow (read rules, write sentinel-prefixed subscriptions to
  `hooks.json`, register once under the prefix).
- § Component Boundaries — corrected the exported-protocol line.
- Dependency-rules bullet — rewrote to describe C6 implementing the
  protocol, dispatcher providing register/unregister.
- DEC-12 — tightened to reference C3 DEC-16 rather than re-describing the
  mechanism.
- Added **DEC-15** logging the correction from the prior inverted assumption.
