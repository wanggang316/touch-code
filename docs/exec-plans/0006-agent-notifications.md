# ExecPlan: Agent Notification Aggregation (C6)

**Status:** Draft
**Author:** Gump (with Claude)
**Date:** 2026-04-20

This is a living document. The Progress, Surprises & Discoveries, Decision Log, and Outcomes & Retrospective sections must be kept up to date as work proceeds.

## Purpose

After this plan lands, a contributor running touch-code with one or more agent-hosted Panels sees the first working version of the agent-notification loop:

- When an agent finishes (`claude` writes the sentinel token `::touchcode:agent-complete <panel-id>`, `codex` exits its CLI, `aider` reaches a natural stop), a **"Claude finished"** banner appears in macOS Notification Centre, the Dock icon shows a red unread-count badge, and a new row appears in the in-app inbox sidebar showing *Project · Worktree · Tab · Panel* provenance.
- When an agent is **waiting for input** (Claude's "Do you want to proceed?" prompt; aider's idle `>` prompt; Codex's approval banner), the same three surfaces fire — with `Kind: blockedOnInput`, a distinct state chip, and copy that tells the user which Panel wants attention.
- Clicking either the OS banner or an inbox row focuses the originating Panel via `touch-code://panel/<id>/focus`. If the Panel has been closed, the app falls back to the inbox row.
- When the user declines macOS notification permission, the Dock badge and inbox still accrue unread items — the product goal ("user returns to the correct Panel within 30s of an agent-completion event") is satisfied without OS banners.
- All defaults (rules, shim scripts, idle threshold) ship out of the box; power users edit `~/.config/touch-code/detection-rules.json` and reload with `tc notifications rules reload`.

This plan is the first capability that makes touch-code **aware** of what its Panels are doing, not just a renderer. It is the validation case for C3's hook design (consumer-side) and the first user-visible payoff from labelling Panels with `tc label --agent <name>`.

## Progress

- [ ] M1 — `TouchCodeCore` data types + field-path enumerator (AgentState, AgentStateTransition, AgentNotification, NotificationInbox, AgentDetectionRules, HookEnvelope field path table)
- [ ] M2 — `touch-code/Notifications/` module: DetectionRouter (InternalHookSubscriber impl), TrackerRegistry (single owner of tracker lifecycle), AgentStateTracker (4-state FSM), RuleStore (read-modify-write via C3 load/save), TemplateRenderer
- [ ] M3 — InboxStore persistence (notifications.json via AtomicFileStore, 500-row cap, 7-day sweep) + codable round-trip + debounced writer
- [ ] M4 — OSNotifier (UNUserNotificationCenter wrapper) + DockBadger (NSApp.dockTile) + permission flow on first agent-Panel creation + NotificationCoordinator fan-out
- [ ] M5 — InboxSidebar SwiftUI surface (320pt, filter chips, swipe-dismiss, deeplink-on-click) + Settings toggles
- [ ] M6 — Default detection rules for claude/codex/aider + Stop-hook shim scripts in `touch-code-skill/` + `tc notifications rules reload`
- [ ] M7 — Integration tests (mock HookDispatcher, mock UNUserNotificationCenter, fake Clock) + end-to-end flow asserting a sentinel match transitions a tracker and surfaces all three sinks

## Surprises & Discoveries

(None yet)

## Decision Log

(None yet)

## Outcomes & Retrospective

(To be filled at milestone completion)

## Context and Orientation

Related documents (all in this repo):

- Product spec — [docs/product-spec.md](../product-spec.md), capability C6 and Open Question #5
- Design doc — [docs/design-docs/c6-agent-notifications.md](../design-docs/c6-agent-notifications.md) — **authoritative** for every design decision (DEC-1 through DEC-15). This plan does not relitigate those decisions; it implements them.
- Sibling design doc — [docs/design-docs/c3-lifecycle-hooks.md](../design-docs/c3-lifecycle-hooks.md) — C3's `HookEvent` / `HookEnvelope` / `HookEventData` schemas, the `InternalHookSubscriber` protocol (C3 DEC-16), and the reserved `__touch-code/internal:` sentinel-prefix convention. Every C6 type binds directly to these.
- Sibling design doc — [docs/design-docs/c4-cli.md](../design-docs/c4-cli.md) — where `tc notifications list / clear / mute / rules reload` and `tc label` originate. C6 exposes no IPC namespace of its own (c6 DEC-10); C4 owns the argv parsing and calls C6 MainActor methods.
- Architecture — [docs/architecture.md](../architecture.md) — codemap, dependency direction, invariants (atomic-rename JSON with version gate; in-app module boundaries under `touch-code/`).
- Golden rules — [docs/golden-rules.md](../golden-rules.md).
- Previous ExecPlans — [docs/exec-plans/0002-terminal-and-hierarchy.md](0002-terminal-and-hierarchy.md) for `HierarchyManager` / `CatalogStore` patterns that `InboxStore` and `RuleStore` copy.

Reference projects (filesystem-local, read-only):

- **supacode** — `/Users/wanggang/dev/opensource/supacode`
  - `supacode/Infrastructure/AgentHookSocketServer.swift` — `AgentHookNotification` payload shape we adapt to `AgentNotification`.
  - `supacode/Features/Terminal/BusinessLogic/WorktreeTerminalManager.swift` — the `@Observable` manager/tracker shape.
- **supaterm** — `/Users/wanggang/dev/opensource/supaterm`
  - `apps/mac/supaterm/App/TerminalCommandExecutor+AgentHooks.swift` — `AgentHookNotification` + `TerminalHostState.NotificationSemantic` pair; the shape of the completed/blocked/idle categorisation we ported into `AgentNotification.Kind`.
  - `bins/supaterm-agent/` — Claude Code / Codex integration scripts; M6's Stop-hook shims borrow the argv convention and env-var resolution trick.

**External dependencies.** This plan assumes C3 exec plan 0003 has landed through its own M3 (C3's `HookDispatcher` exists with `internalEventStream()` and `register(subscriber:for:)`, and `hooks.json` load/save works). C3 also carries C2's prerequisite (`Panel.labels: Set<String>`, per C3 D10). If C3 0003 has not landed when C6 starts, M2 blocks and the Decision Log must record the gap.

**Dependency direction (enforced by code review, not Tuist).**

```
touch-code/Notifications           (new in-app module)
      │
      ├─▶ TouchCodeCore             (data types — AgentState, AgentNotification, AgentDetectionRules)
      ├─▶ touch-code/Hooks (C3)     (HookDispatcher façade: internalEventStream, register/unregister,
      │                              and the InternalHookSubscriber protocol — C6 implements it)
      └─▶ touch-code/Runtime (C1+C2) (read HierarchyManager for provenance; never mutates)
```

The **only** reverse edge anywhere is C3's dispatcher calling C6's `DetectionRouter.handle(envelope:)`, which is correct per C3 DEC-16 — the dispatcher owns routing, C6 provides the callback. No TCA feature calls into C6 directly; TCA reads the inbox store through a `NotificationClient` dependency (mirrors `TerminalClient` / `HierarchyClient`).

**Terminology used in this plan.**

- **AgentState** — the 4-state FSM per c6 design §API Design: `running / completed / blockedOnInput / idle`.
- **AgentStateTracker** — one `@Observable @MainActor` instance per agent-labelled Panel. Owns the FSM plus an idle timer. Produces `AsyncStream<AgentStateTransition>`.
- **DetectionRouter** — the single class implementing `InternalHookSubscriber` (C3-provided protocol). Receives every envelope whose `HookSubscription.command` starts with `__touch-code/internal:notifications:`, splits the suffix back into a rule id, and dispatches to the tracker for the envelope's Panel.
- **RuleStore** — `@MainActor` class managing `~/.config/touch-code/detection-rules.json` (C6-owned — DEC-12). On load, materialises each rule into a C3 `HookSubscription` written into `hooks.json` under the `authoredBy: "touch-code"` flag.
- **TemplateRenderer** — pure function from `(rule.title | rule.body, HookEnvelope, AgentStateTransition) → String`. Rejects unknown field paths at rule-load time per c6 design §Detection Rule DSL.
- **InboxStore** — `@MainActor` wrapper around `AtomicFileStore<NotificationInbox>`; debounced 500ms trailing write; enforces the 500-row cap and the 7-day soft-delete sweep on load.
- **OSNotifier** — protocol + concrete adapter over `UNUserNotificationCenter` (Apple's `UserNotifications` framework).
- **DockBadger** — protocol + concrete adapter over `NSApp.dockTile.badgeLabel`.
- **NotificationCoordinator** — `@MainActor` class that subscribes to every tracker's `transitions` stream, consults muting rules, constructs `AgentNotification`s, and fans out to `InboxStore` + `OSNotifier` + `DockBadger`.
- **Sentinel token / Stop-hook shim** — a one-line shell script that prints `::touchcode:agent-complete $TOUCH_CODE_PANEL_ID` to stdout; installed as the agent's own "Stop" hook (Claude Code's `.claude/settings.json`, Codex's `.codex/settings.json`, etc.). See c6 DEC-14.

**Orientation paragraph.** Seven milestones. M1 is the pure-Swift leaf: Codable types in `TouchCodeCore` that every other milestone imports, plus the template-field enumerator that locks the DSL at compile time. M2 stands up the runtime machinery (FSM + router + rule loading) against a mock envelope stream, so everything is unit-testable without C3 wiring. M3 makes the inbox durable. M4 adds the two macOS surfaces (UN + Dock badge) with the permission flow gated by `NotificationCoordinator`. M5 is the inbox UI — the first time the user can *see* the inbox inside touch-code. M6 ships the shipped defaults (rule bundles + shim scripts for each known agent). M7 proves everything fits together end-to-end with a single live C3 dispatcher feeding a real `DetectionRouter` into a real tracker into real (mocked) OS surfaces. Each milestone is independently verifiable and produces at least one commit per the project's commit-after-each-small-feature cadence.

## Plan of Work

Seven milestones. Slicing is vertical where it helps: M2 punches end-to-end through a fake envelope → tracker → stream, and M4 finishes the full transition → OS banner arc (inbox persistence from M3 included).

### Milestone 1: TouchCodeCore types + field-path enumerator

**Goal after this milestone.** Every C6-owned Codable type (`AgentState`, `AgentStateTransition`, `AgentNotification`, `NotificationInbox`, `AgentDetectionRules`) exists in `TouchCodeCore/` as pure Swift with full `Codable / Equatable / Sendable` conformance. A compile-time table maps every `HookEventData` case to the set of valid template field paths; it is used by M2's `TemplateRenderer` loader to reject bad rules early. Zero imports of AppKit, SwiftUI, UserNotifications, or GhosttyKit. Unit tests cover Codable round-trip, FSM transition-table invariants, and unknown-field-path rejection.

This milestone is cheap, low-risk, and unblocks everything else. It is also the first opportunity to add files to `TouchCodeCore/Notifications/`.

**Work.** Under `apps/mac/TouchCodeCore/Notifications/` (new subfolder), create six files:

- `AgentState.swift` — the 4-case enum, `String`-backed, `Codable / Sendable`. Values: `running / completed / blockedOnInput / idle`. No behaviour; pure enum.
- `AgentStateTransition.swift` — the `struct` with `panelID: PanelID`, `from: AgentState`, `to: AgentState`, `at: Date`, `trigger: Trigger`. The nested `Trigger` enum carries `.rule(id: String)`, `.envelope(event: HookEvent)`, `.idleTimer(seconds: TimeInterval)`, `.userOverride`. `HookEvent` is imported from C3 (added to `TouchCodeCore` by C3 exec plan 0003 M1). All `Codable / Equatable / Sendable`.
- `AgentNotification.swift` — the `struct` with `id: UUID`, `panelID: PanelID`, `agent: String`, `kind: Kind`, `title: String`, `body: String`, `createdAt: Date`, `readAt: Date?`, `dismissedAt: Date?`. `Kind` is `String`-backed enum: `completed / blockedOnInput / idle / crashed`. Computed `isUnread: Bool { readAt == nil && dismissedAt == nil }` — used by the Dock badge count per DEC-13. `Codable / Equatable / Sendable / Identifiable`.
- `NotificationInbox.swift` — the top-level persisted struct: `static let currentVersion = 1`, `version: Int`, `notifications: [AgentNotification]`, `static let empty: NotificationInbox`. Custom `Codable` init that throws `DecodingIssue.unsupportedVersion(Int)` for unknown versions (mirrors `Catalog`'s pattern, file `Catalog.swift`). The 500-row cap and 7-day sweep are **not** enforced by the struct — they live in M3's `InboxStore` so the persisted value stays a plain projection.
- `AgentDetectionRules.swift` — the top-level persisted struct for `detection-rules.json`: `static let currentVersion = 1`, `version: Int`, `idleThresholdSeconds: TimeInterval` (default 120), `rules: [Rule]`. Nested `Rule`, `AppliesWhen`, `Match` (with `Target: String` enum `tail / lastLine / lastNonEmptyLine`) exactly matching c6 design §API Design. `Rule.id: String` is the sentinel-suffix the C3 subscription will carry. Rule decode sanity: a rule whose `appliesWhen.hookEvent == .panelOutputMatch` with `match == nil` throws `AgentDetectionRules.DecodeIssue.missingMatch(ruleID: String)`.
- `TemplateField.swift` — the enumerator. A `public enum TemplateField` listing every valid field path (`agent`, `state.from`, `state.to`, `panel.id`, `panel.workingDirectory`, `panel.initialCommand`, `tab.id`, `tab.name`, `tab.selectedPanelID`, `worktree.id`, `worktree.name`, `worktree.path`, `worktree.branch`, `project.id`, `project.name`, `project.rootPath`, `space.id`, `space.name`, plus event-specific paths `data.match / data.output / data.outputBytes / data.matchedRange.location / data.matchedRange.length / data.idleSeconds / data.sinceLastOutput / data.sinceLastInput / data.pid / data.shell / data.exitCode / data.reason / data.createdVia`). A `static func validPaths(for event: HookEvent) -> Set<TemplateField>` returns the always-available set plus the event-specific set. This is what M2's `TemplateRenderer` calls at rule-load time; if a rule's `title` or `body` references a `{field}` not in `validPaths(for: rule.appliesWhen.hookEvent)`, loading throws.

Add `TouchCodeCoreTests/AgentStateTests.swift`: exhaustive Codable round-trip for every `AgentState` case; round-trip for every `AgentStateTransition.Trigger` variant; assert JSON keys match the design doc (`state.from` → `"from"`, etc.).

Add `TouchCodeCoreTests/AgentNotificationTests.swift`: Codable round-trip; `isUnread` truth table (unread, read, dismissed, read-and-dismissed); a notification with `kind: .idle` round-trips identically.

Add `TouchCodeCoreTests/NotificationInboxTests.swift`: `currentVersion == 1` round-trip; decoding a payload with `"version": 2` throws `DecodingIssue.unsupportedVersion(2)`; empty inbox encodes to `{"version":1,"notifications":[]}` (sorted keys per `JSONEncoder.touchCodeDefault`).

Add `TouchCodeCoreTests/AgentDetectionRulesTests.swift`: decode the "Claude Code blocked on input" example rule from c6 design §Detection Rule DSL verbatim and assert every field; a rule with `appliesWhen.hookEvent == .panelOutputMatch` but `match == nil` throws `missingMatch`; round-trip idempotence.

Add `TouchCodeCoreTests/TemplateFieldTests.swift`: for each `HookEvent` case, `validPaths(for:)` returns the exact expected set documented in c6 design (spot-check: `{data.match}` is in the set for `.panelOutputMatch` and not in the set for `.panelIdle`).

**Observable acceptance.** `xcodebuild test -scheme TouchCodeCore` is green with the five test files above contributing new `func test…` methods (exact count equals the number of functions written; acceptance is "0 failures"). `grep -R 'import AppKit\|import SwiftUI\|import UserNotifications\|import GhosttyKit' apps/mac/TouchCodeCore` returns no matches. `make lint` is clean.

**Expected commits.**

- `feat(core): agent-notification domain types (AgentState, AgentNotification, NotificationInbox)`
- `feat(core): agent-detection rule types + TemplateField enumerator`

### Milestone 2: touch-code/Notifications — DetectionRouter, TrackerRegistry, AgentStateTracker, RuleStore, TemplateRenderer

**Goal after this milestone.** The new in-app module `touch-code/Notifications/` exists. A `DetectionRouter` implements C3's `InternalHookSubscriber` protocol; given a `HookEnvelope` with a `__touch-code/internal:notifications:<rule-id>` sentinel, it looks up the rule, renders its template, and delegates to the tracker owned by `TrackerRegistry` — never creates one lazily. A `TrackerRegistry` is the **single owner of tracker lifecycle across the whole plan**: at construction it enumerates every existing Panel in `HierarchyManager.catalog` whose labels include an `agent:*` entry and creates a tracker for each; it then subscribes to hierarchy events to maintain that set as Panels are added, removed, or relabelled. An `AgentStateTracker` maintains the 4-state FSM per Panel using the exact transition table from c6 design §API Design. A `RuleStore` reads `detection-rules.json`, validates every rule (schema, regex compilation, template-field-path set), and materialises each rule as a C3 `HookSubscription` in `hooks.json` using C3's existing `HookConfigStore.load()` / `save(_:)` API via a read-modify-write adapter. A `TemplateRenderer` handles `{field}` / `| filter[: arg]` with unknown-field rejection at load time. Everything is unit-testable with a fake envelope feed.

This milestone does **not** yet touch `UNUserNotificationCenter`, `NSApp.dockTile`, or disk-based inbox state. It stops at `AsyncStream<AgentStateTransition>`.

**Tracker ownership commitment.** `TrackerRegistry` owns every `AgentStateTracker` from its creation to teardown. `DetectionRouter`, `NotificationCoordinator` (added in M4), and M7's end-to-end tests all access trackers through `registry.tracker(for: panelID)` — never by holding their own references or creating new ones. This replaces the mid-stream ownership handoff that v1 of this plan described between M2 and M4, so there is no refactor between milestones.

**Work.** Under `apps/mac/touch-code/Notifications/` (new subfolder), create:

- `DetectionRouter.swift`:

      @MainActor
      final class DetectionRouter: InternalHookSubscriber {
        init(rules: AgentDetectionRules, registry: TrackerRegistry, renderer: TemplateRenderer)

        /// C3 calls this on @MainActor per the sentinel-prefix route.
        nonisolated func handle(envelope: HookEnvelope) async

        /// Stream of classified transitions; subscribed by NotificationCoordinator in M4.
        var transitions: AsyncStream<AgentStateTransition> { get }
      }

  `handle(envelope:)` (a) extracts the rule id by splitting the `HookSubscription.command` suffix, (b) looks up the rule, (c) checks the `AppliesWhen.panelLabelledAgent` / `panelID` filters C3's scope cannot express, (d) renders `title` and `body` via `TemplateRenderer`, (e) fetches the tracker via `registry.tracker(for: envelope.panel?.id)` — if the registry has no tracker for this Panel the envelope is logged and dropped (this is the expected path when a Panel loses its agent label; no silent creation), (f) calls `tracker.ingest(envelope: envelope, ruleID: ruleID, rendered: (title, body))`, (g) forwards the transition the tracker emits to `transitions`.

- `TrackerRegistry.swift`:

      @MainActor
      final class TrackerRegistry {
        init(hierarchy: HierarchyManager, idleThreshold: TimeInterval, clock: any Clock<Duration>)

        /// Bootstrap step: create trackers for every Panel in hierarchy.catalog whose
        /// labels contain an "agent:*" prefix. Must be called exactly once at app launch,
        /// BEFORE DetectionRouter receives its first envelope. Idempotent on repeat calls.
        func bootstrap()

        /// Forward HierarchyManager events into lifecycle transitions:
        ///   - onPanelCreated(panel) where panel.labels contains "agent:*" → create tracker
        ///   - onPanelRemoved(panelID) → teardown tracker
        ///   - onPanelLabelsChanged(panelID, newLabels) → create if newly labelled,
        ///     teardown if label removed
        func subscribeToHierarchyEvents()

        func tracker(for panelID: PanelID?) -> AgentStateTracker?
        var allTrackers: [AgentStateTracker] { get }  // M4 uses this to iterate for
                                                      // onAgentPanelCreated callbacks
      }

  `bootstrap()` walks the catalog via `hierarchy.catalog.allAgentPanels()` (a small helper added to `HierarchyManager` in this milestone that iterates Space → Project → Worktree → Tab → Panel and yields `(Panel, labels)` pairs whose labels match the prefix). `subscribeToHierarchyEvents()` consumes an `AsyncStream<HierarchyEvent>` exposed by `HierarchyManager` (the `onPanelCreated` / `onPanelRemoved` / `onPanelLabelsChanged` callbacks already sketched in the 0002 M2 design; if this stream does not yet exist, this milestone adds it as a small extension and records the coupling in Decision Log). `tracker(for:)` returns nil for Panels without an agent label — callers must handle nil explicitly.

- `AgentStateTracker.swift`:

      @MainActor @Observable
      final class AgentStateTracker {
        let panelID: PanelID
        private(set) var state: AgentState = .running
        init(panelID: PanelID, idleThreshold: TimeInterval, clock: any Clock<Duration>)

        /// Drive the FSM from a C3-delivered envelope. Returns the transition (or nil if no change).
        @discardableResult
        func ingest(envelope: HookEnvelope, ruleID: String?, rendered: (title: String, body: String)?) -> AgentStateTransition?

        /// Manual override from CLI/UI; never emits a notification (c6 design invariant).
        func override(to newState: AgentState)

        /// Called when the Panel is removed from HierarchyManager. Cancels idle timer.
        func teardown()
      }

  The FSM implements c6 design §API Design's transition table exactly. Activity (non-empty output) rearms the idle timer via `clock.sleep(for: .seconds(idleThreshold))`. On `.panelExited(code: 0)` the tracker emits a `completed` transition with `trigger = .envelope(event: .panelExited)`; on `.panelExited(code != 0)` or `.panelCrashed`, the tracker emits a `crashed` notification kind (via `rendered.title = "<agent> crashed"`, `body = data.reason ?? "exit \(code)"`) then calls `teardown()`. Self-transitions (`from == to`) are dropped — no notification emitted, per c6 design invariant.

- `RuleStore.swift`:

      @MainActor
      final class RuleStore {
        init(fileURL: URL = ConfigPaths.detectionRules(), hookWriter: HookConfigWriting)

        /// Load rules from disk, validate every rule's template/regex against TemplateField, and
        /// materialise each rule as a HookSubscription in hooks.json under authoredBy: "touch-code".
        /// Throws RuleStoreError on malformed rules.
        func loadAndMaterialise() throws -> AgentDetectionRules

        /// Re-read from disk and re-materialise (called by `tc notifications rules reload`).
        func reload() throws -> AgentDetectionRules
      }

      enum RuleStoreError: Error {
        case unknownTemplateField(ruleID: String, path: String)
        case invalidRegex(ruleID: String, pattern: String, underlying: Error)
        case unsupportedVersion(Int)
        case missingMatch(ruleID: String)
      }

  The `hookWriter` is injected (a narrow protocol wrapping C3's `HookConfigStore.load()` / `save(_:)` pair — see `Bridging/HookConfigWriting.swift` below). **This plan deliberately does not require C3 to add a new upsert API.** Instead, the adapter performs read-modify-write: load the current `HookConfig`, remove every subscription whose `command` starts with the `__touch-code/internal:notifications:` prefix, append the freshly materialised subscriptions authored with `authoredBy: "touch-code"`, and save. The operation is atomic because C3's `save(_:)` already goes through `AtomicFileStore`; concurrent edits from the user (via `tc hook install`) are serialised by the file timestamp / version check — if the on-disk config has changed since `load()` returned, `save(_:)` throws and `RuleStore` retries once before surfacing the error. In unit tests the fake writer records every load/save pair. Rule → HookSubscription translation: `event = .panelOutputMatch`, `matchPattern = <rule's regex or pipe-joined contains_any>`, `scope = .panelLabel("agent:\(rule.agent)")` (or `.panelID(rule.panelID)` when set), `command = "__touch-code/internal:notifications:\(rule.id)"`, `mode = .fireAndForget`, `timeoutSeconds = 1` (unused — the sentinel-prefix route short-circuits `ProcessHookExecutor`), `authoredBy = "touch-code"` (the flag C3 DEC-16 reserves for first-party internal subscriptions).

- `TemplateRenderer.swift`:

      @MainActor
      struct TemplateRenderer {
        init(rules: AgentDetectionRules) throws   // validates every rule at init
        func render(template: String, for envelope: HookEnvelope, transition: AgentStateTransition) -> String
      }

  Parser: a single-pass scanner recognising `{field.path}` and `{field.path | filter[: arg]}` with chainable pipes. Filters `truncate: Int`, `firstLine`, `default: String`, `upper`, `lower`. Validation at init enumerates each template literal and asserts every `{path}` is in `TemplateField.validPaths(for: rule.appliesWhen.hookEvent ?? .panelOutputMatch)`; mismatches throw `RuleStoreError.unknownTemplateField`. Literals that are *not* valid template placeholders (e.g. `{foo}`) are likewise rejected to avoid silent no-op templates.

- `ConfigPaths.swift`:

      enum ConfigPaths {
        static let home: URL = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
        static func configDirectory() -> URL { home.appendingPathComponent(".config/touch-code", isDirectory: true) }
        static func notificationInbox() -> URL { configDirectory().appendingPathComponent("notifications.json") }
        static func detectionRules() -> URL { configDirectory().appendingPathComponent("detection-rules.json") }
      }

  Colocated here (not in `TouchCodeCore`) because `CatalogStore` already has `Catalog.defaultURL()` as its own path; keeping the path convention in `Notifications` keeps c6 self-contained.

- `Bridging/HookConfigWriting.swift` — the narrow protocol RuleStore uses. Single home; referenced from Interfaces & Dependencies only at this path.

      @MainActor
      protocol HookConfigWriting {
        func load() throws -> HookConfig
        func save(_ config: HookConfig) throws
      }

      // Concrete adapter delegating to C3's HookConfigStore.
      @MainActor
      final class HookConfigStoreAdapter: HookConfigWriting { init(store: HookConfigStore) }

      // Test double capturing every load/save pair.
      @MainActor
      final class FakeHookConfigWriter: HookConfigWriting { /* in-memory HookConfig + call log */ }

  Neither the adapter nor the fake uses any API beyond `load()` / `save(_:)` — matches the surface C3 0003 M1 already commits to.

Under `apps/mac/touch-code/Tests/NotificationsTests/` — extend the existing `touch-codeTests` Tuist target (already present per 0002 M2) rather than creating a new target. Hosted tests already work there; a new target would require duplicating the host-app configuration. Files land under `apps/mac/touch-code/Tests/NotificationsTests/` as a filesystem-level grouping, identified in tests via `only-testing:touch-codeTests/NotificationsTests/…`.

- `AgentStateTrackerTests.swift` — cover every cell of the 6 × 4 transition table from c6 design (6 input kinds × 4 from-states). Use a `TestClock` from `swift-clocks` (already a test-only dep in supacode; if it isn't available, roll a local `ManualClock: Clock<Duration>` — 20 lines). Assert: (a) self-transitions do not emit; (b) activity rearms the idle timer; (c) `.panelCrashed` emits `crashed` then tears down; (d) `override` never emits.
- `TrackerRegistryTests.swift` — seed a fake `HierarchyManager` with three Panels (two agent-labelled, one plain); call `bootstrap()`; assert exactly two trackers exist. Emit a synthetic `onPanelCreated(panel: agentLabelled)` event; assert a third tracker exists. Emit `onPanelLabelsChanged` that removes the `agent:*` label; assert the corresponding tracker is torn down and `tracker(for:)` returns nil. Emit `onPanelRemoved` for an existing tracked Panel; assert teardown.
- `DetectionRouterTests.swift` — feed a fake `HookEnvelope` whose `HookSubscription.command` starts with the sentinel prefix; assert the correct rule is selected, `panelLabelledAgent` filter rejects non-matching panels, and the rendered title/body exactly match an expected string. Envelope for a Panel with no tracker is dropped silently (logged at `.info`, no transition emitted).
- `RuleStoreTests.swift` — happy path loads the shipped default rules (precursor of M6; stub with one inline rule for now); `missingMatch` / `unknownTemplateField` / `invalidRegex` all throw with the correct associated value. `FakeHookConfigWriter` captures one load + one save per materialise; the saved `HookConfig` contains exactly the new `authoredBy: "touch-code"` subscriptions and preserves any unrelated user-authored rows.
- `TemplateRendererTests.swift` — table-driven: `{agent}` renders literally; `{data.output | firstLine | truncate: 12}` works with multi-line UTF-8 (including grapheme clusters — `"👨‍👩‍👧‍👦 is one cluster"` truncated to 8 keeps the whole emoji); `{foo}` throws at init; `| default: "…"` kicks in when the value is empty.

**Observable acceptance.** `xcodebuild test -scheme touch-code -only-testing:touch-codeTests/NotificationsTests` is all green. A short smoke executable `touch-code-notif-smoke` (optional; throwaway) feeds a hand-constructed `HookEnvelope` to a `DetectionRouter` and prints the resulting `AgentStateTransition` — demonstrates the contract without running the app.

**Expected commits.**

- `feat(notifications): AgentStateTracker FSM`
- `feat(notifications): TrackerRegistry + hierarchy-event bootstrap`
- `feat(notifications): DetectionRouter implementing InternalHookSubscriber`
- `feat(notifications): RuleStore + TemplateRenderer with field validation`

### Milestone 3: InboxStore persistence (notifications.json)

**Goal after this milestone.** An `InboxStore` exists in `touch-code/Notifications/` mirroring `CatalogStore`'s pattern: atomic-rename JSON via `AtomicFileStore<NotificationInbox>`, 500ms debounced trailing writes, synchronous flush on `applicationWillTerminate`, 7-day soft-delete sweep on load, 500-row hard cap. Unit tests round-trip an inbox to disk and back, prove that 100 appends in a burst coalesce into one write, prove that a file at `version: 2` aborts (per architecture invariant), and prove that dismissed items older than 7 days are pruned on load.

**Work.** Under `apps/mac/touch-code/Notifications/`, create `InboxStore.swift`:

    @MainActor
    final class InboxStore {
      private(set) var inbox: NotificationInbox
      init(fileURL: URL = ConfigPaths.notificationInbox(), clock: any Clock<Duration> = ContinuousClock())

      func load() throws -> NotificationInbox          // returns .empty on ENOENT; backs up corrupt files
      func append(_ notification: AgentNotification)    // inserts at index 0; enforces cap; schedules save
      func markRead(_ ids: [UUID])
      func dismiss(_ ids: [UUID])
      func clearAll()
      func saveNow() throws                             // sync flush (applicationWillTerminate)
      var unreadCount: Int { get }                      // isUnread filter; drives the Dock badge
      var unreadPublisher: AsyncStream<Int> { get }     // emits on every mutation — M4 consumes
    }

Implementation mirrors `CatalogStore`:

1. `load()` reads via `AtomicFileStore.read`; on `DecodingIssue.unsupportedVersion`, renames the file to `notifications.json.broken-<ISO8601>` and returns `.empty`, logging via `os.Logger(subsystem: "com.touch-code.notifications", category: "inbox")`.
2. Sweep-on-load: after `load()`, filter out any notification where `dismissedAt != nil && now.timeIntervalSince(dismissedAt!) > 7 * 86_400`. Sweep happens in memory *before* any write; if all 500 rows are live, no sweep occurs.
3. Cap: after every `append`, truncate `notifications` to 500 (newest-first). Truncated items are dropped silently — the 500 cap is a storage cap, not a retention guarantee.
4. Debounce: same pattern as `CatalogStore.scheduleSave` — one in-flight `Task`, cancelled and re-armed on each mutation.
5. `unreadPublisher`: a plain `AsyncStream<Int>` wrapped around `unreadCount` and yielded on every mutation. Replaces ad-hoc observation and lets the `DockBadger` in M4 subscribe without re-computing.

Under `apps/mac/touch-code/Tests/NotificationsTests/`:

- `InboxStoreTests.swift` — round-trip: append 3 notifications, save, reload a fresh store against the same file, assert identical state. Decode-abort test: write `{"version":2}` to the file and assert `load()` returns `.empty` and the broken file ends up as `notifications.json.broken-*`. Debounce coalescing: `append` 100 times in a tight loop inside a `@MainActor` task; advance `ManualClock` by 500ms; assert exactly one call to a fake disk writer. 7-day sweep: seed with 5 notifications (3 dismissed 10 days ago, 2 dismissed 2 days ago, plus 1 live), call `load()`, assert the live one plus the 2 recent dismissals survive. Cap: append 600 notifications; assert `inbox.notifications.count == 500` and the newest 500 are kept. Clock injection: use `ManualClock` so tests run in microseconds, not real wall time.

**Observable acceptance.** `xcodebuild test -scheme touch-codeTests -only-testing:touch-codeTests/NotificationsTests/InboxStoreTests` green. Running the app (still without OS notifications — those are M4) and programmatically calling `inboxStore.append(...)` during debug produces `~/.config/touch-code/notifications.json` containing `"version": 1` and the appended notification. Deleting the file and relaunching yields an empty inbox.

**Expected commits.**

- `feat(notifications): InboxStore with debounced writes and 7-day sweep`

### Milestone 4: OSNotifier + DockBadger + NotificationCoordinator + permission flow

**Goal after this milestone.** `NotificationCoordinator` subscribes to `DetectionRouter.transitions`, applies muting policy, constructs `AgentNotification`s, and fans out to `InboxStore.append`, `DockBadger.setUnreadCount`, and `OSNotifier.post`. The macOS permission flow fires exactly once — on first agent-Panel creation after install, per DEC-4. When permission is `.notDetermined`, the coordinator calls a `permissionDelegate` hook whose implementation is supplied by M5's UI layer (the coordinator itself does **not** present a sheet — responsibility split: coordinator decides *when* to prompt, M5 decides *how*). When denied, `OSNotifier.post` is a no-op but the inbox + Dock badge still update (DEC-5). The Dock badge is an unread count irrespective of OS-banner mute (DEC-13). Click handling routes through `DeeplinkRouter` (already exists per architecture §URL scheme; if not, M4 adds a placeholder that logs and is completed later by a C2/C4 PR). Everything is unit-testable via protocol-backed mocks for `OSNotifier`, `DockBadger`, and `NotificationPermissionDelegate`.

**Tracker lifecycle.** Trackers are owned by M2's `TrackerRegistry`; `NotificationCoordinator` does not create them. At launch, the app shell calls `registry.bootstrap()` *before* wiring the coordinator, so that any agent-labelled Panel present from a prior session already has its tracker when the first envelope arrives. For each bootstrap-created tracker, the coordinator is invoked with `onAgentPanelCreated(trackerID)` exactly once during startup so that the permission prompt fires iff needed; an `alreadyPrompted: Set<PanelID>` guard on the coordinator prevents re-prompting for Panels added later in the same session. This resolves the prior-session-restart ambiguity.

**Work.** Under `apps/mac/touch-code/Notifications/`:

- `OSNotifier.swift`:

      protocol OSNotifier: Sendable {
        func currentAuthorizationStatus() async -> AuthorizationStatus
        func requestAuthorization() async -> AuthorizationStatus
        func post(_ notification: AgentNotification) async
      }

      enum AuthorizationStatus: String, Sendable { case notDetermined, authorized, denied, provisional }

      @MainActor
      final class UserNotificationsOSNotifier: OSNotifier {
        init(bundleIdentifier: String)
        // Wraps UNUserNotificationCenter.current()
      }

  `post` constructs a `UNMutableNotificationContent` with `title`, `body`, `threadIdentifier = notification.panelID.raw.uuidString` (per-Panel grouping — c6 design), `categoryIdentifier = notification.kind.rawValue`, `userInfo["deeplink"] = "touch-code://panel/\(notification.panelID)/focus"`. Action categories (`completed` / `blockedOnInput` / `crashed`) are registered once at init with a `Focus Panel` default action and a `Dismiss` button.

- `DockBadger.swift`:

      protocol DockBadger: Sendable {
        func setUnreadCount(_ n: Int)
      }

      @MainActor
      final class AppKitDockBadger: DockBadger {
        func setUnreadCount(_ n: Int) {
          NSApp.dockTile.badgeLabel = n == 0 ? nil : (n > 99 ? "99+" : String(n))
        }
      }

- `NotificationCoordinator.swift`:

      @MainActor
      final class NotificationCoordinator {
        init(
          inbox: InboxStore,
          badger: DockBadger,
          osNotifier: OSNotifier,
          muting: MuteSettings,
          registry: TrackerRegistry,
          permissionDelegate: NotificationPermissionDelegate
        )

        /// Subscribe to the router's transitions and the inbox's unread publisher.
        /// Called once at app launch by the app shell, AFTER registry.bootstrap().
        func bind(to transitions: AsyncStream<AgentStateTransition>) async

        /// Invoked by app shell when TrackerRegistry creates a new tracker — both during
        /// bootstrap (one call per pre-existing agent Panel) and later for dynamically
        /// added Panels. Idempotent: a second call for the same PanelID is a no-op.
        /// First eligible call after install prompts via permissionDelegate iff .notDetermined.
        func onAgentPanelCreated(_ panelID: PanelID) async
      }

      /// Supplied by M5's UI layer. M4 ships a no-op default (NullPermissionDelegate)
      /// that auto-calls osNotifier.requestAuthorization() with no pre-prompt sheet —
      /// acceptable because M4 runs in development where the system prompt is fine.
      /// M5 swaps in the SwiftUI pre-prompt sheet.
      @MainActor
      protocol NotificationPermissionDelegate: AnyObject {
        func presentPrompt() async -> PermissionDecision   // .continue / .notNow / .never
      }

  `bind` runs two concurrent loops under `async let`: one consumes `transitions`, applies muting, appends to `inbox`, calls `osNotifier.post`; the other consumes `inbox.unreadPublisher` and calls `badger.setUnreadCount`. The Dock badge count is recomputed from the inbox every time, so it is authoritative across CLI + UI mutations (DEC-13, R8 mitigation).

  `onAgentPanelCreated` consults `settings.json#notifications.auth_status` plus the `alreadyPrompted` in-memory set; if still `.notDetermined` and the "Never" flag is not set, calls `permissionDelegate.presentPrompt()` and branches on the result (`.continue` → `osNotifier.requestAuthorization` → cache; `.notNow` → 24h cool-down timestamp; `.never` → `settings.notifications.neverPrompt = true`). The delegate itself is M5-owned.

- `MuteSettings` (already declared in M1 under `TouchCodeCore/Notifications/`) is persisted by a new **`SettingsStore`** that M4 introduces under `apps/mac/touch-code/Runtime/SettingsStore.swift` — a `@MainActor` wrapper around `~/.config/touch-code/settings.json` following the same `AtomicFileStore` + version-gate pattern as `CatalogStore`. If a `SettingsStore` already exists in the repo by the time this milestone runs (check `apps/mac/touch-code/Runtime/` and `apps/mac/touch-code/Settings/` first), adopt it and record the choice in Decision Log; otherwise this milestone owns the file. The CLI `tc notifications mute` verb (M6) mutates through the same store. The store is authoritative for `notifications.*` keys; no other component writes them.

Wire into `TouchCodeApp.swift` / `Runtime.swift`: the app shell constructs the C6 stack at launch in this order:

    1. let settings = try SettingsStore.load()
    2. let inbox = try InboxStore().load()
    3. let rules = try RuleStore(hookWriter: adapter).loadAndMaterialise()
    4. let registry = TrackerRegistry(hierarchy: hierarchy, idleThreshold: rules.idleThresholdSeconds, clock: ContinuousClock())
    5. registry.bootstrap()                                   // creates trackers for pre-existing agent panels
    6. registry.subscribeToHierarchyEvents()                  // watches for future changes
    7. let router = DetectionRouter(rules: rules, registry: registry, renderer: try TemplateRenderer(rules: rules))
    8. hookDispatcher.register(subscriber: router, for: "__touch-code/internal:notifications:")
    9. let coordinator = NotificationCoordinator(inbox: inbox, badger: AppKitDockBadger(), osNotifier: UserNotificationsOSNotifier(bundleIdentifier: Bundle.main.bundleIdentifier!), muting: settings.notifications, registry: registry, permissionDelegate: NullPermissionDelegate())
   10. for tracker in registry.allTrackers { await coordinator.onAgentPanelCreated(tracker.panelID) }   // restart-time permission sweep (no-op if already prompted)
   11. Task { await coordinator.bind(to: router.transitions) }

Step 10 is the explicit restart-with-pre-existing-agents bootstrap the reviewer called out: every tracker produced by step 5 goes through the coordinator's idempotent `onAgentPanelCreated` path, so the first-run permission prompt fires even if the app previously crashed during onboarding. Subsequent Panels added during the session go through the `TrackerRegistry → coordinator` path via `subscribeToHierarchyEvents` (the registry exposes an `AsyncStream<PanelID>` of newly-created tracker ids that the coordinator consumes).

Under `apps/mac/touch-code/Tests/NotificationsTests/`:

- `NotificationCoordinatorTests.swift` — the integration test suite. Scenarios:
  1. Permission `.authorized`, unmuted rule → `InboxStore.append` called once, `OSNotifier.post` called once, `DockBadger.setUnreadCount(1)` called.
  2. Permission `.denied`, unmuted rule → append + badge(1) called, post **not** called.
  3. Permission `.authorized`, rule in `mutedRuleIDs` → append + badge(1) called (DEC-13), post **not** called.
  4. `kind: .idle` with default `surfaceIdle: false` → append + badge(1), post not called (DEC-7).
  5. `redactBodies: true` → the `body` passed to `osNotifier.post` is literally `"(redacted)"` while the body stored in the inbox is the original template render (DEC-8).
  6. Dismiss one of two unread notifications → `badger.setUnreadCount(1)` called with the new count.
  7. `onAgentPanelCreated` on a fresh `.notDetermined` status calls `permissionDelegate.presentPrompt`; with a stub delegate returning `.continue`, `osNotifier.requestAuthorization` is called once. A second call for the same `PanelID` does not re-invoke the delegate. A call for a different `PanelID` in the same session does not re-prompt (the `.denied`/`.authorized` cache persists). A fresh tracker created by `registry.bootstrap()` at restart flows through the same idempotent path: `onAgentPanelCreated` is called once per bootstrap tracker in step 10 of the wiring sequence; if the status was already `.denied`, no prompt.

  Mocks: `MockOSNotifier` records every call and returns a configurable `AuthorizationStatus`; `MockDockBadger` records every `setUnreadCount` argument; `StubPermissionDelegate` returns a scripted `PermissionDecision`.

**Observable acceptance.** `xcodebuild test -scheme touch-codeTests -only-testing:touch-codeTests/NotificationsTests/NotificationCoordinatorTests` green with 7 scenarios. A manual run: launch the app, open a Panel via `HierarchyManager`, `tc label <panel-id> --agent claude` (needs C4 M1+; if not yet shipped, insert a debug-only shim on `TouchCodeApp.init`), type the sentinel `::touchcode:agent-complete <panel-id>` into the Panel, and observe (a) an OS banner titled "Claude finished", (b) the Dock icon gaining a red `1` badge, (c) a new row in the inbox (M5 makes the inbox visible; M4 can verify via LLDB or a `tc notifications list` debug shim).

**Note.** M4 ships `NullPermissionDelegate` — a no-op fallback that calls `osNotifier.requestAuthorization` directly (the system prompt is acceptable in dev builds). M5 swaps in the real SwiftUI pre-prompt sheet (Continue / Not now / Never). This keeps M4's shipping surface headless-testable and defers every pixel to M5.

**Expected commits.**

- `feat(notifications): OSNotifier + DockBadger adapters with mock-friendly protocols`
- `feat(notifications): NotificationCoordinator fan-out with muting policy`
- `feat(notifications): first-run permission flow on agent-Panel creation`

### Milestone 5: InboxSidebar UI + Settings toggles

**Goal after this milestone.** Pressing ⌘⇧N (or clicking a toolbar bell icon) reveals a 320pt right-side sidebar listing every `AgentNotification` newest-first. Filter chips (All / Unread / Waiting / Completed / Crashed) reshape the list. Swipe-left on a row reveals **Dismiss**; double-click on a row marks read and deeplinks to the originating Panel. A "Clear all" header action exists. Empty state reads "No agent pings. Nice." A Settings pane row toggles each of `enabled`, `badgeEnabled`, `surfaceIdle`, `redactBodies`, and offers a "Mute this rule" secondary action on every inbox row that populates `mutedRuleIDs`.

**Work.** Under `apps/mac/touch-code/Notifications/Views/`:

- `InboxSidebar.swift` — the top-level SwiftUI view. Takes an `@ObservedObject` / `@Bindable` `InboxViewModel`. `HStack` with a 320pt trailing panel animated via `transition(.move(edge: .trailing))`. Filter chips as a `Picker(.segmented)` bound to an `@State filter: InboxFilter`. Empty state when filtered list is empty. The sidebar is rooted in `MainView.swift` as an overlay controlled by a new TCA feature `InboxFeature` (matches the rest of the app flow state — architecture §State Management).
- `InboxRow.swift` — row layout: `AgentAvatar` (32pt circle with first letter uppercase of `agent`), `VStack(title, body, provenance)`, state chip on the right, relative time. Hover reveals trailing action buttons (`Focus Panel`, `Dismiss`). Swipe-left gesture reveals Dismiss via `.swipeActions(edge: .trailing, allowsFullSwipe: true)`.
- `InboxFeature.swift` — TCA reducer: `Action.toggleSidebar`, `.filterChanged(InboxFilter)`, `.rowTapped(AgentNotification.ID)`, `.rowSwiped(AgentNotification.ID)`, `.clearAllTapped`, `.muteRuleTapped(ruleID: String)`. Each action delegates to `InboxClient` (a new `DependencyKey` wrapping `InboxStore` for TCA consumption). Matches the existing client pattern used by `HierarchyClient` / `TerminalClient`.
- `InboxClient.swift` — thin TCA adapter: `markRead`, `dismiss`, `clearAll`, `muteRule`, `observeInbox() -> AsyncStream<NotificationInbox>`. Implementation delegates to `InboxStore` on the MainActor.
- `NotificationsSettingsView.swift` — a SwiftUI section for a forthcoming Settings feature (or standalone, depending on repo state at the time). Toggle rows for the five MuteSettings flags; an "Open System Settings (Notifications)" button when the permission status is `.denied` (opens `x-apple.systempreferences:com.apple.preference.notifications?id=<bundle-id>`).
- `NotificationPermissionSheet.swift` — the full pre-prompt surface (Continue / Not now / Never) that M4 deferred. A view-model `NotificationPermissionViewModel: NotificationPermissionDelegate` implements `presentPrompt() async` by driving a SwiftUI `.sheet` bound to a `@Published var isPresented: Bool`; the `async` method resolves when the user taps one of the three buttons. M5 replaces `NullPermissionDelegate` with this view-model in the app-shell wiring (step 9 of M4's sequence).
- `MainView.swift` — add a top-right toolbar bell icon with a badge count reading from `InboxViewModel.unreadCount`; clicking toggles the sidebar. Add a ⌘⇧N keyboard shortcut bound to the same toggle action.

Under `apps/mac/touch-code/Tests/NotificationsTests/`:

- `InboxFilterTests.swift` — pure-value tests of the filter logic: given a fixed 7-notification inbox, each filter returns the expected subset.
- (SwiftUI snapshot tests are nice-to-have but deferred to a later UI-test-harness task; explicit non-goal for M5.)

**Observable acceptance.** Launch the app; press ⌘⇧N — the sidebar appears. Trigger three notifications of different kinds via the M4 test harness — they appear newest-first with correct provenance strings. Click "Waiting" — only `blockedOnInput` rows show. Double-click a row — the sidebar closes and the originating Panel gains focus (or, if the Panel is gone, a toast reads "Panel closed; inbox entry remains."). Swipe-left on a row → Dismiss action appears; activating it removes the row from the active view and the inbox file (verify with `cat ~/.config/touch-code/notifications.json`).

**Expected commits.**

- `feat(notifications-ui): InboxSidebar SwiftUI surface + InboxRow`
- `feat(notifications-ui): InboxFeature TCA reducer + InboxClient dependency`
- `feat(notifications-ui): Settings toggles + System Settings deeplink`

### Milestone 6: Default detection rules + Stop-hook shims

**Goal after this milestone.** `detection-rules.json` ships with sensible defaults for Claude Code, Codex CLI, and aider, installed to `~/.config/touch-code/` on first run if the file does not already exist. `touch-code-skill/` (the `touch-code-skill` companion package — co-located with the app per architecture §Future peer directories) gains a `shims/` directory containing `claude-stop-hook.sh`, `codex-complete-hook.sh`, `aider-idle-hook.sh`. `tc notifications rules reload` reloads the file and re-materialises C3 subscriptions without restarting the app. Smoke tests exercise the full path: hook shim → pty sentinel → C3 subscription → C6 router → tracker → `AgentNotification`.

**Work.**

- Under `apps/mac/touch-code/Notifications/Defaults/`, create `DefaultRules.swift` — the exact JSON from c6 design §Detection Rule DSL bundled as a string resource. On first launch, if `detection-rules.json` does not exist, write the defaults via `AtomicFileStore.write`. Subsequent launches never overwrite the user's file.
- Under `touch-code-skill/shims/` (new directory; if `touch-code-skill/` does not yet exist at this point, M6 creates it following the reference layout at `/Users/wanggang/dev/opensource/supaterm-skills/`), create:
  - `claude-stop-hook.sh`:

        #!/bin/sh
        # Installed as Claude Code's Stop hook (~/.claude/settings.json):
        #   { "hooks": { "Stop": [{ "type": "command", "command": "~/.config/touch-code/shims/claude-stop-hook.sh" }] } }
        printf '\n::touchcode:agent-complete %s\n' "${TOUCH_CODE_PANEL_ID:-unknown}"

  - `codex-complete-hook.sh` — same pattern, different agent name in the sentinel suffix so `detection-rules.json` can discriminate if we ever need per-agent completion copy (v1 uses the same regex for all three).
  - `aider-idle-hook.sh` — a light wrapper that writes `::touchcode:agent-idle` when aider returns to its `>` prompt, bypassing the pty-tail regex for users who run aider under `tmux` where tail-matching is less reliable.
- Under `apps/mac/touch-code/Notifications/`, extend `RuleStore` with `reloadAndRematerialise() async throws`. **App-internal path lands in this milestone**: `NotificationCoordinator` exposes a public `reloadRules()` method that calls `RuleStore.reloadAndRematerialise()` and re-registers the sentinel prefix subscribers. The CLI verb `tc notifications rules reload` is a **follow-up PR on the C3+C4 exec plan (0003)** because the `system.*` namespace and the CLI surface for `notifications` belong to C4 per c6 DEC-10 — not blocking on C4 keeps C6 shippable. Record the follow-up in Decision Log and file a tracking note on the 0003 plan. In the meantime, users reload by restarting the app (documented in M6's User-visible notes).
- Under `apps/mac/touch-code/Tests/NotificationsTests/`:
  - `DefaultRulesTests.swift` — parse the shipped JSON via `AgentDetectionRules.decode`; assert three rules present (`claude.*`, `codex.*`, `aider.*`); assert every rule's template renders against a hand-constructed envelope without throwing.
  - `ShimSmokeTest.swift` — a small XCTest that spawns `/bin/sh shims/claude-stop-hook.sh` with `TOUCH_CODE_PANEL_ID=abc` and captures stdout. Asserts stdout equals `"\n::touchcode:agent-complete abc\n"`. This proves the shim contract without needing Claude Code installed.

**Reload-without-file policy (decided now):** `RuleStore.reloadAndRematerialise()` — when invoked with `detection-rules.json` missing from disk — **regenerates the bundled defaults via `DefaultRules.installIfMissing(at:)` before re-loading**. Rationale: a user who deleted the file and hit reload is unambiguously asking for "get me back to a working state"; the alternative (return an error and leave the app rule-less) is worse UX and causes silent notification gaps. First-launch behaviour remains identical (defaults installed iff file missing). Users who genuinely want an empty rule set can write `{"version":1,"rules":[]}` to disk; reload preserves that file verbatim.

**Observable acceptance.** After `make mac-build && make mac-run-app`, inspect `~/.config/touch-code/detection-rules.json` — it contains the three default rules. Invoke `coordinator.reloadRules()` via LLDB (or a debug-only menu item under `MainView`) and confirm new rules are materialised. Install `shims/claude-stop-hook.sh` as Claude Code's Stop hook, run a short Claude session inside an agent-labelled Panel, end the session — OS banner fires within ≈1s of session end. Delete the rule file, call `coordinator.reloadRules()` — the app regenerates defaults and continues. (The `tc notifications rules reload` CLI verb ships as a follow-up PR on plan 0003; its absence does not gate this milestone.)

**Expected commits.**

- `feat(notifications): default detection rules for claude/codex/aider`
- `feat(skill): Stop-hook shim scripts for supported agents`
- `feat(notifications): app-internal reloadRules with regenerate-on-missing policy`

### Milestone 7: Integration tests + end-to-end flow

**Goal after this milestone.** A single XCTest case drives a real `HookDispatcher` (constructed in-process by C3's test utilities from 0003) with a mocked `UNUserNotificationCenter` and a `ManualClock`, installs a C6 rule, fires a synthetic `panel.output` event matching the rule, and asserts: (a) `AgentStateTracker.state` transitions `running → blockedOnInput`; (b) `InboxStore.inbox.notifications` gains one entry; (c) `MockOSNotifier.postedNotifications` has one entry with the expected title/body; (d) `MockDockBadger.lastUnreadCount == 1`. A second test drives the idle-timer path (advance the clock past 120s with no activity; assert `idle` transition). A third test drives the crash path (fake `.panelCrashed` envelope; assert `crashed` notification kind and tracker teardown).

**Work.** Under `apps/mac/touch-code/Tests/NotificationsTests/`:

- `EndToEndTests.swift` — assembles the full stack: real `AtomicFileStore`-backed `InboxStore` with a temp directory URL, real `DetectionRouter`, real `AgentStateTracker`, real `NotificationCoordinator`, mocked `OSNotifier` and `DockBadger`, and a real-but-headless `HookDispatcher` from C3's test support module. Three scenarios:
  1. `claudeBlockedOnInputTransitionsAndNotifies()` — install `claude.blocked_on_input` rule; fire `panel.outputMatch` envelope with `data.output = "Do you want to proceed?"`; assert the full chain.
  2. `idleTimerTransitions()` — install no output rules; tracker starts in `running`; advance `ManualClock` by 121 seconds; assert transition to `idle` and that `MockOSNotifier.postedNotifications` is empty (DEC-7 — idle muted by default).
  3. `crashDestroysTracker()` — fire `.panelCrashed` envelope; assert `MockOSNotifier` got one `crashed` notification; assert calling `.panelOutput` envelope for the same panel afterwards is a no-op (tracker torn down).

- `IntegrationTestSupport.swift` — shared helpers: `makeEnvelope(event:panelID:data:)`, `makeAgentLabelledPanel(agent:)`, `captureNotifications(from:)`.

If C3's test support module is not yet usable (test-side assembly of `HookDispatcher` without a live app shell), stub it with a minimal in-memory `HookDispatcher`-lookalike for these three tests. Record the choice in Decision Log.

**Observable acceptance.** `xcodebuild test -scheme touch-codeTests -only-testing:touch-codeTests/NotificationsTests/EndToEndTests` green with 3 scenarios each asserting `MockOSNotifier`, `MockDockBadger`, and `InboxStore` state. The full test suite (`xcodebuild test -scheme touch-code`) remains green.

**Expected commits.**

- `test(notifications): end-to-end flow asserting all three sinks`

## Concrete Steps

Run commands from the worktree root (`.claude/worktrees/design+c6-agent-notifications/`) unless stated otherwise.

Per-milestone bootstrap:

    # Once per milestone — regenerates Tuist project if targets changed
    make mac-generate

    # Build
    make mac-build

    # Run the app (M3 onwards, once GhosttyKit is green from 0002 M3)
    make mac-run-app

    # Lint
    make lint

Per-milestone test:

    # M1 — TouchCodeCore tests
    xcodebuild test -workspace apps/mac/TouchCode.xcworkspace \
      -scheme TouchCodeCore \
      -only-testing:TouchCodeCoreTests/AgentStateTests \
      -only-testing:TouchCodeCoreTests/AgentNotificationTests \
      -only-testing:TouchCodeCoreTests/NotificationInboxTests \
      -only-testing:TouchCodeCoreTests/AgentDetectionRulesTests \
      -only-testing:TouchCodeCoreTests/TemplateFieldTests \
      | xcbeautify

    # M2–M7 — app-hosted notifications tests
    xcodebuild test -workspace apps/mac/TouchCode.xcworkspace \
      -scheme touch-code \
      -only-testing:touch-codeTests/NotificationsTests \
      | xcbeautify

Expected M1 transcript tail:

    Test Suite 'All tests' passed at ...
    Executed <n> tests, with 0 failures (0 unexpected) in 0.0XX (0.XXX) seconds

Where `<n>` equals the number of `func test…` methods added for that milestone (see the test-file listings per milestone above). The exact count is whatever the listed functions sum to; the transcript is green iff failures is 0.

Per-milestone commit cadence: one small commit per sub-task per CLAUDE.md's commit-after-each-small-feature memory. Use `/commit` to draft messages; prefix `feat(core):`, `feat(notifications):`, `feat(notifications-ui):`, `feat(cli):`, `feat(skill):`, `test(notifications):`, or `docs(plan):` as the types already present in this repo's history.

Progress dashboard update after every milestone: edit the Progress section at the top of this file to flip `[ ] Mx — …` to `[x] Mx — … — YYYY-MM-DD`, append a milestone-complete block to Outcomes & Retrospective (mirroring 0002's M1/M2 blocks), and append any surprises to Decision Log. Commit as `docs(plan): mark C6 Mx complete`.

## Validation and Acceptance

The plan is complete when all seven milestones are green and the following manual checks pass:

1. **Happy path.** Install `shims/claude-stop-hook.sh` as Claude Code's Stop hook. Launch the app; open a Panel; run `tc label <panel-id> --agent claude`; start a Claude Code session; let it complete. Within ≤ 2 seconds: an OS banner titled "Claude finished" appears; the Dock icon shows `1`; opening the inbox (⌘⇧N) shows the new row at the top.
2. **Provenance click.** Click the OS banner body or "Focus Panel" action. The app comes to front; the Panel that ran Claude gains focus; the inbox row marks read; the Dock badge clears to `0` (assuming only one unread).
3. **Permission denial fallback.** Fresh install; on first agent-Panel creation, tap **Don't Allow** in the system permission sheet. Repeat step 1 — the OS banner does **not** appear, but the Dock badge still flips to `1` and the inbox gains the row.
4. **Rule reload.** Edit `~/.config/touch-code/detection-rules.json` and add a new rule for agent `custom-bot`. Run `tc notifications rules reload`. Run a panel labelled `agent:custom-bot` and feed a matching sentinel — the rule fires without restarting the app.
5. **7-day sweep.** Manually edit an inbox entry's `dismissedAt` to 8 days ago; restart the app; assert the entry is gone from the file.
6. **Idle transition (muted).** Open a Panel labelled `agent:claude`, wait > 120 seconds with no output. The tracker's `state` is `idle` (verify via LLDB or a `tc notifications list --verbose` debug view once C4 ships); no OS banner fires (DEC-7).
7. **Crash path.** Kill the agent process via `kill -9` from another Panel. A `crashed` notification appears; the tracker is torn down (subsequent output for that Panel does not fire further notifications).
8. **Unit + integration suites.** `xcodebuild test -scheme TouchCodeCore` and `xcodebuild test -scheme touch-code` are both green. Every test file listed per milestone exists and contributes `func test…` methods; failures is 0 across the suite.

## Idempotence and Recovery

- Re-running `make mac-generate` after a milestone is idempotent (Tuist-driven).
- Running a milestone's tests multiple times is idempotent.
- The shipped defaults in `DefaultRules.swift` only write to disk if `~/.config/touch-code/detection-rules.json` does not exist — never overwrite user edits.
- Deleting `~/.config/touch-code/notifications.json` while the app is running triggers a re-read on next save; the file re-materialises with the live in-memory inbox at the next debounced write.
- A corrupt `notifications.json` is backed up to `notifications.json.broken-<ISO8601>` and replaced with `.empty` (mirrors `CatalogStore`). Users never lose the broken file.
- A corrupt `detection-rules.json` aborts load with a specific error (`RuleStoreError`) that `tc notifications rules reload` surfaces to the user's terminal; the app keeps running with the previously loaded rules until the file is fixed.
- The `claude-stop-hook.sh` / `codex-complete-hook.sh` / `aider-idle-hook.sh` scripts are self-contained one-liners — users can remove them at any time without app-side cleanup.

Rollback per milestone: `git revert <milestone commits>` is clean because each milestone is a contiguous block of commits and no milestone introduces schema migrations on other capabilities. Reverting M6 leaves users without defaults but does not brick existing installs (the app reads whatever rules file is present; absent file → empty rules).

## Artifacts and Notes

(None yet — will be filled as milestones complete; mirrors 0002's Outcomes pattern.)

## Risks

Implementation risks for this plan. Design-level risks already live in [docs/design-docs/c6-agent-notifications.md](../design-docs/c6-agent-notifications.md) §Risks (R1 through R11); the entries here are specific to building C6 under touch-code's current state.

- **R1 — Idle-timer precision across sleep/wake.** macOS power-nap / sleep freezes dispatch queues; an idle timer armed for 120 s before sleep fires immediately on wake, producing a spurious `.idle` transition for every tracked Panel at once. Mitigation: the tracker stores a `lastActivityAt: Date` on every envelope and on `override`; `idleTimer` fire compares `now - lastActivityAt < idleThreshold` and, if smaller than the threshold, re-arms instead of transitioning. A targeted XCTest in M2 advances `ManualClock` by an hour to simulate wake, feeds a fresh output envelope, asserts no spurious transition emits. Observability: `os.Logger` records timer rearm events at `.debug` so the behaviour is auditable under `Console.app`.
- **R2 — UN permission revoked mid-session.** A user can deny permission in System Settings while the app is running. Further `osNotifier.post` calls silently no-op, but the coordinator's cached `auth_status` becomes stale. Mitigation: subscribe to `NSApplication.didBecomeActiveNotification` and re-query `getNotificationSettings()` whenever the app returns to foreground, update `settings.notifications.auth_status`, and — if the status flipped to `.denied` — log a one-time `.info` entry. Inbox and Dock badge continue working (DEC-5). A targeted unit test in M4 verifies the re-query path with a mock `OSNotifier` returning different statuses across calls.
- **R3 — Rule-file corruption during hot-reload mid-match.** A user edits `detection-rules.json` to add a new rule, saves; between `RuleStore.reload()` read and the C3 dispatcher re-registering its compiled regexes, an envelope arrives and its old rule id is no longer valid. Mitigation: `reloadAndRematerialise()` performs the C3 `hooks.json` save *first* and the in-memory rule-table swap *second*; `DetectionRouter.handle` tolerates an envelope whose sentinel suffix matches no current rule by logging at `.info` and dropping the envelope (no crash, no misattributed notification). Additionally, a file-system watch on `detection-rules.json` is left out of v1 — reload is explicit via `coordinator.reloadRules()` — so there is no background race with an in-flight match.
- **R4 — Sentinel token leakage visible to the user.** The `::touchcode:agent-complete <panel-id>` line written by the Stop shim appears in the Panel's scrollback and in any clipboard copy the user makes. Mitigation: accepted trade-off in v1 per c6 DEC-14 / c6 R10; documented in the shim script comments so users know what the line is. A future variant can wrap the token in ANSI `ESC [ ? 2026 h … ESC [ ? 2026 l` bracketed-paste sequences (or a dedicated DECSTBM mode) to suppress visibility at the terminal level; tracked as a post-v1 enhancement, not a blocker.
- **R5 — C3 exec plan 0003 milestone-ordering skew.** C6 M1 depends on the `HookEvent` / `HookEnvelope` / `HookEventData` / `HookSubscription` / `Panel.labels` types landing in `TouchCodeCore` (C3 0003 M1). C6 M2 depends on `HookDispatcher.register(subscriber:for:)` and `HookConfigStore.load()/save(_:)` (C3 0003 M2 or M3). If C3 0003 slips, C6 blocks at exactly those boundaries. Mitigation: each milestone states its C3 dependency in Observable Acceptance; if a milestone is blocked, the Decision Log records the blocked-on-SHA and the team pulls C3 forward rather than shipping a stub that has to be reverted.
- **R6 — `NSApp.dockTile` unavailable in unit-test processes.** `AppKitDockBadger` touches `NSApp`, which requires a foreground bundled app. Headless test processes will crash on first call. Mitigation: the protocol-backed `DockBadger` keeps `MockDockBadger` tests free of AppKit; the real `AppKitDockBadger` is only constructed in the app-shell wiring step, not in tests. Integration test (M7) verifies via the mock; the real adapter is exercised only by manual run.
- **R7 — Read-modify-write race on `hooks.json`.** Two processes calling `HookConfigStore.save(_:)` at nearly the same time (e.g. `tc hook install` plus `RuleStore.reloadAndRematerialise` concurrently) can clobber each other's unrelated edits between load and save. Mitigation: `save(_:)` throws on stale-version conflict (C3 DEC-16 policy); `RuleStore` retries once with a fresh load; if the retry also fails, returns `RuleStoreError.hooksFileBusy(path:)` and leaves the in-memory rules unchanged. A targeted unit test in M2 with a fake writer that flips the "changed between load and save" flag once verifies the retry path.

## Interfaces and Dependencies

The following interfaces must exist at plan completion. Paths are worktree-relative.

### `apps/mac/TouchCodeCore/Notifications/`

- `AgentState.swift` — `public enum AgentState: String, Codable, Sendable { case running, completed, blockedOnInput, idle }`.
- `AgentStateTransition.swift` — `public struct AgentStateTransition: Codable, Equatable, Sendable { public let panelID: PanelID; public let from, to: AgentState; public let at: Date; public let trigger: Trigger; public enum Trigger: Codable, Equatable, Sendable { case rule(id: String), envelope(event: HookEvent), idleTimer(seconds: TimeInterval), userOverride } }`.
- `AgentNotification.swift` — `public struct AgentNotification: Codable, Equatable, Sendable, Identifiable { public let id: UUID; public let panelID: PanelID; public let agent: String; public let kind: Kind; public let title, body: String; public let createdAt: Date; public var readAt, dismissedAt: Date?; public var isUnread: Bool { readAt == nil && dismissedAt == nil }; public enum Kind: String, Codable, Sendable { case completed, blockedOnInput, idle, crashed } }`.
- `NotificationInbox.swift` — `public struct NotificationInbox: Codable, Equatable, Sendable { public static let currentVersion = 1; public var version: Int; public var notifications: [AgentNotification]; public static let empty: NotificationInbox; public enum DecodingIssue: Error, Equatable { case unsupportedVersion(Int) } }`.
- `AgentDetectionRules.swift` — top-level `public struct AgentDetectionRules: Codable, Sendable { … }` with `Rule`, `AppliesWhen`, `Match(Target)` nested types as sketched in c6 design §API Design.
- `MuteSettings.swift` — `public struct MuteSettings: Codable, Sendable { public var enabled, badgeEnabled, surfaceIdle, redactBodies: Bool; public var mutedRuleIDs: Set<String>; public var mutedPanelIDs: Set<PanelID> }`.
- `TemplateField.swift` — `public enum TemplateField: String, CaseIterable, Sendable { … ; static func validPaths(for event: HookEvent) -> Set<TemplateField> }`.

### `apps/mac/touch-code/Notifications/`

- `DetectionRouter.swift` — `@MainActor final class DetectionRouter: InternalHookSubscriber`. Public surface: `init(rules: AgentDetectionRules, registry: TrackerRegistry, renderer: TemplateRenderer)`, `nonisolated func handle(envelope: HookEnvelope) async`, `var transitions: AsyncStream<AgentStateTransition> { get }`.
- `TrackerRegistry.swift` — `@MainActor final class TrackerRegistry`. Public surface: `init(hierarchy: HierarchyManager, idleThreshold: TimeInterval, clock: any Clock<Duration>)`, `func bootstrap()`, `func subscribeToHierarchyEvents()`, `func tracker(for panelID: PanelID?) -> AgentStateTracker?`, `var allTrackers: [AgentStateTracker] { get }`, `var trackerCreations: AsyncStream<PanelID> { get }`. Single owner of tracker lifecycle across the whole plan.
- `AgentStateTracker.swift` — `@MainActor @Observable final class AgentStateTracker`. Public surface: `init(panelID: PanelID, idleThreshold: TimeInterval, clock: any Clock<Duration>)`, `func ingest(envelope: HookEnvelope, ruleID: String?, rendered: (title: String, body: String)?) -> AgentStateTransition?`, `func override(to: AgentState)`, `func teardown()`.
- `RuleStore.swift` — `@MainActor final class RuleStore`. Public surface: `init(fileURL: URL, hookWriter: HookConfigWriting)`, `func loadAndMaterialise() throws -> AgentDetectionRules`, `func reload() throws -> AgentDetectionRules`, `func reloadAndRematerialise() async throws -> AgentDetectionRules` (M6; regenerates bundled defaults if file is missing).
- `TemplateRenderer.swift` — `struct TemplateRenderer { init(rules: AgentDetectionRules) throws; func render(template: String, for envelope: HookEnvelope, transition: AgentStateTransition) -> String }`.
- `InboxStore.swift` — `@MainActor final class InboxStore`. Public surface: `init(fileURL: URL, clock: any Clock<Duration>)`, `func load() throws -> NotificationInbox`, `func append(_ notification: AgentNotification)`, `func markRead(_ ids: [UUID])`, `func dismiss(_ ids: [UUID])`, `func clearAll()`, `func saveNow() throws`, `var unreadCount: Int { get }`, `var unreadPublisher: AsyncStream<Int> { get }`.
- `NotificationCoordinator.swift` — `@MainActor final class NotificationCoordinator`. Public surface: `init(inbox: InboxStore, badger: DockBadger, osNotifier: OSNotifier, muting: MuteSettings, registry: TrackerRegistry, permissionDelegate: NotificationPermissionDelegate)`, `func bind(to transitions: AsyncStream<AgentStateTransition>) async`, `func onAgentPanelCreated(_ panelID: PanelID) async`, `func reloadRules() async throws`.
- `NotificationPermissionDelegate` protocol (same file or `Permissions/`): `@MainActor protocol NotificationPermissionDelegate: AnyObject { func presentPrompt() async -> PermissionDecision }` with `enum PermissionDecision: Sendable { case `continue`, notNow, never }`. M4 ships `NullPermissionDelegate` (no-op, calls `requestAuthorization` directly); M5 ships `NotificationPermissionViewModel` backed by a SwiftUI sheet.
- `OSNotifier.swift` — `protocol OSNotifier: Sendable { func currentAuthorizationStatus() async -> AuthorizationStatus; func requestAuthorization() async -> AuthorizationStatus; func post(_ notification: AgentNotification) async }` + `@MainActor final class UserNotificationsOSNotifier: OSNotifier`.
- `DockBadger.swift` — `protocol DockBadger: Sendable { func setUnreadCount(_ n: Int) }` + `@MainActor final class AppKitDockBadger: DockBadger`.
- `ConfigPaths.swift` — `enum ConfigPaths` with two computed URLs for `notifications.json` and `detection-rules.json` under `~/.config/touch-code/`.
- `Bridging/HookConfigWriting.swift` — single home. `@MainActor protocol HookConfigWriting { func load() throws -> HookConfig; func save(_ config: HookConfig) throws }` + `HookConfigStoreAdapter` delegating to C3's `HookConfigStore` using only its existing `load()` / `save(_:)` API + `FakeHookConfigWriter` for tests.
- `Views/InboxSidebar.swift`, `Views/InboxRow.swift`, `Views/NotificationsSettingsView.swift`, `Views/NotificationPermissionSheet.swift`, `InboxFeature.swift`, `InboxClient.swift`, `InboxViewModel.swift`, `NotificationPermissionViewModel.swift` — the SwiftUI + TCA surface for M5.
- `SettingsStore.swift` (M4, under `apps/mac/touch-code/Runtime/`) — `@MainActor final class SettingsStore` owning `~/.config/touch-code/settings.json`. Authoritative for `notifications.*` keys; mutated by `NotificationCoordinator` (`muted_rule_ids`, `auth_status`, `neverPrompt`, cool-down timestamp) and by the eventual `tc notifications mute` CLI verb (follow-up on 0003).

### `apps/mac/touch-code/Notifications/Defaults/`

- `DefaultRules.swift` — `enum DefaultRules { static let json: String; static func installIfMissing(at url: URL) throws }` — used by M6 and the app launch path.

### `touch-code-skill/shims/`

- `claude-stop-hook.sh`, `codex-complete-hook.sh`, `aider-idle-hook.sh` — one-line shell scripts per M6.

### External dependencies (from C3 exec plan 0003)

- `public protocol InternalHookSubscriber: AnyObject, Sendable { func handle(envelope: HookEnvelope) async }` — from C3 design DEC-16.
- `extension HookDispatcher { func register(subscriber: InternalHookSubscriber, for prefix: String) throws; func unregister(prefix: String) }` — called once by the app shell at launch: `hookDispatcher.register(subscriber: detectionRouter, for: "__touch-code/internal:notifications:")`.
- `HookConfigStore` (C3-owned) exposes only its existing `load() throws -> HookConfig` and `save(_: HookConfig) throws` methods — **C6 does not require a new upsert API from C3.** The `HookConfigStoreAdapter` in `Bridging/HookConfigWriting.swift` performs read-modify-write atomically over those two methods. This is recorded as the chosen approach in the Decision Log at M2 implementation time so no cross-plan coordination is needed with 0003.
- `HookEvent`, `HookEnvelope`, `HookEventData`, `HookSubscription` types (added to `TouchCodeCore` by C3 exec plan 0003 M1).
- `Panel.labels: Set<String>` (added by C3 D10, implemented in C3 exec plan 0003 M1).
- `HierarchyManager` event stream for `onPanelCreated` / `onPanelRemoved` / `onPanelLabelsChanged` (if not already exposed by 0002, M2 of this plan adds it — single-owner principle: the stream is emitted from `HierarchyManager` and read-only for subscribers). Record in Decision Log at implementation time.

### Test dependencies

- `Clock<Duration>` abstraction for idle-timer determinism. If `swift-clocks` is not already a test dep, roll a local `ManualClock` (≈20 lines) under `apps/mac/touch-code/Tests/NotificationsTests/Support/ManualClock.swift`.
- A minimal `FakeHookConfigWriter: HookConfigWriting` recording every upsert; used by `RuleStoreTests` so tests do not write `hooks.json` on disk.
- `MockOSNotifier` and `MockDockBadger` under `apps/mac/touch-code/Tests/NotificationsTests/Support/`.
