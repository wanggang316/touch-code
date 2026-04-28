---
title: "Git Viewer Independent Window"
status: Rejected
author: Gump
date: 2026-04-28
superseded_by: git-viewer-modal-overlay.md
---

# Design Doc: Git Viewer Independent Window

> **Rejected 2026-04-28.** Superseded by
> [`git-viewer-modal-overlay.md`](./git-viewer-modal-overlay.md). Window
> lifecycle ↔ `gitViewerVisible` 双向同步引入的复杂度（NSWindow 通知过滤、
> reducer/用户双路 close 的幂等、Worktree 切换与窗口存在的解耦）相对
> "diff 看不全 / 太窄"这一核心痛点不划算。改走"居中模态 overlay"路线：
> 状态机不变，只是把 360 pt 右侧条带换成居中放大的模态面板，完整保留
> 当前的 TCA 单 store + per-Worktree 持久化模型。本档保留作为多实例 /
> 跨屏需求出现时的参考。

## Context and Scope

The Git Viewer (`GitViewerFeature` / `GitViewerView`, shipped in T3 of the main-window
redesign — see `mw-t3-gitviewer-overlay-shortcuts.md`) is currently hosted as a
360 pt right-edge overlay on top of the terminal region of `WorktreeDetailView`. Its
visibility is per-Worktree, persisted in `Worktree.gitViewerVisible`, and toggled via
the header button (`HeaderGitViewerToggle`), the Command Palette, or `⌘⇧G`.

The overlay design has two recurring frictions:

1. **Window-width contention.** The overlay reserves 360 pt; if the host's width
   drops below `gvOverlayWidth + gvOverlayMinTerminalWidth` (840 pt) the overlay
   hides entirely behind a "Widen window" hint capsule (`shouldShowOverlay`).
   Users on smaller laptops, or anyone who keeps the main window deliberately
   narrow next to other apps, never see the diff.
2. **Mono-display lock-in.** The Git Viewer cannot be parked on a second display
   while the terminal stays on the primary one — a common ergonomic ask for
   diff review during long-running terminal work.

This design re-hosts the Git Viewer as an **independent single-instance macOS
`Window(id:)` scene**, mirroring the Settings window pattern that already exists.
The window content follows the **currently active Worktree** (no per-window
identity), so all existing TCA wiring under `RootFeature.gitViewer` carries over
without state sharding.

### Existing state we build on

- `Window(id:)` + `OpenWindowAction` + presenter-dependency pattern is already
  established by `SettingsWindowPresenter` and the Settings scene
  (`TouchCodeApp.swift:92`, `Clients/SettingsWindowPresenter.swift`).
- `RootFeature.gitViewer: GitViewerFeature.State` is single-instance and
  scope-retargets on `.worktreeSelected` (`RootFeature.swift:223`); the feature
  itself is host-agnostic.
- `Worktree.gitViewerVisible` already persists via
  `HierarchyClient.setWorktreeGitViewerVisible`; the toggle action
  `gitViewerToggledForCurrentWorktree` (`RootFeature.swift:785`) writes through
  this setter.
- `applicationShouldTerminateAfterLastWindowClosed` is already `false`
  (`TouchCodeApp.swift:143`) — opening additional `Window(id:)` scenes does not
  affect quit semantics.

## Goals and Non-Goals

### Goals

- Git Viewer renders inside a dedicated macOS window — independently sizable,
  movable to any display, restored across launches by SwiftUI's built-in window
  state restoration (keyed by scene id).
- Window content tracks the **currently active Worktree** in the main window;
  switching the active Worktree updates the GV window's content in place
  (no window churn).
- ⌘⇧G / header button / Command Palette open and bring the GV window forward
  when not visible; close it when visible. Behavior is symmetric and persisted
  per-Worktree via the existing `Worktree.gitViewerVisible` field.
- Closing the GV window (⌘W, red traffic light) writes
  `gitViewerVisible = false` for the current Worktree so the header button's
  highlight state stays in sync.
- The 360 pt right-edge overlay, its width-clamp logic
  (`shouldShowOverlay(totalWidth:)`, `MainWindowConstants.gv*`), and the
  "Widen window" suppression hint are removed.

### Non-Goals

- **Multi-instance windows.** One GV window per Worktree (parallel diff review
  across Worktrees) is *not* a goal of this iteration. The state-sharding cost
  is non-trivial (see Alternatives Considered §B); we revisit if real demand
  appears.
- **Auto-open on launch / Worktree-switch.** The window does not automatically
  open just because the new active Worktree's `gitViewerVisible` is `true`.
  Persistence informs the header button's highlight; window lifecycle is
  user-initiated. (See Alternatives Considered §C for why.)
- **Custom window chrome / toolbar customization.** Default `Window(id:)`
  chrome with a title-only toolbar; no per-window git-status badges or
  toolbar buttons in this iteration.
- Changes inside `GitViewerFeature` reducer or any of its sub-views.

## Design

### Overview

Add a second single-instance `Window(id: "gitViewer")` scene to `TouchCodeApp`
hosting `GitViewerView(store: ...)` scoped from the existing
`RootFeature.gitViewer`. Introduce `GitViewerWindowPresenter` (twin of
`SettingsWindowPresenter`) so the reducer can request `open()` / `close()`
without leaking `OpenWindowAction` / `DismissWindowAction` into TCA. Augment
the existing `gitViewerToggledForCurrentWorktree` reducer branch to call
`presenter.open()` or `presenter.close()` after the catalog write. Listen to
`NSWindow.willCloseNotification` (filtered to the GV window) so user-initiated
close maps back to a `gitViewerWindowDidClose` action that writes
`gitViewerVisible = false`. Delete the overlay path from `WorktreeDetailView`,
the width-clamp constants, and the obsolete `WorktreeDetailViewLayoutTests`
cases.

The trade-off boundary that drives the design: **single-instance window
following active Worktree** versus **multi-instance per-Worktree windows**
(§Alternatives §B). Single-instance keeps the entire TCA state graph
unchanged (one `GitViewerFeature.State` slot, retargeted on
`.worktreeSelected`); multi-instance requires an `IdentifiedArrayOf<...>`
slice keyed by `WorktreeID`, per-window store factories, and a redefinition of
what `Worktree.gitViewerVisible` means (window-presence is runtime, not
catalog state). The 80 % use-case ("I want the diff on my second monitor") is
fully served by the single-instance design.

### System Context Diagram

```
┌────────────────────────────────────────────────────────┐
│ TouchCodeApp (App scene graph)                         │
│                                                        │
│   ┌───────────────────────┐   ┌──────────────────────┐ │
│   │ Window(id: "main")    │   │ Window(id:           │ │
│   │   ContentView         │   │   "gitViewer")       │ │
│   │     WorktreeDetail    │   │   GitViewerView      │ │
│   │       Terminal        │   │     (scoped from     │ │
│   │       HeaderToolbar   │   │      RootFeature     │ │
│   │         [GV button]──╲│   │      .gitViewer)     │ │
│   └────────┬──────────────╲│  └──────────┬───────────┘ │
│            │               ╲             │              │
│            ▼                ╲ open/close ▼              │
│   ┌──────────────────────────────────────────────┐     │
│   │ RootFeature                                  │     │
│   │   .gitViewerToggledForCurrentWorktree        │     │
│   │     1. flip Worktree.gitViewerVisible        │     │
│   │     2. presenter.open() | .close()           │     │
│   │   .gitViewerWindowDidClose (from NSWindow    │     │
│   │      notification)                           │     │
│   │     1. write gitViewerVisible = false        │     │
│   └──────────────────┬───────────────────────────┘     │
│                      │                                  │
│                      ▼                                  │
│   ┌──────────────────────────────────────────────┐     │
│   │ GitViewerWindowPresenter (TCA dependency)    │     │
│   │   open():  openWindow(id: "gitViewer")       │     │
│   │   close(): dismissWindow(id: "gitViewer")    │     │
│   └──────────────────────────────────────────────┘     │
└────────────────────────────────────────────────────────┘
```

### API Design

**New TCA dependency: `GitViewerWindowPresenter`**

```swift
nonisolated struct GitViewerWindowPresenter: Sendable {
  var open:  @MainActor @Sendable () -> Void
  var close: @MainActor @Sendable () -> Void
}
```

`liveValue` `fatalError`s (matches `SettingsWindowPresenter` convention —
missing wiring is a programmer error, not a silent no-op). `testValue` uses
`unimplemented(...)` so reducer tests must inject a fake.

`TouchCodeApp.body` wires the live closures inside the GV scene's `.task` (so
SwiftUI's `@Environment(\.openWindow)` / `\.dismissWindow` resolve correctly):

```
appState.openGitViewerWindowAction  = { openWindow(id: gitViewerWindowID) }
appState.closeGitViewerWindowAction = { dismissWindow(id: gitViewerWindowID) }
```

`AppState` then passes both through into `RootFeature`'s
`withDependencies` block when constructing the store.

**RootFeature reducer changes**

- `gitViewerToggledForCurrentWorktree` (existing): after the catalog write,
  return a `.run` effect that calls `presenter.open()` if `target == true` or
  `presenter.close()` if `target == false`. The catalog write remains the
  single source of truth for header-button highlight state.
- New action `gitViewerWindowDidClose` (no payload): writes
  `gitViewerVisible = false` for the current Worktree if the catalog currently
  reads `true`. Idempotent — no-op when already `false` (avoids a redundant
  write when the close came from the reducer itself via `presenter.close()`).
- New `.run` subscription started in `RootFeature` `.appLaunched` (or
  equivalent existing one-shot setup): observe
  `NotificationCenter.default.notifications(named: NSWindow.willCloseNotification)`,
  filter to the GV window via `(notification.object as? NSWindow)?.identifier`,
  and dispatch `.gitViewerWindowDidClose`. Window identifier comparison key
  is the SwiftUI scene id string.

**Removed**

- `RootFeature.State.gitViewerOverlayVisible(in:)` helper (unused once the
  overlay is gone; `HeaderGitViewerToggle` reads `gitViewerVisible` directly
  off the `Worktree`).
- `MainWindowConstants.gvOverlayWidth`, `gvOverlayMinTerminalWidth`.
- `WorktreeDetailView.overlayContent`, `overlaySuppressedHint`,
  `shouldShowOverlay(totalWidth:)`.

### Data Storage

No catalog schema changes. `Worktree.gitViewerVisible: Bool` keeps its
existing semantic ("the user has opted into a Git Viewer for this Worktree"),
just with a slightly different rendering: instead of "render the overlay
inline now," it means "the GV window is currently expressing this Worktree."

The persistence value is still per-Worktree because the *intent* — "this is
a Worktree I want to review" — is per-Worktree. Window position and size
are stored separately by SwiftUI keyed on scene id (`gitViewer`), independent
of which Worktree is active.

### Component Boundaries

| Component | Responsibility | Not Responsible For |
|---|---|---|
| `TouchCodeApp` (scene) | Declare `Window(id: "gitViewer")`; bridge `OpenWindowAction` / `DismissWindowAction` into `AppState` closures. | Knowing about `RootFeature` actions or `Worktree` state. |
| `GitViewerWindowPresenter` | TCA dependency surface for "open / close GV window." | Carrying scene state; deciding *when* to open/close. |
| `RootFeature` (toggle branch) | Decide visibility flip; write catalog; ask presenter to sync window. | Window position / size; SwiftUI scene mechanics. |
| `RootFeature` (close subscription) | Observe `NSWindow.willCloseNotification` for the GV scene; reflect into catalog. | Distinguishing reducer-driven close from user-driven close (idempotent write handles both). |
| `WorktreeDetailView` | Display the active Worktree's terminal. | Hosting the Git Viewer (deleted from this view). |
| `HeaderGitViewerToggle` | Render highlight from `Worktree.gitViewerVisible`; dispatch toggle. | Window mechanics — same as before. |
| `GitViewerView` / `GitViewerFeature` | Diff/log/files UI. | Where it's hosted — host-agnostic. |

Dependency direction: scene → presenter (creation) → reducer (consumption).
Reducer never imports SwiftUI window types. The notification subscription
sits in `RootFeature` because it produces a domain action; the AppKit detail
(`NSWindow.willCloseNotification`) is encapsulated inside the `.run` effect.

## Alternatives Considered

### A. Pop-out (overlay + optional independent window, both states allowed)

Keep the right-edge overlay; add a "Detach" button that moves the same
`GitViewerView` instance into a window. The overlay re-appears when the
window closes.

- **Trade-off:** Maximum flexibility — users who like the overlay keep it,
  users who want the window can opt in.
- **Why rejected:** Three valid UI states (overlay-only / window-only /
  neither) need a state machine and a non-trivial conflict policy when both
  hosts try to render the same SwiftUI store. The width-clamp logic and
  "Widen window" hint stay alive forever. Doubles the surface area for an
  iteration whose primary motivation (both frictions named in
  §Context) the window-only design fully solves on its own. If the overlay
  turns out to be missed, we can add it back in a follow-up — additive is
  cheaper than maintaining both paths from day one.

### B. Multi-instance: one Git Viewer window per Worktree

`WindowGroup("Git Viewer", for: WorktreeID.self) { id in ... }`. Each window
binds to a specific Worktree id; users can review multiple Worktrees in
parallel.

- **Trade-off:** Real parallel review (rare but high-value scenario).
- **Why rejected:**
  - `RootFeature.gitViewer` becomes
    `IdentifiedArrayOf<GitViewerFeature.State>` keyed by `WorktreeID`, and
    `gitViewerScopeRetargeted` retargeting logic disappears — every window
    is permanently bound. Significant TCA refactor.
  - `Worktree.gitViewerVisible` no longer makes sense as catalog-persisted
    state: window presence is a runtime concern, and "open this window
    automatically on launch because it was open last time" is an
    aggressive default that needs a separate UX call.
  - Each GV window needs its own ⌘⇧G chord semantics — does the chord open
    the window for the *currently focused main-window's* active Worktree?
    Toggle the focused GV window? The chord's invariant breaks.
  - The 80 % use-case ("diff on second monitor") is fully covered by
    single-instance. Going multi-instance is a 3–5× implementation cost
    for a long-tail benefit.
  - Reversible: if real demand surfaces, the single-instance design's
    `RootFeature.gitViewer` slot can later be promoted to an
    `IdentifiedArrayOf` without affecting the in-window UI code.

### C. Automatic window lifecycle from `Worktree.gitViewerVisible`

Drive window open/close purely from the active Worktree's
`gitViewerVisible`: switching to a Worktree where the flag is `true` opens
the window; switching to a Worktree where it's `false` closes it.

- **Trade-off:** State purity — `gitViewerVisible` is the single
  arbiter of window lifecycle.
- **Why rejected:** Switching Worktrees becomes a window-flicker event —
  open / close / open as the user navigates the sidebar. Worse, the user's
  manual `⌘W` to dismiss the window now also writes the persistence flag,
  and a Worktree-switch immediately reopens it. The flicker problem and
  the implicit "follow-active" mental model fight each other. Chosen
  alternative ("intent persists per-Worktree, window lifecycle is
  user-initiated, content follows active Worktree") splits these
  concerns cleanly.

### D. Sheet / popover / `.inspector` modifier

Keep the GV inside the main window but as a sheet, popover, or
`.inspector` panel.

- **Trade-off:** Native SwiftUI primitives, less scene-management code.
- **Why rejected:** None of these can be moved to a second display, none
  resize independently of the main window, and `.inspector` recreates the
  exact "right-edge overlay competing for width" problem we're trying to
  escape. Doesn't address either of the named frictions.

## Cross-Cutting Concerns

### Testing strategy

- **RootFeature reducer:** new `RootFeatureTests` cases assert that
  `.gitViewerToggledForCurrentWorktree` calls `presenter.open()` when the
  resulting state is visible and `presenter.close()` when not. Use a fake
  `GitViewerWindowPresenter` injected via `withDependencies`.
- New test for `.gitViewerWindowDidClose`: dispatching when
  `gitViewerVisible == true` writes `false`; dispatching when already
  `false` is a no-op (idempotency).
- **Deletions:** `WorktreeDetailViewLayoutTests` cases covering
  `shouldShowOverlay(totalWidth:)` are removed. Verify the rest of the
  layout test file still compiles and passes.
- **Manual smoke:** ⌘⇧G opens window; second ⌘⇧G closes it; ⌘W on the
  window matches the chord-toggle's persisted state; switching Worktrees
  retargets content without window churn; window position survives quit
  + relaunch.

### Observability

The window lifecycle uses standard AppKit notifications; no new logging
required. Existing `GitViewerFeature` instrumentation (selection retarget,
log/diff loading state) is unchanged.

### Migration / rollback

- **Migration:** None. `Worktree.gitViewerVisible` keeps its on-disk
  representation; existing catalogs continue to decode. The only behavior
  change for users with `gitViewerVisible == true` saved is that on first
  launch after upgrade, the GV window does **not** auto-open (per
  Non-Goals); they press ⌘⇧G to bring it up. One-time friction, no data
  loss.
- **Rollback:** Reverting the PR restores the overlay path. No catalog or
  settings changes to reverse.

### Accessibility

- The GV window inherits standard macOS window-level accessibility (window
  rotor, focus chain) for free — strictly an improvement over the
  custom-overlay layer (which lived inside the main window's hit-testing
  hierarchy and required special-case focus handling).
- Existing `GitViewerKeybindings` (j / k / g / G / Tab / Enter / r / 1 /
  2 / 3 / . / / / ⌘⇧C) remain attached to `GitViewerView` — they fire
  whenever the GV window is key, which is the expected behavior.

## Risks

| Risk | Mitigation |
|---|---|
| `NSWindow.willCloseNotification` fires for every closing window in the process — filtering by SwiftUI scene id requires identifying the GV window correctly. | Set an explicit `.windowIdentifier(...)` (or compare via `NSWindow.identifier`'s `rawValue` against `gitViewerWindowID`). Unit-test the filter helper in isolation; manually verify Settings-window close does not trigger `gitViewerWindowDidClose`. |
| Reducer-driven `presenter.close()` and the close-subscription's `gitViewerWindowDidClose` could race, producing a redundant catalog write. | The `.gitViewerWindowDidClose` handler is idempotent (no-op when `gitViewerVisible` already `false`). Worst case is a single redundant `false → false` setter call, which `HierarchyManager.setWorktreeGitViewerVisible` already short-circuits. |
| User opens GV window, then closes the **main** window — the GV window remains open, with no visible Worktree to track. | When `selection.worktreeID == nil`, `GitViewerView` already renders its "No Worktree selected" empty state (existing behavior). No new code; verify the empty-state copy still reads sensibly without a host. |
| SwiftUI window state restoration may re-show the GV window on launch even though we explicitly chose "no auto-open" — `Window(id:)` restores by default. | If restoration on relaunch is undesired, opt the scene out via `.restorationBehavior(.disabled)` (macOS 14+). Decision: leave default-on for now (matches Settings); if it surprises users we flip it in a follow-up. Tracked, not a blocker. |
| Multi-display moves: window is closed via ⌘W on a now-disconnected display state. | AppKit handles display loss by parking the window on an active display. SwiftUI restoration re-clamps to visible bounds. No special handling required. |
