# Design Doc: Agent Notification Aggregation (C6)

**Status:** Draft (v2.1 — aligned with C3 DEC-16 subscriber shape)
**Author:** Gump (with Claude)
**Date:** 2026-04-20

## Context and Scope

touch-code runs coding agents (Claude Code, Codex CLI, aider, …) as first-class inhabitants of its Panels. In a typical session a user has 2–8 Panels distributed across Worktrees; most are driven by an agent; the user attends only to whichever one last asked for input or just finished. Today, to know which Panel wants attention, the user must tab-scan visually. **C6 closes that loop.**

C6 observes each agent Panel through the C3 hook pipeline, classifies its state (`Running / Completed / BlockedOnInput / Idle`), and surfaces transitions on three surfaces: a macOS OS notification, the Dock badge, and an in-app inbox with per-Panel provenance. The user can click a notification (OS or in-app) and land in the originating Panel with a single action.

C6 is the **first built-in consumer of C3** and the validation case for the hook design; it ships no public IPC surface of its own (user-facing control is through `tc notifications …` in C4 and a Settings pane), but it owns the detection state machine, the inbox data model, and the UserNotifications plumbing.

**Dependency direction:** `C6 → C3 → C2`. No reverse edges.

Repository state at the time of this design:

- [docs/architecture.md](../architecture.md) is stable. [docs/design-docs/0001-terminal-and-hierarchy.md](0001-terminal-and-hierarchy.md) is approved.
- **C3 has landed** (sibling branch `worktree-design+c3-c4-hooks-cli`). C6 binds against the concrete C3 wire types: `HookEvent`, `HookEnvelope`, `HookEventData`, `HookSubscription`, `HookConfig`, and the in-process `HookDispatcher` façade. References to an earlier draft's fictional `AgentHookEvent.structuredPayload` have been removed.
- `TouchCodeCore` contains the hierarchy value types and (per C3 D3) gains `HookEvent`, `HookEnvelope`, `HookEventData`, `HookSubscription`, `HookConfig`. C6 adds its own persisted types (`AgentState`, `AgentStateTransition`, `AgentNotification`, `NotificationInbox`, `AgentDetectionRules`). `touch-code/Hooks/` is owned by C3; C6 lives in a new `touch-code/Notifications/` in-app module.

## Goals and Non-Goals

**Goals**

- Define the `AgentState` state machine, its **full transition table**, and the rules that drive transitions from C3-delivered `HookEnvelope`s.
- Define the C6-owned **detection rule DSL** for matching agent prompts and classifying state — persisted in a C6-owned file, not in C3's `hooks.json`.
- Define how touch-code bridges **agent-internal signals** (Claude Code's own `Stop` hook, Codex CLI completion events) into C3's Panel-centric event model via a documented sentinel pattern.
- Define the data model for `AgentNotification` and `NotificationInbox` (Codable, persisted via `AtomicFileStore` per architecture § Persistence).
- Define the three surfaces: OS notifications via `UNUserNotificationCenter`, Dock badge via `NSApp.dockTile.badgeLabel`, and the in-app inbox (store + UI layout + dismissal flow).
- Define macOS notification permission handling with a single, non-contradictory flow: first-run prompt deferred to first agent-Panel creation; on app launch only refresh cached status — no automatic prompting.
- Preserve the architecture dependency direction (`C6 → C3 → C2`, zero reverse edges) and consume C3 only through its in-process `HookDispatcher` façade; no new cross-process surface from C6.
- Specify the testing strategy so detection rules are unit-testable without a live libghostty or the macOS notification daemon.

**Non-Goals**

- **Magic agent detection.** No process-tree sniffing, no pty-output heuristics beyond what the C6 detection rules explicitly match. Users opt in by labelling Panels (`tc label <panel> --agent <name>`) — this is the sole detection switch. Resolves product-spec Open Question #5.
- **Auto-labelling from foreground-binary inspection.** Earlier C6 drafts proposed polling a Panel's foreground binary basename against a known-binary allowlist. We do not ship that in v1 (see DEC-1). The "allowlist" becomes a rule-template library keyed by agent name.
- **In-app reply / conversational UI.** The inbox shows what happened and where; replying requires focusing the Panel and typing.
- **Cross-device notification sync / push.** Local-first; no network.
- **Notification scheduling, snoozing, rich attachments.**
- **Hook execution semantics** (in-process vs. out-of-process, concurrency, sandboxing). That belongs to C3.
- **Notifications for non-agent Panels** (build finishes, test-runner output). The detection DSL could express them, but shipped defaults target agents only; power users can extend.
- **Toast-style in-app overlays** — v2 consideration.

## Design

### Overview

Three pieces, all in-process.

1. **AgentStateTracker.** One per Panel labelled `agent:*`. Owns the `AgentState` FSM plus an idle timer. Transitions are driven exclusively by C3-delivered `HookEnvelope`s (received via `HookDispatcher.internalEventStream()`): `.panelOutputMatch` events carry a matched regex from a C6-authored C3 subscription; `.panelIdle` events drive the idle transition; `.panelExited` / `.panelCrashed` finalise the tracker. No side effects live in the tracker — it emits `AgentStateTransition` values on an `AsyncStream`.

2. **NotificationCoordinator.** Subscribes to `AgentStateTransition`s, decides whether a transition warrants a user-visible notification (muting policy in § Cross-Cutting § Muting), constructs an `AgentNotification` value, and fans out to three sinks: the inbox (always), the Dock badge (unread counter), and `UNUserNotificationCenter` (if permission granted and the transition is not muted). Click handling goes back through a deeplink (`touch-code://panel/<id>/focus`) so there's one code path for "jump to Panel".

3. **Detection rule DSL.** A small, declarative, JSON-serialised grammar persisted in the **C6-owned file `~/.config/touch-code/detection-rules.json`** (not in C3's `hooks.json`, which C3 owns). At C6 startup, the rules are materialised into (a) a small set of C3 `HookSubscription`s (with `command:` pointing to an internal sentinel — see § Component Boundaries), so the C3 dispatcher compiles regexes and emits `.panelOutputMatch` envelopes; (b) an in-process classifier table keyed by rule `id` so C6 maps an incoming envelope back to its rule's `transition_to` and template strings.

**Why this shape.** The hard problem in agent notification is separating *what counts as an attention moment* from *how we tell the user*. Mixing them — the iTerm "bell" model — produces either too many notifications or too few. Splitting along an `AgentState` FSM lets the detection layer be about recognising states, and the coordinator layer about presentation policy. Both can be tested in isolation.

The supaterm/supacode reference projects converged on the same split (`AgentHookNotification` + `TerminalHostState.NotificationSemantic`); we inherit the structure and adapt to touch-code's hierarchy (per-Panel provenance).

### System Context Diagram

```
 ┌──────────────────────────────────────────────────────────────────────────┐
 │                            touch-code app                                │
 │                                                                          │
 │  Runtime/C1 ──▶ TerminalEngine ─ AsyncStream<TerminalEvent> ─▶ Hooks/C3  │
 │                                                                          │
 │  Hooks/C3 ─▶ HookDispatcher.internalEventStream()  (AsyncStream<HookEnv.>)
 │                   │                                                      │
 │                   ▼                                                      │
 │       ┌──────────────────────────────────┐                               │
 │       │ Notifications/C6                 │                               │
 │       │   AgentStateTracker[panelID]     │  (one per agent-labelled     │
 │       │      ├─ FSM state machine        │   Panel)                      │
 │       │      └─ idle timer (local)       │                               │
 │       │      ▼ AgentStateTransition      │                               │
 │       │   NotificationCoordinator        │                               │
 │       └──────────┬───────────────────────┘                               │
 │                  │                                                       │
 │         ┌────────┼────────────────┐                                      │
 │         ▼        ▼                ▼                                      │
 │  UNUserNotification   NSApp.dockTile        NotificationInbox            │
 │  Center  (OS banner)  .badgeLabel           (sidebar + AtomicFileStore)  │
 │         │                                          │                     │
 │         │ click → touch-code://panel/<id>/focus   │                     │
 │         └──────────────────┬─────────────────────┘                      │
 │                            ▼                                             │
 │                  DeeplinkRouter → HierarchyClient.focusPanel             │
 └──────────────────────────────────────────────────────────────────────────┘
```

External touchpoints: `UNUserNotificationCenter` (macOS), `NSApp.dockTile` (AppKit). No network. No C6-owned IPC. Persistence via `AtomicFileStore` (TouchCodeCore).

### API Design

#### Types — `TouchCodeCore` additions

Lives in `TouchCodeCore` because the data is persisted (inbox history survives restart) and read by CLI list commands, which must not import Runtime. All time intervals are `TimeInterval` (not `Duration`) for consistency with C3 (`HookSubscription.timeoutSeconds: Double`) and Foundation API surfaces.

```swift
public enum AgentState: String, Codable, Sendable {
  case running           // agent is actively producing output
  case completed         // agent reached a natural stop (rule match or panelExited)
  case blockedOnInput    // agent printed a prompt and stopped producing output
  case idle              // no output for `idleThreshold` seconds and not classified above
}

public struct AgentStateTransition: Codable, Sendable, Equatable {
  public let panelID: PanelID
  public let from: AgentState
  public let to: AgentState
  public let at: Date
  public let trigger: Trigger
  public enum Trigger: Codable, Sendable, Equatable {
    case rule(id: String)                   // user-configured detection rule matched
    case envelope(event: HookEvent)         // direct transition from HookEnvelope (.panelExited, .panelCrashed)
    case idleTimer(seconds: TimeInterval)   // idle timeout fired
    case userOverride                       // user manually set via CLI/UI
  }
}

public struct AgentNotification: Codable, Sendable, Equatable, Identifiable {
  public let id: UUID
  public let panelID: PanelID                 // provenance; resolves to Worktree/Tab via Catalog
  public let agent: String                    // "claude" / "codex" / "aider" / "custom:<label>"
  public let kind: Kind
  public let title: String                    // rendered on banner + inbox row
  public let body: String                     // rendered in banner body + inbox detail
  public let createdAt: Date
  public var readAt: Date?                    // nil = unread
  public var dismissedAt: Date?               // soft-delete; swept from inbox after 7 days

  public enum Kind: String, Codable, Sendable {
    case completed                            // → Completed
    case blockedOnInput                       // → BlockedOnInput
    case idle                                 // → Idle (muted by default)
    case crashed                              // from .panelCrashed or nonzero .panelExited
  }
}

public struct NotificationInbox: Codable, Sendable, Equatable {
  public static let currentVersion = 1
  public var version: Int
  public var notifications: [AgentNotification]   // newest first; cap 500 retained
}

public struct AgentDetectionRules: Codable, Sendable, Equatable {
  public static let currentVersion = 1
  public var version: Int
  public var idleThresholdSeconds: TimeInterval    // default 120
  public var rules: [Rule]

  public struct Rule: Codable, Sendable, Equatable {
    public let id: String
    public let agent: String
    public let appliesWhen: AppliesWhen
    public let match: Match?                       // nil when appliesWhen is event-only
    public let transitionTo: AgentState
    public let title: String                       // template string
    public let body: String                        // template string
  }

  public struct AppliesWhen: Codable, Sendable, Equatable {
    public var panelLabelledAgent: String?         // matches when Panel has label "agent:<value>"
    public var hookEvent: HookEvent?               // scope to one HookEvent case (usually .panelOutputMatch)
    public var panelID: PanelID?                   // advanced: scope to one Panel
  }

  public enum Match: Codable, Sendable, Equatable {
    case containsAny([String])
    case regex(pattern: String, on: Target = .tail)
    public enum Target: String, Codable, Sendable { case tail, lastLine, lastNonEmptyLine }
  }
}
```

Read/write through `TouchCodeCore/Persistence.swift` + `AtomicFileStore<T>` using the existing helpers (no `defaultURL` sugar API; callers construct the URL from `ConfigPaths.home` + the file name, matching `CatalogStore`).

`AgentNotification.panelID` is the provenance pointer. The inbox view joins against `Catalog` at render time to show *Project / Worktree / Tab / Panel title*; the join is one-shot on render, not persisted (Panels rename and move; resolve fresh each time).

#### FSM Transition Table

The tracker processes exactly four kinds of input: (a) a `HookEnvelope` whose `event` is a detection-rule match, (b) a `HookEnvelope` whose `event` is a direct lifecycle signal (`.panelExited`, `.panelCrashed`, `.panelOutput` with non-empty bytes used as "activity"), (c) a local idle-timer fire, (d) a user override.

| From \ Input | rule(→`s`) | envelope `.panelExited(0)` | envelope `.panelExited(≠0)` / `.panelCrashed` | idleTimer | activity (non-empty output) | userOverride(→`s`) |
|---|---|---|---|---|---|---|
| `running` | `s` (emit if s≠from) | `completed` (notify) | `completed` (notify `crashed`) + tracker teardown | `idle` (notify iff not muted) | `running` (no-op; rearm idle) | `s` |
| `completed` | `s` | no-op | teardown | no-op | `running` | `s` |
| `blockedOnInput` | `s` | `completed` (notify) | teardown (notify `crashed`) | no-op | `running` (implicit — user/agent resumed) | `s` |
| `idle` | `s` | `completed` (notify) | teardown (notify `crashed`) | no-op | `running` | `s` |

Invariants:

- Any `HookEnvelope` carrying non-empty bytes (`.panelOutput`, `.panelOutputMatch`) rearms the idle timer.
- A notification is emitted only on `from ≠ to` transitions, except `crashed` which always emits.
- On `.panelCrashed` or when the Panel is removed from `HierarchyManager`, the tracker is destructed; its idle-timer task is cancelled.
- `userOverride` can set any state; it never emits a notification (it's a correction, not an event).

#### Swift interfaces inside the app

```swift
@Observable @MainActor
final class AgentStateTracker {
  let panelID: PanelID
  private(set) var state: AgentState = .running
  init(panelID: PanelID, idleThreshold: TimeInterval, clock: any Clock<Duration>) { … }

  /// Feed one envelope from C3's dispatcher. Idempotent on repeated identical envelopes.
  func ingest(_ envelope: HookEnvelope, matchedRuleID: String?)

  /// Manual override (from CLI / UI).
  func override(to: AgentState)

  var transitions: AsyncStream<AgentStateTransition> { get }
}

@MainActor
final class NotificationCoordinator {
  init(
    inbox: InboxStore,                         // AtomicFileStore<NotificationInbox> wrapper
    badger: DockBadger,                        // abstracts NSApp.dockTile (stubbable)
    osNotifier: OSNotifier,                    // abstracts UNUserNotificationCenter
    muting: MuteRules                          // from settings
  )
  func bind(to trackers: AsyncStream<AgentStateTransition>) async
}

/// Provided by C3 — C6 consumes it. Not C6-owned.
protocol HookEventStreaming: Sendable {
  func internalEventStream() -> AsyncStream<HookEnvelope>
}

protocol OSNotifier: Sendable {
  func currentAuthorizationStatus() async -> AuthorizationStatus
  func requestAuthorization() async -> AuthorizationStatus
  func post(_ n: AgentNotification) async       // no-op if denied
}

protocol DockBadger: Sendable {
  func setUnreadCount(_ n: Int)                 // "" when 0; "99+" when > 99
}
```

The tracker is `@Observable` so the inbox-row live badge ("still running" vs. "completed 3s ago") updates without going through TCA. The coordinator is main-actor confined; it is invoked from a single subscription task started at app launch.

#### Consumer contract with C3

C6 reads events via `HookDispatcher.internalEventStream()` — an **in-process** `AsyncStream<HookEnvelope>`. Rationale (see DEC-11): C6 and C3 share a process; going through C3's `hook.events` streaming RPC would add JSON serialisation on every envelope and block on socket backpressure (C3 R10). The in-process path is zero-copy and naturally backpressured via AsyncStream.

C3's `hook.events` RPC remains as C3 designed it — a **secondary seam for third-party tools** (other MCP servers, external dashboards, `tc hook tail`). C6 is not its consumer.

To receive matched envelopes without forking `/bin/sh -c` per event, C6 uses C3's **sentinel-prefix route** (C3 DEC-16). C3 exposes:

```swift
// Provided by C3 — authoritative shape:
public protocol InternalHookSubscriber: AnyObject, Sendable {
  func handle(envelope: HookEnvelope) async
}

// Registration lives on HookDispatcher, not on the subscriber.
// (Called in-process; C6 implements InternalHookSubscriber.)
extension HookDispatcher {
  func register(subscriber: InternalHookSubscriber, for prefix: String) throws
  func unregister(prefix: String)
}
```

C6 implements `InternalHookSubscriber` on its `NotificationCoordinator` (or a thin `DetectionRouter` façade). At startup, C6:

1. Reads `detection-rules.json`.
2. Writes one C3 `HookSubscription` per rule into `hooks.json` with `event: .panelOutputMatch`, the rule's `matchPattern`, and `command: "__touch-code/internal:notifications:<rule.id>"`. The `__touch-code/internal:` namespace is reserved by C3 (load-time rejects user-authored rows unless `authoredBy: "touch-code"`).
3. Calls `hookDispatcher.register(subscriber: self, for: "__touch-code/internal:notifications:")` once.

When the dispatcher matches a subscription whose `command` starts with that prefix, it calls `subscriber.handle(envelope:)` on `@MainActor` and skips `ProcessHookExecutor` entirely (C3 routing rule). C6's `handle` splits the command suffix back into the rule id, looks up the rule, applies the `AppliesWhen.panelLabelledAgent` / `panelID` filters C3's `scope` can't express, renders the template, and feeds the resulting `AgentStateTransition` to the tracker.

This preserves C3 as the single owner of regex compilation, scope matching, recursion-guard, rate-limiting, and `hook.recent` bookkeeping — C6 only receives the envelope and classifies it.

#### IPC surface (owned by C4, consumed by users)

C6 does not add new IPC method namespaces. C4 exposes (documented in C4's design doc):

- `tc notifications list [--unread] [--panel <id>]` — reads `NotificationInbox`.
- `tc notifications clear [--panel <id> | --all]` — soft-dismisses.
- `tc notifications mute <rule-id> [--panel <id>]` — updates settings.
- `tc label <panel> --agent <name>` — sets `Panel.labels` to include `agent:<name>` (already defined by C3 D10).
- `tc notifications rules reload` — re-reads `detection-rules.json`, rebuilds C3 subscriptions.

All of these resolve to MainActor calls into `NotificationCoordinator` / `InboxStore` / `HierarchyClient` via the existing `system.*` namespace. No new namespace — DEC-10.

### Data Storage

Two new files under `~/.config/touch-code/`, both C6-owned:

| File | Owner | Schema version | Cadence |
|---|---|---|---|
| `notifications.json` | `InboxStore` (C6) | top-level `version: Int` | debounced 500ms trailing; flushed on `applicationWillTerminate`; cap 500; 7-day soft-delete sweep on load |
| `detection-rules.json` | `DetectionRulesStore` (C6) | top-level `version: Int` | read on launch + on `tc notifications rules reload`; written only by explicit user edits (no app-side debounce) |

C3's `hooks.json` stays C3-owned. Detection rules deliberately live in a separate file to preserve C3's ownership boundary — DEC-12.

`settings.json` (owned by a future settings feature) gains a `notifications` object: permission status cache, `muted_rule_ids`, `muted_panel_ids`, `badge_enabled`, `surface_idle`, `redact_bodies`.

Both C6 files go through `TouchCodeCore/Persistence.swift` + `AtomicFileStore` — the same atomic-rename + version-gated decoder used by `catalog.json`. Readers abort on unknown `version` per architecture invariant.

Inbox cap rationale: 500 rows keeps JSON under ~200KB and the list trivially scrollable; most notifications are acted on within the first minute; sweep runs on load — no background timers.

### Component Boundaries

```
TouchCodeCore (static framework — persisted types)
├── AgentState, AgentStateTransition
├── AgentNotification, NotificationInbox
├── AgentDetectionRules  (Codable DSL; no matching logic)
└── (existing) AtomicFileStore, Catalog, PanelID, HookEvent, HookEnvelope, HookEventData, HookSubscription

touch-code/Notifications  (NEW in-app module)
├── AgentStateTracker.swift        — per-Panel FSM (see transition table)
├── TrackerRegistry.swift          — owns trackers keyed by PanelID; created/torn-down on HookEnvelope .panelCreated / .panelCrashed / Panel removal
├── NotificationCoordinator.swift  — fan-out policy
├── InboxStore.swift               — AtomicFileStore<NotificationInbox> wrapper + debounce
├── DetectionRulesStore.swift      — AtomicFileStore<AgentDetectionRules> wrapper + C3-subscription materialisation
├── TemplateRenderer.swift         — {field} + | filter grammar; rejects unknown keys at load
├── OSNotifier.swift               — UNUserNotificationCenter adapter + mock
├── DockBadger.swift               — NSApp.dockTile adapter + mock
└── Views/
    ├── InboxSidebar.swift         — SwiftUI list + filter chips (All / Unread / Waiting / Completed / Crashed)
    └── InboxRow.swift             — provenance + actions (Focus / Dismiss)

touch-code/Hooks  (C3 — owned by C3 design doc)
├── HookDispatcher                 — exposes internalEventStream(): AsyncStream<HookEnvelope>
│                                    plus register(subscriber:for:) / unregister(prefix:)
│                                    for the sentinel-prefix route (C3 DEC-16)
└── InternalHookSubscriber         — protocol C6 implements: handle(envelope:) async
```

**Dependency rules.**

- `Notifications` imports `TouchCodeCore` (domain types) and `Hooks` (the `HookDispatcher` façade for `internalEventStream()` + `register(subscriber:for:)`, plus the `InternalHookSubscriber` protocol it implements). It reads `HierarchyManager` for provenance but never mutates it. SwiftUI + AppKit are imported only by the Views + Badger/Notifier adapter files.
- `TouchCodeCore` must not import `UserNotifications` or AppKit — it stays pure. CLI list commands read the inbox file through `AtomicFileStore<NotificationInbox>` without any UI framework dependency.
- No reverse edges. C3 does not know C6 exists beyond the `command: "__touch-code/internal:..."` sentinel routing convention, which is opaque to C3. `HierarchyManager` does not know C6 exists; it is a read dependency.

**Responsibilities that are NOT C6's.**

- Regex compilation and scope matching of detection rules (C3's job — C6 emits `HookSubscription`s).
- The idle timer *for hook subscriptions* (C3 owns `.panelIdle` emission; C6 runs a secondary tracker-local timer only for FSM transitions when no C3 `.panelIdle` subscription exists with a shorter threshold).
- Scrollback storage or Panel focus — those belong to C1 + C2.
- Reading raw `.panelOutput` bytes — C6 only needs matched envelopes and lifecycle signals.

### Detection Rule DSL

Rules are JSON under `detection-rules.json`. Example (ships as default for Claude Code):

```json
{
  "version": 1,
  "idle_threshold_seconds": 120,
  "rules": [
    {
      "id": "claude.blocked_on_input",
      "agent": "claude",
      "applies_when": {
        "panel_labelled_agent": "claude",
        "hook_event": "panel.outputMatch"
      },
      "match": { "contains_any": ["Do you want to proceed?", "Approve tool call?"] },
      "transition_to": "blockedOnInput",
      "title": "Claude is waiting for your approval",
      "body": "{data.output | firstLine | truncate: 140}"
    },
    {
      "id": "claude.completed",
      "agent": "claude",
      "applies_when": {
        "panel_labelled_agent": "claude",
        "hook_event": "panel.outputMatch"
      },
      "match": { "regex": "::touchcode:agent-complete(?:\\s|$)", "on": "lastNonEmptyLine" },
      "transition_to": "completed",
      "title": "Claude finished",
      "body": "Worktree {worktree.branch} · Tab {tab.name}"
    },
    {
      "id": "aider.blocked_on_input",
      "agent": "aider",
      "applies_when": {
        "panel_labelled_agent": "aider",
        "hook_event": "panel.outputMatch"
      },
      "match": { "regex": "^>\\s*$", "on": "lastNonEmptyLine" },
      "transition_to": "blockedOnInput",
      "title": "Aider is waiting",
      "body": "aider prompt ready"
    }
  ]
}
```

**Grammar.**

- `id` (required, string) — stable identifier; used for muting and telemetry; becomes the C3 sentinel-command suffix.
- `agent` (required, string) — attached to the resulting `AgentNotification.agent`.
- `applies_when` (required object) — all of:
  - `panel_labelled_agent: <string>` — matches when `Panel.labels` contains `agent:<value>` (see DEC-1, C3 D10).
  - `hook_event: <HookEvent rawValue>` — scopes which C3 `HookEvent` this rule is fed from. Default `panel.outputMatch`.
  - `panel_id: <uuid>` (optional) — scopes to one Panel.
- `match` (required when `hook_event == .panelOutputMatch`) — exactly one of:
  - `contains_any: [<string>, …]`
  - `regex: <ECMA-262>` and optional `on: "tail" | "lastLine" | "lastNonEmptyLine"` (default `tail`).
- `transition_to` (required) — one of the `AgentState` cases.
- `title` / `body` (required) — template strings.

**Template grammar.** `{path.field}` references values; `| filter[: arg]` transforms. The field set is keyed to the `HookEventData` case on the envelope. Unknown keys → rule rejected at `DetectionRulesStore.load()` with `DetectionRuleError.unknownTemplateKey(rule: id, key: name)`.

Always available:

- `{agent}` — rule's `agent`
- `{state.from}`, `{state.to}` — AgentState raw values
- `{panel.id}`, `{panel.workingDirectory}`, `{panel.initialCommand}` — from `HookEnvelope.panel`
- `{tab.id}`, `{tab.name}`, `{tab.selectedPanelID}` — from `HookEnvelope.tab`
- `{worktree.id}`, `{worktree.name}`, `{worktree.path}`, `{worktree.branch}` — from `HookEnvelope.worktree`
- `{project.id}`, `{project.name}`, `{project.rootPath}` — from `HookEnvelope.project`
- `{space.id}`, `{space.name}` — from `HookEnvelope.space`

Event-specific (available only when `hook_event` matches):

- `panel.outputMatch`: `{data.match}`, `{data.output}`, `{data.outputBytes}`, `{data.matchedRange.location}`, `{data.matchedRange.length}`
- `panel.idle`: `{data.idleSeconds}`, `{data.sinceLastOutput}`, `{data.sinceLastInput}`
- `panel.ready`: `{data.pid}`, `{data.shell}`
- `panel.exited`: `{data.exitCode}`
- `panel.crashed`: `{data.reason}`
- `panel.created`: `{data.createdVia}`

Filters (applied left-to-right; chainable):

- `| truncate: <Int>` — cap length by grapheme cluster count
- `| firstLine` — first non-empty line
- `| default: "<string>"` — literal fallback when value is empty/missing
- `| upper`, `| lower` — case

**Evaluation.** C3 does all regex compilation and `.panelOutputMatch` synthesis; C6 receives envelopes pre-filtered. For each incoming envelope with an internal sentinel command, C6 looks up the rule by id, runs `AppliesWhen.panelLabelledAgent` / `panelID` filters (these are outside C3's `scope` expressiveness), renders the template, and hands the transition to the tracker.

**Why a DSL and not user Swift/JS.** Declarative, auditable, and aligned with the C3 principle (C3 A5) that rule DSLs stay tiny. Users needing Turing-complete logic write a full C3 `HookSubscription` with their own handler, which can in turn shell out to `tc notifications …` commands (not `tc hook fire` — that fires a new C3 envelope and could loop; see C3 D4).

### Bridging Agent-Internal Signals

Claude Code, Codex CLI, and aider each have their own post-completion hook systems (Claude Code's `Stop` hook, Codex's `on_complete`, etc.). These are **external to touch-code and C3**; they fire inside the agent process, not against Panel lifecycle. The C3 `HookEvent` enum has no `Stop` / `on_complete` case and will not grow them (C3 non-goal).

**The bridge is a sentinel token written to the Panel's stdout.** The `touch-code-skill` package (C5) ships a tiny shim per supported agent, typically a shell script `.touchcode/stop-hook.sh` that prints:

```
printf '\n::touchcode:agent-complete %s\n' "$TOUCH_CODE_PANEL_ID"
```

The user installs it as the agent's stop hook (`~/.claude/settings.json → hooks.Stop`, Codex equivalent, …). Because the shim writes to the Panel's stdout, C3's `panel.outputMatch` subscription (registered by C6's `claude.completed` rule, regex `::touchcode:agent-complete`) matches it, the dispatcher emits a `HookEnvelope`, and C6 transitions the tracker to `Completed`.

Why this path and not a direct RPC (`tc notifications ingest --panel …`):

- Works with any agent that can exec a shell command; no per-agent integration code in the app.
- Rides on existing C3 machinery; no new IPC method for C6.
- The sentinel is a literal string inside the Panel — if the user is looking at the Panel, they see the completion marker directly.
- No recursion risk (C3 D4): the shim writes to the pty; that output is a legitimate Panel event.

Trade-off: the sentinel is visible in scrollback. If the user finds this objectionable, a future variant can use ANSI-escape-hidden bytes. Documented in § Risks.

### Known-Agent Rule Templates

The "known-binary allowlist" of v1 (`claude`, `codex`, `aider`) is **not** an auto-detection mechanism — DEC-1. It is a library of preinstalled rule bundles keyed by agent name. When the user runs:

```
tc label <panel> --agent claude
```

…they (a) add the `agent:claude` label to `Panel.labels` (C3 D10), and (b) activate the preinstalled rules in `detection-rules.json` whose `agent == "claude"` because those rules' `applies_when.panel_labelled_agent == "claude"`.

Why drop auto-detection:

- `aider` runs as `python3` — argv[0]-basename inspection would miss it without shipping argv[1:] inspection and pid-monitoring polling. Adds a new Runtime capability for marginal UX (users still choose which Panels are agent-hosted).
- Users starting agents via `tmux`, `sudo`, or shell wrappers confuse the detector further.
- Explicit labelling is a one-keystroke operation and is the norm in similar tools (supaterm labels, Ghostty's config explicit).

The `tc label` verb is provided by C4; the label semantics (`agent:<name>`) match C3's scope system.

### Surfaces

**OS notifications — `UNUserNotificationCenter`.**

- Request authorization once, at first agent-Panel creation after install (DEC-4).
- `UNAuthorizationOptions`: `[.alert, .badge, .sound]`.
- Every `AgentNotification` posted sets:
  - `threadIdentifier = panelID.raw.uuidString` — macOS groups per-Panel.
  - `categoryIdentifier` = `kind` raw value — drives action buttons.
  - `userInfo["deeplink"] = "touch-code://panel/<id>/focus"` — click routes through `DeeplinkRouter`.
- Actions: **Focus Panel** (default; dismisses + focuses), **Dismiss** (dismisses only).

**Dock badge — `NSApp.dockTile.badgeLabel`.**

Definition (single source of truth, DEC-13): the badge shows the count of **unread, non-dismissed `AgentNotification`s**, irrespective of whether their OS banner was posted, suppressed by muting, or silenced by permission denial. Rationale: the badge is the user's unified "how many things haven't I looked at" indicator; it must match the inbox view's "Unread" filter exactly. Rendered as plain decimal; "99+" when > 99.

Cleared when: the user opens the inbox (visible rows mark read), focuses a Panel via notification click (that Panel's unreads mark read), or runs `tc notifications clear`. Toggleable globally via `notifications.badge_enabled` (default `true`).

**In-app inbox — `InboxSidebar`.**

Right-side slide-in sidebar, toggled via ⌘⇧N or toolbar bell icon. Width 320pt; collapsible. Rows newest-first; each row shows: agent avatar (text badge "C" / "X" / "A"), title, body (1 line, truncated), provenance (Project / Worktree · Tab · Panel), relative time, state chip (Completed / Waiting / Idle / Crashed), hover actions (Focus, Dismiss).

Filter chips: **All / Unread / Waiting / Completed / Crashed**. "Waiting" is the high-value view.

Dismissal: swipe-left reveals Dismiss (soft-delete; sets `dismissedAt`, kept 7 days for undo). "Clear all" in header. Double-click focuses the Panel and marks read.

Empty state: *"No agent pings. Nice."*

### Permission Handling (single flow)

Apple's `UNUserNotificationCenter` permission model has three states: `.notDetermined`, `.authorized` (includes `.provisional`), `.denied`. C6 handles each with the following **single, non-contradictory flow**:

- **On app launch** — call `getNotificationSettings()` once, cache the status into `settings.json#notifications.auth_status`. **Never prompt automatically on launch.**
- **On first agent-Panel creation after install, if status is `.notDetermined`** — show a pre-prompt sheet with "Continue" (calls `requestAuthorization`), "Not now" (defers 24h), and "Never" (permanently suppresses the prompt; inbox stays active).
- **If status is `.authorized`** — post banners normally.
- **If status is `.denied`** — suppress OS banners. Inbox + Dock badge still function. Settings pane shows a "Notifications are off — Open System Settings" link (`x-apple.systempreferences:com.apple.preference.notifications?id=<bundle-id>`).
- **On `applicationDidBecomeActive`** (user returning from System Settings) — refresh `getNotificationSettings()` once to update cached status. No prompt.

Fallback when denied: the **Dock badge + inbox are the source of truth** (DEC-5). The success metric "user returns to the correct Panel within 30s" is satisfied by the in-app surfaces alone; OS banners are an enhancement.

First-run prompt copy (draft): *"touch-code can tell you when an agent finishes or is waiting for your input, even when this app is in the background. We only notify on state changes — no chatty pings."*

## Alternatives Considered

### A1. Magic agent detection via process scanning

Poll `ps` / `proc_pidinfo` on every Panel, detect `claude` / `codex` / `aider` dynamically, auto-apply rules.

- **Pros:** zero configuration.
- **Cons:** CPU/power drag from polling; agents run under `tmux`, `sudo`, and shell wrappers (aider = `python3`); heuristics break silently. Product-spec Open Q5 explicitly rejects magic detection.
- **Verdict:** rejected.

### A2. Single uniform notification per output burst

Every burst of output ending in N seconds of silence → one notification.

- **Pros:** trivial.
- **Cons:** iTerm's "bell" model; loses the separation between "waiting for you" and "chatting at you" that is C6's core value.
- **Verdict:** rejected.

### A3. Deliver notifications only via the OS, no inbox

Lean on macOS Notification Centre; touch-code just posts.

- **Pros:** minimal UI.
- **Cons:** (a) no provenance-aware history by Panel/Worktree; (b) permission denial kills the feature; (c) "what happened while I was in a meeting" has no answer.
- **Verdict:** rejected.

### A4. Store `AgentNotification` inside `catalog.json`

One file; simpler persistence story.

- **Pros:** fewer files.
- **Cons:** notifications churn 100× faster than hierarchy; would muddy catalog's write cadence. Separate pressures → separate files.
- **Verdict:** rejected.

### A5. Consume C3's `hook.events` streaming RPC instead of `internalEventStream()`

C6 would subscribe via JSON-RPC over the Unix socket, same as external tools.

- **Pros:** single uniform path; easier to stub.
- **Cons:** JSON serialisation of every envelope; socket backpressure (C3 R10) can drop events and lose notifications; extra thread hop; encoder/decoder cost. For an in-process consumer this is waste.
- **Verdict:** rejected — in-process subscription (DEC-11). `hook.events` RPC remains C3's surface for external tools.

### A6. Put detection rules inside `hooks.json`

Add a C6-owned object to C3's config file.

- **Pros:** one user-facing config.
- **Cons:** C3 owns `hooks.json`; adding a C6 schema couples the two files' version evolution and blurs ownership. Two separate, small, version-gated files cost almost nothing.
- **Verdict:** rejected — DEC-12.

### A7. Dedicated `notifications.*` IPC namespace

Expose a full RPC surface for inbox queries.

- **Pros:** consistent with `hierarchy.*`, `terminal.*`, `hook.*`.
- **Cons:** four verbs (list/clear/mute/reload) are CRUD on existing state, not a domain. Fewer namespaces → simpler CLI surface.
- **Verdict:** rejected — DEC-10. Verbs live under `system.*`.

### A8. Per-Tab state chip instead of notifications

Colour the Tab icon; no banners.

- **Pros:** zero interruption.
- **Cons:** invisible when touch-code is not foreground; fails the "user left the app" case.
- **Verdict:** partially adopted — per-Tab state indicator is a C2 UI enhancement (tracked separately); C6 owns the cross-app attention path.

## Cross-Cutting Concerns

### Muting policy

An `AgentNotification` posts to the OS iff all of these hold:

- `notifications.enabled == true` (global kill switch).
- `UNUserNotificationCenter` status is `.authorized` (or `.provisional`).
- The originating rule's `id` is not in `muted_rule_ids`.
- The target Panel's UUID is not in `muted_panel_ids`.
- `kind != .idle` **or** `notifications.surface_idle == true` (default `false`).

The inbox always receives the notification — even when OS posting is muted — so history is complete. **The Dock badge counts all unread, non-dismissed notifications regardless of OS mute status** (DEC-13). This keeps the badge synchronous with the inbox "Unread" filter.

### Performance

- C3 does regex matching against its 4KB rolling tail; C6 pays zero cost on non-matching output.
- `.panelOutputMatch` + `.panelIdle` envelopes are already rate-limited by C3 (≤60Hz, ≤16KB per batch; idle events are edge-triggered per threshold).
- Tracker idle timer is a single `Task.sleep` rearmed on activity — zero cost when Panels are chatty.
- Inbox writes: debounced 500ms, capped at 500. Sweep on load only.
- Template rendering is O(template length) per posted notification (rare).

### Observability

- `os.Logger` category `com.touch-code.notifications`: transitions (`.info`), OS post success/failure (`.debug`), permission state changes (`.info`).
- Every posted notification carries a correlation UUID that matches its inbox entry; `tc notifications list --verbose` surfaces it for debugging.
- Telemetry (opt-in; aligned with product-spec Success Metrics): per-day transitions by kind; time from notification to Panel focus via `DeeplinkRouter` instrumentation. Reserved field in `notifications.json`.

### Testing strategy

- **`TemplateRenderer`** — 100% unit coverage; table-driven tests for every supported field and filter; unknown-key rejection; grapheme-cluster correctness for `truncate`.
- **`AgentStateTracker`** — FSM is unit-tested with a mock `Clock` and hand-fed `HookEnvelope`s. Test matrix covers every cell of the § FSM Transition Table, plus invariants (no duplicate notifications on self-transitions; crash teardown).
- **`DetectionRulesStore`** — round-trip Codable; reject-on-load for unknown template keys, unknown `AgentState`, and conflicting `match` kinds.
- **`NotificationCoordinator`** — integration-tested against mock `OSNotifier` + `DockBadger`. Scenarios: permission denied (inbox + badge still increment); muted rule (inbox accrues, OS skipped, **badge still increments** — DEC-13); dismiss updates badge synchronously.
- **`InboxStore`** — round-trip Codable; write-debounce coalescing (100 appends / 100ms → 1 file write); flush-on-terminate; cap + 7-day sweep on load.
- **End-to-end** — XCTest drives the stack: a fake `HookDispatcher.internalEventStream()` emits a `.panelOutputMatch` envelope with a sentinel match; the stack asserts `AgentNotification` of kind `.blockedOnInput` reaches the inbox and the badge flips to `1`. No live UNUserNotificationCenter. Gated by the same flag as C1+C2 tests.

### Migration

v1 only. `notifications.json` and `detection-rules.json` both ship at `version: 1`. Unknown versions abort per architecture invariant. Users downgrading keep their catalog but see an empty inbox (acceptable — inbox is ephemeral).

### Security & privacy

- No network. No telemetry without opt-in.
- `AgentNotification.body` can include terminal output (e.g. `{data.output | firstLine}`), which may contain secrets. Mitigations: (a) default rules use `{data.output}` only for `blockedOnInput` (prompt text, rarely secret); (b) `notifications.redact_bodies = true` (default `false`) replaces bodies with `"(redacted)"` on the OS surface while keeping them in the (local-only) inbox; (c) docs warn about custom rules.
- The sentinel token `::touchcode:agent-complete <panel-id>` is a stable marker; it is not a secret. Writing it is equivalent to writing any other line to the Panel's pty.

## Decisions

Locked at approval; revisit only via amendment.

- **DEC-1 — Open Q5 resolution (revised v2).** Agent detection is **user-driven only**, via `tc label <panel> --agent <name>`. The "known-agent allowlist" (`claude`, `codex`, `aider`) is a library of preinstalled rule bundles, not an auto-detector. No process-tree polling, no argv inspection, no magic. Aligns with product-spec Q5 leaning and avoids failures against agents running under `python3` / `tmux` / `sudo`.
- **DEC-2 — State machine shape.** Four states: `running | completed | blockedOnInput | idle`. Transitions driven by (i) matched detection rules, (ii) direct envelope events (`panel.exited`, `panel.crashed`), (iii) an idle timer, (iv) user override. Full table in § API Design.
- **DEC-3 — Persistence separation.** Inbox in `notifications.json`; detection rules in `detection-rules.json`. Not merged into `catalog.json` (churn mismatch) nor into `hooks.json` (C3 ownership).
- **DEC-4 — Permission prompt timing.** First-run prompt on first agent-Panel creation, not app launch. Launch only refreshes cached status via `getNotificationSettings()`; never prompts automatically. Single flow documented in § Permission Handling.
- **DEC-5 — Inbox > OS banner as source of truth.** Dock badge + inbox satisfy the product goal when UN permission is denied. OS banners are an enhancement.
- **DEC-6 — Rule DSL scope.** Declarative only. Turing-complete logic escalates to a user-written C3 `HookSubscription` that shells out; no embedded VM.
- **DEC-7 — Idle notifications muted by default.** High-volume, low-signal.
- **DEC-8 — Body redaction is a toggle, not mandatory.** Default off; users in regulated environments flip it.
- **DEC-9 — Inbox retention.** 500 rows, 7-day soft-delete sweep on load.
- **DEC-10 — No new IPC namespace.** C6 verbs attach to `system.*`.
- **DEC-11 — C6 consumes `HookDispatcher.internalEventStream()` in-process.** C3's `hook.events` streaming RPC is retained by C3 as a **secondary seam for third-party tools** (`tc hook tail`, external dashboards). C6 does not go through the socket for its own operation.
- **DEC-12 — Detection rules live in a C6-owned file.** `~/.config/touch-code/detection-rules.json`. C3 owns `hooks.json` unchanged; C6 materialises its rules as C3 `HookSubscription`s at startup and routes matches via C3's sentinel-prefix mechanism (C3 DEC-16) under the reserved `__touch-code/internal:notifications:` namespace.
- **DEC-13 — Dock badge counts unread non-dismissed notifications regardless of OS mute.** The badge mirrors the inbox's "Unread" filter exactly. Keeps the badge meaningful for users who mute noisy rules but still want to know when the inbox has content.
- **DEC-14 — Agent-internal completion signals bridge via pty sentinel.** A `::touchcode:agent-complete <panel-id>` line printed to the Panel's stdout (by the agent's own Stop hook, shipped via `touch-code-skill`) is matched by C3's `panel.outputMatch` and converted by C6 to a `Completed` transition. No new C3 `HookEvent` case; no new IPC method; no per-agent integration code in the app.
- **DEC-15 — `InternalHookSubscriber` is a receiver protocol; registration lives on `HookDispatcher`.** An earlier C6 v2 draft inverted the direction — it defined `InternalHookSubscriber` as a registration API (`registerInternal(_:id:)`) on the dispatcher side. C3 v2 DEC-16 is authoritative: the subscriber is the **callback** C6 implements (`func handle(envelope: HookEnvelope) async`), and registration is `HookDispatcher.register(subscriber:for:) / unregister(prefix:)`. C6 v2.1 adopts the C3 shape; code examples and the Consumer-contract section were realigned accordingly.

## Risks

- **R1 — False positives from brittle regexes in user rules.** A rule that fires on every agent output floods the inbox and badge.
  - *Mitigation:* per-rule origin recorded in `AgentNotification` correlation; one-click "Mute this rule" from the inbox row (adds to `muted_rule_ids`); conservative defaults; DSL documents anti-patterns.
- **R2 — Notification fatigue.** Many agents + correct rules can still overwhelm.
  - *Mitigation:* `threadIdentifier` groups per Panel in Notification Centre; idle muted by default; "Waiting" filter in inbox is the high-value view. `notifications.cooldown_seconds` per rule reserved in the grammar but not implemented in v1.
- **R3 — Permission denial treated as "broken feature".** Users who decline may think C6 is dead.
  - *Mitigation:* inbox + Dock badge are primary surfaces; Settings shows status; onboarding copy explains.
- **R4 — Provenance drift when the Panel is closed.** Notification fires; user closes the Panel; clicking lands on a missing Panel.
  - *Mitigation:* `DeeplinkRouter` resolves `panelID` via `HierarchyManager`; on miss, opens the inbox row and logs a missed-focus event.
- **R5 — New agents outside the rule-template library.** Users adopting `amp`, `aide-plus`, etc., get no defaults.
  - *Mitigation:* documented `tc label --agent <name>` + rule-copy flow; template rules for Claude / Codex / aider serve as starting points.
- **R6 — Rule evaluation on the hot path.** Regex matching happens inside C3's dispatcher; a pathological regex could stall it.
  - *Mitigation:* not C6's concern per se — C3 owns compile + execute. C6 rejects malformed regexes at `DetectionRulesStore.load()`. C3's own timeout/concurrency caps apply.
- **R7 — Secret leakage via templated `{data.output}`.** Careless rule authorship echoes sensitive lines to the OS surface.
  - *Mitigation:* redaction toggle (DEC-8); documented warning; default rules use `{data.output | firstLine}` only for `blockedOnInput` (prompt text, rarely secret).
- **R8 — Dock badge / inbox drift.** Count desyncs across CLI + UI mutations.
  - *Mitigation:* `InboxStore` is `@MainActor`-confined; all mutations serialise; badge recomputes from in-memory inbox on every mutation.
- **R9 — C3 schema drift. [CLOSED 2026-04-20]** Earlier draft referenced a fictional `AgentHookEvent.structuredPayload`. The v2 doc binds directly against C3's concrete types (`HookEvent`, `HookEnvelope`, `HookEventData`) and the `InternalHookSubscriber` + `HookEventStreaming` protocols. R9 is closed; future C3 schema changes will surface via Swift compiler errors, not a doc drift.
- **R10 — Sentinel token visible in scrollback.** `::touchcode:agent-complete <panel-id>` lines appear in the user's Panel output.
  - *Mitigation:* accepted trade-off in v1 — it's a stable, greppable marker. Future work: ANSI-escape-hidden variant (`\e[?2026h`-bracketed or similar) if users object.
- **R11 — C3 `internalEventStream()` backpressure.** If C6's tracker loop falls behind a very chatty output stream, AsyncStream buffers can grow.
  - *Mitigation:* C6 processes each envelope synchronously on MainActor (no per-envelope `await`); tracker operations are O(1). On the pathological path, AsyncStream drops the oldest value first per bounded-buffer policy; a dropped `.panelOutput` envelope does not change state (idle timer rearm is inferred from any later activity). Dropped `.panelOutputMatch` envelopes would silently miss a notification — acceptable because the next match fires correctly.
