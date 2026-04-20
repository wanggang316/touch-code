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
- [ ] M2 — `touch-code/Notifications/` module: DetectionRouter (InternalHookSubscriber impl), AgentStateTracker (4-state FSM), RuleStore, TemplateRenderer
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

**Observable acceptance.** `xcodebuild test -scheme TouchCodeCore` reports N new passing tests (N ≈ 25). `grep -R 'import AppKit\|import SwiftUI\|import UserNotifications\|import GhosttyKit' apps/mac/TouchCodeCore` returns no matches. `make lint` is clean.

**Expected commits.**

- `feat(core): agent-notification domain types (AgentState, AgentNotification, NotificationInbox)`
- `feat(core): agent-detection rule types + TemplateField enumerator`

### Milestone 2: touch-code/Notifications — DetectionRouter, AgentStateTracker, RuleStore, TemplateRenderer

**Goal after this milestone.** The new in-app module `touch-code/Notifications/` exists. A `DetectionRouter` implements C3's `InternalHookSubscriber` protocol; given a `HookEnvelope` with a `__touch-code/internal:notifications:<rule-id>` sentinel, it looks up the rule, renders its template, and emits an `AgentStateTransition` through an `AsyncStream`. An `AgentStateTracker` maintains the 4-state FSM per Panel using the exact transition table from c6 design §API Design. A `RuleStore` reads `detection-rules.json`, validates every rule (schema, regex compilation, template-field-path set), and materialises each rule as a C3 `HookSubscription` written to `hooks.json`. A `TemplateRenderer` handles `{field}` / `| filter[: arg]` with unknown-field rejection at load time. Everything is unit-testable with a fake envelope feed.

This milestone does **not** yet touch `UNUserNotificationCenter`, `NSApp.dockTile`, or disk-based inbox state. It stops at `AsyncStream<AgentStateTransition>`.

**Work.** Under `apps/mac/touch-code/Notifications/` (new subfolder), create:

- `DetectionRouter.swift`:

      @MainActor
      final class DetectionRouter: InternalHookSubscriber {
        init(rules: AgentDetectionRules, hierarchy: HierarchyManager, renderer: TemplateRenderer)

        /// C3 calls this on @MainActor per the sentinel-prefix route.
        nonisolated func handle(envelope: HookEnvelope) async

        /// Stream of classified transitions; subscribed by NotificationCoordinator in M4
        /// and by trackers registered through registerTracker(for:).
        var transitions: AsyncStream<AgentStateTransition> { get }

        func registerTracker(for panelID: PanelID, tracker: AgentStateTracker)
        func unregisterTracker(for panelID: PanelID)
      }

  `handle(envelope:)` (a) extracts the rule id by splitting the `HookSubscription.command` suffix, (b) looks up the rule, (c) checks the `AppliesWhen.panelLabelledAgent` / `panelID` filters C3's scope cannot express, (d) renders `title` and `body` via `TemplateRenderer`, (e) fetches the `AgentStateTracker` for the envelope's panel (creating one lazily if the panel carries a `agent:*` label and no tracker exists — M2 accepts this responsibility; M4 moves tracker lifecycle to `NotificationCoordinator` once `HierarchyManager` events are wired), (f) calls `tracker.ingest(envelope: envelope, ruleID: ruleID, rendered: (title, body))`, (g) forwards the transition the tracker emits to `transitions`.

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

  The `hookWriter` is injected (a protocol that wraps C3's `HookConfigStore`); in unit tests the fake writer records what subscriptions would have been written. Rule → HookSubscription translation: `event = .panelOutputMatch`, `matchPattern = <rule's regex or pipe-joined contains_any>`, `scope = .panelLabel("agent:\(rule.agent)")` (or `.panelID(rule.panelID)` when set), `command = "__touch-code/internal:notifications:\(rule.id)"`, `mode = .fireAndForget`, `timeoutSeconds = 1` (unused — the sentinel-prefix route short-circuits `ProcessHookExecutor`).

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

- `HookConfigWriting.swift` — the narrow protocol RuleStore uses to materialise subscriptions without importing `Hooks` internals. C3's `HookConfigStore` conforms to it (implementation lives in C3's module after C3 0003 lands; M2 ships a `FakeHookConfigWriter` that records writes for tests and a `HookConfigStoreAdapter` that delegates to C3 — both added under `touch-code/Notifications/Bridging/`).

Under `apps/mac/touch-code/Tests/NotificationsTests/` (new `.unitTests` target `touch-codeNotificationsTests` or extension of the existing `touch-codeTests`; decide at implementation based on Tuist ergonomics and record in Decision Log):

- `AgentStateTrackerTests.swift` — cover every cell of the 6 × 4 transition table from c6 design (6 input kinds × 4 from-states). Use a `TestClock` from `swift-clocks` (already a test-only dep in supacode; if it isn't available, roll a local `ManualClock: Clock<Duration>` — 20 lines). Assert: (a) self-transitions do not emit; (b) activity rearms the idle timer; (c) `.panelCrashed` emits `crashed` then tears down; (d) `override` never emits.
- `DetectionRouterTests.swift` — feed a fake `HookEnvelope` whose `HookSubscription.command` starts with the sentinel prefix; assert the correct rule is selected, `panelLabelledAgent` filter rejects non-matching panels, and the rendered title/body exactly match an expected string.
- `RuleStoreTests.swift` — happy path loads the shipped default rules (precursor of M6; stub with one inline rule for now); `missingMatch` / `unknownTemplateField` / `invalidRegex` all throw with the correct associated value. Fake `HookConfigWriting` captures the materialised subscriptions.
- `TemplateRendererTests.swift` — table-driven: `{agent}` renders literally; `{data.output | firstLine | truncate: 12}` works with multi-line UTF-8 (including grapheme clusters — `"👨‍👩‍👧‍👦 is one cluster"` truncated to 8 keeps the whole emoji); `{foo}` throws at init; `| default: "…"` kicks in when the value is empty.

**Observable acceptance.** `xcodebuild test -scheme touch-codeTests -only-testing:touch-codeTests/NotificationsTests` is all green with ≈ 35 new tests. A short smoke executable `touch-code-notif-smoke` (optional; throwaway) feeds a hand-constructed `HookEnvelope` to a `DetectionRouter` and prints the resulting `AgentStateTransition` — demonstrates the contract without running the app.

**Expected commits.**

- `feat(notifications): AgentStateTracker FSM + DetectionRouter scaffolding`
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

**Goal after this milestone.** `NotificationCoordinator` subscribes to `DetectionRouter.transitions`, applies muting policy, constructs `AgentNotification`s, and fans out to `InboxStore.append`, `DockBadger.setUnreadCount`, and `OSNotifier.post`. The macOS permission flow fires exactly once — on first agent-Panel creation after install, per DEC-4. When permission is `.notDetermined`, a pre-prompt sheet appears (with Continue / Not now / Never). When denied, `OSNotifier.post` is a no-op but the inbox + Dock badge still update (DEC-5). The Dock badge is an unread count irrespective of OS-banner mute (DEC-13). Click handling routes through `DeeplinkRouter` (already exists per architecture §URL scheme; if not, M4 adds a placeholder that logs and is completed later by a C2/C4 PR). Everything is unit-testable via protocol-backed mocks for `OSNotifier` and `DockBadger`.

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
          hierarchy: HierarchyManager
        )

        /// Subscribe to the router's transitions and the inbox's unread publisher.
        /// Called once at app launch by the app shell.
        func bind(to transitions: AsyncStream<AgentStateTransition>) async

        /// Invoked by app shell when a Panel labelled agent:* is created.
        /// First call after install prompts for UN permission iff .notDetermined.
        func onAgentPanelCreated(_ panelID: PanelID) async
      }

  `bind` runs two concurrent loops under `async let`: one consumes `transitions`, applies muting, appends to `inbox`, calls `osNotifier.post`; the other consumes `inbox.unreadPublisher` and calls `badger.setUnreadCount`. The Dock badge count is recomputed from the inbox every time, so it is authoritative across CLI + UI mutations (DEC-13, R8 mitigation).

  `onAgentPanelCreated` consults `settings.json#notifications.auth_status`; if `.notDetermined` and the "Never" flag is not set, show the pre-prompt sheet via a `NotificationPermissionSheet` SwiftUI surface (under `Notifications/Views/` — M5 moves it to the inbox UI code but M4 ships a minimal version). `Continue` calls `osNotifier.requestAuthorization`, caches the result. `Not now` sets a 24h cool-down timestamp. `Never` permanently sets `settings.notifications.neverPrompt = true`.

- `MuteSettings.swift` — a `struct MuteSettings: Codable, Sendable` with `mutedRuleIDs: Set<String>`, `mutedPanelIDs: Set<PanelID>`, `surfaceIdle: Bool`, `redactBodies: Bool`, `badgeEnabled: Bool`, `enabled: Bool` (global kill switch). Lives in `TouchCodeCore/Notifications/MuteSettings.swift` (to be importable by CLI for `tc notifications mute` later). M4 persists it as a fragment of `settings.json` via a small `SettingsStore` stub if none exists yet (if `settings.json` already has an owner in the repo by the time this milestone runs, adopt that owner's API and record the choice in Decision Log).

Wire into `TouchCodeApp.swift` / `Runtime.swift`: the app shell constructs the C6 stack at launch — `InboxStore.load()`, `RuleStore.loadAndMaterialise()`, `DetectionRouter(rules:)`, a `NotificationCoordinator(...)`, calls `coordinator.bind(to: router.transitions)`. `HierarchyManager.onPanelCreated(_ panel:)` (already present per M2 of 0002) gains a delegate callback that, when the Panel carries `agent:*` labels, invokes `coordinator.onAgentPanelCreated(panel.id)`. The C3 dispatcher (from its M3) is wired to route sentinel-prefix envelopes to `router.handle(envelope:)` via `hookDispatcher.register(subscriber: router, for: "__touch-code/internal:notifications:")`.

Under `apps/mac/touch-code/Tests/NotificationsTests/`:

- `NotificationCoordinatorTests.swift` — the integration test suite. Scenarios:
  1. Permission `.authorized`, unmuted rule → `InboxStore.append` called once, `OSNotifier.post` called once, `DockBadger.setUnreadCount(1)` called.
  2. Permission `.denied`, unmuted rule → append + badge(1) called, post **not** called.
  3. Permission `.authorized`, rule in `mutedRuleIDs` → append + badge(1) called (DEC-13), post **not** called.
  4. `kind: .idle` with default `surfaceIdle: false` → append + badge(1), post not called (DEC-7).
  5. `redactBodies: true` → the `body` passed to `osNotifier.post` is literally `"(redacted)"` while the body stored in the inbox is the original template render (DEC-8).
  6. Dismiss one of two unread notifications → `badger.setUnreadCount(1)` called with the new count.
  7. `onAgentPanelCreated` on a fresh `.notDetermined` status triggers `osNotifier.requestAuthorization`; a second call in the same app session does not re-prompt; status `.denied` does not re-prompt.

  Mocks: `MockOSNotifier` records every call and returns a configurable `AuthorizationStatus`; `MockDockBadger` records every `setUnreadCount` argument.

**Observable acceptance.** `xcodebuild test -scheme touch-codeTests -only-testing:touch-codeTests/NotificationsTests/NotificationCoordinatorTests` green with 7 scenarios. A manual run: launch the app, open a Panel via `HierarchyManager`, `tc label <panel-id> --agent claude` (needs C4 M1+; if not yet shipped, insert a debug-only shim on `TouchCodeApp.init`), type the sentinel `::touchcode:agent-complete <panel-id>` into the Panel, and observe (a) an OS banner titled "Claude finished", (b) the Dock icon gaining a red `1` badge, (c) a new row in the inbox (M5 makes the inbox visible; M4 can verify via LLDB or a `tc notifications list` debug shim).

**Known risk.** The pre-prompt sheet might need TCA integration if the settings / sheet infrastructure is TCA-owned by the time this milestone runs. If so, the sheet becomes a TCA `PresentationState` feature and M4 writes a small `NotificationPermissionFeature` reducer; the coordinator calls a TCA action rather than presenting directly. Record the chosen pattern in Decision Log.

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
- Under `apps/mac/touch-code/Notifications/`, extend `RuleStore` with `reloadAndRematerialise() async throws` and wire it into C4's `tc notifications rules reload` via the `system.*` namespace per c6 DEC-10. If C4's exec plan (0004, forthcoming) hasn't defined `system.notifications_rules_reload` yet, M6 defines the RPC shape in a follow-up PR against the C4 plan — record the dependency in Decision Log.
- Under `apps/mac/touch-code/Tests/NotificationsTests/`:
  - `DefaultRulesTests.swift` — parse the shipped JSON via `AgentDetectionRules.decode`; assert three rules present (`claude.*`, `codex.*`, `aider.*`); assert every rule's template renders against a hand-constructed envelope without throwing.
  - `ShimSmokeTest.swift` — a small XCTest that spawns `/bin/sh shims/claude-stop-hook.sh` with `TOUCH_CODE_PANEL_ID=abc` and captures stdout. Asserts stdout equals `"\n::touchcode:agent-complete abc\n"`. This proves the shim contract without needing Claude Code installed.

**Observable acceptance.** After `make mac-build && make mac-run-app`, inspect `~/.config/touch-code/detection-rules.json` — it contains the three default rules. `tc notifications rules reload` (from a Panel) returns success. Install `shims/claude-stop-hook.sh` as Claude Code's Stop hook, run a short Claude session inside an agent-labelled Panel, end the session — OS banner fires within ≈1s of session end. Delete the rule file and reload — the app reloads the bundled defaults on next launch (or on `tc notifications rules reload` — TBD policy; record in Decision Log, leaning towards: reloading without a file regenerates defaults for UX recovery).

**Expected commits.**

- `feat(notifications): default detection rules for claude/codex/aider`
- `feat(skill): Stop-hook shim scripts for supported agents`
- `feat(cli): tc notifications rules reload wired through system.*`

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
    Executed 25 tests, with 0 failures (0 unexpected) in 0.0XX (0.XXX) seconds

Expected M2 transcript tail:

    Executed 35 tests, with 0 failures (0 unexpected) in 0.0XX (0.XXX) seconds

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
8. **Unit + integration suites.** `xcodebuild test -scheme TouchCodeCore` and `xcodebuild test -scheme touch-code` are both green with ≥ 60 new tests added across the plan.

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

- `DetectionRouter.swift` — `@MainActor final class DetectionRouter: InternalHookSubscriber`. Public surface: `init(rules: AgentDetectionRules, hierarchy: HierarchyManager, renderer: TemplateRenderer)`, `nonisolated func handle(envelope: HookEnvelope) async`, `var transitions: AsyncStream<AgentStateTransition> { get }`.
- `AgentStateTracker.swift` — `@MainActor @Observable final class AgentStateTracker`. Public surface: `init(panelID: PanelID, idleThreshold: TimeInterval, clock: any Clock<Duration>)`, `func ingest(envelope: HookEnvelope, ruleID: String?, rendered: (title: String, body: String)?) -> AgentStateTransition?`, `func override(to: AgentState)`, `func teardown()`.
- `RuleStore.swift` — `@MainActor final class RuleStore`. Public surface: `init(fileURL: URL, hookWriter: HookConfigWriting)`, `func loadAndMaterialise() throws -> AgentDetectionRules`, `func reload() throws -> AgentDetectionRules`.
- `TemplateRenderer.swift` — `struct TemplateRenderer { init(rules: AgentDetectionRules) throws; func render(template: String, for envelope: HookEnvelope, transition: AgentStateTransition) -> String }`.
- `InboxStore.swift` — `@MainActor final class InboxStore`. Public surface: `init(fileURL: URL, clock: any Clock<Duration>)`, `func load() throws -> NotificationInbox`, `func append(_ notification: AgentNotification)`, `func markRead(_ ids: [UUID])`, `func dismiss(_ ids: [UUID])`, `func clearAll()`, `func saveNow() throws`, `var unreadCount: Int { get }`, `var unreadPublisher: AsyncStream<Int> { get }`.
- `NotificationCoordinator.swift` — `@MainActor final class NotificationCoordinator`. Public surface: `init(inbox: InboxStore, badger: DockBadger, osNotifier: OSNotifier, muting: MuteSettings, hierarchy: HierarchyManager)`, `func bind(to transitions: AsyncStream<AgentStateTransition>) async`, `func onAgentPanelCreated(_ panelID: PanelID) async`.
- `OSNotifier.swift` — `protocol OSNotifier: Sendable { func currentAuthorizationStatus() async -> AuthorizationStatus; func requestAuthorization() async -> AuthorizationStatus; func post(_ notification: AgentNotification) async }` + `@MainActor final class UserNotificationsOSNotifier: OSNotifier`.
- `DockBadger.swift` — `protocol DockBadger: Sendable { func setUnreadCount(_ n: Int) }` + `@MainActor final class AppKitDockBadger: DockBadger`.
- `ConfigPaths.swift` — `enum ConfigPaths` with two computed URLs for `notifications.json` and `detection-rules.json` under `~/.config/touch-code/`.
- `Bridging/HookConfigWriting.swift` — `@MainActor protocol HookConfigWriting { func upsertInternal(_ subscriptions: [HookSubscription]) throws; func removeInternal(idsPrefixed: String) throws }` + a `HookConfigStoreAdapter` that bridges to C3's `HookConfigStore`.
- `Views/InboxSidebar.swift`, `Views/InboxRow.swift`, `Views/NotificationsSettingsView.swift`, `InboxFeature.swift`, `InboxClient.swift`, `InboxViewModel.swift` — the SwiftUI + TCA surface for M5.

### `apps/mac/touch-code/Notifications/Defaults/`

- `DefaultRules.swift` — `enum DefaultRules { static let json: String; static func installIfMissing(at url: URL) throws }` — used by M6 and the app launch path.

### `touch-code-skill/shims/`

- `claude-stop-hook.sh`, `codex-complete-hook.sh`, `aider-idle-hook.sh` — one-line shell scripts per M6.

### External dependencies (from C3 exec plan 0003)

- `public protocol InternalHookSubscriber: AnyObject, Sendable { func handle(envelope: HookEnvelope) async }`.
- `extension HookDispatcher { func register(subscriber: InternalHookSubscriber, for prefix: String) throws; func unregister(prefix: String) }` — called once by the app shell at launch: `hookDispatcher.register(subscriber: detectionRouter, for: "__touch-code/internal:notifications:")`.
- `HookConfigStore` (C3-owned) exposes an upsert API consumable through `HookConfigWriting` adapter; if C3's current API does not expose upsert for programmatically-authored subscriptions, C3 exec plan 0003 must add it before C6 M2 can land — record in Decision Log if this blocks.
- `HookEvent`, `HookEnvelope`, `HookEventData`, `HookSubscription` types (added to `TouchCodeCore` by C3 exec plan 0003 M1).
- `Panel.labels: Set<String>` (added by C3 D10, implemented in C3 exec plan 0003 M1).

### Test dependencies

- `Clock<Duration>` abstraction for idle-timer determinism. If `swift-clocks` is not already a test dep, roll a local `ManualClock` (≈20 lines) under `apps/mac/touch-code/Tests/NotificationsTests/Support/ManualClock.swift`.
- A minimal `FakeHookConfigWriter: HookConfigWriting` recording every upsert; used by `RuleStoreTests` so tests do not write `hooks.json` on disk.
- `MockOSNotifier` and `MockDockBadger` under `apps/mac/touch-code/Tests/NotificationsTests/Support/`.
