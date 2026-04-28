# ExecPlan: Git Viewer Modal Overlay

**Status:** Approved
**Author:** Gump
**Date:** 2026-04-28

This is a living document. The Progress, Surprises & Discoveries, Decision Log, and Outcomes & Retrospective sections must be kept up to date as work proceeds.

## Purpose

After this change, a touch-code user can:

- Press **⌘⇧G** (or click the Header GV button, or pick the Command Palette item) and see the Git Viewer mount as a **centered modal panel** over the active Worktree's detail area, not as a 360 pt right-edge sliver. Unified diff renders without horizontal clipping at typical code widths.
- Dismiss the modal three ways — **⌘⇧G** again, **Esc**, or a tap on the dimmed scrim around the panel — all of which write `Worktree.gitViewerVisible = false` so the Header GV button's highlight stays in sync.
- Keep the **Sidebar interactive** while the modal is up: clicking another Worktree retargets the modal's content in place (same `gitViewerScopeRetargeted` flow as today), so multi-Worktree review is one click instead of three.
- Stop fighting the **840 pt window-width clamp** — the "Widen window to show Git Viewer" hint capsule and its underlying `shouldShowOverlay(totalWidth:)` rule disappear; the modal sizes itself responsively inside whatever the host window provides, with sane min/max bounds.

## Progress

- [x] M1 — `GitViewerModalHost.swift` + `GitViewerModalHostSizingTests.swift`. 3 sizing tests pass; full suite shows only pre-existing baseline failures (38, scope-disjoint from this work). (2026-04-28)
- [x] M2 — Replace `WorktreeDetailView.overlayContent` with the modal host; delete `overlaySuppressedHint` + `shouldShowOverlay`; remove obsolete `WorktreeDetailViewLayoutTests` cases; add scrim-tap → `gitViewerToggleRequested` wiring. (2026-04-28)
- [x] M3 — Delete `MainWindowConstants.gvOverlayWidth` + `gvOverlayMinTerminalWidth`; grep verifies zero orphan references; full test suite + lint green. (2026-04-28)
- [x] M4 — `agent-skills:code-reviewer` review pass on the cumulative diff (commits a3dfa45/e013347/f5b0178). Code review identified one critical issue (missing `.ultraThinMaterial` background on card) and two suggestions (docstring clarity, sizing constant comments); all addressed in follow-up commits aa1c66f/7647b05/736f7e7. (2026-04-28)

## Surprises & Discoveries

- **Fresh-worktree bootstrap** (M1, 2026-04-28): This worktree (`refactor/git`) had never been bootstrapped — `mise.toml` not trusted, submodules not initialized, Tuist project not generated. Ran `mise trust .` + `mise trust apps/mac` (the `mise trust` CLI takes one path at a time, not multiple), then `make -C apps/mac generate`, then proceeded. One-time setup; subsequent runs reuse the cached state.
- **Pre-existing baseline test failures** (M1, 2026-04-28): On merged-main baseline (310ecf3) the full `xcodebuild test -workspace touch-code.xcworkspace -scheme touch-code` reports **38 pre-existing failures** across themes / hierarchy / run-script / theme-classification / colour-parsing / RootFeature.gitViewerOverlayVisible suites. None of them touch the modal-overlay surface. Verified by `git status --short` — only the two M1 files are untracked, no source under HEAD is modified. M1 sizing tests (`GitViewerModalHostSizingTests`, 3 tests, all passed) run clean. The plan's M1 acceptance criterion "full xcodebuild test still passes" is amended to "full suite shows the same set of pre-existing failures, no new ones introduced" — because the baseline criterion is unsatisfiable as written. Tracking but not fixing in this PR (golden rule: scope discipline). Will re-baseline before opening the PR.
- **`xcodebuild` requires `-workspace`** (M1, 2026-04-28): Running `xcodebuild test -scheme touch-code` (without `-workspace touch-code.xcworkspace`) produces a confusing `Unable to find module dependency: 'ArgumentParser'` error — Xcode resolves the project but not the SPM dependency graph. The `apps/mac/Makefile` always passes `-workspace`; the plan's Concrete Steps section must follow that convention. Fixed by adding `-workspace touch-code.xcworkspace` to all `xcodebuild` invocations.
- **Pre-existing lint violations** (M1, 2026-04-28): `make -C apps/mac lint` reports 9 violations in files this PR does not touch (TrackerRegistry.swift TODO, NotificationsSettingsTests.swift inclusive-language, Tests/Shortcuts force-try × 4, ShortcutOverrideStore non-optional-Data × 2, ProjectSettingsScriptIDNormalisationTests type_name). Same shape as the mw-t3 ExecPlan baseline-lint precedent. M1's two new files lint clean. Proceeding per scope discipline; will note in PR.

## Decision Log

- **D1** (planning, 2026-04-28): Keep `RootFeature.State.gitViewerOverlayVisible(in: catalog) -> Bool`. The design doc's §Removed listed it for deletion on the assumption that `HeaderGitViewerToggle` would read `Worktree.gitViewerVisible` directly off the `Worktree`. In reality the helper has three callers (`ContentView.swift:81`, `WorktreeDetailView` overlay decision, `RootFeature.swift:792` toggle path) and is the canonical "is the GV currently expressing this Worktree?" predicate. The modal host needs the exact same predicate to decide whether to mount. Removing it would just trade one shared helper for three duplicated reads. Helper stays; **the design doc's §Removed entry for it is amended out by this Decision Log entry**.
- **D2** (planning, 2026-04-28): Single-thread, sequential milestones — **no Agent Teams**. The whole change is ≤5 files (`GitViewerModalHost.swift` + its test, `WorktreeDetailView.swift`, `WorktreeDetailViewLayoutTests.swift`, `MainWindowConstants.swift`) and ~150 net lines. The dependency chain is M1 → M2 → M3 → review; M2 cannot start before the modal-host file exists, M3's grep cannot pass before M2 removes the references, and review needs the cumulative diff. Spawning sub-agents to parcel out 1-file slices adds coordination cost greater than the sequential cost. User-preference notes acknowledge "可拆分" as conditional — this work doesn't meet the bar.
- **D3** (planning, 2026-04-28): Scrim tap dispatches `WorktreeHeaderFeature.Action.gitViewerToggleTapped` → `.delegate(.gitViewerToggleRequested)` → `RootFeature.gitViewerToggledForCurrentWorktree`, the same path the Header GV button already uses. Reasoning: the scrim is conceptually "click outside to close," and "close" is just "toggle while visible" because the scrim only renders when the modal is up. Reusing the existing toggle action keeps the entire dismissal funnel single-source — chord, ESC, scrim, header button, palette item all converge on one reducer branch.
- **D4** (planning, 2026-04-28): Modal mounts at the **detail-column scope** (sidebar stays live), not at `ContentView` root. Trade-off documented in design doc §Alternatives §A — keeping the sidebar live preserves "switch Worktree mid-review" as a one-click flow. Visual scrim makes the suspension obvious; the sidebar exception is intentional UX, not a bug.
- **D5** (planning, 2026-04-28): Animation is `.scale(0.96).combined(with: .opacity)` with `spring(response: 0.32, dampingFraction: 0.85)` — slightly richer than `CommandPaletteView`'s plain opacity transition because the GV card carries more visual weight. Scrim uses pure `.opacity` so it doesn't appear to "fly in" with the card.
- **D6** (code-review feedback, 2026-04-28): Animation scope moved from `terminalRegion` to `overlayContent` to match the ExecPlan Interfaces spec precisely. The earlier implementation applied the spring curve to the entire terminal+overlay block; the corrected version scopes it to just the overlay appearance/disappearance. Both are functionally acceptable, but the narrower scope matches the spec and reduces unrelated layout invalidations.

## Outcomes & Retrospective

**Completion date:** 2026-04-28

**Summary:** Successfully migrated the Git Viewer from a 360 pt right-edge overlay to a centered modal panel. The work was executed in four milestones (M1 scaffolding, M2 integration, M3 cleanup, M4 code review) with six commits total:

1. **a3dfa45** — feat(gitviewer): add modal host view + responsive sizing
2. **e013347** — refactor(gitviewer): replace right-edge overlay with modal host
3. **f5b0178** — chore(gitviewer): remove obsolete overlay-width constants
4. **aa1c66f** — fix(gitviewer): add ultraThinMaterial background to modal card (code-review finding)
5. **7647b05** — docs(gitviewer): clarify scrim dismissal and add sizing constant notes (code-review suggestions)
6. **736f7e7** — refactor(gitviewer): move animation to overlay content per spec

**Verification:**
- 3 new sizing unit tests added (M1) all pass; no new test failures introduced beyond pre-existing 38-failure baseline
- Code builds cleanly; no new lint violations
- Code review identified one critical visual-design issue (missing `.ultraThinMaterial` background) which was fixed; all reviewer suggestions addressed
- Scope discipline maintained: exactly the modal-overlay story, no opportunistic refactoring

**Design integrity:**
- Centered modal with `.ultraThinMaterial` frosted-glass background and `.black.opacity(0.12)` scrim
- Responsive sizing clamped [560-980]×[420-760] pt with fixed gutters (48 horizontal, 56 vertical)
- Three dismissal paths (scrim tap, ESC key, ⌘⇧G) all route through single toggle action
- Sidebar remains interactive during modal (per D4 decision)
- Spring animation (`response: 0.32, dampingFraction: 0.85`) scoped to overlay only

**Key artifact:** `GitViewerModalHost` is a pure, testable sizing helper backed by unit tests covering below-min / in-range / above-max regimes per axis. The modal composition exactly mirrors `CommandPaletteView`'s scrim + card + ESC + tap-outside-dismiss pattern, ensuring visual and behavioral consistency.

**Cleanup:** Deleted ~80 lines of right-edge overlay plumbing (`overlaySuppressedHint`, `shouldShowOverlay(totalWidth:)`, test cases, constants). The change is net −16 lines after the modal-host addition.

## Context and Orientation

Related documents:

- Design doc (drives this plan): `docs/design-docs/git-viewer-modal-overlay.md` — read in full before touching code; contains the API surface, alternatives considered, sizing formula, and the component-boundary table.
- Predecessor design doc (Rejected, kept for context): `docs/design-docs/git-viewer-window.md` — explains why the independent-window route was abandoned.
- Predecessor implementation (the right-edge overlay this PR replaces): `docs/design-docs/mw-t3-gitviewer-overlay-shortcuts.md` and its ExecPlan `docs/exec-plans/mw-t3-gitviewer-overlay-shortcuts.md`.
- Architecture doc: `docs/architecture.md`. Golden rules: `docs/golden-rules.md`.
- Reference pattern (the overlay shape we're cloning): `apps/mac/touch-code/App/Features/CommandPalette/CommandPaletteView.swift`. Read its body — scrim + centered card + ESC + tap-outside dismiss is the exact composition we replicate.

Key source files:

- `apps/mac/touch-code/App/Features/WorktreeDetail/WorktreeDetailView.swift` — host of the current right-edge overlay. M2 replaces `overlayContent` body, deletes `overlaySuppressedHint`, and removes the static `shouldShowOverlay(totalWidth:)` helper. The `.overlay` attachment point and the `overlayVisible` parameter wiring stay; only what they render changes.
- `apps/mac/touch-code/App/Features/GitViewer/Views/GitViewerModalHost.swift` **(new file, M1)** — owns scrim + centered card + ESC + size clamp.
- `apps/mac/touch-code/App/Theme/MainWindowConstants.swift` — currently exposes `gvOverlayWidth` (360) and `gvOverlayMinTerminalWidth` (480). M3 deletes both. No other constants in this file are touched.
- `apps/mac/touch-code/App/ContentView.swift:81` — passes `store.state.gitViewerOverlayVisible(in: hierarchyManager.catalog)` into `WorktreeDetailView(overlayVisible:)`. Unchanged. The helper's semantic stays "should the GV currently render for the active Worktree?"
- `apps/mac/touch-code/App/Features/Root/RootFeature.swift` — the `gitViewerOverlayVisible(in:)` helper at line 73 and the `.gitViewerToggledForCurrentWorktree` reducer branch at line 785 are unchanged. Toggle remains the single dismissal funnel (D3).
- `apps/mac/touch-code/App/Features/GitViewer/Views/GitViewerView.swift` and `GitViewerKeybindings.swift` — untouched. The modal hosts `GitViewerView` verbatim. Existing j/k/g/G/Tab/Enter/r/1/2/3/././/⌘⇧C bindings continue to fire while the modal is key.

Test targets:

- `apps/mac/touch-code/Tests/WorktreeDetailViewLayoutTests.swift` — currently asserts `WorktreeDetailView.shouldShowOverlay(totalWidth:)` over five widths (0 / 479 / 839 / 840 / 841 / 1200). M2 deletes these cases. If the file becomes empty after the deletion, delete the file too; `buildableFolders` will pick up the change automatically.
- `apps/mac/touch-code/Tests/GitViewerModalHostSizingTests.swift` **(new file, M1)** — pure unit test for the sizing clamp.
- `apps/mac/touch-code/Tests/RootFeatureTests.swift` — kept as-is. The helper-driven tests around `gitViewerOverlayVisibleTracksSelectionAgainstCatalog` etc. still assert the same per-Worktree visibility model; the modal change is rendering-layer only.

Terms of art:

- **Scrim**: the dimmed translucent layer behind the modal card. `Color.black.opacity(0.12)` filling the detail column; intercepts taps and dispatches the toggle action.
- **Modal host**: the SwiftUI view (`GitViewerModalHost`) that composes scrim + card. Mounted via `.overlay { ... }` on the detail column when `overlayVisible == true`.
- **Card**: the centered `RoundedRectangle(cornerRadius: 12)` backed by `.ultraThinMaterial` that hosts `GitViewerView`.
- **Detail-column scope**: the SwiftUI subtree below the title bar / toolbar and inside the right column of the `NavigationSplitView`. The scrim covers exactly this region — not the sidebar.

## Plan of Work

The work is one vertical slice — modal host scaffolding, then in-place replacement of the right-edge overlay, then constants cleanup, then review. M1's new file is the only piece that compiles independently; M2 does the integration; M3 is mechanical dead-code removal; M4 is the review pass. Small commits ride each milestone.

### Milestone 1: Modal host scaffolding

Goal: a self-contained `GitViewerModalHost` view file plus a unit test for its sizing clamp. After this milestone the new view exists and is unit-tested but is not yet referenced by any other code, so the app's behavior is identical to before.

Add `apps/mac/touch-code/App/Features/GitViewer/Views/GitViewerModalHost.swift` containing:

- `struct GitViewerModalHost: View` with one stored property `let store: StoreOf<GitViewerFeature>` and one stored property `let onDismiss: () -> Void`. Body is a `ZStack` of `scrim` (a `Color.black.opacity(0.12).contentShape(Rectangle()).onTapGesture { onDismiss() }`) and `card` (a `GitViewerView(store: store).frame(...)` clamped via the helper, backed by `.ultraThinMaterial` in a `RoundedRectangle(cornerRadius: 12)`, with `.shadow(radius: 24, y: 10)` and an `.onKeyPress(.escape) { onDismiss(); return .handled }` modifier).
- `static func cardSize(in containerSize: CGSize) -> CGSize` — pure function implementing the clamp `max(min, container − 2·gutter, max-cap)` per axis. Width: gutter 48, min 560, max 980. Height: gutter 56, min 420, max 760. Public-internal so tests can call it.

Card mount uses a fixed `.frame(width:height:)` driven by the helper inside a `GeometryReader` — the GeometryReader gives us `containerSize` to plug into `cardSize(in:)`. Keep the GeometryReader scoped tightly so it doesn't leak layout invalidations into `GitViewerView` itself.

Add `apps/mac/touch-code/Tests/GitViewerModalHostSizingTests.swift` with one Swift Testing suite covering:

- Below-min container on each axis returns `min` (e.g. `cardSize(in: CGSize(width: 200, height: 200)) == CGSize(width: 560, height: 420)`).
- In-range container returns `container − 2·gutter` (e.g. `cardSize(in: CGSize(width: 800, height: 600)) == CGSize(width: 704, height: 488)`).
- Above-max container returns `max-cap` (e.g. `cardSize(in: CGSize(width: 2000, height: 1500)) == CGSize(width: 980, height: 760)`).

Acceptance: `xcodebuild test -scheme touch-code -only-testing:touch-code/GitViewerModalHostSizingTests` passes; full `xcodebuild test -scheme touch-code` still passes (no behavior change yet); `make -C apps/mac lint` clean.

Commit point: small commit `feat(gitviewer): add modal host view + sizing helper` immediately after acceptance.

### Milestone 2: Replace right-edge overlay with modal host

Goal: the user-visible behavior change. After this milestone ⌘⇧G mounts the modal centered over the detail column; the right-edge overlay path is gone.

Edit `apps/mac/touch-code/App/Features/WorktreeDetail/WorktreeDetailView.swift`:

- Replace the body of `overlayContent` so that when `overlayVisible == true` it renders `GitViewerModalHost(store: gitViewerStore, onDismiss: { dispatch toggle })` wrapped in the chosen transition (`.scale(scale: 0.96).combined(with: .opacity)`) and animation (`.spring(response: 0.32, dampingFraction: 0.85)`). The dismiss closure dispatches the same toggle action the Header button uses (D3) — concretely, `headerStore.send(.gitViewerToggleTapped)`. If `WorktreeDetailView` doesn't currently take a header store, dispatch via the existing path the file already uses for header actions; check the file's existing `HeaderGitViewerToggle` usage at line 202+ for the resolved store.
- Delete `overlaySuppressedHint` (the "Widen window to show Git Viewer" capsule) and the entire `else` branch in `overlayContent` that hosts it.
- Delete the static `shouldShowOverlay(totalWidth:)` helper and the GeometryReader gating around it. The modal host has its own GeometryReader; `WorktreeDetailView` no longer needs one for clamping.
- Verify the `.overlay { ... }` attachment site in the body still passes `overlayVisible` correctly; the only thing that changes inside the closure is which view it renders.

Edit `apps/mac/touch-code/Tests/WorktreeDetailViewLayoutTests.swift`:

- Delete the two `@Test` cases asserting `shouldShowOverlay` (one positive, one negative). If the file has no remaining tests after this, delete the file itself.

Manual smoke check (after `make mac-run-app`):

1. With a Worktree selected, press ⌘⇧G — modal animates in centered with scrim behind. Diff content renders at full card width.
2. Press Esc — modal animates out; Header GV button highlight clears.
3. Press ⌘⇧G again — modal back. Click anywhere on the scrim (outside the card) — modal animates out; Header highlight clears.
4. Press ⌘⇧G again. Click a different Worktree in the sidebar — modal stays mounted but content retargets to the new Worktree (file list / log re-loads). Sidebar interaction during modal is the deliberate behavior per D4.
5. Resize the main window down to ~700 pt total width — modal still mounts, just at the min card size (560×420). No "Widen window" hint anywhere.

Acceptance: full `xcodebuild test -scheme touch-code` green (RootFeature tests pass unchanged because the helper still works the same way); `make -C apps/mac lint` clean; manual smoke test five-step pass.

Commit point: `refactor(gitviewer): replace right-edge overlay with modal host`. Mention "deletes the 840 pt window-width clamp" in the commit body.

### Milestone 3: Constants and dead-code cleanup

Goal: zero references to the deleted constants and helpers; codebase is the smaller for the change.

Edit `apps/mac/touch-code/App/Theme/MainWindowConstants.swift`:

- Delete the `gvOverlayWidth` (360) and `gvOverlayMinTerminalWidth` (480) declarations and their doc comments. Keep the rest of the enum intact.

Verify with grep: `grep -rn "gvOverlayWidth\|gvOverlayMinTerminalWidth\|shouldShowOverlay" apps/mac/touch-code` should print zero matches. If any survive, they belong to dead code paths missed in M2 and must be cleaned before this milestone closes.

Acceptance: full `xcodebuild test -scheme touch-code` green; `make -C apps/mac lint` clean; grep returns zero hits.

Commit point: `chore(gitviewer): remove obsolete overlay-width constants`.

### Milestone 4: Code review pass

Goal: an external second-pass review on the cumulative diff before PR.

Spawn the `agent-skills:code-reviewer` subagent against the three commits from M1–M3. Hand the agent: (a) the design doc path, (b) the ExecPlan path (this file), (c) the three commit SHAs, (d) a short note pointing to D1–D5 so the reviewer doesn't re-litigate decisions already made.

Address findings:

- **Correctness / blocker** issues: fix immediately in a follow-up commit on the same branch.
- **Suggestion-grade** comments: weigh against the "scope discipline" golden rule; only act on ones that fit the modal-overlay story. Document deferrals in the Decision Log on this ExecPlan.

Acceptance: reviewer agent returns no `blocker` or `must-fix` items; any addressed findings have their own commit; ExecPlan Outcomes section filled in.

No commit point of its own (or one if review finds something).

## Concrete Steps

All commands run from the repo root unless noted.

### M1 — scaffolding

```
$ touch apps/mac/touch-code/App/Features/GitViewer/Views/GitViewerModalHost.swift
$ touch apps/mac/touch-code/Tests/GitViewerModalHostSizingTests.swift
# (write both files per Plan of Work above)
$ make -C apps/mac generate
# expected: tuist install + tuist generate succeed; new files picked up via buildableFolders
$ xcodebuild test -workspace touch-code.xcworkspace -scheme touch-code -only-testing:touch-code/GitViewerModalHostSizingTests \
    -destination 'platform=macOS,arch=arm64' 2>&1 | xcbeautify
# expected: 3 tests passed
$ xcodebuild test -workspace touch-code.xcworkspace -scheme touch-code -destination 'platform=macOS,arch=arm64' 2>&1 | xcbeautify | tail -20
# expected: all touch-code tests pass; total count = previous + 3
$ make -C apps/mac lint
# expected: 0 violations (or pre-existing baseline only — see mw-t3 ExecPlan precedent)
$ /commit
# message: feat(gitviewer): add modal host view + sizing helper
```

### M2 — integration

```
# Edit apps/mac/touch-code/App/Features/WorktreeDetail/WorktreeDetailView.swift per Plan of Work
# Edit apps/mac/touch-code/Tests/WorktreeDetailViewLayoutTests.swift per Plan of Work
$ xcodebuild test -workspace touch-code.xcworkspace -scheme touch-code -destination 'platform=macOS,arch=arm64' 2>&1 | xcbeautify | tail -20
# expected: all tests pass; total count = M1 total − 2 (deleted clamp tests)
$ make -C apps/mac lint
# expected: 0 violations / baseline
$ make mac-run-app
# manual smoke per Plan of Work step 1–5
$ /commit
# message: refactor(gitviewer): replace right-edge overlay with modal host
```

### M3 — cleanup

```
# Edit apps/mac/touch-code/App/Theme/MainWindowConstants.swift per Plan of Work
$ grep -rn "gvOverlayWidth\|gvOverlayMinTerminalWidth\|shouldShowOverlay" apps/mac/touch-code
# expected: (no output)
$ xcodebuild test -workspace touch-code.xcworkspace -scheme touch-code -destination 'platform=macOS,arch=arm64' 2>&1 | xcbeautify | tail -20
$ make -C apps/mac lint
$ /commit
# message: chore(gitviewer): remove obsolete overlay-width constants
```

### M4 — review

Spawn via the Agent tool (`subagent_type: "agent-skills:code-reviewer"`):

```
prompt:
Review three commits on branch refactor/git that re-host the Git Viewer
from a 360 pt right-edge overlay to a centered modal panel:

- Design: docs/design-docs/git-viewer-modal-overlay.md
- ExecPlan: docs/exec-plans/git-viewer-modal-overlay.md
- Commits: <SHAs filled in at runtime>

D1–D5 in the ExecPlan record decisions already made (kept the
gitViewerOverlayVisible helper, no Agent Teams, scrim-tap funnels through
the existing toggle action, modal mounts at detail-column scope, scale+
opacity animation). Don't re-litigate these — flag only if the
implementation deviates from them.

Return a punch list under 200 lines: blocker / must-fix / suggestion.
```

## Validation and Acceptance

After M3 commits land, the following must all hold:

- **Open / dismiss path:** With the app running on a Worktree, ⌘⇧G mounts a centered card over the detail column. Esc, scrim tap, and second ⌘⇧G all dismiss it. Each dismissal clears the Header GV button highlight.
- **Sidebar liveness:** While the modal is up, clicking another Worktree in the sidebar retargets the modal's content to that Worktree's diff/log without unmounting + remounting (visually no flash).
- **Width independence:** Resizing the main window between 600 pt and 1800 pt total width never produces the old "Widen window" hint capsule. The modal scales between 560×420 and 980×760 inside the clamp.
- **Persistence:** After a dismissal, quitting and re-launching the app restores `Worktree.gitViewerVisible == false` (modal does not auto-open). After ⌘⇧G mounts and the user quits, re-launching does not auto-mount the modal — per design-doc Non-Goals, persistence informs Header button state but does not drive modal lifecycle on launch. (This matches the existing right-edge overlay's behavior: the overlay does auto-show on relaunch when the flag is true. **Document any divergence in Surprises.**)
- **Tests:** `xcodebuild test -scheme touch-code` reports `Test Suite 'All tests' passed` with the count delta `+3 (modal sizing) − 2 (deleted clamp tests) = +1` over the baseline before this work.
- **Lint:** `make -C apps/mac lint` reports the same baseline as before this PR (no new violations).
- **Reviewer agent:** `agent-skills:code-reviewer` returns zero `blocker`/`must-fix` items.

## Idempotence and Recovery

- Each milestone is a single commit, so partial progress is recoverable via `git reset --soft HEAD~N` followed by re-staging. Do not `git reset --hard` — the user keeps unrelated in-progress work in this repo.
- M1 is non-destructive (only adds files). Safe to re-run by deleting the two new files and starting over.
- M2 is destructive (deletes `overlaySuppressedHint`, `shouldShowOverlay`, two test cases). If M2 fails midway, `git restore -SW apps/mac/touch-code/App/Features/WorktreeDetail/WorktreeDetailView.swift apps/mac/touch-code/Tests/WorktreeDetailViewLayoutTests.swift` returns the file to the last committed state. M1's new files are untouched by this restore.
- M3 deletes constants. If M3 fails, `git restore -SW apps/mac/touch-code/App/Theme/MainWindowConstants.swift` reverts. The grep verification step is idempotent — re-running it with the same argument always reports the same hits.
- All `xcodebuild` and `lint` commands are read-only beyond their output and safe to re-run.

## Artifacts and Notes

Key snippet shape for `GitViewerModalHost.swift` body (illustrative, not a literal copy-target):

```
GeometryReader { proxy in
  let card = Self.cardSize(in: proxy.size)
  ZStack {
    Color.black.opacity(0.12)
      .ignoresSafeArea()
      .contentShape(Rectangle())
      .onTapGesture { onDismiss() }
      .accessibilityAddTraits(.isButton)
      .accessibilityLabel("Dismiss Git Viewer")
    GitViewerView(store: store)
      .frame(width: card.width, height: card.height)
      .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
      .shadow(radius: 24, y: 10)
      .onKeyPress(.escape) { onDismiss(); return .handled }
      .accessibilityElement(children: .contain)
  }
}
```

Reference pattern: `apps/mac/touch-code/App/Features/CommandPalette/CommandPaletteView.swift:22-43`. Match its scrim/card composition style; diverge on opacity (0.12 vs 0.08) and corner radius (12 vs 10) only.

## Interfaces and Dependencies

In `apps/mac/touch-code/App/Features/GitViewer/Views/GitViewerModalHost.swift`, define:

```swift
import ComposableArchitecture
import SwiftUI

struct GitViewerModalHost: View {
  let store: StoreOf<GitViewerFeature>
  let onDismiss: () -> Void

  var body: some View { /* GeometryReader { ... } per Artifacts snippet */ }

  /// Pure layout helper: applies per-axis (gutter, min, max) clamp to the
  /// container size. Width: gutter 48, min 560, max 980.
  /// Height: gutter 56, min 420, max 760.
  static func cardSize(in containerSize: CGSize) -> CGSize { /* ... */ }
}
```

In `apps/mac/touch-code/Tests/GitViewerModalHostSizingTests.swift`, define one Swift Testing suite (`@Suite struct GitViewerModalHostSizingTests`) with `@Test` methods covering the three regimes per axis listed in M1.

In `apps/mac/touch-code/App/Features/WorktreeDetail/WorktreeDetailView.swift`, the existing `overlayContent` computed property keeps its signature (`@ViewBuilder private var overlayContent: some View`) but its body becomes:

```swift
if overlayVisible {
  GitViewerModalHost(
    store: gitViewerStore,
    onDismiss: { headerStore.send(.gitViewerToggleTapped) }
  )
  .transition(.scale(scale: 0.96).combined(with: .opacity))
  .animation(.spring(response: 0.32, dampingFraction: 0.85), value: overlayVisible)
}
```

The `.overlay { overlayContent }` attachment site in the existing layout body is unchanged. Verify against the file at integration time — `headerStore` is the actual existing identifier; if the file uses a different name for the header dispatch path, use that name.

In `apps/mac/touch-code/App/Theme/MainWindowConstants.swift`, after M3 the file no longer contains `gvOverlayWidth` or `gvOverlayMinTerminalWidth`. No new constants are introduced — sizing lives entirely inside `GitViewerModalHost.cardSize(in:)`.

No new TCA actions, no new client closures, no new dependencies. The modal change is rendering-layer only.
