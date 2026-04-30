# Design Doc: Notifications

**Status:** Draft
**Author:** Gump (with Claude)
**Date:** 2026-04-30

## Context and Scope

This design implements the [Notifications product spec](../product-specs/notifications.md) — a system that pulls the user's attention back to a specific Pane when a coding agent or long-running command needs them. It supersedes the prior C6 design line:

- `docs/design-docs/c6-agent-notifications.md`
- `docs/design-docs/c6-agent-notifications-v2.md`
- `docs/design-docs/c6-m5-inbox-sidebar.md`
- `docs/exec-plans/0006-agent-notifications.md`

…all of which assumed a "Panel" abstraction that was never adopted on `main`, an FSM tracker, a user-editable rule DSL, and an ~24-file / ~2900-line implementation. The audit in this thread concluded the C6 design was overbuilt for the actual user need; this doc replaces it with a smaller design grounded in primitives the runtime already exposes.

The hierarchy on `main` is `Catalog → Project → Worktree → Tab → Pane`. A Pane is a single Ghostty surface; multiple Panes split-arrange inside a Tab via a recursive `SplitTree<PaneID>`.

## Goals and Non-Goals

**Goals**

- Translate two classes of in-Pane events (waiting-for-input, task-finished) into notifications without writing a stdout scanner from scratch.
- Persist the inbox across app restarts using the existing `AtomicFileStore` pattern.
- Expose unread state through hierarchical roll-up badges that show only at the deepest hidden ancestor, plus a single bell entry in the worktree status bar with a popover inbox.
- Deliver macOS banners only when the originating Pane is not the user's current focus.
- Land in ≤ 7 files / ≈ 600 LOC, including tests.

**Non-Goals**

- No stdout regex scanning. v1 consumes only the structured events libghostty + the runtime already emit. Tools that don't emit OSC 9 / ring the bell / use shell integration are silently uncovered; this is documented, not patched.
- No hook-based detection (c3-hooks integration). The hook-source path is reserved for v2 and would be additive.
- No user-editable detection rules, template DSL, severity levels, snooze, sound, pane-internal toast, hover popover, or per-rule mute.
- No CLI access to the inbox in v1. The data model lives in `TouchCodeCore` so that surfacing it later is a small change, but `tc` does not query it now.

## Design

### Overview

The single design insight that drives everything: **the runtime already exposes the structured events we need**. `TerminalEvent` and `PaneInfoDelta` already surface OSC 9 desktop notifications, terminal bell, OSC 133 command-finished, child-exit, idle, and crash. v1 of the notification system is therefore a small **translator + store + UI** sitting downstream of the existing event stream — not a new detection engine.

The user-facing surface is one bell button in the existing worktree status bar (with a numeric unread badge) and four hierarchical roll-up badges in the sidebar / tab bar / pane chrome that show only at the deepest still-hidden ancestor. Clicking the bell opens a popover; clicking a row in the popover (or a macOS banner) drives a new `RootFeature.focusHierarchyPath` action that walks the path expanding ancestors, switching worktrees, activating tabs, and focusing panes as needed.

The chosen trade-off compared with both reference points:

- vs. **supacode** (~900 LOC): we add persistence + per-level roll-up badges + on-demand permission. We keep the bell-popover entry and the structural simplicity.
- vs. **C6 worktree** (~2900 LOC): we drop the stdout scanner, FSM tracker, rule DSL, template renderer, registry, settings store, broken-file backup, and most of the bridging adapters. We keep the salvaged `OSNotifier` only.

### System Context Diagram

```
                                                    ┌────────────────────────────┐
                                                    │  UNUserNotificationCenter  │
                                                    └──────────▲─────────────────┘
                                                               │ banner / permission
                                                               │
┌──────────────┐   TerminalEvent /   ┌────────────────────┐    │
│   Runtime    │   PaneInfoDelta     │     Notification   │    │     ┌─────────────────┐
│  (Ghostty +  │────────────────────▶│       Detector     │────┼────▶│   OSNotifier    │
│ TerminalEng) │                     └─────────┬──────────┘    │     └─────────────────┘
└──────────────┘                               │ append        │
                                               ▼               │     ┌─────────────────┐
                                     ┌────────────────────┐    └────▶│    DockBadger   │
                                     │ NotificationStore  │          └─────────────────┘
                                     │   (in-mem + JSON)  │
                                     └─────────┬──────────┘
                                               │ unread set deltas
                                               ▼
┌─────────────────────┐  Catalog focus + ┌────────────────────┐
│   RootFeature /     │─────────────────▶│    RollupIndex     │
│  HierarchySidebar   │  expanded state  │  [ScopePath: Int]  │
└──────────▲──────────┘                  └─────────┬──────────┘
           │                                        │ keypath read
           │ focusHierarchyPath(P,W,T,Pn)           ▼
           │                            ┌────────────────────┐
           └────────────────────────────│  Status-Bar Bell + │
                                        │   Inbox Popover    │
                                        └────────────────────┘
```

### Detection (DQ1)

`NotificationDetector` subscribes to the runtime's `TerminalEvent` stream and translates structured events into notifications. The translation table:

| Source event | Becomes | Kind |
|---|---|---|
| `PaneInfoDelta.desktopNotification(title, body)` | one notification with that title/body | `.waitingForInput` if title/body matches a small heuristic ("permission", "approval", "input", "?"); else `.taskFinished` |
| `PaneInfoDelta.bellRang` | "Pane rang the bell" | `.waitingForInput` |
| `PaneInfoDelta.commandFinished(exitCode, duration)` | "command finished in Ns" or "exited with status N" | `.taskFinished` (only emitted when shell-integration is active) |
| `TerminalEvent.paneExited(code, signal)` | "pane exited" with status / signal | `.taskFinished` |
| `TerminalEvent.paneCrashed(reason)` | "pane crashed: $reason" | `.taskFinished` (was T3 in the spec; merged here) |
| `TerminalEvent.paneIdle(duration)` | "task idle for $duration" | `.taskFinished` (only when `duration ≥ 30s` AND the pane has produced output recently AND no shell prompt detected) |

Notifications are dropped silently when the source Pane has notifications disabled (`Pane.labels` contains `"notifications:muted"`).

**Dedup window** (N5): the store keeps a small `(paneID, kind) → lastTimestamp` map. An incoming notification within 30 s of the previous one for the same `(paneID, kind)` updates the existing row's body and timestamp instead of appending. Unread count is unchanged.

The detector runs on the same actor as the runtime event loop; output is fanned to the store via a `MainActor` hop.

### Storage (DQ2)

`NotificationStore` holds the inbox as `[Notification]` in memory and persists to `~/.config/touch-code/notifications.json` using `AtomicFileStore`. The file is **separate** from `catalog.json`: notifications are time-series data, the catalog is structural; mixing them complicates Catalog schema migration.

```swift
public struct Notification: Codable, Sendable, Identifiable {
  public let id: NotificationID
  public let kind: Kind                    // .waitingForInput | .taskFinished
  public let title: String
  public let body: String
  public let createdAt: Date
  public var readAt: Date?                 // nil while unread
  public let source: SourcePath            // (P, W, T, Pn) at creation time

  public enum Kind: String, Codable, Sendable { case waitingForInput, taskFinished }
  public struct SourcePath: Codable, Sendable, Equatable {
    public let projectID: ProjectID
    public let worktreeID: WorktreeID
    public let tabID: TabID
    public let paneID: PaneID
  }
}
```

Persistence is debounced (250 ms after the last mutation) and runs off the MainActor. On launch, the store loads the file, then synchronously runs two sweeps before exposing the inbox:

- **Age sweep (P3):** drop anything older than 7 days.
- **Cap sweep (P2):** if `> 500` entries remain, evict oldest read first, then oldest unread, until size = 500.

The 500-entry cap is also enforced on every append.

`SourcePath` deliberately stores raw IDs, not weak references. The catalog can mutate independently; on click, navigation re-resolves the IDs against the current catalog (G3: dead-target fallback to the deepest still-existing ancestor).

### Roll-up (DQ3)

Roll-up is computed in a TCA reducer derivation, not a separate background process. A small struct `RollupIndex` is rebuilt whenever either input changes:

- **Input A:** the set of unread notifications (each carries a `SourcePath`).
- **Input B:** focus state from `RootFeature` — `(focusedPaneID, activeTabID, activeWorktreeID, expandedProjectIDs, expandedWorktreeIDs)`.

The output is a flat `[ScopePath: Int]` keyed by hierarchy node, where a level emits a count only if it is *currently hidden* per the visibility rules:

- A Project shows a count if it is collapsed in the sidebar.
- A Worktree shows a count if its Project is expanded but the Worktree is not the active one (or is collapsed in a sidebar that supports collapse).
- A Tab shows a count if its Worktree is active but the Tab is not the active one.
- A Pane shows a count if its Tab is active but the Pane is not the focused one.

The rule is single-source: **each unread notification contributes its count to exactly one level — the deepest ancestor currently hidden from the user.** Sidebar / tab-bar / pane-chrome views read counts via key path; the global Dock badge mirrors `unread.total`.

Catalog size on the user side is small (tens of nodes), so an O(N) recompute on every input delta is fine. No incremental tree maintenance.

### Navigation (DQ4)

A new action on `RootFeature`:

```swift
case focusHierarchyPath(SourcePath, fallback: NavigationFallback)
```

Handler walks the path:

1. If the Project no longer exists → fall back per `NavigationFallback`.
2. Switch `Catalog.selectedProjectID` and expand the project row.
3. If the Worktree no longer exists → fall back to project root.
4. Set `Project.selectedWorktreeID` to switch to that Worktree's tabs/panes.
5. If the Tab no longer exists → land on the Worktree (no further descent).
6. Set `Worktree.selectedTabID`.
7. If the Pane no longer exists → land on the Tab (no further descent).
8. Set focused Pane via the existing `hierarchyClient` API.

`NavigationFallback` is a single enum value picked by the caller (`.deepestExisting` for inbox-row clicks, identical for banner clicks). G3's "subtle 'source no longer exists' indicator" is rendered in the inbox popover as a faded row with a strikethrough source label; the row stays.

This action is *not* routed through `PaneActionRouter` — that router handles intra-pane / intra-tab intents. Cross-worktree navigation is `RootFeature`'s natural responsibility (it already owns selection state).

### Status-Bar Bell + Inbox Popover

The existing `StatusBarFeature` (`apps/mac/touch-code/App/Features/StatusBar/`) currently fills a single center slot of the worktree status bar with one of `{toast, pullRequest, motivational}`. v1 adds a **right-anchored bell slot** that is independent of the center slot and always present:

```
┌─────────────────────── worktree status bar ───────────────────────┐
│  [left chrome]    [   center-slot form   ]              [🔔 3]    │
└───────────────────────────────────────────────────────────────────┘
```

`InboxBellFeature` owns:

- The bell button (icon + small badge with global unread count, hidden when 0).
- The popover content: a vertical list of `Notification` rows newest-first, with two filter chips (All / Unread). Each row shows kind icon, title, body, "Project › Worktree › Tab" trail, relative time. Clicking dispatches `focusHierarchyPath`.
- A "Mark all read" action in the popover header.
- A "Settings…" link that opens the Settings Notifications panel.

The bell button does **not** open a sidebar route or a separate window; the popover is the only entry into the inbox.

### Component Boundaries (DQ5)

```
TouchCodeCore/Notifications/
  Notification.swift             // model only — id, kind, source path, ts, read
                                 // (kept in Core in case CLI exposes inbox later)

touch-code/App/Features/Notifications/
  NotificationDetector.swift     // TerminalEvent → Notification
  NotificationStore.swift        // [Notification] + AtomicFileStore + sweep/cap
  RollupIndex.swift              // [ScopePath: Int] derivation
  OSNotifier.swift               // UNUserNotificationCenter wrapper (salvaged from C6)
  DockBadger.swift               // dockTile.badgeLabel mirror, ~30 LOC
  InboxBellFeature.swift         // bell button + popover content + filter chips
```

Dependency direction: `TouchCodeCore.Notification ← Detector → Store → RollupIndex → InboxBellFeature, OSNotifier, DockBadger`. The store has no knowledge of UI or OS facilities; UI components observe the store.

The Settings Notifications panel is a thin section added to the existing `App/Features/Settings/` reducer; it is not a separate file owned by Notifications.

## Alternatives Considered

### A1 — stdout regex scanner

Add a per-Pane regex scanner over `paneOutput` to detect prompt-style waits on shells without OSC 9 / bell.

**Why rejected:** Patterns drift. A regex for "(y/n)" matches code review explanations and chat transcripts. Once we ship one regex set, users want to edit it; the rule editor was the largest single piece of complexity in the C6 worktree (`AgentDetectionRules` + `RuleStore` + `TemplateField` + `TemplateRenderer` + `DetectionRouter`, ~700 LOC). Documenting the gap ("emit OSC 9 from your tooling") is cheaper than maintaining the regex set forever. v2 can reintroduce a scanner as an optional module if real users hit the gap.

### A2 — Sidebar inbox route (separate page)

Inbox lives in a top-level sidebar entry that takes over the main viewport when selected (this was the C6.M5 design).

**Why rejected:** Confirmed with the user. The sidebar is already busy (project list, worktree groups, tag chips). Notifications are by nature transient — we read them, click through, forget. A persistent route promotes them to first-class navigation, which they don't deserve. A bell + popover matches the actual flow ("oh, notification → read → jump → done").

### A3 — Hook-based detection via c3-hooks

Treat the c3 lifecycle hook stream as the authoritative T1/T2 source.

**Why rejected:** c3-hooks landed but only Claude Code currently writes them; relying on hooks excludes every other agent and every plain shell command. The runtime's structured events cover the same ground for any tool that respects OSC 9 / OSC 133 — strictly broader coverage. We can additively consume hooks in v2 if there are hook-only signals not reachable via OSC, but v1 doesn't depend on c3.

### A4 — Reuse C6 worktree as-is

Land the C6 design with cosmetic edits.

**Why rejected:** The audit (this conversation, prior turns) found the C6 codebase to be ~3× the LOC needed for the v1 user surface, with most abstractions (`TrackerRegistry`, `TemplateRenderer`, `AgentStateTransition`, `BrokenFileBackup`, the `Bridging/` layer, `NotificationPermissionDelegate`, the rule-editor surface) carrying no v1 user value. Selectively extracting from it is more work than rewriting; ~80 % of its tests are coupled to the discarded abstractions.

The one C6 artifact we keep: `OSNotifier.swift`, a thin `UNUserNotificationCenter` wrapper.

## Cross-Cutting Concerns

### Permission

`OSNotifier` requests authorization on the **first** notification routed through C3 (PM1), not at app launch. If the prompt was dismissed (`notDetermined`) the user can re-trigger from Settings → Notifications. If denied (`denied`), Settings shows a deep-link to System Settings (PM2). All other channels (in-app badges, inbox, dock badge) work unconditionally — denial does not silence them.

The authorization status is re-read on `applicationDidBecomeActive` so a user who flips the switch in System Settings sees the change without restart.

### Performance

- **Roll-up recompute:** O(N) over unread set on every change, with N typically ≤ 50. Cheap.
- **Event volume:** the runtime already coalesces `paneOutput` and rate-limits emit-back-pressure; the detector only consumes structured events, which fire at human cadence (≤ a few per minute per Pane).
- **Persistence:** debounced 250 ms; full inbox snapshot is JSON-encoded and atomically renamed. At 500 entries × ~250 B = ~125 KB, this is sub-millisecond on SSD.
- **Idle timer (OQ4):** the runtime's `paneIdle` is already user-input-aware (resets on PTY input). We rely on that — no separate idle timer in the notification system.

### Observability

- All produced notifications pass through `NotificationStore.append` — a single seam for logging.
- A debug developer view in `Tests/Developer/` lists raw `TerminalEvent → Notification` translations for ad-hoc inspection. Not a user-facing surface.

### Migration

The C6 worktree (`design+c6-agent-notifications`) is **abandoned**, not merged. After this design is approved:

1. The exec plan (next phase) will scope file-level removal of the C6-only files in that worktree, but since C6 was never on `main`, this is a no-op for `main`.
2. The C6 worktree branch can be deleted after the design is approved.
3. The three C6 design docs remain in `docs/design-docs/` as historical context; their `Status` should flip to `Deprecated` with a one-line pointer to this doc.

### Testing

- **Detector:** unit tests over a stub `TerminalEvent` stream; assert translation table (every row in the table maps as documented).
- **Store:** unit tests over append, dedup window, age sweep, cap sweep, persistence round-trip.
- **Roll-up:** unit tests with a fixture catalog and a fixture unread set; assert exactly one level emits each count, parameterized on focus state.
- **Navigation:** integration test driving `focusHierarchyPath` against a populated catalog, asserting selection state lands correctly and that fallback works for missing nodes.
- **End-to-end:** one happy-path test — fake an OSC 9 → see banner request → see badge → click → focus.

C6's 149 tests are not migrated; total target is ≤ 25 tests.

## Risks

| Risk | Mitigation |
|---|---|
| **OSC 9 adoption gap.** Tools that don't emit OSC 9 / ring the bell silently fail to trigger T1. | Documented as a known limitation in the spec and in user-facing docs. v2 introduces an opt-in scanner if real users hit this. The bell + child-exit + idle paths still cover most "long task done" cases. |
| **Idle timer mis-fires** on long-lived shells where the user is intentionally just reading output. | Runtime's `paneIdle` already resets on user input. We additionally gate on "Pane produced output in the last 60 s" so a stale REPL prompt doesn't keep firing T2. |
| **OSC 133 not enabled in user's shell.** `commandFinished` only fires with shell integration; plain shells never emit it. | This is acceptable — `paneExited` covers the foreground-process-exit case for any shell. Shell integration is opt-in and additive. |
| **Catalog mutation between notification creation and click** (e.g., user deletes the Worktree). | Persistence stores raw IDs; navigation re-resolves on click and falls back to the deepest existing ancestor (G3). The inbox row remains and is visually flagged. |
| **Permission denial blocks all banners.** | In-app badges + dock badge + inbox popover continue to work unconditionally. The Settings panel exposes a recovery path (PM2). |
| **Bell button consumes status bar real estate** in narrow windows. | Right-anchored slot stays; the center `ViewThatFits` slot shrinks first. If the window is too narrow to fit even the bell, it collapses the badge to a single dot. |

## Open Questions

None at design-doc time. The four spec-level OQs were resolved during this design pass:

- OQ1 (prompt patterns) → moot: no scanner; input set is the structured event list above.
- OQ2 (sidebar inbox position) → bell in the worktree status bar (right slot), no sidebar route.
- OQ3 (split-visible Pane R1 scope) → only the focused Pane clears unread on focus.
- OQ4 (idle timer pause on user input) → relies on runtime's existing input-aware `paneIdle`.

---

## References

- Product spec: [docs/product-specs/notifications.md](../product-specs/notifications.md)
- Hierarchy primitives: `apps/mac/TouchCodeCore/{Catalog,Project,Worktree,Tab,Pane,SplitTree,TerminalEvent,PaneInfoDelta}.swift`
- Atomic file I/O: `apps/mac/TouchCodeCore/AtomicFileStore.swift`
- Status bar host: `apps/mac/touch-code/App/Features/StatusBar/`
- Salvaged from C6: `apps/mac/touch-code/Notifications/OSNotifier.swift` (in worktree branch `worktree-design+c6-agent-notifications`)
- Reference implementation studied: `supacode/Clients/Notifications/`, `supacode/Features/Repositories/Views/*Notification*View*.swift`
- Deprecated by this doc:
  - [c6-agent-notifications.md](c6-agent-notifications.md)
  - [c6-agent-notifications-v2.md](c6-agent-notifications-v2.md)
  - [c6-m5-inbox-sidebar.md](c6-m5-inbox-sidebar.md)
