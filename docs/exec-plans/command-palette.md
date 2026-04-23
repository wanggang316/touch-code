# ExecPlan: Command Palette (Quick Action)

**Status:** In Progress
**Author:** Gump
**Date:** 2026-04-23

This is a living document. The Progress, Surprises & Discoveries, Decision Log, and Outcomes & Retrospective sections must be kept up to date as work proceeds.

## Purpose

After this change, a touch-code user can:

- Press **⌘P** from anywhere in the main window and see a floating search box at the top-center of the active window.
- Type a few characters and see a fuzzy-ranked list of every command currently available — Space switching, Worktree switching, "Open in default editor", "Toggle Git Viewer", split/new-tab/focus panel actions, new/close window, open settings — without needing to remember which menu hosts each.
- Press **↑/↓** to move selection, **Enter** to execute, **Esc** (or click outside) to dismiss.
- On reopen, see their recently-used commands float to the top: commands activated within the last 30 days are boosted, with half-life = 7 days.
- Press the ghostty keybind bound to `toggle_command_palette` (if the user configured one in `ghostty/config`) and see the same palette open — the existing intent hook in `PanelActionRouterFeature.Delegate.commandPaletteToggleRequested` stops being a no-op.

Nothing new happens at the "what can the app do" layer — every command invoked from the palette already has a dedicated entry point (menu, sidebar row, header button, ghostty keybind). The palette is a single keyboard-first surface that lowers the discovery cost for all of them.

## Progress

- [ ] M0 — Baseline: lint + `xcodebuild build` green on current branch `feature/command-p`; record any pre-existing failures
- [ ] M1 — Data types: `CommandPaletteItem` + `Kind` enum + `KeyEquivalentDescriptor` in new folder `App/Features/CommandPalette/`, no behavior
- [ ] M2 — Vertical slice: `CommandPaletteFeature` reducer (toggle / query / selection / commit) + minimal `CommandPaletteItems.build(for:)` returning 3 static global commands (`openSettings`, `toggleGitViewer`, `checkForUpdates`) + basic `CommandPaletteView` overlay + `⌘P` menu binding + `RootFeature` wiring + `route(_:)` for those 3 Kinds — user can `⌘P → type → Enter → Settings opens`
- [ ] M3 — Full fuzzy scorer: `CommandPaletteFuzzyScorer.score(...)` with contiguous / subsequence / separator-bonus / quoted-contiguous rules + unit tests; feature reducer swaps stub filter for scorer
- [ ] M4 — Recency: `@Shared(.appStorage("commandPaletteRecency"))` dictionary, write on commit, read during scoring, prune-on-open, 200-entry LRU cap + tests
- [ ] M5 — Full command set: expand `CommandPaletteItems.build` to cover all `Kind` cases (Space / Worktree / Editor / Panel / Window); extend `RootFeature.route(_:)` to cover them; wire `panelActionRouter.delegate.commandPaletteToggleRequested` at `RootFeature:421` to dispatch `.commandPalette(.togglePresented)` instead of no-op
- [ ] M6 — Tests + manual QA + PR: `CommandPaletteFeatureTests`, `CommandPaletteItemsTests`, `RootFeatureRoutingTests` (exhaustive `Kind` → action map), manual pass across all item categories, lint, xcodebuild test, open PR against `main`

## Surprises & Discoveries

(None yet)

## Decision Log

- **D1** (planning, 2026-04-23): Palette lives as a child of `RootFeature`, presented via `@Presents var commandPalette: CommandPaletteFeature.State?`. Matches the `@Presents var spaceManagerSheet` pattern at `RootFeature.swift:46`. Discarding query/selection on close is deliberate — a palette that remembers your last query confuses more than it helps.
- **D2** (planning, 2026-04-23): Palette view is a **ZStack overlay**, not `.sheet(item:)`. The ContentView already hosts a ZStack where the Git Viewer overlay lives; palette joins there at `.zIndex(100)`. `.sheet` was rejected because it dims the window chrome, animates slowly, and pre-empts `Esc` before the reducer can handle activation-and-dismiss.
- **D3** (planning, 2026-04-23): Command items are **rebuilt on open**, not held as a static catalog. `CommandPaletteItems.build(for:)` is a pure function over `(Catalog, HierarchySelection, EditorFeature.State)`. This makes context-sensitivity free — if no Worktree is selected, worktree-scoped Kinds simply aren't in the list — and avoids a registration protocol that would only pay off with a plugin system we do not have.
- **D4** (planning, 2026-04-23): Activation routes through a new `CommandPaletteFeature.Action.Delegate.activate(Kind)` that `RootFeature` pattern-matches into existing feature actions (`.editor(.openRequested)`, `.gitViewerToggledForCurrentWorktree`, `.switchToSpaceAtIndex`, `.sidebar(.spaceRowTapped)`, `.panelActionRouter(.requested)`, `.windowActionRouter(.requested)`, `SettingsWindowPresenter.open()`). No new client, no new dependency; every branch reuses a path that already ships.
- **D5** (planning, 2026-04-23): **Panel-scoped palette actions resolve the target panel on demand, not from `HierarchySelection`.** Confirmed while reading `HierarchyClient.swift:268` — `HierarchySelection` carries `(spaceID, projectID, worktreeID)` only; no `panelID` field. The `route(_:)` helper walks `Tab.selectedPanelID` in the current catalog snapshot to find the focused panel when dispatching a `Kind.panelAction(…)`. No `HierarchySelection` schema change.
- **D6** (planning, 2026-04-23): Ghostty-sourced `toggle_command_palette` intent is reused. `PanelActionRouterFeature.swift:42` already emits `Delegate.commandPaletteToggleRequested`; `RootFeature.swift:421` currently consumes it as an explicit no-op. In M5 that branch becomes `.send(.commandPalette(.togglePresented))`.
- **D7** (planning, 2026-04-23): Recency stored as `[String: TimeInterval]` under UserDefaults key `commandPaletteRecency` via `@Shared(.appStorage(...))`. Rejected routing it through `SettingsStore` — settings are atomic-rename JSON on disk with a 500 ms debounce designed for versioned user-facing preferences, not for write-heavy ephemeral counters touched on every palette activation.
- **D8** (planning, 2026-04-23): First cut ships **no category/section headers** in the UI and **no mode prefixes** (`>`, `@`, `:`). Flat list ordered by score. These can be added later without breaking existing recency IDs.
- **D9** (planning, 2026-04-23): `⌘K` Space switcher stays as-is. Palette can select any Space by typing its name, but `⌘K` is muscle memory and removing it is a separate UX call that should not block palette landing.

## Outcomes & Retrospective

(To be filled at milestone completion)

## Context and Orientation

Related documents:

- Design doc: `docs/design-docs/command-palette.md` — read in full before M1. Contains the state/action shapes, the scorer rules, the seven alternatives considered, and the risk table. This ExecPlan does not duplicate them.
- Architecture: `docs/architecture.md`, `docs/golden-rules.md`.
- Ghostty routing precedent: `docs/design-docs/0008-ghostty-action-routing.md`. The palette reuses `PanelActionRequest` / `WindowActionRequest` verbatim, so understanding the decoder → router → root fan-out is load-bearing.

Key source files to read (in this order) before M1:

- `apps/mac/touch-code/App/Features/Root/RootFeature.swift` — the parent reducer. Lines 17–42 hold the `State` struct the palette extends; line 46 is the `@Presents var spaceManagerSheet` pattern the palette mirrors; lines 135–137 (`spaceManagerSheetShown`, `spaceManagerSheet(PresentationAction<…>)`, `switchToSpaceAtIndex`) are the Action shape precedent; line 421 is the `panelActionRouter(.delegate)` no-op branch that M5 replaces; the `.ifLet(\.$spaceManagerSheet, …)` at line 486 is where `.ifLet(\.$commandPalette, …)` lands.
- `apps/mac/touch-code/App/Features/SpaceManager/SpaceManagerFeature.swift` — **read for shape only, do not edit**. This is the cleanest in-tree example of a `@Presents`-hosted child reducer. The new feature's file layout (`State` / `Action` / `body: some Reducer` / `Delegate`) matches this one.
- `apps/mac/touch-code/App/Commands/MainWindowCommands.swift` — the `CommandGroup(after: .newItem)` block. A new `Button("Quick Action…") { store.send(.commandPalette(.togglePresented)) }.keyboardShortcut("p", modifiers: .command)` is inserted *above* the existing ⌘E / ⌘⇧G / ⌘K block.
- `apps/mac/touch-code/App/ContentView.swift` — the overlay host. The palette overlay is mounted in the same `ZStack` that already carries the Git Viewer overlay, with `.zIndex(100)` so it sits above it.
- `apps/mac/touch-code/App/Features/PanelActionRouter/PanelActionRouterFeature.swift` — lines 37–43 declare `Delegate.commandPaletteToggleRequested`; lines 179–180 emit it. Nothing changes here; M5 just connects the delegate to a real action in `RootFeature`.
- `apps/mac/TouchCodeCore/PanelActionRequest.swift` and `apps/mac/TouchCodeCore/WindowActionRequest.swift` — the public enums `CommandPaletteItem.Kind` wraps. **Do not edit these enums**. Every case is reachable from the palette by adding a `Kind.panelAction(case)` or `Kind.windowAction(case)` item to `build(for:)`.
- `apps/mac/touch-code/App/Clients/HierarchyClient.swift` — lines 268–274 (`HierarchySelection`) confirm the selection does not carry a panel ID; palette routing resolves the focused panel by walking `Tab.selectedPanelID` from the catalog snapshot. No client changes.
- `apps/mac/touch-code/App/Features/Editor/EditorFeature.swift` — look up `State.descriptors` and `State.globalDefault`; the palette item builder reads both to emit `Kind.openCurrentWorktreeIn(EditorID)` items for each installed editor.

Terms of art:

- **Kind** — a discriminated enum inside `CommandPaletteItem` describing what the item does. One case per command family; parameterized cases carry stable IDs (e.g. `SpaceID`) so recency survives app restart.
- **Recency** — a `[stableCommandID: lastActivationTimestamp]` map persisted to UserDefaults. Read during scoring to apply an exponential-decay bonus; written on every command activation.
- **Contiguous mode** — the fuzzy scorer matches the query as a single substring of the title, not as a subsequence. Triggered by a double-quoted query (`"git view"`) or implicitly as the highest-scoring match when both succeed.
- **Focused panel resolution** — given a `HierarchySelection`, the palette finds the panel to target by looking up the selected Worktree's `selectedTabID`, then that Tab's `selectedPanelID`. The `RootFeature.resolveActiveTab` helper at line 509 is the existing precedent; a sibling helper `resolveFocusedPanelID` is added for palette routing.

Test target layout:

- `apps/mac/touch-code/Tests/` — home for `CommandPaletteFeatureTests` (new), `CommandPaletteItemsTests` (new), `RootFeatureCommandPaletteRoutingTests` (new).
- `apps/mac/TouchCodeCoreTests/` — home for `CommandPaletteFuzzyScorerTests` (new). Scorer has no TCA dependency, so it belongs in Core tests; follow the placement of existing pure-function tests (e.g. `CatalogCodableTests`).

## Plan of Work

The work is sliced vertically so every milestone produces an observably-working palette. M2 proves the full pipeline end-to-end with three commands; M3–M5 deepen the feature without rebuilding the substrate.

### Milestone 0 — Baseline

Before any edit, confirm the working tree builds clean on the current branch:

```
make -C apps/mac lint
xcodebuild build -scheme touch-code -destination 'platform=macOS'
```

Record any pre-existing lint or test failures so the post-work comparison is apples-to-apples. If unrelated failures exist, escalate before touching code — the palette should not silently inherit regressions.

### Milestone 1 — Data types (no behavior)

Create the feature directory `apps/mac/touch-code/App/Features/CommandPalette/` and drop in two files with types only:

- `CommandPaletteItem.swift` — `struct CommandPaletteItem: Equatable, Identifiable` with fields `id: String`, `title: String`, `subtitle: String?`, `icon: String`, `shortcut: KeyEquivalentDescriptor?`, `priorityTier: Int`, `hiddenWhenQueryEmpty: Bool`, `kind: Kind`. The `Kind` enum lists the 16 cases named in design doc §3.3.1. All enums conform to `Equatable`; nothing is public because the feature is internal to the macOS target.
- `KeyEquivalentDescriptor.swift` — a `struct { let keys: [String] }` used only for display (e.g. rendering `"⌘⇧G"` on a row). Not a real `SwiftUI.KeyEquivalent` — the view converts it to a `Text` label at render time.

No reducer, no view yet. Verify by `xcodebuild build -scheme touch-code`: the new files compile as dead code. No behavior change visible.

### Milestone 2 — Vertical slice with three commands

This is the smallest version of the palette that proves the entire pipeline works end-to-end. Three commands, a stub scorer, real view, real routing.

1. **`CommandPaletteItems.swift`** — pure function `static func build(forSelection: HierarchySelection, editor: EditorFeature.State, catalog: Catalog) -> [CommandPaletteItem]`. For M2 return exactly three items unconditionally: `openSettings`, `toggleGitViewer`, `checkForUpdates`. (Later milestones flesh it out.)

2. **`CommandPaletteFuzzyScorer.swift`** — stub: `static func score(item:query:recency:now:) -> Int?` returns `item.title.lowercased().contains(query.lowercased()) ? 1 : nil` for non-empty query, `1` for empty. Full scorer lands in M3.

3. **`CommandPaletteFeature.swift`** — `@Reducer` with `@ObservableState struct State: Equatable { var query: String = ""; var selectionID: CommandPaletteItem.ID?; var items: [CommandPaletteItem] = []; var filtered: [CommandPaletteItem] = [] }`. Actions: `togglePresented`, `dismissed`, `queryChanged(String)`, `selectionMoved(Direction)`, `selectionCommitted`, `rowTapped(ID)`, `catalogChanged`, `delegate(Delegate)` where `Delegate = .activate(Kind)`. The reducer:
   - On `togglePresented` / `catalogChanged`: invoke `CommandPaletteItems.build`, store in `state.items`, recompute `state.filtered`, set `state.selectionID` to the first filtered item's id.
   - On `queryChanged(s)`: set `state.query = s`, recompute `state.filtered`, reset selection to first.
   - On `selectionMoved(.up/.down)`: move `selectionID` within `state.filtered` with wrap.
   - On `selectionCommitted` / `rowTapped`: look up the selected item, emit `.delegate(.activate(item.kind))`. Reducer does not clear state itself — dismissal is driven by the parent clearing `@Presents` via `.ifLet`.

4. **`CommandPaletteView.swift`** — ZStack overlay per design doc §3.6. A dimmed scrim tap-gesture sends `.dismissed`. Keyboard handling uses `.onKeyPress(.escape/.upArrow/.downArrow/.return)`. The text field is auto-focused via `@FocusState`.

5. **`RootFeature.swift` edits:**
   - Add `@Presents var commandPalette: CommandPaletteFeature.State?` near `spaceManagerSheet` (line ~46).
   - Add action cases `commandPalette(PresentationAction<CommandPaletteFeature.Action>)` and local `commandPaletteToggle` — the latter converts the top-level toggle into the presentation set/clear.
   - Compose via `.ifLet(\.$commandPalette, action: \.commandPalette) { CommandPaletteFeature() }` right after the existing `.ifLet(\.$spaceManagerSheet, …)` at line 486.
   - Add a private helper `route(_ kind: CommandPaletteItem.Kind, state: inout State) -> Effect<Action>`. For M2, handle only three cases: `.openSettings` → `settingsWindowPresenter.open()` via `.run`; `.toggleGitViewer` → `.send(.gitViewerToggledForCurrentWorktree)`; `.checkForUpdates` → placeholder `.none` (wiring lands in M5).
   - Pattern-match `.commandPalette(.presented(.delegate(.activate(let kind))))` → `return route(kind, state: &state)` and also set `state.commandPalette = nil` so the overlay dismisses immediately on commit.

6. **`ContentView.swift` edits:** inside the existing `ZStack` (same one hosting the Git Viewer overlay), add the palette overlay:

   ```swift
   if let paletteStore = store.scope(state: \.commandPalette, action: \.commandPalette.presented) {
     CommandPaletteView(store: paletteStore)
       .zIndex(100)
       .transition(.opacity.combined(with: .scale(scale: 0.97)))
   }
   ```

7. **`MainWindowCommands.swift` edits:** add a new `Button("Quick Action…") { store.send(.commandPaletteToggle) }.keyboardShortcut("p", modifiers: .command)` as the first entry of the `CommandGroup(after: .newItem)` block.

Verify end-to-end: `make -C apps/mac mac-run-app`, press `⌘P`, type "set", press Enter. The Settings window must open. Reopen palette, type "git", press Enter. Git Viewer overlay must toggle.

### Milestone 3 — Full fuzzy scorer

Replace the M2 stub `CommandPaletteFuzzyScorer.score` with the real implementation per design doc §3.3.3. Score rules in priority order:

1. Empty query: items with `hiddenWhenQueryEmpty == true` return `nil`; others return a score derived from recency + priorityTier only (no match bonus).
2. Non-empty query: attempt contiguous substring match on `title` (case-folded). Match → base `0x2_0000` + length-ratio bonus. Else attempt subsequence match on `title` → base `0x1_0000`. Else subsequence match on `subtitle` → base `0x0_8000`. No match → `nil`.
3. Add per-character bonus: `+5` for a query char matching a title char that follows `/`; `+4` for `- _ . space`; `+2` for an uppercase letter at start-of-word.
4. Add recency bonus: `R * 0.5^(ageDays / 7)` capped at 30 days; `R` chosen so a recent-but-subsequence match loses to a never-used contiguous match.
5. Quoted-query rule: when `query` starts and ends with `"`, skip subsequence mode entirely — contiguous only.

Add `CommandPaletteFuzzyScorerTests` in `apps/mac/TouchCodeCoreTests/` with table-driven cases:

- Contiguous `"git"` on "Toggle Git Viewer" outranks subsequence `"gtv"` on the same.
- Prefix `"ope"` outranks suffix `"ngs"` on "Open Settings".
- Recency bonus reorders within a bucket but cannot flip a contiguous match below a subsequence match.
- Quoted query `"\"git view\""` drops subsequence-only matches.
- Deterministic on identical input (sort stable).

Verify: `xcodebuild test -scheme touch-code -only-testing:TouchCodeCoreTests/CommandPaletteFuzzyScorerTests` expects all cases passing.

### Milestone 4 — Recency

Add persistence:

1. In `CommandPaletteFeature.swift`, add `@Shared(.appStorage("commandPaletteRecency")) var recency: [String: TimeInterval] = [:]` at the feature level. Not on `State` — the `@Shared` property is injected at composition time.
2. On `.selectionCommitted` / `.rowTapped`: before emitting the delegate, write `recency[item.id] = Date().timeIntervalSince1970`. Apply a 200-entry LRU cap: when size exceeds 200, drop the oldest-timestamp entries until size = 200.
3. On `.togglePresented`: prune dead IDs. Rule: for every key in `recency` whose prefix matches `"space.select."`, `"worktree.select."`, or `"editor.open."`, drop the key if the parameter (UUID after the dot) is not present in the freshly-built items list. Static IDs are never pruned.
4. Pass `recency` and `Date().timeIntervalSince1970` into every `CommandPaletteFuzzyScorer.score(…)` call when filtering.

Add to `CommandPaletteFeatureTests`:

- Activating `"openSettings"` bumps `recency["app.open-settings"]`.
- 201st activation evicts the oldest entry.
- Recency for a stale `worktree.select.<uuid>` ID is dropped when the worktree is deleted and palette reopened.

Verify: same test suite plus a manual pass where ⌘P → Settings → close → ⌘P shows "Open Settings" at the top of the empty-query list.

### Milestone 5 — Full command set + ghostty hook

Expand `CommandPaletteItems.build(forSelection:editor:catalog:)` to emit every `Kind`:

- Always: `openSettings`, `checkForUpdates`, `openSpaceManager`, one `selectSpace(id)` per `catalog.spaces`, one `switchToSpaceAtIndex(n)` for n=1…min(9, spaces.count).
- When `selection.worktreeID != nil`: `toggleGitViewer`, `closeCurrentWorktree` (flagged `hiddenWhenQueryEmpty = true`), `refreshCurrentWorktree`, `openCurrentWorktreeInDefaultEditor`, `revealCurrentWorktreeInFinder`, one `openCurrentWorktreeIn(editorID)` per installed descriptor in `editor.descriptors`.
- When `selection.worktreeID != nil`: panel actions — one `panelAction(.newTab)`, one per `NewSplitDirection`, one per `FocusDirection` as `panelAction(.gotoSplit(direction:))`, `panelAction(.closeTab(.this))` (hidden-when-empty), `panelAction(.equalizeSplits)`, `panelAction(.toggleSplitZoom)`.
- Always: window actions — `windowAction(.new(from: resolvedPanelID))`, `windowAction(.close(from: resolvedPanelID))`, `windowAction(.toggleFullscreen(from: resolvedPanelID))`, `windowAction(.toggleTabOverview(from: resolvedPanelID))`. When no panel is focused, these items are omitted rather than emitting synthetic IDs.

Items whose Kind requires a focused `PanelID` resolve it at build time via a new helper `resolveFocusedPanelID(selection:catalog:) -> PanelID?` that walks Tab→selectedPanelID. If `nil`, the corresponding items are not emitted.

Extend `RootFeature.route(_:)` to cover all Kinds. Each case is 1–4 lines, dispatching into an existing feature action. A typical block:

```swift
case .selectSpace(let id):
  return .send(.sidebar(.spaceRowTapped(id)))
case .switchToSpaceAtIndex(let n):
  return .send(.switchToSpaceAtIndex(n))
case .toggleGitViewer:
  return .send(.gitViewerToggledForCurrentWorktree)
case .openCurrentWorktreeInDefaultEditor:
  return .send(.openDefaultForCurrentWorktreeRequested)
case .openCurrentWorktreeIn(let editorID):
  // Build a worktree-path resolver inline or reuse RootFeature.projectOverrideEditorID
  …
case .panelAction(let req):
  guard let panelID = resolveFocusedPanelID(selection: state.selection,
                                            catalog: hierarchyClient.snapshot()) else { return .none }
  return .send(.panelActionRouter(.requested(panelID, req)))
case .windowAction(let req):
  return .send(.windowActionRouter(.requested(req)))
```

Replace the current `panelActionRouter(.delegate)` no-op at `RootFeature.swift:421`:

```swift
case .panelActionRouter(.delegate(.commandPaletteToggleRequested)):
  return .send(.commandPaletteToggle)
case .panelActionRouter(.delegate(.presentTerminalRequested)):
  return .none  // unchanged
case .panelActionRouter(.delegate):
  return .none
```

Verify: add a contract test `RootFeatureCommandPaletteRoutingTests` that iterates every `Kind` case (using a helper `Kind.allFixtureCases` returning one representative value per case) and asserts the reducer emits exactly one downstream action of the expected type. This is the regression net that catches future renames.

### Milestone 6 — Tests + Manual QA + PR

Final test passes:

- `CommandPaletteItemsTests` — synthetic catalog with (0 spaces / 1 space / 2 spaces × 0 projects / 2 projects × 0 worktrees / 1 worktree selected) produces the expected item IDs.
- `CommandPaletteFeatureTests` — toggle / query / selectionMoved / selectionCommitted / rowTapped / catalogChanged.
- `RootFeatureCommandPaletteRoutingTests` — exhaustive Kind coverage.
- `CommandPaletteFuzzyScorerTests` — ranking + recency + quoted-query.

Manual QA matrix:

- `⌘P` opens palette in every main-window state (no space / no worktree / worktree selected).
- Type "settings" / "git" / "personal" / "new tab" / "split right" / "open in zed" — each yields the expected item at rank 1 and Enter executes it.
- Type garbage → "No matching commands" empty-state shows; Enter is silent; Esc closes.
- Close palette, reopen → recently-used commands float to the top.
- Delete a Space whose `selectSpace` command had recency, reopen → the stale recency entry is pruned (assert via `defaults read com.touch-code commandPaletteRecency`).
- Configure ghostty `toggle_command_palette` on a key combo → pressing it opens the palette.
- Open palette, then click into a terminal panel → palette dismisses; ghostty receives the click normally.

Run `make -C apps/mac lint` and `xcodebuild test -scheme touch-code -destination 'platform=macOS'` — all green.

Open a PR against `main` from the `feature/command-p` branch with the title `feat(palette): add Command Palette (⌘P)` and a summary that links to the design doc.

## Concrete Steps

From the repo root `/Users/wanggang/.prowl/repos/touch-code/feature/command-p`:

```
# M0 baseline
make -C apps/mac lint
xcodebuild build -scheme touch-code -destination 'platform=macOS,arch=arm64' 2>&1 | xcbeautify
```

Expected: lint exits 0, build succeeds. Record any pre-existing failures in Surprises & Discoveries.

```
# After each milestone
make -C apps/mac mac-check          # swift-format + swiftlint
xcodebuild test -scheme touch-code \
  -destination 'platform=macOS,arch=arm64' \
  -only-testing:touch-codeTests \
  -only-testing:TouchCodeCoreTests 2>&1 | xcbeautify
```

Expected: 0 failing tests. New test files appear in the output as they are added.

```
# M2 manual smoke
make -C apps/mac mac-run-app
# press ⌘P, type "set", press Enter → Settings window opens
# press ⌘P, type "git", press Enter → Git Viewer overlay toggles
```

```
# M5 ghostty hook smoke
# in ~/.config/ghostty/config (or per-worktree override):
#   keybind = ctrl+shift+p=toggle_command_palette
# then in a touch-code terminal panel, press ctrl+shift+p → palette opens
```

```
# M6 recency inspection
defaults read com.touch-code commandPaletteRecency
```

Expected: a dictionary mapping stable command IDs (e.g. `app.open-settings`) to Unix timestamps.

## Validation and Acceptance

The feature is accepted when all of the following are true:

1. Pressing `⌘P` in any main-window state opens the palette; pressing `Esc` or clicking the scrim dismisses it.
2. Typing a command name selects the expected top item for all of: `"settings"` → Open Settings; `"git"` → Toggle Git Viewer; one of the space names → Switch to that Space; `"new tab"` → Panel: New Tab; `"open in <editor>"` → Open Current Worktree in that editor (only when installed).
3. Pressing `Enter` on the top item executes it and dismisses the palette in the same tick.
4. Activating the same command three times in a session causes it to appear at the top of the empty-query list on the next open, and after relaunching the app.
5. Deleting a Worktree whose `worktree.select.<uuid>` had recency causes that recency entry to disappear on the next palette open (verified via `defaults read`).
6. A ghostty keybind bound to `toggle_command_palette` opens the palette; the existing `PanelActionRouterFeature.Delegate.commandPaletteToggleRequested` no longer no-ops at `RootFeature`.
7. `RootFeatureCommandPaletteRoutingTests` passes with every `Kind` case covered.
8. `CommandPaletteFuzzyScorerTests` passes; the scorer's ordering is deterministic on identical input.
9. No regression in lint or existing tests.

## Idempotence and Recovery

Every milestone's edits are additive. The feature can be disabled at any point by:

- Removing the `⌘P` menu button in `MainWindowCommands.swift` and
- Deleting the `if let paletteStore = …` block in `ContentView.swift`.

The remaining types, reducer, and scorer compile as inert code.

Recency data lives under UserDefaults key `commandPaletteRecency`. To reset during development:

```
defaults delete com.touch-code commandPaletteRecency
```

If a milestone's build fails, revert the milestone's edits and run `make -C apps/mac mac-check`; the tree returns to the previous green state.

## Artifacts and Notes

Expected file additions at completion:

```
apps/mac/touch-code/App/Features/CommandPalette/
  CommandPaletteFeature.swift
  CommandPaletteItem.swift
  CommandPaletteItems.swift
  CommandPaletteFuzzyScorer.swift
  CommandPaletteView.swift
  KeyEquivalentDescriptor.swift

apps/mac/touch-code/Tests/
  CommandPaletteFeatureTests.swift
  CommandPaletteItemsTests.swift
  RootFeatureCommandPaletteRoutingTests.swift

apps/mac/TouchCodeCoreTests/
  CommandPaletteFuzzyScorerTests.swift
```

Edits to existing files:

- `apps/mac/touch-code/App/Features/Root/RootFeature.swift` — ~50 lines added (State field, action cases, `.ifLet` composition, `route(_:)`, `resolveFocusedPanelID`, replace `line 421` no-op).
- `apps/mac/touch-code/App/Commands/MainWindowCommands.swift` — ~6 lines added (new Button, ⌘P binding, inserted at the top of `CommandGroup(after: .newItem)`).
- `apps/mac/touch-code/App/ContentView.swift` — ~6 lines added (overlay mount inside existing ZStack).

No edits expected to: `PanelActionRouterFeature.swift`, `PanelActionRequest.swift`, `WindowActionRequest.swift`, `HierarchyClient.swift`, `EditorFeature.swift`, `SettingsWindowPresenter`, `TouchCodeApp.swift`, `GhosttyActionDecoder.swift`.

## Interfaces and Dependencies

In `apps/mac/touch-code/App/Features/CommandPalette/CommandPaletteItem.swift`, define:

```swift
struct CommandPaletteItem: Equatable, Identifiable {
  let id: String
  let title: String
  let subtitle: String?
  let icon: String
  let shortcut: KeyEquivalentDescriptor?
  let priorityTier: Int
  let hiddenWhenQueryEmpty: Bool
  let kind: Kind

  enum Kind: Equatable {
    case openSettings
    case checkForUpdates
    case quit

    case selectSpace(SpaceID)
    case openSpaceManager
    case switchToSpaceAtIndex(Int)

    case selectWorktree(SpaceID, ProjectID, WorktreeID)
    case closeCurrentWorktree
    case refreshCurrentWorktree
    case toggleGitViewer

    case openCurrentWorktreeInDefaultEditor
    case openCurrentWorktreeIn(EditorID)
    case revealCurrentWorktreeInFinder

    case panelAction(PanelActionRequest)
    case windowAction(WindowActionRequest)
  }
}
```

In `apps/mac/touch-code/App/Features/CommandPalette/CommandPaletteItems.swift`:

```swift
enum CommandPaletteItems {
  static func build(
    selection: HierarchySelection,
    editor: EditorFeature.State,
    catalog: Catalog
  ) -> [CommandPaletteItem]
}
```

In `apps/mac/touch-code/App/Features/CommandPalette/CommandPaletteFuzzyScorer.swift`:

```swift
enum CommandPaletteFuzzyScorer {
  static func score(
    item: CommandPaletteItem,
    query: String,
    recency: [String: TimeInterval],
    now: TimeInterval
  ) -> Int?
}
```

In `apps/mac/touch-code/App/Features/CommandPalette/CommandPaletteFeature.swift`:

```swift
@Reducer
struct CommandPaletteFeature {
  @ObservableState
  struct State: Equatable {
    var query: String = ""
    var selectionID: CommandPaletteItem.ID?
    var items: [CommandPaletteItem] = []
    var filtered: [CommandPaletteItem] = []
  }

  @Shared(.appStorage("commandPaletteRecency"))
  var recency: [String: TimeInterval] = [:]

  enum Action: Equatable {
    case togglePresented
    case dismissed
    case queryChanged(String)
    case selectionMoved(Direction)
    case selectionCommitted
    case rowTapped(CommandPaletteItem.ID)
    case catalogChanged
    case delegate(Delegate)

    enum Direction: Equatable { case up, down }
    enum Delegate: Equatable { case activate(CommandPaletteItem.Kind) }
  }

  var body: some Reducer<State, Action> { /* … */ }
}
```

In `apps/mac/touch-code/App/Features/Root/RootFeature.swift`, extend:

```swift
@Presents var commandPalette: CommandPaletteFeature.State?

enum Action {
  // … existing cases
  case commandPaletteToggle
  case commandPalette(PresentationAction<CommandPaletteFeature.Action>)
}

// in body:
.ifLet(\.$commandPalette, action: \.commandPalette) {
  CommandPaletteFeature()
}

private func route(
  _ kind: CommandPaletteItem.Kind,
  state: inout State
) -> Effect<Action>

private func resolveFocusedPanelID(
  selection: HierarchySelection,
  catalog: Catalog
) -> PanelID?
```

No changes to `PanelActionRequest`, `WindowActionRequest`, `HierarchyClient`, `HierarchyManager`, or any `*Feature` outside CommandPalette / Root.

Dependencies:

- **The Composable Architecture** — already a target dependency; uses `@Reducer`, `@ObservableState`, `@Presents`, `@Shared(.appStorage(…))`, `Scope`, `.ifLet(_:action:)`, `PresentationAction`.
- **SwiftUI** — `ZStack`, `TextField`, `List`, `FocusState`, `.onKeyPress`, `.ultraThinMaterial`. All available on macOS 14+; the app's `Tuist.swift` already pins `compatibleXcodeVersions: .upToNextMajor("26.0")` which ships with macOS 14+ SDKs.
- **TouchCodeCore** — `PanelActionRequest`, `WindowActionRequest`, `Catalog`, `Space`, `Project`, `Worktree`, `SpaceID`, `ProjectID`, `WorktreeID`, `PanelID`, `TabID`. Imported, not modified.

No new third-party dependencies. No new Swift Package additions.
