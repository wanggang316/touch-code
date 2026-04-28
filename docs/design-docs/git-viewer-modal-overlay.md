---
title: "Git Viewer Modal Overlay"
status: Approved
author: Gump
date: 2026-04-28
supersedes: git-viewer-window.md
---

# Design Doc: Git Viewer Modal Overlay

## Context and Scope

The Git Viewer (`GitViewerFeature` / `GitViewerView`, shipped in T3 — see
`mw-t3-gitviewer-overlay-shortcuts.md`) is currently mounted as a 360 pt
right-edge slot inside `WorktreeDetailView.overlayContent`, with a width-clamp
suppressing it below 840 pt total host width and replacing it with a "Widen
window to show Git Viewer" hint capsule. The slot is too narrow to render the
unified diff legibly — long lines wrap or are clipped, file lists feel
cramped — and on smaller laptop displays the overlay is suppressed entirely.

The previous iteration of this doc (`git-viewer-window.md`, now Rejected)
proposed re-hosting the GV as an independent macOS `Window(id:)`. After
review, that path's complexity (window-lifecycle ↔ catalog-state two-way
sync via `NSWindow.willCloseNotification`, idempotency between reducer-driven
and user-driven close, and Worktree-switch decoupling from window presence)
was judged disproportionate to the actual pain point: the overlay simply
isn't big enough.

This design keeps the entire existing TCA model — single
`RootFeature.gitViewer` store, retargeting on `.worktreeSelected`, per-Worktree
`Worktree.gitViewerVisible` persistence, three toggle entry points
(`HeaderGitViewerToggle`, `⌘⇧G`, Command Palette) — and changes only the
**hosting geometry**: from a right-edge column to a centered modal panel
sitting on top of a dimmed scrim, mirroring the established
`CommandPaletteView` overlay pattern.

### Existing state we build on

- `CommandPaletteView` (`Features/CommandPalette/CommandPaletteView.swift:22`)
  is the canonical centered-modal pattern in this codebase: ZStack with a
  `Color.black.opacity(0.08)` scrim wired to `onTapGesture { onDismiss() }`,
  a centered card backed by `.ultraThinMaterial`, ESC dismissal via
  `.onKeyPress(.escape)`. Reusing this pattern keeps the visual language
  consistent.
- `RootFeature.gitViewer` is host-agnostic and already retargets on
  `.worktreeSelected` — no reducer changes needed for the move.
- `gitViewerToggledForCurrentWorktree` (`RootFeature.swift:785`) writes
  `Worktree.gitViewerVisible` through `HierarchyClient.setWorktreeGitViewerVisible`.
  The view layer reads back via `gitViewerOverlayVisible(in:)`. This exact
  loop survives unchanged.
- `GitViewerKeybindings` does **not** currently bind ESC; it owns
  `j / k / g / G / Tab / Enter / r / 1 / 2 / 3 / . / / / ⌘⇧C`. ESC is free
  for the modal scrim to claim.

## Goals and Non-Goals

### Goals

- Git Viewer renders as a **centered modal panel** over the main window's
  detail area when `Worktree.gitViewerVisible == true`, with a dimmed scrim
  behind it. Panel sizing leaves diff content room to breathe (target:
  unified diff renders without horizontal clipping at typical code widths).
- Three dismissal paths, all of which write `gitViewerVisible = false` for
  the active Worktree:
  - `⌘⇧G` (existing toggle chord)
  - `Esc`
  - Tap on the scrim outside the panel
- Sidebar remains visible and interactive while the modal is up — switching
  Worktrees from the sidebar retargets the modal's content in place
  (existing `gitViewerScopeRetargeted` flow), which is materially better
  UX than a true OS-modal that would block the sidebar.
- Width-clamp logic and the "Widen window" hint
  (`MainWindowConstants.gv*`, `shouldShowOverlay(totalWidth:)`,
  `overlaySuppressedHint`) are removed: the modal sizes itself responsively
  inside whatever the host window width permits.
- Visual chrome matches `CommandPaletteView`: rounded card on
  `.ultraThinMaterial`, soft shadow, scrim at low opacity (~0.12 — slightly
  heavier than CP's 0.08 because GV is a longer-engagement modal).

### Non-Goals

- **Independent / detachable window.** Rejected upstream
  (`git-viewer-window.md`). If multi-display review demand returns, that
  doc is the starting point.
- **Multi-instance modal.** Single-instance, follows active Worktree.
- **Native `.sheet()` presentation.** macOS sheets attach to the titlebar
  with fixed-content sizing and cannot be dismissed by clicking outside —
  the wrong primitive for "keep sidebar usable, click-outside-to-dismiss."
- **Blocking the rest of the UI in a true-modal sense.** Sidebar stays
  live; only the detail column (terminal + tab bar + worktree header) is
  visually obscured by the scrim.
- Changes inside `GitViewerFeature` reducer or its sub-views.

## Design

### Overview

Replace `WorktreeDetailView.overlayContent` (right-edge frame) with a new
modal-style overlay layered on top of the detail-column content via SwiftUI
`.overlay {}`. The overlay is a `ZStack` of:

1. A scrim (`Color.black.opacity(0.12)`) filling the detail column,
   `contentShape(Rectangle())` + `onTapGesture` → dispatches
   `gitViewerToggleRequested` (existing action; idempotently writes
   `false`).
2. A centered card hosting `GitViewerView(store: gitViewerStore)`, sized
   responsively (see §Sizing), backed by
   `.ultraThinMaterial` with `RoundedRectangle(cornerRadius: 12)` and
   `.shadow(radius: 24, y: 10)`.

ESC dismissal is wired via a `.onKeyPress(.escape)` modifier on the card
(active when the modal is mounted). All three dismissal paths funnel into
the same `gitViewerToggleRequested` action that the chord and header button
already use — single reducer entry point, no new actions required.

The overlay mounts at the detail-column scope (not at `ContentView` root) so
the sidebar remains hit-testable. This is a deliberate departure from a
"true modal" — the trade-off is documented in §Alternatives §A.

### System Context Diagram

```
┌──────────────────────────────────────────────────────────────────┐
│ Window(id: "main")                                               │
│                                                                  │
│  ┌─────────────┬──────────────────────────────────────────────┐  │
│  │             │  Worktree Header / Toolbar                   │  │
│  │             ├──────────────────────────────────────────────┤  │
│  │             │  Tab bar                                     │  │
│  │  Sidebar    ├──────────────────────────────────────────────┤  │
│  │  (live —    │  ┌───────────────────────────────────────┐  │  │
│  │  switching  │  │ Scrim (Color.black 0.12, onTap →      │  │  │
│  │  retargets  │  │   gitViewerToggleRequested)           │  │  │
│  │  modal)     │  │   ┌─────────────────────────────────┐ │  │  │
│  │             │  │   │ GitViewerView (centered card)   │ │  │  │
│  │             │  │   │   .ultraThinMaterial            │ │  │  │
│  │             │  │   │   .onKeyPress(.escape) → toggle │ │  │  │
│  │             │  │   └─────────────────────────────────┘ │  │  │
│  │             │  └───────────────────────────────────────┘  │  │
│  │             │  Terminal SplitViewport (visually obscured) │  │
│  └─────────────┴──────────────────────────────────────────────┘  │
└──────────────────────────────────────────────────────────────────┘
```

### Sizing

Card frame:

```
width  = clamp(host_width  - 2 * 48, min: 560, max: 980)
height = clamp(host_height - 2 * 56, min: 420, max: 760)
```

- Min sizes guarantee the file list + diff stay legible when the user has
  shrunk the window.
- Max sizes keep the modal from stretching uselessly wide on large
  displays — diff readability degrades past ~110 columns regardless of
  monitor size.
- The 48 / 56 pt gutters give the scrim enough perimeter to be a clear
  dismissal target.

If the host window is narrower than the min (~656 pt total before sidebar),
the modal still mounts and just consumes whatever's available; we no longer
have a "too narrow, refuse to show" path. This is a deliberate reversal of
the existing 840 pt clamp — the modal is the GV's only UI now, refusing to
show it would leave the user with no path to git review.

### Animation

Transition: `.scale(0.96).combined(with: .opacity)` driven by
`.animation(.spring(response: 0.32, dampingFraction: 0.85))` on the
modal's mount/unmount. This matches the "lifted card" feel of
`CommandPaletteView` (which uses default opacity transition; we go slightly
richer because GV is more visually substantial). Scrim uses simple
`.opacity` transition.

### Component Boundaries

| Component | Responsibility | Not Responsible For |
|---|---|---|
| `WorktreeDetailView` | Mount the modal `.overlay {}` over the detail column. Drive scrim tap → `gitViewerToggleRequested`. | Modal sizing math (extracted to a small helper); `GitViewerView` internals. |
| `GitViewerModalHost` (new private view) | Compose scrim + card + ESC handler + sizing. Owns the `.transition` modifier. | Reducer state — purely presentational. |
| `GitViewerView` / `GitViewerFeature` | Diff/log/files UI. | Where it's hosted. (Same as today.) |
| `RootFeature.gitViewerToggledForCurrentWorktree` | Flip `Worktree.gitViewerVisible`. | Knowing about modal vs. side-overlay. |

Dependency direction unchanged: view → reducer (action dispatch) → catalog.

### Removed

- `WorktreeDetailView.overlayContent`, `overlaySuppressedHint`,
  `shouldShowOverlay(totalWidth:)`.
- `MainWindowConstants.gvOverlayWidth`, `gvOverlayMinTerminalWidth`.
- `WorktreeDetailViewLayoutTests` cases pinned to `shouldShowOverlay`.

### Added

- `GitViewerModalHost` view (private to `WorktreeDetailView` file or a
  sibling `Views/GitViewerModalHost.swift`).
- A small pure helper `GitViewerModalHost.cardSize(in: CGSize) -> CGSize`
  encapsulating the clamp formula above, unit-testable in isolation.
- ESC key handling — local to `GitViewerModalHost`, does not extend
  `GitViewerKeybindings`.

## Alternatives Considered

### A. Mount overlay at `ContentView` root (covers sidebar too)

True-modal feel: scrim covers everything below the toolbar, sidebar
included. Clicking sidebar items while the modal is up does nothing.

- **Trade-off:** Visually more committed; matches what most apps mean by
  "modal."
- **Why rejected:** The single biggest piece of useful interaction during
  a diff review is "switch to the next Worktree to look at its diff." If
  the sidebar is dead while the modal is up, that becomes "ESC → click
  Worktree → ⌘⇧G again" — three steps for what could be one click.
  Keeping the sidebar live preserves the existing TCA retarget flow at
  zero cost. The lost "modal purity" is a UX gain, not a loss.

### B. Native `.sheet { ... }`

Use SwiftUI's macOS sheet presentation, attached to the main window's
titlebar.

- **Trade-off:** Native chrome, free animations, automatic ESC.
- **Why rejected:** macOS sheets cannot be dismissed by clicking outside
  the sheet body, and they cap content sizing in awkward ways (the sheet
  shrinks to fit its content's intrinsic size; growing requires explicit
  `.presentationSizing` modifiers that aren't available on macOS pre-15).
  Sheet presentation also blocks sidebar interaction by default — the
  same problem as §A. Loses the lightweight feel we want.

### C. `.popover { ... }` anchored to the header GV button

Native popover, follows the toggle source.

- **Trade-off:** Strong visual affordance ("this came from that
  button"), zero focus-management code.
- **Why rejected:** Popovers auto-dismiss on any click outside, including
  clicks inside the GV's own embedded controls if they bubble. They also
  cap practical size around 600×500 — too small for unified diff. Wrong
  primitive.

### D. Keep right-edge overlay, just widen it (e.g., 560 pt)

Smallest possible change: bump `gvOverlayWidth`, raise the clamp threshold.

- **Trade-off:** Trivially small implementation, no UI re-architecture.
- **Why rejected:** Doesn't address the root issue — at any width that
  fits next to a usable terminal, unified diff still wraps. Pushing the
  width up until diff fits puts the clamp above realistic laptop window
  sizes (>1200 pt), reintroducing the "Widen window" hint as the default
  state for many users. The geometry is fundamentally wrong; widening
  it is rearranging chairs.

### E. Independent window (`git-viewer-window.md`)

See `git-viewer-window.md` Rejected for full analysis. Summary: window
lifecycle ↔ catalog persistence two-way sync (NSWindow notification
filtering, idempotent close handling, multi-display edge cases) is heavy
machinery whose primary benefit (off-window placement) the modal does not
provide — but the modal does fully solve the "diff doesn't fit"
complaint, which was the actual user pain.

## Cross-Cutting Concerns

### Testing strategy

- **Pure helper:** `GitViewerModalHost.cardSize(in:)` gets a small unit
  test covering the three regimes (below min, in-range, above max) on
  both axes.
- **Reducer:** `RootFeatureTests` already covers
  `gitViewerToggleRequested` writing the catalog flag — unchanged.
- **View-level smoke:** Manual: ⌘⇧G opens modal; ESC, scrim tap, and a
  second ⌘⇧G all dismiss; sidebar Worktree switch retargets modal
  content in place; modal renders correctly at 800 / 1280 / 1600 pt
  window widths; multiple-monitor scaling.
- **Removed:** Layout-clamp tests pinned to `shouldShowOverlay` — no
  longer applicable.

### Accessibility

- Scrim gets `accessibilityAddTraits(.isButton)` +
  `accessibilityLabel("Dismiss Git Viewer")` (mirror of CommandPaletteView).
- Card gets `.accessibilityElement(children: .contain)` so VoiceOver
  treats the modal as a region; existing GitViewerView accessibility
  inside is untouched.
- Focus: when the modal mounts, focus shifts into the GV (existing
  `PaneFocus.list` behavior on
  `gitViewerScopeRetargeted` already handles this). Confirm the existing
  focus path still fires when mount transitions from invisible→visible.

### Migration / rollback

- **Migration:** None. `Worktree.gitViewerVisible` semantics unchanged
  (still per-Worktree intent). Catalog format untouched.
- **Rollback:** Single PR revert restores the right-edge overlay. The
  removed constants and `shouldShowOverlay` helper come back via revert.

### Performance

- Modal mount / unmount adds one `ZStack` layer + one `.ultraThinMaterial`
  background to the detail-column rendering when visible. Material
  rendering is GPU-cheap on modern macOS. Scrim is a flat color — free.
- Terminal continues running behind the scrim (PTY does not pause). No
  rendering optimization needed; the terminal's `NSView` is just visually
  obscured.

## Risks

| Risk | Mitigation |
|---|---|
| Scrim's `onTapGesture` swallows clicks intended for elements inside the card (e.g., file-list rows). | The card sits **above** the scrim in the ZStack, so its hit-testing wins for any tap landing inside its frame. Verify with a quick test (click file row inside modal — should still select file, not dismiss). |
| `.onKeyPress(.escape)` competes with future GitViewer ESC bindings. | `GitViewerKeybindings` does not currently bind ESC, and no spec calls for it inside the GV. If a sub-view ever needs ESC (e.g., to clear the file filter), that handler returns `.handled` first and the modal-level ESC sees nothing — standard SwiftUI key-press bubbling. Document the precedence in `GitViewerModalHost`. |
| Backdrop tap on a region that overlaps the (covered) terminal could leak through to the terminal's NSView underneath. | `Color.black.opacity(0.12)` with `.contentShape(Rectangle())` is hit-testable; the gesture recognizer claims the event before AppKit's terminal NSView sees it. SwiftUI overlay layering also means the scrim sits above the terminal hit region. Verify with a manual click test. |
| ⌘⇧G on the modal may double-fire (chord registered both at scene and at the modal level). | The chord lives at the scene `.commands {}` level only (existing `MainWindowCommands`). The modal does not bind ⌘⇧G locally. Single source. |
| Sidebar interaction during modal could feel inconsistent with "modal" word ("if it's modal, why does the sidebar work?"). | Documented in §Alternatives §A as a deliberate UX choice. The visual scrim makes "the rest of the detail area is suspended" obvious; the live sidebar is a feature ("switch what you're reviewing"), not a bug. If user feedback says otherwise, easy follow-up: lift the scrim mount up to `ContentView` root. |
| Modal blocks visual access to the terminal (e.g., a process that just printed an error). | Three single-key dismissals (⌘⇧G / Esc / scrim-tap). Round-trip "peek terminal" is one keystroke. Acceptable. |
