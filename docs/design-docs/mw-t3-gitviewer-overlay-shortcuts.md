---
title: "Main-Window Redesign — T3 Git Viewer Overlay + Keyboard Shortcuts"
status: Draft
author: Gump (T3 sub-agent, via Claude)
date: 2026-04-21
---

# Design Doc: Main-Window Redesign — T3 Git Viewer Overlay + Keyboard Shortcuts

## Context and Scope

The main-window redesign (see `docs/product-specs/ui-main-window-redesign.md`) lands on
`feature/main-window` in four sub-tasks (T0 / T1 / T2 / T3). T0 is merged; it already
defined and persisted the per-Worktree `gitViewerVisible: Bool` field and the
`HierarchyManager.setWorktreeGitViewerVisible(worktreeID:visible:)` setter — this PR
consumes them.

T3 ships two user-visible capabilities:

1. **Re-host the Git Viewer as a right-side overlay inside the Detail area.** Before
   this PR, `ContentView` lays out `HStack { WorktreeDetailView; Divider; GitViewerView }`
   as a third column. After this PR, the detail column is just `WorktreeDetailView`, and
   `GitViewerView` is drawn as a right-edge overlay on top of the terminal region of
   `WorktreeDetailView` — not covering the Worktree header strip or the Tab bar. The
   overlay's visibility is per-Worktree, read from and written to `Worktree.gitViewerVisible`.
2. **Global keyboard shortcuts wired to real actions.**
   - `⌘E` — Open the current Worktree in its default editor.
   - `⌘⇧G` — Toggle the Git Viewer overlay for the current Worktree.
   - `⌘K` — Open the Sidebar's Space switcher popover.

T3 also retires the pre-redesign global `RootFeature.State.inspectorVisible` and the
toolbar button that drove it. Per-Worktree `gitViewerVisible` becomes the single source of
truth.

T3 explicitly does **not** touch the Sidebar (T1), the Header chrome (T2), or anything
inside `GitViewerFeature` — only its hosting container and keyboard entry points.

### Existing state we build on

- `Worktree.gitViewerVisible: Bool` persisted in the Catalog (T0 M1). Decoded with a
  `false` default so pre-T0 on-disk catalogs are unaffected.
- `HierarchyManager.setWorktreeGitViewerVisible(worktreeID:visible:)` writes through the
  standard debounced-save pipeline; no-op on unchanged or unknown worktree (T0 M2).
- `RootFeature.State.selection: HierarchySelection` is updated by the
  `selectionChanges()` stream; it is the canonical "current Worktree" cursor available
  inside the reducer.
- `RootFeature.State.gitViewer: GitViewerFeature.State` already forwards selection on
  `.selectionChanged` and drives `GitViewerView`; no changes needed inside it.
- `EditorFeature.Action.openRequested(editorID:worktreePath:projectID:)` is the single
  editor-open entry point; `WorktreeHeaderOpenButton` is the only live caller today.
- `GitViewerKeybindings` owns `j / k / g / G / Tab / Enter / r / 1 / 2 / 3 / . / / / ⌘⇧C`
  — all within the focused GitViewer subtree. None of T3's ⌘-modifier shortcuts collide.
- `TouchCodeApp` constructs a `WindowGroup { ContentView(...) }` with no `.commands {}`
  block yet. T3 adds one.

## Goals and Non-Goals

### Goals

- Git Viewer renders as a right-edge overlay on top of the terminal region of the active
  Worktree (below the Worktree header strip and the Tab bar). The Tab bar remains fully
  clickable while the overlay is shown.
- Overlay visibility is driven solely by the **current Worktree's `gitViewerVisible`**.
  Switching Worktrees (or Spaces via T1) updates the overlay deterministically.
- Toggling the overlay (via T2's Header button **and** via `⌘⇧G`) calls
  `HierarchyManager.setWorktreeGitViewerVisible(...)`; persistence is automatic.
- If the terminal would be forced below `MainWindowConstants.gvOverlayMinTerminalWidth` (480 pt),
  the overlay is suppressed for that layout pass (visibility stays `true` in state; it
  re-appears when the window widens). A small inline hint makes the suppression
  discoverable.
- Three global keyboard shortcuts bound from a `Commands` block — each dispatches a real
  reducer action and propagates through `RootFeature` to the right target:
  - `⌘E` → `.editor(.openDefaultInCurrentWorktreeRequested)` (new thin action)
  - `⌘⇧G` → `.gitViewerToggledForCurrentWorktree` (new thin action on RootFeature)
  - `⌘K` → `.sidebar(.openSpaceSwitcherRequested)` via `.openSpaceSwitcherRequested` on
    RootFeature (minimal API; T1 binds it when they land)
- `RootFeature.State.inspectorVisible` and `.inspectorVisibilityToggled`, and the old
  `ContentView` toolbar toggle, are removed.
- Tests: RootFeature reducer + EditorFeature reducer tests covering all three shortcut
  paths, plus overlay-visibility derivations from the catalog, plus a layout-clamp test
  for the min-terminal-width guard. The existing `GitViewerFeatureTests` do not regress.

### Non-Goals

- **No changes inside `GitViewerFeature` / its subviews.** Reducer, data, diff rendering,
  and the `j / k / g / G / …` in-viewer key bindings are untouched.
- **No Header UI work.** The Header "GV toggle" button lives in T2. T3 only guarantees
  the `HierarchyManager` mutation contract T2 will call into.
- **No Sidebar UI work.** T3 only introduces the `openSpaceSwitcherRequested` plumbing
  that T1 will bind to the Space footer popover.
- **No drag-resize of the overlay width.** Fixed-width overlay (Spec Could-Have; deferred).
- **No rename of `SidebarMode` / `RootFeature.State.sidebarMode` / `state.inbox`.** T0
  reserved those for T2; they stay untouched here.
- **No removal of `GitViewerFeature.State` or `Scope(\.gitViewer, …)`.** They remain the
  backing store for the overlay's `GitViewerView`.

## Design

### Overview

Visibility becomes a **derived projection** of the current selection + catalog, computed
inside `RootFeature` on every `.selectionChanged(_)` or `hierarchyManager` catalog change.
The projection lives on `RootFeature.State` as a single Bool
(`gitViewerOverlayVisible`) that views read directly. Writes go through a single
`.gitViewerToggledForCurrentWorktree` action that resolves the active Worktree from
`state.selection`, calls `HierarchyManager.setWorktreeGitViewerVisible(...)`, and refreshes
the projection. T2's Header button dispatches the same action.

The overlay render site is **inside `WorktreeDetailView`**, attached to the "terminal
area" region (`SplitViewportView` / `emptyTab`) via `.overlay(alignment: .trailing) {…}`
inside a `GeometryReader` that enforces the min-terminal-width guard.
`ContentView` is simplified to a plain `NavigationSplitView` with two columns.

Keyboard shortcuts are bound through a SwiftUI `Commands` block
(`MainWindowCommands`) attached to the `WindowGroup` in `TouchCodeApp`. The block
dispatches store actions; it does not own business logic.

### System Context Diagram

```
┌───────────────────────────┐         ┌────────────────────────────────┐
│ WindowGroup               │         │ HierarchyManager               │
│  .commands {              │         │  .setWorktreeGitViewerVisible  │
│     MainWindowCommands(   │         │   (writes Catalog)             │
│       store: rootStore)   │         └──────────────┬─────────────────┘
│  }                        │                        │
└─────────┬─────────────────┘                        │ debounced save
          │ sends Actions                            ▼
          ▼                                 ┌────────────────────┐
┌───────────────────────────┐               │ Catalog (on disk)  │
│ RootFeature (reducer)     │               └────────────────────┘
│  .editor(.openDefault…)   │
│  .gitViewerToggledFor…    │◀── ⌘⇧G         ▲
│  .openSpaceSwitcher…      │◀── ⌘K          │
│  state.gitViewerOverlay   │                │ derived on selection /
│  Visible (derived)        │────────────────┘    catalog change
└──────────┬────────────────┘
           │ reads
           ▼
┌───────────────────────────────────────────────────────────┐
│ ContentView                                                │
│  NavigationSplitView {                                     │
│    HierarchySidebarView   (T1; unchanged host API)         │
│  } detail: {                                               │
│    WorktreeDetailView { … }                                │
│      ├── header strip (unchanged; T2 extends)              │
│      ├── Divider                                           │
│      ├── TabBarView                                        │
│      └── terminal region                                   │
│            .overlay(alignment: .trailing) {                │
│               if gitViewerOverlayVisible && width ok {     │
│                 GitViewerView(…)                           │
│               }                                            │
│            }                                               │
│  }                                                         │
└────────────────────────────────────────────────────────────┘
```

### API Design

#### 1. `RootFeature` additions and removals

**Add** to `RootFeature.State`:

```swift
/// Derived projection: whether the Git Viewer overlay should be shown for the current
/// selection. Re-computed from `state.selection` + catalog on every `.selectionChanged`
/// and every `.gitViewerToggledForCurrentWorktree` dispatch. Views read this directly;
/// writes go through `.gitViewerToggledForCurrentWorktree`.
var gitViewerOverlayVisible: Bool = false

/// Monotonic request token. Bumped each time `⌘K` fires
/// `.openSpaceSwitcherRequested`. `HierarchySidebarView` (T1) observes changes via
/// `.onChange(of:)` and opens its Space-switcher popover. Kept as a counter (not
/// a Bool) so repeated presses retrigger even if the popover was dismissed.
var spaceSwitcherOpenToken: UInt = 0
```

**Add** actions:

```swift
case gitViewerToggledForCurrentWorktree
case openSpaceSwitcherRequested
```

**Remove** from `RootFeature`:

- `State.inspectorVisible: Bool`
- `Action.inspectorVisibilityToggled`
- The branch that handled `.inspectorVisibilityToggled`

**Modify** the existing `.selectionChanged(_)` branch to refresh `gitViewerOverlayVisible`:

```swift
case .selectionChanged(let selection):
  state.selection = selection
  ...
  state.gitViewerOverlayVisible = resolveOverlayVisibility(selection: selection)
  return .send(.gitViewer(.worktreeSelected(...)))
```

`resolveOverlayVisibility` is a small private helper that reads `hierarchyClient.snapshot()`
(the same path used by `resolveActiveTab`) and returns `worktree.gitViewerVisible ?? false`.

**New branch** for the toggle:

```swift
case .gitViewerToggledForCurrentWorktree:
  guard let worktreeID = state.selection.worktreeID else { return .none }
  let target = !state.gitViewerOverlayVisible
  state.gitViewerOverlayVisible = target
  let client = hierarchyClient
  return .run { _ in
    await MainActor.run {
      client.setWorktreeGitViewerVisible(worktreeID, target)
    }
  }
```

Optimistic local update + fire-and-forget catalog write. Reads on next `.selectionChanged`
reconcile from the persisted catalog. Writing through `hierarchyClient` (not through an
environment reference) keeps the reducer pure. **This requires a small
`HierarchyClient` surface extension** — see §2.

**New branch** for the space switcher:

```swift
case .openSpaceSwitcherRequested:
  state.spaceSwitcherOpenToken &+= 1
  return .none
```

#### 2. `HierarchyClient` extension (minimal)

`HierarchyClient` already exposes `selectionChanges()`, `snapshot()`, and mutation wrappers
like `setDefaultEditor(projectID, spaceID, editorID)`. T3 adds a parallel wrapper:

```swift
var setWorktreeGitViewerVisible: @Sendable (WorktreeID, Bool) -> Void
```

Live binding calls through to `hierarchyManager.setWorktreeGitViewerVisible(...)` on the
main actor. Test bindings can provide a no-op or a recording stub. This matches the
existing style and keeps RootFeature reducer free of a direct `@MainActor` reference.

#### 3. `EditorFeature` addition

A new thin action:

```swift
case openDefaultInCurrentWorktreeRequested(
  spaceID: SpaceID,
  projectID: ProjectID,
  worktreeID: WorktreeID,
  worktreePath: String
)
```

Resolution lives inside the reducer: it reads the per-Project override via
`hierarchyClient.catalog()` (same pattern as the existing `currentDefaultLabel` logic in
`WorktreeHeaderOpenButton`) and forwards to `.openRequested(...)`. If neither a
per-Project override nor a `globalDefault` is set, falls back to the Finder editor ID —
same resolution chain the header button already shows. The caller (ContentView) supplies
the resolved Worktree identifiers so the reducer doesn't need to re-decode
`HierarchySelection`; keeps the action self-contained and TestStore-friendly.

Rationale: adding an action rather than an "openDefault" view helper keeps the open-editor
path observable in TestStore (same reason WorktreeHeaderOpenButton dispatches through
the reducer — see its doc-comment).

#### 4. `Commands` block

New file `apps/mac/touch-code/App/Commands/MainWindowCommands.swift`:

```swift
struct MainWindowCommands: Commands {
  let store: StoreOf<RootFeature>

  var body: some Commands {
    CommandGroup(after: .newItem) {
      Button("Open in Default Editor") {
        sendOpenDefault()
      }
      .keyboardShortcut("e", modifiers: .command)
      .disabled(!hasActiveWorktree)

      Button("Toggle Git Viewer") {
        store.send(.gitViewerToggledForCurrentWorktree)
      }
      .keyboardShortcut("g", modifiers: [.command, .shift])
      .disabled(!hasActiveWorktree)

      Button("Switch Space…") {
        store.send(.openSpaceSwitcherRequested)
      }
      .keyboardShortcut("k", modifiers: .command)
    }
  }

  private var hasActiveWorktree: Bool { store.state.selection.worktreeID != nil }

  private func sendOpenDefault() {
    // Resolve selection + path from the shared HierarchyManager snapshot via
    // hierarchyClient (injected into the store); dispatch
    // .editor(.openDefaultInCurrentWorktreeRequested(...)). If no worktree is
    // selected the command is disabled, so nil-guard is a belt-and-braces return.
    ...
  }
}
```

Attached in `TouchCodeApp`:

```swift
WindowGroup { ContentView(...) }
  .commands { if let store = appState.store { MainWindowCommands(store: store) } }
```

Modifier choice: `CommandGroup(after: .newItem)` puts these entries into the **File**
menu. Rationale: they're workspace-level actions; the spec doesn't request a custom menu;
File is macOS-idiomatic for "Open…" / "Switch to …". Low priority decision and cheap to
move later.

Concerns about collision:
- `⌘E` is "Use Selection for Find" in some text contexts. Our `CommandGroup` binding wins
  at the window scope when no first-responder text field grabs the chord. Acceptable; the
  spec explicitly requests `⌘E` for Open-in-default-editor (Should-Have).
- `⌘⇧G` is "Find Previous" in `NSText` contexts. Our Git Viewer does not embed editable
  text views; all Git Viewer text is non-editable. If the Filter field inside
  `FileChangeListView` has focus, `⌘⇧G` may compete — the filter uses the unmodified `/`
  trigger, so typical use does not put focus there when toggling.
- `⌘K` conflicts with nothing in the current app.
- In-Git-Viewer bindings (`j / k / g / G / …`) are unmodified; our `⌘`-modified commands
  pass their `press.modifiers.isEmpty` guards and do not collide.

#### 5. `ContentView` simplification

`ContentView` before:

```swift
} detail: {
  HStack {
    WorktreeDetailView(...)
    if store.inspectorVisible {
      Divider()
      GitViewerView(...)
    }
  }
  .toolbar { ... ToolbarItem { inspectorVisible toggle } ... }
}
```

`ContentView` after:

```swift
} detail: {
  WorktreeDetailView(
    store: store.scope(state: \.detail, action: \.detail),
    selection: store.selection,
    editorStore: store.scope(state: \.editor, action: \.editor),
    gitViewerStore: store.scope(state: \.gitViewer, action: \.gitViewer),
    overlayVisible: store.gitViewerOverlayVisible
  )
  .toolbar { settings button (unchanged) }
}
```

The editor-toast overlay (`editorToastOverlay`) stays where it is (wraps the detail
column). No other ContentView logic changes.

#### 6. `WorktreeDetailView` host for the overlay

`WorktreeDetailView` currently renders:

```swift
VStack(spacing: 0) {
  worktreeHeader(address:)      // branch label + "Open in ▾"
  Divider
  TabBarView(...)
  if let tabID = address.activeTab {
    SplitViewportView(...)
  } else {
    emptyTab
  }
}
```

After T3 the terminal region (the `if let tabID` branch) is wrapped to host the overlay:

```swift
terminalRegion(address: address, tabID: address.activeTab)
  .overlay(alignment: .trailing) {
    GeometryReader { proxy in
      if overlayVisible && proxy.size.width >= MainWindowConstants.gvOverlayMinTerminalWidth
         + MainWindowConstants.gvOverlayWidth {
        GitViewerView(store: gitViewerStore)
          .frame(width: MainWindowConstants.gvOverlayWidth)
          .transition(.move(edge: .trailing).combined(with: .opacity))
      } else if overlayVisible {
        suppressedHint   // small "↔ Widen window to show Git Viewer" badge
      }
    }
    .animation(.easeInOut(duration: 0.15), value: overlayVisible)
  }
```

Tab bar and Worktree header are not inside the overlay host, so they stay fully
clickable. The overlay does not introduce a Divider on the terminal side — a
subtle 1-px leading border on the GitViewerView itself provides the visual break.

`MainWindowConstants` namespace (new or extended `apps/mac/touch-code/App/Theme/MainWindowConstants.swift`):

```swift
enum Constants {
  static let gvOverlayWidth: CGFloat = 360
  static let gvOverlayMinTerminalWidth: CGFloat = 480
}
```

Close affordance: the overlay does not need its own `×` button in T3 because T2's
Header toggle already dismisses via the shared action, and `⌘⇧G` toggles too. Adding a
tiny close chevron is cheap and can come after T2 if telemetry/UX calls for it — not in
scope.

### Data Storage

No new on-disk fields. `Worktree.gitViewerVisible` already persists (T0 M1). The
`ContentView`-side `RootFeature.State.inspectorVisible` property being deleted was never
persisted; no migration needed.

### Component Boundaries

| Component | Owns | Does not own |
|---|---|---|
| `RootFeature` | `gitViewerOverlayVisible` derivation, `.gitViewerToggledForCurrentWorktree`, `.openSpaceSwitcherRequested`, `spaceSwitcherOpenToken` counter | Catalog writes (delegates via `hierarchyClient`) |
| `EditorFeature` | `.openDefaultInCurrentWorktreeRequested` resolver → `.openRequested` | Editor-launch implementation (existing) |
| `HierarchyClient` | `setWorktreeGitViewerVisible` wrapper | Manager's debounced save (existing) |
| `ContentView` | Plain 2-column layout; passes overlay state into detail | Overlay placement |
| `WorktreeDetailView` | Overlay placement + layout-clamp guard | Overlay visibility (derived) |
| `MainWindowCommands` | Keyboard bindings | Business logic |

Dependency direction is unchanged: app → TouchCodeCore.

## Alternatives Considered

**(A) Keep overlay state as a global `ContentView` `@State` or `RootFeature` Bool not
tied to the catalog.**
Rejected. T0 explicitly requires per-Worktree persistence. A global flag loses that
behavior on worktree / Space switch, and duplicates T0's `gitViewerVisible` field.

**(B) Render overlay at the `ContentView` / `NavigationSplitView` detail boundary
(covers the whole detail column).**
Rejected. Overlay would cover the Worktree header strip (branch label + Open-in) and the
Tab bar — spec explicitly says the Tab bar must remain clickable. Hosting one level
deeper, at the terminal region inside `WorktreeDetailView`, achieves that trivially.

**(C) Put the min-terminal-width clamp in the reducer (hide overlay by flipping the
catalog flag to `false` when width < threshold).**
Rejected. That would mutate user intent based on a transient window dimension, and the
overlay would not reappear when the user widens the window. Keeping the clamp as a
layout-time visibility filter preserves the persisted user intent.

**(D) Use `.keyboardShortcut` attached to hidden buttons inside `ContentView` instead of
a `Commands` block.**
Rejected. `Commands` is the macOS-idiomatic path for window-global shortcuts, appears in
the menu bar (improves discoverability), and does not rely on hidden views being laid out
for the shortcut to be live. `.keyboardShortcut` on an on-screen button also competes with
focused first-responders more aggressively.

**(E) Add a full `openDefault(worktree:)` to `EditorClient` and wire `⌘E` directly.**
Rejected. Duplicates logic that lives in `WorktreeHeaderOpenButton.currentDefaultLabel`
(project override → global default → Finder). A thin EditorFeature action that re-uses
the existing `.openRequested` pipeline gives one resolution path and preserves TestStore
observability. The `openDefault` naming is effectively preserved at the Action layer.

**(F) Drive `⌘K` by mutating a Bool on `HierarchySidebarFeature.State` directly from
RootFeature via a child action.**
Rejected-for-now. T1 has not merged yet; the Sidebar feature's popover contract doesn't
exist. A counter token on `RootFeature.State` is a minimal API T1 can observe with two
lines (`.onChange(of:)` + present popover) and lets T3 land independently. When T1
merges, T3 rebases and — if T1 prefers — swaps the token for a direct child action.

**(G) Delete the in-Worktree `GitViewerView`'s `.focusable(true)` so the overlay doesn't
steal focus when shown.**
Rejected. The overlay's own `j / k / g / G / …` require focus; the existing pattern
works. The Tab bar and terminal surfaces have their own focus, and the user opts into the
overlay by toggling it.

## Cross-Cutting Concerns

**Testing strategy.** Four test surfaces:

1. `RootFeatureTests` (extend existing):
   - `selectionChangedRefreshesGitViewerOverlayVisible` — feed selections against a
     scripted catalog (one worktree with `gitViewerVisible = true`, a sibling with
     `false`); assert `state.gitViewerOverlayVisible` flips accordingly.
   - `gitViewerToggleUpdatesStateAndCallsHierarchyClient` — send
     `.gitViewerToggledForCurrentWorktree`; assert `state.gitViewerOverlayVisible`
     flipped and the test `HierarchyClient.setWorktreeGitViewerVisible` received the
     right `(worktreeID, true/false)`.
   - `openSpaceSwitcherRequestedBumpsToken` — send twice; assert
     `state.spaceSwitcherOpenToken == 2`.
   - `gitViewerToggleWithoutSelectionIsNoOp` — selection with nil worktree; assert no
     state change + no hierarchy-client call.
2. `EditorFeatureTests` (extend existing):
   - `openDefaultInCurrentWorktreeResolvesOverrideAndForwards` — scripted catalog +
     `globalDefault == zed`, override on the Project == `vscode`; assert
     `.openRequested(editorID: vscode, worktreePath: ..., projectID: ...)` flows next.
   - `openDefaultInCurrentWorktreeFallsBackToGlobal` / `…ToFinder` twins.
3. `WorktreeDetailViewLayoutTests` (new, small; can be a SwiftUI preview snapshot test
   or a pure logic test against a helper `shouldShowOverlay(width:)`):
   - Width ≥ 480+360 → show; width < threshold → hide.
4. `GitViewerFeatureTests` — run unchanged; smoke test that the overlay host doesn't
   perturb existing `.worktreeSelected(...)` flow.

Integration smoke (manual, logged in PR description): exercise the four walkthroughs in
the task brief's §Acceptance.

**Observability.** No new loggers. Catalog writes via `HierarchyManager` already log
through the existing `hierarchy` logger. The `⌘K` path is intentionally silent — it's a
UI open; T1's popover will take it from there.

**Migration.** None.

**Rollback.** Revert the T3 commits. Pre-T3 binaries read `gitViewerVisible` the same way
(the field was added in T0 and stays in the catalog). The only runtime effect of rollback
is that the overlay goes back to being a third `HStack` column and the shortcut entries
disappear.

**Contracts consumed from T0:**

- Read/write `Worktree.gitViewerVisible` via `HierarchyManager.setWorktreeGitViewerVisible`.
- `SidebarMode` enum and `state.inbox` untouched (not our lane).

**Contracts published for T1 / T2:**

- T2 (Header): dispatch `RootFeature.Action.gitViewerToggledForCurrentWorktree` from the
  Header GV-toggle button. No other coordination needed; T2 **must not** read or write
  `state.gitViewerOverlayVisible` directly — it's a derived projection.
- T1 (Sidebar): observe `RootFeature.State.spaceSwitcherOpenToken` via
  `.onChange(of:)` at the sidebar's root view to open the Space-switcher popover.
  The token is monotonic; value is irrelevant, only the change matters.

## Risks

**R1: Keyboard shortcut collisions (⌘E, ⌘⇧G) with text-field / `NSText` defaults.**
Mitigation: Binding from the `Commands` block at window scope. When focus is inside an
editable text field, AppKit's first-responder default wins; when focus is on a non-text
element (typical for the terminal + Git Viewer), our binding wins. The single edge case is
the Git Viewer filter field — only active when user hits `/` — and `⌘⇧G` is Find-Previous
in that context, which no one hits unintentionally. Documented in the `Commands` file.

**R2: `gitViewerOverlayVisible` drifting out of sync with the catalog after a direct
`HierarchyManager.setWorktreeGitViewerVisible(...)` write that happens outside the
reducer.**
Mitigation: the derivation re-runs on every `.selectionChanged`. `HierarchyManager`
mutations don't currently emit a selection-change event; for T3 this is fine because the
only writer is the reducer itself. If T2 or a future path mutates outside the reducer,
they must dispatch `.selectionChanged(state.selection)` or the derivation doesn't fire.
Flagged in the `gitViewerOverlayVisible` doc-comment; cheap to upgrade later by
re-broadcasting the selection on catalog change.

**R3: Overlay animation jitter when the user resizes the window across the clamp
threshold.**
Mitigation: `.animation(.easeInOut(duration: 0.15))` is keyed on `overlayVisible` only,
not on the computed width. Crossing the width threshold swaps presence without animation
to avoid a half-slide-in-half-slide-out. The suppressed-hint variant is a static badge.

**R4: T1 Sidebar doesn't merge before T3.**
Mitigation: `spaceSwitcherOpenToken` is an internal state counter; if T1 never wires up,
`⌘K` becomes a no-op. No crash, no regression. When T1 merges, they subscribe to the
token — one line.

**R5: Double-toggle races (user holds ⌘⇧G, Header button, or rapid clicks).**
Mitigation: reducer is serial on the Store's actor; each toggle is a pure state flip.
`HierarchyManager.setWorktreeGitViewerVisible` is a main-actor call; debounced save
coalesces adjacent writes.

**R6: Removing `RootFeature.State.inspectorVisible` breaks an external caller.**
Mitigation: `grep -r inspectorVisible apps/` shows only `ContentView` and `RootFeature`.
Safe to delete; explicit removal commit + compile error is the safety net.
