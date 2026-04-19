# Design Doc: Agent Notification Aggregation (C6)

**Status:** Draft
**Author:** Gump (with Claude)
**Date:** 2026-04-20

## Context and Scope

touch-code runs coding agents (Claude Code, Codex CLI, aider, …) as first-class inhabitants of its Panels. In a typical session a user has 2–8 Panels distributed across Worktrees; most of them are driven by an agent; the user attends only to whichever one last asked for input or just finished. Today, to know which Panel wants attention, the user must tab-scan visually. **C6 closes that loop.**

C6 observes each agent Panel through the C3 lifecycle-hook stream, classifies its state (Running / Completed / BlockedOnInput / Idle), and surfaces transitions on three surfaces: a macOS OS notification, the Dock badge, and an in-app notification inbox with per-Panel provenance. The user can click a notification (OS or in-app) and land in the originating Panel with a single action.

C6 is the **first built-in consumer of C3** and the validation case for the hook design; it ships no public IPC surface of its own (user-facing control is through `tc notifications …` in C4 and a settings pane), but it owns the detection state machine, the inbox data model, and the UserNotifications plumbing.

Repository state at the time of this design:

- [docs/architecture.md](../architecture.md) is stable. [docs/design-docs/0001-terminal-and-hierarchy.md](0001-terminal-and-hierarchy.md) is approved. The C3 design doc is still a placeholder — this doc therefore binds against the product-spec C3 row, the hook event shape already committed by C1+C2 in § API Design (`AsyncStream<TerminalEvent>`), and the supacode/supaterm `AgentHookNotification` reference (pattern borrowing per CLAUDE.md golden rule). Integration points with the eventual C3 design are called out inline and in § Component Boundaries.
- `TouchCodeCore` already contains the hierarchy value types (`Space`, `Project`, `Worktree`, `Tab`, `Panel`, `PanelID`, `Catalog`, `SplitTree`, `AtomicFileStore`). `touch-code/Hooks/` is an empty enum placeholder; `touch-code/Runtime/` has `HierarchyManager` + `CatalogStore`. C6 types will land in `TouchCodeCore` (persistable) and a new `touch-code/Notifications/` in-app module (app-only surfaces).

## Goals and Non-Goals

**Goals**

- Define the `AgentState` state machine and the rules that drive transitions from C3 hook events.
- Define the **detection rule DSL** that users configure in `hooks.json` so C3 can recognise agent prompts without magic.
- Define the **known-binary allowlist** (default-on) that labels a Panel as agent-hosted without user configuration.
- Define the data model for `Notification` and `NotificationInbox` (Codable, persisted) and where they live relative to the architecture invariants.
- Define the three surfaces: OS notifications via `UNUserNotificationCenter`, Dock badge via `NSApp.dockTile.badgeLabel`, and the in-app inbox (store + UI layout + dismissal flow).
- Define macOS notification permission handling: first-run prompt, graceful fallback when denied, user-visible settings toggle.
- Preserve the architecture dependency direction: `C6 → C3 → C2`, zero reverse edges, no new cross-process surface.
- Specify the testing strategy so detection rules are unit-testable without a live libghostty or the macOS notification daemon.

**Non-Goals**

- **Magic agent detection.** No process-tree sniffing, no pty-output heuristics beyond what the hook DSL explicitly matches. Users opt in by labelling Panels (`tc label --agent …`), configuring rules, or accepting the allowlist default. Resolves product-spec Open Question #5.
- **In-app reply / conversational UI.** The inbox shows what happened and where; replying requires focusing the Panel and typing. Building a chat-style reply surface is an IDE move and out of scope per product-spec.
- **Cross-device notification sync / push.** Local-first; no network.
- **Notification scheduling, snoozing, rich attachments.** A transition fires one notification; users can mute per-rule in settings but cannot schedule follow-ups.
- **Hook execution semantics** (in-process vs. out-of-process, concurrency, sandboxing). That belongs to C3. C6 consumes whatever C3 delivers.
- **Notification for non-agent Panels** (build finishes, test-runner output). The hook DSL is general enough to express those, but the default rules set targets agents. Power users can extend.
- **Toast-style in-app overlays** that pop over the terminal. The inbox is a slide-in sidebar; ephemeral toasts are a v2 consideration.

## Design

### Overview

Three pieces.

1. **AgentStateTracker.** One per Panel marked `isAgent = true`. Owns the `AgentState` FSM (`Running | Completed | BlockedOnInput | Idle`) plus an idle timer. Transitions are driven exclusively by C3's event stream: `.panelOutput` bytes are pattern-matched against the user's detection rules; `.panelIdle` fires the idle transition; agent-initiated hooks (e.g. Claude Code's `Stop` hook) arrive as structured `AgentHookEvent`s that map directly onto state transitions. No side effects live in the tracker — it emits `AgentStateTransition` values on an `AsyncStream`.

2. **NotificationCoordinator.** Subscribes to `AgentStateTransition`s, decides whether a transition warrants a user-visible notification (per the rules in § Cross-Cutting § Muting), constructs a `Notification` value, and fans out to three sinks: the inbox (always), the Dock badge (unread counter), and `UNUserNotificationCenter` (if permission granted and the transition is classified as "attention-worthy"). Click handling goes back through a deeplink (`touch-code://panel/<id>/focus`) so there's one code path for "jump to Panel".

3. **Detection rule DSL.** A small, declarative, JSON-serialised grammar persisted in `hooks.json` under `agent_detection`. Users author it by hand (or via `tc hooks edit`); touch-code ships defaults for Claude Code, Codex CLI, and aider. Rules match against the recent output buffer of a Panel (a rolling 4KB tail) and produce `AgentEvent` values consumed by the tracker.

**Why this shape.** The hard problem in agent notification is separating *what counts as an attention moment* from *how we tell the user*. Mixing them — the iTerm "bell" model — produces either too many notifications (every completed command rings) or too few (only hard bells ring, soft "I need your input" moments are missed). Splitting along an `AgentState` FSM lets the detection layer be purely about recognising states from output, and the coordinator layer be purely about presentation policy. Both can be tested in isolation.

The supaterm/supacode reference projects converged on the same split (they call it `AgentHookNotification` + `TerminalHostState.NotificationSemantic`); we inherit the structure and adapt to touch-code's hierarchy (per-Panel provenance instead of per-session).

### System Context Diagram

```
  ┌────────────────────────────────────────────────────────────────────┐
  │                         touch-code app                             │
  │                                                                    │
  │   Runtime/C1  ──▶  AsyncStream<TerminalEvent>                      │
  │                               │                                    │
  │   Hooks/C3    ──▶  AsyncStream<AgentHookEvent>  (raw Hook payloads │
  │                               │                  + rule matches)   │
  │                               ▼                                    │
  │                   ┌──────────────────────────┐                     │
  │                   │ Notifications/C6         │                     │
  │                   │   AgentStateTracker[pid] │  (per agent Panel)  │
  │                   │       │                  │                     │
  │                   │       ▼ AgentStateTransition                   │
  │                   │   NotificationCoordinator                      │
  │                   └───────────┬──────────────┘                     │
  │                               │                                    │
  │            ┌──────────────────┼──────────────────┐                 │
  │            ▼                  ▼                  ▼                 │
  │   UNUserNotification     NSApp.dockTile     NotificationInbox      │
  │   Center  (OS banner)    .badgeLabel         (in-app sidebar +     │
  │                                               Codable store)       │
  │            │                                       │               │
  │            │ click → touch-code://panel/<id>/focus │               │
  │            └───────────────┬───────────────────────┘               │
  │                            ▼                                       │
  │                  DeeplinkRouter → HierarchyClient.focusPanel       │
  └────────────────────────────────────────────────────────────────────┘
```

External touchpoints: `UNUserNotificationCenter` (macOS), `NSApp.dockTile` (AppKit). No network, no IPC. The inbox persists through `AtomicFileStore` (already in `TouchCodeCore`).

### API Design

C6 exposes three Swift interfaces inside the app process. None of them appear on the `tc` IPC surface as first-class methods in v1 (the CLI gets `tc notifications list / clear / mute` implemented as thin wrappers that read/write the inbox store and settings).

#### Types — `TouchCodeCore` additions

Lives in `TouchCodeCore` because the data is persisted (inbox history survives restart) and read by CLI list commands, which must not import Runtime.

```swift
public enum AgentState: String, Codable, Sendable {
  case running           // agent is actively producing output
  case completed         // agent signalled "done" (hook rule or agent-side Stop hook)
  case blockedOnInput    // agent printed a prompt and stopped producing output
  case idle              // no output for `idleThreshold` seconds; not classified above
}

public struct AgentStateTransition: Codable, Sendable, Equatable {
  public let panelID: PanelID
  public let from: AgentState
  public let to: AgentState
  public let at: Date
  public let trigger: Trigger
  public enum Trigger: Codable, Sendable, Equatable {
    case rule(id: String)           // user-configured rule matched
    case agentHook(name: String)    // structured hook payload from the agent (Stop, PermissionRequest…)
    case idleTimer(seconds: Int)    // idle timeout fired
    case userOverride               // user manually set via CLI/UI
  }
}

public struct Notification: Codable, Sendable, Equatable, Identifiable {
  public let id: UUID
  public let panelID: PanelID        // provenance; resolves to Worktree/Tab via Catalog
  public let agent: String           // "claude" / "codex" / "aider" / "custom:<label>"
  public let kind: Kind
  public let title: String           // rendered on banner + inbox row
  public let body: String            // rendered in banner body + inbox detail
  public let createdAt: Date
  public var readAt: Date?           // nil = unread; drives Dock badge count
  public var dismissedAt: Date?      // soft-delete; swept from inbox after 7 days

  public enum Kind: String, Codable, Sendable {
    case completed                   // Running → Completed
    case blockedOnInput              // Running → BlockedOnInput
    case idle                        // Running → Idle  (often muted by default)
    case crashed                     // from .panelCrashed or .panelExited(nonzero)
  }
}

public struct NotificationInbox: Codable, Sendable, Equatable {
  public static let currentVersion = 1
  public var version: Int
  public var notifications: [Notification]   // newest first; cap 500 retained
  public init(version: Int = Self.currentVersion, notifications: [Notification] = []) { … }
  public static func defaultURL(home: URL) -> URL  // ~/.config/touch-code/notifications.json
}
```

`Notification.panelID` is the provenance pointer. The inbox view joins against `Catalog` at render time to show *Project / Worktree / Tab / Panel title*; the join is one-shot on render, not persisted into the `Notification` itself (Panels rename and move; we resolve fresh each time).

#### Swift interfaces inside the app

```swift
@Observable @MainActor
final class AgentStateTracker {
  let panelID: PanelID
  private(set) var state: AgentState = .running
  init(panelID: PanelID, idleThreshold: Duration, clock: any Clock<Duration>) { … }

  func ingest(_ event: TerminalEvent)          // from C1 AsyncStream
  func ingest(_ hook: AgentHookEvent)          // from C3 AsyncStream
  var transitions: AsyncStream<AgentStateTransition> { get }
}

@MainActor
final class NotificationCoordinator {
  init(
    inbox: InboxStore,                         // wraps AtomicFileStore<NotificationInbox>
    badger: DockBadger,                        // abstracts NSApp.dockTile (stubbable in tests)
    osNotifier: OSNotifier,                    // abstracts UNUserNotificationCenter
    muting: MuteRules                          // from settings
  )
  func bind(to trackers: AsyncStream<AgentStateTransition>) async
}

protocol OSNotifier: Sendable {
  func requestAuthorization() async -> AuthorizationStatus
  func post(_ n: Notification) async           // no-op if denied
}

protocol DockBadger: Sendable {
  func setUnreadCount(_ n: Int)                // "" when 0; "99+" when >99
}
```

The tracker is `@Observable` so the inbox-row live badge ("still running" vs. "completed 3s ago") updates without going through TCA. The coordinator is main-actor confined; it is invoked from a single subscription task started at app launch.

#### IPC surface (C4 consumes, defined fully in C4 doc)

C6 does not add new IPC method namespaces. C4 will expose:

- `tc notifications list [--unread] [--panel <id>]` — reads `NotificationInbox` via `system.get_notifications`.
- `tc notifications clear [--panel <id> | --all]` — dismisses via `system.clear_notifications`.
- `tc notifications mute <rule-id> [--panel <id>]` — updates settings via `system.set_mute`.
- `tc label <panel> --agent <name>` — sets `Panel.agentLabel`; drives detection even with no binary match.

All four resolve to MainActor calls into `NotificationCoordinator` / `InboxStore` / `HierarchyClient`. C4 owns the argument parsing; the methods themselves are thin.

### Data Storage

One new file under `~/.config/touch-code/`:

| File | Owner | Schema version | Lifecycle |
|---|---|---|---|
| `notifications.json` | `InboxStore` (C6) | top-level `version: Int` | debounced 500ms trailing, flushed on `applicationWillTerminate`; capped at 500 retained entries; dismissed entries older than 7 days swept on load |

`hooks.json` (owned by C3 per architecture § Persistence) gains a new top-level object `agent_detection` documented below. `settings.json` gains a `notifications` object (permissions status cache, muted rule IDs, badge toggle). No migrations — schema v1 only; unknown versions abort per architecture invariant.

The inbox is capped at **500 retained notifications** with a **7-day soft-delete sweep** because:

- Most notifications are acted on within the first minute; longer history is of archival interest only.
- 500 rows keeps the JSON under ~200KB and the list view trivially scrollable.
- The sweep runs on load; no background timer needed.

Write path mirrors `CatalogStore`: the store is `@MainActor`, holds the in-memory `NotificationInbox`, and calls `AtomicFileStore<NotificationInbox>.save` on a debounced trailing 500ms timer. `applicationWillTerminate` flushes synchronously. Reads are one file on launch.

### Component Boundaries

```
TouchCodeCore (static framework — persistable types)
├── AgentState, AgentStateTransition
├── Notification, NotificationInbox
├── AgentDetectionRules  (Codable DSL types; no matching logic)
└── (existing) AtomicFileStore, Catalog, PanelID, …

touch-code/Notifications  (NEW in-app module; folder-level boundary)
├── AgentStateTracker.swift        — per-Panel FSM
├── NotificationCoordinator.swift  — fan-out policy
├── InboxStore.swift               — AtomicFileStore wrapper + debounced save
├── DetectionRuleMatcher.swift     — regex + literal + anchored matchers
├── OSNotifier.swift               — UNUserNotificationCenter adapter + mock
├── DockBadger.swift               — NSApp.dockTile adapter + mock
└── Views/
    ├── InboxSidebar.swift         — SwiftUI list + filter chips
    └── InboxRow.swift             — provenance + actions (Focus / Dismiss)

touch-code/Hooks  (C3 — owned by C3 design doc)
├── HookDispatcher                 — emits AsyncStream<AgentHookEvent>
├── AgentHookEvent                 — { panelID, name, structuredPayload? }
└── (C6 subscribes; does not import internals)
```

**Dependency rules.**

- `touch-code/Notifications` imports `TouchCodeCore` (domain types), `touch-code/Hooks` (subscribes to the event stream — read-only), `touch-code/Runtime` (reads `HierarchyManager` for provenance; never mutates). It does **not** import AppKit-GUI from elsewhere; SwiftUI inbox views import AppKit only as needed for `NSApp.dockTile`.
- `TouchCodeCore` must not grow a dependency on `UserNotifications` / AppKit — it stays pure. The UN adapter lives in the app module. CLI list commands read the inbox file through `AtomicFileStore<NotificationInbox>` without needing any UI framework.
- No reverse edges. C3 does not know C6 exists; it publishes an event stream. `HierarchyManager` does not know C6 exists; it is a read dependency.

**What each component is NOT responsible for.**

- `AgentStateTracker`: not responsible for persistence, for OS notifications, for formatting strings for the user. It only classifies transitions.
- `NotificationCoordinator`: not responsible for the idle timer, for detecting "which Panel is an agent" (driven by `Panel.agentLabel` + allowlist check at tracker-creation time). It only decides *whether* to notify and *where*.
- `InboxStore`: not responsible for UI concerns (unread styling, ordering in the view) — that's SwiftUI-level computed state.
- `DetectionRuleMatcher`: not responsible for owning rules (they live in `hooks.json` / C3) — it is a pure function from (rule, text tail) → match.

### Detection Rule DSL

Rules are JSON under `hooks.json#agent_detection.rules`. Example (default ships for Claude Code):

```json
{
  "agent_detection": {
    "known_binary_allowlist": ["claude", "codex", "aider"],
    "rules": [
      {
        "id": "claude.blocked_on_input",
        "agent": "claude",
        "applies_when": { "panel_labelled_agent": "claude" },
        "match": { "contains_any": ["Do you want to proceed?", "Approve tool call?"] },
        "transition_to": "blockedOnInput",
        "title": "Claude is waiting for your approval",
        "body": "{last_line}"
      },
      {
        "id": "claude.completed",
        "agent": "claude",
        "applies_when": { "hook_event_name": "Stop" },
        "transition_to": "completed",
        "title": "Claude finished",
        "body": "{hook.last_assistant_message | truncate: 140}"
      },
      {
        "id": "aider.blocked_on_input",
        "agent": "aider",
        "applies_when": { "panel_labelled_agent": "aider" },
        "match": { "regex": "^>\\s*$", "on": "last_nonempty_line" },
        "transition_to": "blockedOnInput",
        "title": "Aider is waiting",
        "body": "aider prompt ready"
      }
    ]
  }
}
```

**Grammar.**

- `id` (required, string) — stable identifier; used for muting and telemetry.
- `agent` (required, string) — the label attached to the resulting `Notification.agent`.
- `applies_when` (optional object) — predicate gates. Supported keys:
  - `panel_labelled_agent: <string>` — matches if `Panel.agentLabel == <string>` (set by `tc label --agent …` or inferred from allowlist).
  - `hook_event_name: <string>` — matches on structured hook payload name (requires C3 agent-hook support; Claude Code's `Stop`, `PreToolUse`, etc.).
  - `panel_id: <uuid>` — scopes to one Panel (advanced; for user overrides).
- `match` (optional object) — applied against the Panel's rolling output tail (4KB). Exactly one of:
  - `contains_any: [<string>, …]` — literal substring match.
  - `regex: <ECMA-262>` and optional `on: "tail" | "last_line" | "last_nonempty_line"` (default `tail`).
- `transition_to` (required) — one of the `AgentState` cases.
- `title` / `body` (required for user-visible transitions) — template strings with `{…}` placeholders: `{agent}`, `{panel_title}`, `{worktree_branch}`, `{last_line}`, `{hook.<field>}`, with an optional `| truncate: N` filter.

**Evaluation order.** Rules are evaluated top-down on every C3-delivered event that carries a matched rule ID (C3 does the regex/contains work for efficiency; C6 only consumes the match). Structured agent-hook events (`hook_event_name`) bypass the match engine and go straight to the `applies_when.hook_event_name` branch. First matching rule wins; later rules on the same event are ignored for notification purposes but not for state: if two rules would both transition to a state, the first rule's `title`/`body` is used, and `AgentStateTransition.trigger.rule(id:)` records the winner.

**Idle transition** is not rule-driven — it is a timer owned by `AgentStateTracker`. Default `idleThreshold = 120s` (configurable per-rule group via `agent_detection.idle_threshold_seconds`). Idle notifications are **muted by default**; power users opt in via settings.

**Why a DSL and not user-supplied Swift/JS.** The DSL is small, declarative, and auditable by reading `hooks.json`. In-process scripting would require an embedded VM (loss of Swift 6 strict concurrency safety) or an out-of-process hook per event (already handled by C3 for arbitrary handlers; C6 rides on top of C3's matched-event stream for the 95% case). Users who need arbitrary logic write a C3 hook that emits an explicit `AgentHookEvent` and map it via `applies_when.hook_event_name`.

### Known-Binary Allowlist

On Panel creation (`Runtime.PanelSurface` spawns a shell and records the foreground process via pty/ptrace-free polling), the tracker asks `HierarchyManager` for the Panel's last-seen foreground binary basename. If it is in `known_binary_allowlist` (default `["claude", "codex", "aider"]`), the Panel is auto-labelled with that agent and the corresponding default rules apply. The user can override at any time with `tc label <panel> --agent <name>` or `--no-agent` to opt out entirely.

Rationale: aligns with product-spec Open Question #5 ("user-configured hook rules + known-binary allowlist default; no magic detection"). The allowlist is the only automatic step; everything else is user-driven.

### Surfaces

**OS notifications — `UNUserNotificationCenter`.**

- Request authorization once, at first agent-Panel creation after install (not at launch — reduces prompt fatigue).
- `UNAuthorizationOptions`: `[.alert, .badge, .sound]`. `.alert` covers banner + alert styles (user chooses in System Settings).
- Every `Notification` posted to the OS sets:
  - `threadIdentifier = panelID.raw.uuidString` — macOS groups per-Panel so a chatty agent doesn't flood the Notification Centre.
  - `categoryIdentifier` = notification Kind (`completed` / `blockedOnInput` / `crashed`) — drives action buttons (Focus, Dismiss).
  - `userInfo["deeplink"] = "touch-code://panel/<id>/focus"` — click routes through `DeeplinkRouter`.
- `UNNotificationAction`s: "Focus Panel" (default; dismisses + focuses), "Dismiss" (dismisses only). No "Reply" — v1 does not own agent-side input injection beyond `tc send`.

**Dock badge — `NSApp.dockTile.badgeLabel`.**

- Count is `inbox.notifications.count(where: { $0.readAt == nil && $0.dismissedAt == nil })`.
- Rendered as a plain decimal; "99+" when > 99.
- Cleared when the last unread is read (opening the inbox marks visible rows read; focusing a Panel via click marks that Panel's unreads read).
- Toggleable in settings (`notifications.badge_enabled`, default `true`).

**In-app inbox — `InboxSidebar`.**

Layout: right-side slide-in sidebar, toggled via ⌘⇧N or the toolbar bell icon. Width 320pt; collapsible. Rows are newest-first; each row shows agent avatar (text badge "C" / "X" / "A"), title, body (1 line, truncated), provenance (Project / Worktree · Tab · Panel), relative time, state chip (Completed / Waiting / Idle / Crashed), and hover actions (Focus, Dismiss).

Filter chips at the top: "All / Unread / Waiting / Completed / Crashed". The "Waiting" filter is the high-value view — at a glance, all Panels currently asking for input.

Dismissal flow: swipe-left on a row reveals Dismiss (soft-delete; sets `dismissedAt`, kept 7 days for undo). "Clear all" action in the sidebar header. Double-click focuses the originating Panel and marks the notification read.

Empty state: inbox-zero art with copy "No agent pings. Nice."

### Permission Handling

Apple's `UNUserNotificationCenter` permission model is three-state: `.notDetermined`, `.authorized` (includes `.provisional`), `.denied`. C6 handles each:

- `.notDetermined` → on first agent-Panel creation, show a pre-prompt sheet explaining why (with "Not now" deferring for 24h and a "Never" suppressing the prompt permanently but keeping the inbox active). On "Continue", call `UNUserNotificationCenter.current().requestAuthorization(options:)`.
- `.authorized` → post notifications normally.
- `.denied` → suppress OS banners. Inbox and Dock badge still function. Settings pane shows a "Notifications are off — open System Settings" link with a deeplink to `x-apple.systempreferences:com.apple.preference.notifications?id=<bundle-id>`.
- On every app launch after the first, re-query `getNotificationSettings()` once and update `settings.json#notifications.auth_status` so the UI reflects the current state without prompting.

First-run prompt text (draft): *"touch-code can tell you when an agent finishes or is waiting for your input, even when this app is in the background. We only notify on state changes — no chatty pings."*

Fallback when denied: the **Dock badge + inbox are the source of truth**, not the banner. The product goal is "user returns to the correct Panel within 30s of an agent-completion event"; the Dock badge + inbox view satisfy this without OS permission. We document this explicitly so users who decline do not think the feature is broken.

## Alternatives Considered

### A1. Magic agent detection via process scanning

Traverse the Panel's pty child processes, detect `claude`/`codex`/`aider` dynamically, auto-apply rules, and infer state from subprocess stdin/stdout without user config.

- **Pros:** zero user configuration.
- **Cons:** requires running `ps`/`proc_pidinfo` on every Panel at frequent intervals — power and CPU drag. More importantly, agents run inside `tmux`, `sudo`, shells, and `zellij` sessions where the literal binary isn't the Panel's immediate child; heuristics break silently. Product-spec Open Q5 *explicitly* rejects magic detection.
- **Verdict:** rejected — spec-level.

### A2. Single uniform notification per output burst

Every burst of output ending in N seconds of silence produces one notification ("Panel X spoke"); user decides if it matters.

- **Pros:** simplest implementation; no state machine.
- **Cons:** matches iTerm's "bell" model, which is famously noisy. The core value of C6 is *separating* "waiting for you" from "chatting at you"; erasing that separation reduces C6 to a bell.
- **Verdict:** rejected — regresses on the stated user value ("80% of notifications lead the user to the correct Panel within 30s").

### A3. Deliver notifications only via the OS, no in-app inbox

Lean entirely on macOS Notification Centre; touch-code just posts.

- **Pros:** minimal UI work.
- **Cons:** (a) macOS groups notifications by thread but has no provenance-aware list filtered by "Panel / Worktree"; (b) when permission is denied the feature silently dies; (c) the user's query "what did agent X say while I was in a meeting" has no answer. The inbox is the fallback + the history + the filter surface.
- **Verdict:** rejected — the inbox is load-bearing for the permission-denied case and for catch-up UX.

### A4. Store `Notification` inside `Catalog` / `catalog.json`

Put the inbox in the hierarchy file since every notification has a `panelID`.

- **Pros:** one file; simpler persistence story.
- **Cons:** notifications churn 100× faster than hierarchy; debouncing them through catalog writes would muddy catalog's write cadence and inflate its file size. Separate files have separate write pressures.
- **Verdict:** rejected — separation is cleaner and no harder.

### A5. Use a Swift script / JS VM for detection rules

Allow users to write arbitrary Swift or JavaScript in a `detection.js` file, evaluated in an embedded VM.

- **Pros:** expressive power.
- **Cons:** C3 already exists for arbitrary logic — users who need Turing-complete detection write a C3 hook handler. Embedding a JS VM adds a large dependency, a sandboxing problem, and a testing surface that architecture invariants already say no to ("Hooks are out-of-process only in v1").
- **Verdict:** rejected — C3 is the escape hatch.

### A6. Per-Panel agent-state chip in the Tab bar instead of (or alongside) notifications

Drop banners; just colour the Tab icon when state changes.

- **Pros:** zero interruption; purely passive.
- **Cons:** fails the "user left the app" case — if touch-code isn't foreground, the Tab colour is invisible. OS notifications are necessary for cross-app attention capture.
- **Verdict:** partially adopted — we will add a subtle per-Tab state indicator in the Tab-bar UI (tracked separately in the C2 UI pass). C6 focuses on the cross-app attention path.

## Cross-Cutting Concerns

### Muting policy

A `Notification` is surfaced on the OS if **all** of these hold:

- `notifications.enabled == true` in settings (global kill switch).
- Permission is `.authorized`.
- The originating rule's `id` is not in `settings.json#notifications.muted_rule_ids`.
- The target Panel is not in `settings.json#notifications.muted_panel_ids`.
- The notification `Kind` is not `idle` *unless* `notifications.surface_idle == true` (default `false`).

The inbox always receives the `Notification` — even when the OS surface is muted — so the history is complete. The Dock badge counts only unread non-dismissed notifications whose OS surface would have been shown (so muted rules don't inflate the count). This keeps the badge meaningful as "things the user hasn't yet attended to".

### Performance

- Rule matching runs inside C3's dispatch loop against a 4KB rolling tail (not the full scrollback). Regex compilation is cached per rule (stable `id`).
- The tracker receives `.panelOutput` events pre-coalesced by C1 (≤60Hz, ≤16KB batches). At 8 agent Panels this is ≤480 events/s — trivial.
- Idle timer uses a single `Task.sleep` rearmed on each output event, so idle tracking is zero-cost when Panels are chatty.
- Inbox writes are debounced 500ms, capped at 500 entries. No background sweeps; sweep runs on load only.

### Observability

- `os.Logger` category `com.touch-code.notifications`: transitions (`.info`), OS post success/failure (`.debug`), permission state changes (`.info`).
- Every posted notification has a correlation UUID that matches its inbox entry; CLI `tc notifications list --verbose` shows it for debugging.
- Local-only telemetry (opt-in, aligned with product-spec Success Metrics): per-day counts of transitions by kind; time from notification to Panel focus (measurable via `DeeplinkRouter` → `focusPanel` latency). Ships as a future feature; schema slot reserved in `notifications.json`.

### Testing strategy

- **`DetectionRuleMatcher`** — pure-value-type; 100% unit coverage. Table-driven tests: (rule, tail) → expected match or no-match; regex anchoring cases; template rendering with `{…}` placeholders; `truncate` filter edge cases (Unicode grapheme clusters).
- **`AgentStateTracker`** — `@Observable` FSM is unit-tested with a mock `Clock` and hand-fed `TerminalEvent` / `AgentHookEvent` streams. Test matrix: every `(AgentState, Trigger) → AgentState`; idle timer rearming; no spurious transitions on zero-length output; multi-rule-same-event wins first.
- **`NotificationCoordinator`** — integration-tested against a mock `OSNotifier` and `DockBadger`. Scenarios: permission denied (no OS post but inbox still accrues; badge still increments); muted rule (inbox accrues, OS skipped, badge does not increment); dismiss updates badge synchronously.
- **`InboxStore`** — round-trip Codable tests; write-debounce coalescing test (100 appends in 100ms produce 1 file write); flush-on-terminate test; cap + sweep on load.
- **End-to-end** — a small XCTest that drives the in-memory stack: fake C3 delivers a "Claude blocked on input" match, asserts a `Notification` of kind `.blockedOnInput` reaches the inbox and the badge flips to `1`. No live UNUserNotificationCenter; we assert against the mock. Gated behind the same flag the C1+C2 test suite uses.

### Migration

v1 only: `notifications.json` ships at `version: 1`. Unknown versions abort per architecture invariant. Users downgrading keep their catalog but see an empty inbox (acceptable; inbox is ephemeral).

### Security & privacy

- Notifications never cross a network. No telemetry is enabled unless the user opts in.
- `Notification.body` may include the last line of terminal output, which could contain secrets. Mitigation: the default rule templates use `{last_line}` only for `blockedOnInput` (prompt text, rarely secret) and `{hook.last_assistant_message | truncate: 140}` for `completed` (agent's own summary). Users authoring custom rules are warned in `hooks.json` documentation. A global toggle `notifications.redact_bodies = true` (default `false`) replaces bodies with "(redacted)" on the OS surface while keeping them in the inbox (which is local-only and user-readable anyway).

## Decisions

These are locked at approval; revisit via amendment only.

- **DEC-1 — Open Q5 resolution.** Agent detection is user-driven: **(a)** a known-binary allowlist (`claude`, `codex`, `aider`) auto-labels matching Panels; **(b)** users override with `tc label <panel> --agent <name>` or `--no-agent`; **(c)** rules live in `hooks.json#agent_detection.rules`. No process-tree heuristics, no ML, no magic. Directly implements the product-spec Q5 leaning.
- **DEC-2 — State machine shape.** Four states: `running | completed | blockedOnInput | idle`. Transitions driven by (i) matched detection rules, (ii) structured agent-hook events from C3, (iii) an idle timer. No intermediate states ("near-idle", "warming up") in v1.
- **DEC-3 — Persistence separation.** Inbox lives in `notifications.json`, not inside `catalog.json`. Notifications churn orders of magnitude faster than hierarchy; separate file, separate write pressure.
- **DEC-4 — Permission prompt timing.** First-run prompt fires on **first agent-Panel creation**, not app launch. Reduces unearned-permission asks for users who never run agents.
- **DEC-5 — Inbox > OS banner as source of truth.** Feature stays useful when UN permission is denied; Dock badge + inbox satisfy the "find the right Panel" product goal. OS banners are an enhancement, not a prerequisite.
- **DEC-6 — Rule DSL scope.** Declarative only; Turing-complete detection handled by C3 hook handlers escalating to `AgentHookEvent`s. No embedded VM, no user-supplied Swift.
- **DEC-7 — Idle notifications muted by default.** Idle is high-volume and low-signal; surfacing it by default trains users to ignore the badge. Power users opt in.
- **DEC-8 — Body redaction is a toggle, not mandatory.** Default off (keeps the product useful out of the box); users in regulated environments can flip it. The inbox is always local; network posting is not a v1 feature.
- **DEC-9 — Inbox retention: 500 rows, 7-day soft-delete sweep.** Rationale in § Data Storage. Revisit if telemetry shows active users routinely scroll past 500.
- **DEC-10 — No new IPC namespace.** C4's `tc notifications …` commands attach to an existing `system.*` namespace rather than adding `notifications.*`. Fewer namespaces keep the CLI surface predictable; the list/clear/mute operations are CRUD on existing state, not a new domain.

## Risks

- **R1 — False positives from brittle regexes in user rules.** A rule that fires on every agent output ("matches too much") floods the inbox and the badge. Mitigation: (i) per-rule telemetry in the inbox entry (`trigger.rule(id:)` is persisted); (ii) "Mute this rule" action on inbox rows (one click → adds to `muted_rule_ids`); (iii) ship conservative defaults and document the DSL with anti-patterns.
- **R2 — Notification fatigue.** Even correct rules can overwhelm a user running 6 agents. Mitigation: (i) `threadIdentifier` groups by Panel so Notification Centre collapses them; (ii) idle muted by default; (iii) "Waiting" filter in the inbox is the high-value view; (iv) a future `notifications.cooldown_seconds` per rule is reserved in the DSL grammar but not in v1.
- **R3 — macOS permission denial treated as "broken feature".** Users who decline may think C6 is dead. Mitigation: inbox + Dock badge are the primary surfaces; settings pane shows permission state clearly with a deep-link to System Settings; permission denial is documented in onboarding copy.
- **R4 — Provenance drift when Panel is closed.** A notification fires; user dismisses the Panel 10 seconds later; clicking the banner lands on a closed Panel. Mitigation: `DeeplinkRouter` resolves `panelID` via `HierarchyManager`; if not found, falls back to focusing the inbox row (still useful) and logs a missed-focus event for telemetry.
- **R5 — Agent renames / new agents out of the allowlist.** Users adopting a new agent ("amp", "aide-plus") get no defaults. Mitigation: documented `tc label --agent <name>` flow; ship sample rule templates for Claude Code / Codex / aider that users copy and rename.
- **R6 — Rule evaluation on the hot path.** If C3's dispatch loop runs rule matches synchronously against every `panelOutput`, a pathological regex could stall the UI. Mitigation: (i) C1 already coalesces output; (ii) rule matching runs on C3's background queue, not main actor; (iii) per-rule compile cache; (iv) regex compilation failures at load time reject the rule with a user-visible error in settings rather than crashing at runtime.
- **R7 — Secret leakage in `{last_line}`.** A rule sloppily matched on `contains_any: ["]"]` could echo a line with an API key. Mitigation: redaction toggle (DEC-8); documented warning in `hooks.json`; default rules never use `{last_line}` on `completed` (only on `blockedOnInput`, which is prompt text).
- **R8 — Dock badge + actual unread drift.** Count can desync if state is mutated from multiple paths (CLI clear concurrent with UI dismiss). Mitigation: `InboxStore` is `@MainActor`-confined; all mutations serialise through it; badge recomputes on every mutation from the current in-memory inbox.
- **R9 — C3 contract drift.** C6 binds against `AgentHookEvent` shape that C3 hasn't finalised. Mitigation: this doc pins the minimum payload C6 requires (`panelID`, `name`, `structuredPayload: [String: JSONValue]?`); the C3 design doc must satisfy at least this shape. Integration review is the gate.
