# ExecPlan: Terminal Engine and Five-Level Hierarchy (C1 + C2)

**Status:** In Progress
**Author:** Gump (with Claude)
**Date:** 2026-04-19

This is a living document. The Progress, Surprises & Discoveries, Decision Log, and Outcomes & Retrospective sections must be kept up to date as work proceeds.

## Purpose

After this plan lands, a contributor who `make mac-build && make mac-run-app` sees the first working touch-code session:

- The app launches and restores a previously-saved hierarchy from disk, so opening the app twice in a row resumes exactly where the user left off.
- The sidebar shows Space → Project → Worktree levels. The selected Worktree shows its Tabs in a tab bar; the active Tab shows one or more live Panels arranged by a split tree.
- Each Panel is a real libghostty terminal running the user's shell. Typing into a Panel works. Splitting, closing, switching Tabs, and switching Worktrees all happen in under one frame.
- A Panel that crashes shows a placeholder with a "Retry" action instead of taking down the Tab; three crashes in 30s close the Tab with a toast.
- Creating or removing a git Worktree from the UI calls `git worktree add|remove` under the hood and the file system reflects the change immediately.

This is the first plan where the app becomes recognisable as "a terminal orchestrator" rather than "an empty window". Every later capability (C3 Hooks, C4 CLI, C6 notifications, C7 git viewer, C8 editor) attaches to the event stream and hierarchy produced here.

## Progress

- [x] M1 — Domain model skeleton in `TouchCodeCore` (IDs, Space/Project/Worktree/Tab/Panel structs, `SplitTree<PanelID>`, `AtomicFileStore`, unit tests) — 2026-04-19
- [ ] M2 — `CatalogStore` + headless `HierarchyManager` (load/save, pruning, debounced write, structural mutations, unit tests with a fake runtime)
- [ ] M3 — Re-enable `GhosttyKit` and render a single hardcoded Panel (bootstrap DEC-8 follow-up; `GhosttyRuntime`, `PanelSurface`, bare `PanelHostView`)
- [ ] M4 — `TerminalEngine` façade + `AsyncStream<TerminalEvent>` + crash isolation + output coalescing
- [ ] M5 — TCA clients, sidebar / tab bar / split-view UI, lazy surface creation, full persistence round-trip
- [ ] M6 — Git worktree CLI integration, default sibling `<repo>-worktrees/<branch>/` layout, non-git Project fallback

## Surprises & Discoveries

(None yet)

## Decision Log

- **DEC-1 (M1, 2026-04-19): `SWIFT_DEFAULT_ACTOR_ISOLATION = nonisolated` on data-only targets.** The workspace-level default is `MainActor`, which caused protocol requirements (`HierarchyID.init(raw:)`, `var raw`) to be MainActor-isolated and unreachable from nonisolated struct extensions. Matching supaterm's `SupatermCLIShared` / `SPCLI` pattern, overrode the setting on `TouchCodeCore`, `TouchCodeCoreTests`, and `TouchCodeIPC`. The app target keeps the MainActor default.
- **DEC-2 (M1, 2026-04-19): `SplitTree` trimmed — deferred spatial operations.** Supaterm's `SplitTree<ViewType>` carries spatial helpers (`Spatial`, `resizing by:pixels in:`, `sizing to:cells`, `equalized`, `tiled`, `mainVertical`, `viewBounds`) that depend on `NSView` bounds. For the pure-Swift, AppKit-free TouchCodeCore, only algebraic/topological ops ship in M1: `leaves`, `contains`, `path(to:)`, `inserting`, `removing`, `replacing`, `settingZoomed`, `resizing(at:ratio:)`, `focusTarget(for:from:)` (no `.spatial` case), `focusTargetAfterClosing`. UI-layer extensions in M5 will bring back bounds-aware operations.
- **DEC-3 (M1, 2026-04-19): Disabled SwiftLint `identifier_name` rule.** Same pattern as supaterm. The rule's 3-char minimum conflicts with idiomatic Swift names (`l`/`r` in SplitTree pattern matching, `fd` for file descriptor, `fm` for FileManager, enum cases like `up`/`down`). Domain-meaningful short names are preferable to renaming them; disabling the rule costs less than constant exclusions.
- **DEC-4 (M1, 2026-04-19): M1 landed as a single commit rather than the two commits the plan predicted.** The plan suggested `feat(core): domain types and SplitTree<PanelID>` plus `feat(core): AtomicFileStore + round-trip tests`. In practice the two pieces were interleaved (tests cover both; the test target PR itself is inherently one unit). Kept it as one coherent M1 commit to preserve reviewability.

## Outcomes & Retrospective

### M1 — Domain model skeleton (2026-04-19)

**What landed:**
- `apps/mac/TouchCodeCore/` — `IDs.swift` (SpaceID/ProjectID/WorktreeID/TabID/PanelID behind `HierarchyID` protocol), `Panel.swift`, `Tab.swift` (with `splitTreeLeafIDs` / `flatPanelIDs` / `validateInvariants()`), `Worktree.swift`, `Project.swift` (with `supportsWorktrees`), `Space.swift`, `Catalog.swift` (version-gated Codable, `currentVersion = 1`, `defaultURL`), `SplitTree.swift` (generic `SplitTree<Leaf>` pure-value API), `AtomicFileStore.swift` (write-to-temp → fsync → rename).
- `apps/mac/TouchCodeCoreTests/` — new `.unitTests` Tuist target with `SplitTreeTests` (15 cases), `CatalogCodableTests` (7 cases), `AtomicFileStoreTests` (5 cases). 28 tests total; all pass on first green build.
- `apps/mac/Project.swift` — new `TouchCodeCoreTests` target; `SWIFT_DEFAULT_ACTOR_ISOLATION = nonisolated` on `TouchCodeCore`, `TouchCodeCoreTests`, `TouchCodeIPC`.
- `apps/mac/.swiftlint.yml` — added `TouchCodeCoreTests` to included; disabled `identifier_name`.

**Verification:** `xcodebuild test -scheme TouchCodeCore` → 28 passed in 0.028s. `xcodebuild build -scheme touch-code` → `BUILD SUCCEEDED`. `make lint` → clean.

**Carry-forward to M2:** `CatalogStore` can now be built on top of `AtomicFileStore` + `Catalog`'s version-gated decoder. `HierarchyManager` has stable UUID IDs, `Tab.validateInvariants()`, and `SplitTree<PanelID>` mutations to drive structural tests without ghostty.

## Context and Orientation

Related documents (all in this repo):

- Product spec — [docs/product-spec.md](../product-spec.md), capabilities C1 and C2
- Design doc — [docs/design-docs/0001-terminal-and-hierarchy.md](../design-docs/0001-terminal-and-hierarchy.md) — **authoritative** for every design decision. This plan does not relitigate those decisions; it implements them.
- Architecture — [docs/architecture.md](../architecture.md) — codemap, dependency direction, invariants (Panel mutability in Runtime, hybrid state management, atomic-rename JSON, IPC namespaces)
- Golden rules — [docs/golden-rules.md](../golden-rules.md)
- Previous ExecPlan — [docs/exec-plans/0001-bootstrap-monorepo.md](0001-bootstrap-monorepo.md), especially DEC-8 (deferred GhosttyKit `foreignBuild`) which M3 resolves

Reference projects (filesystem-local, read-only — we borrow first and deviate with a stated reason, per memory):

- **supacode** — `/Users/wanggang/dev/opensource/supacode`
  - `supacode/Infrastructure/Ghostty/GhosttyRuntime.swift` — how to wrap `ghostty_app_t` + `ghostty_surface_t`, surface reference bookkeeping, callback plumbing
  - `supacode/Features/Terminal/BusinessLogic/WorktreeTerminalManager.swift` — shape of the `@Observable` manager that glues hierarchy and runtime
  - `supacode/Clients/Terminal/TerminalClient.swift` — the TCA `DependencyKey` command/event bridge we copy
  - `supacode/Domain/` — worktree models
- **supaterm** — `/Users/wanggang/dev/opensource/supaterm`
  - `apps/mac/supaterm/Features/Terminal/Models/SplitTree.swift` — the generic split tree we specialise to `SplitTree<PanelID>`
  - `apps/mac/supaterm/Features/Terminal/Models/TerminalSession*.swift` — schema-versioned catalog with `pruned()` cascade
  - `apps/mac/supaterm/Features/Terminal/Ghostty/GhosttyRuntime.swift` — sibling Ghostty wrapper, simpler than supacode
  - `apps/mac/supaterm/Features/Terminal/Views/SplitView.swift` — the `NSView` tree that renders a `SplitTree`
- **upstream ghostty** (via submodule at `apps/mac/ThirdParty/ghostty`)
  - `macos/Sources/Ghostty/Ghostty.Surface.swift` + `Surface View/SurfaceView_AppKit.swift` — the official `SurfaceView` we host inside a SwiftUI `NSViewRepresentable`. We do **not** reimplement the view; we embed ghostty's

**Terminology used in this plan**:

- **Panel** — the user-facing "one terminal tile" concept from the product spec. In code, a `Panel` is a value-type struct (identity + working directory + initial command) stored under a Tab; its live surface is a separate `PanelSurface` inside Runtime.
- **PanelSurface** — a Runtime-owned class wrapping one `ghostty_surface_t`. One-to-one with a Panel while alive. Owns scrollback, cursor, crash state, callbacks.
- **HierarchyManager** — the `@Observable` single writer for the hierarchy tree. All structural mutations (create/remove/move Worktree / Tab / Panel, split, swap) go through it. Exposed to TCA features via `HierarchyClient`.
- **TerminalEngine** — a façade that composes `GhosttyRuntime`, `HierarchyManager`, and `CatalogStore` and exposes the public `AsyncStream<TerminalEvent>` and the two `*Client` types. "The Runtime" in the design doc refers to this façade when talking about external-visible behaviour.
- **SplitTree** — `SplitTree<PanelID>`, a recursive value type (leaf of `PanelID` or split with direction + ratio + two children). Lives in `TouchCodeCore`, Codable, Equatable, pure Swift.
- **catalog.json** — the persisted hierarchy file at `~/.config/touch-code/catalog.json`. Version-gated; atomic-rename writes; debounced.
- **foreignBuild target** — same meaning as in the bootstrap plan: a Tuist target declaring an external build step whose output is an artifact (here, `GhosttyKit.xcframework`). Currently commented out per bootstrap DEC-8; M3 re-enables it.

**Orientation paragraph.** The implementation is layered but we deliver vertically. M1 gives us the pure-Swift domain model; M2 adds persistence and a headless `HierarchyManager` that can be unit-tested without ever spinning up a ghostty surface. M3 derisks the external integration by resolving the deferred `GhosttyKit` `foreignBuild` and landing a single hardcoded Panel — the first moment a user sees a real terminal. M4 merges the two halves: the `HierarchyManager` now drives real `PanelSurface` creation/teardown, wired by a `TerminalEngine` façade exposing the event stream we will reuse in every future capability. M5 wraps it in UI — sidebar, tab bar, split view — and wires restore-on-launch. M6 closes the last gap (git worktree operations and non-git Projects) so that the "add Worktree" button in the sidebar actually creates a worktree on disk. Each milestone is independently verifiable and produces at least one commit per the project's commit-after-each-small-feature cadence.

## Plan of Work

Six milestones. Slicing is vertical where it helps: M3 punches end-to-end through to pixels for a single Panel, and M5 does the same for the full UI.

### Milestone 1: Domain model skeleton in TouchCodeCore

**Goal after this milestone.** Every Space/Project/Worktree/Tab/Panel identifier, value type, and the `SplitTree<PanelID>` type exists in `TouchCodeCore` as pure Swift with full Codable / Equatable / Sendable conformance, plus a Persistence helper for atomic-rename reads and writes. Unit tests cover Codable round-trips and every `SplitTree` operation. Zero imports of AppKit, SwiftUI, or GhosttyKit.

This milestone is cheap, low-risk, and unblocks everything else. It is also the first opportunity to land a new Tuist test target (`TouchCodeCoreTests`).

**Work.** Under `apps/mac/TouchCodeCore/`, create `IDs.swift` defining UUID newtypes `SpaceID`, `ProjectID`, `WorktreeID`, `TabID`, `PanelID`, each a `struct` wrapping `UUID` with Codable / Hashable / Sendable and an `init()` that calls `UUID()`. Create `Space.swift`, `Project.swift`, `Worktree.swift`, `Tab.swift`, `Panel.swift` for the value-type structs as sketched in the design doc (§Data Storage). Create `Catalog.swift` with the top-level `Catalog` struct, `currentVersion: Int = 1`, and a custom `Codable` that aborts on unknown version (copy supaterm's pattern in `TerminalSessionCatalog`). Create `SplitTree.swift` adapting supaterm's `SplitTree<ViewType>` to `SplitTree<PanelID>`: same shape (`Node`, `Split`, `Direction`, `Path`, `SpatialSlot`, `SplitError`, `FocusDirection`, `SizeUnit`, `NewDirection`), but the generic parameter is `PanelID` and the tree is `Codable` + `Equatable` + `Sendable`. Remove anything tied to `NSView` (the `bounds` / `Spatial` computation moves to the UI layer in M5; keep a placeholder `enum SpatialDirection` so paths still parse). Create `AtomicFileStore.swift` with a single public helper:

    enum AtomicFileStore {
      static func read<T: Decodable>(
        _ type: T.Type, at url: URL, decoder: JSONDecoder = .default
      ) throws -> T?
      static func write<T: Encodable>(
        _ value: T, to url: URL, encoder: JSONEncoder = .default
      ) throws
    }

`write` encodes to a sibling temp file in the target directory, `fsync`s the temp descriptor, and `rename(2)`s over the original. `read` returns `nil` on ENOENT; every other error throws. The version check is **not** here — it lives on the concrete decoder side of each store that uses this helper.

Create a new Tuist test target `TouchCodeCoreTests` (static framework, `dependencies: [.target(name: "TouchCodeCore")]`, `buildableFolders: ["TouchCodeCoreTests"]`, `product: .unitTests`). Add `TouchCodeCoreTests/SplitTreeTests.swift` with supaterm's SplitTree test cases ported to the new generic (insert, remove, replace, zoom/unzoom, focus navigation, path resolution). Add `TouchCodeCoreTests/CatalogCodableTests.swift` covering round-trip encode/decode, unknown-version rejection, pruning behaviour of `Tab.validateInvariants()`. Add `TouchCodeCoreTests/AtomicFileStoreTests.swift` covering write-then-read, rename semantics (a `kill -9` simulated mid-write leaves the original intact — implemented as two separate writes and a check that the first file is still readable).

Add `invariants(...) -> Bool` and `validateInvariants()` throws helper to `Tab`: the leaf-ID set of `splitTree` equals the ID set of `panels[*].id`. Debug-only callers use this after every structural mutation; release builds skip it.

**Observable acceptance.** `make mac-generate && make mac-build` succeeds. Running the new test scheme from Xcode or via `xcodebuild test -scheme TouchCodeCoreTests` produces all tests green. A quick `grep -r 'import AppKit\|import SwiftUI\|import GhosttyKit' apps/mac/TouchCodeCore` returns no matches (enforced as a review check, not a lint rule for now).

**Expected commits.** One or two commits: `feat(core): domain types and SplitTree<PanelID>`, and `feat(core): AtomicFileStore + round-trip tests`.

### Milestone 2: CatalogStore + headless HierarchyManager

**Goal after this milestone.** `HierarchyManager` exists in `apps/mac/touch-code/Runtime/`, is fully unit-testable without ghostty, and can round-trip a `Catalog` through `~/.config/touch-code/catalog.json`. A fake runtime covers the Panel side so we can exercise every structural mutation without rendering pixels.

**Work.** Under `apps/mac/touch-code/Runtime/`, create `CatalogStore.swift`:

    @MainActor
    final class CatalogStore {
      init(fileURL: URL = Catalog.defaultURL())
      func load() throws -> Catalog                 // returns .default on ENOENT
      func scheduleSave(_ catalog: Catalog)          // 500ms debounce
      func saveNow(_ catalog: Catalog) throws        // sync flush (applicationWillTerminate, worktree switch)
    }

The debounce uses a single `Task` with `Task.sleep(nanoseconds: 500_000_000)` armed on every `scheduleSave`; a second call within the window cancels the pending task and starts a new one (carrying the latest `Catalog` value). Decode failure backs the broken file up to `catalog.json.broken-<ISO8601>` and returns `.default`, logging via `os.Logger(subsystem: "com.touch-code.persistence", category: "catalog")`.

Create `HierarchyManager.swift`:

    @MainActor @Observable
    final class HierarchyManager {
      private(set) var catalog: Catalog
      init(catalog: Catalog, store: CatalogStore, runtime: HierarchyRuntime)

      // Space / Project / Worktree / Tab / Panel structural mutations
      func createSpace(name: String) -> SpaceID
      func renameSpace(_ id: SpaceID, name: String) throws
      func removeSpace(_ id: SpaceID) throws
      // … one method per command in the design doc §API Design — Command surface
    }

`HierarchyRuntime` is a narrow protocol that `HierarchyManager` uses to tell the runtime side "open a surface for this Panel ID" and "close the surface for this Panel ID". In M2 we write one real implementation (`FakeHierarchyRuntime`, just records calls) and stub an empty `GhosttyBackedHierarchyRuntime` that `preconditionFailure`s — M4 fills it in.

    protocol HierarchyRuntime: AnyObject {
      func ensureSurface(for panel: Panel, in worktree: Worktree) throws
      func closeSurface(for panelID: PanelID)
    }

Add a new Tuist test target `TouchCodeRuntimeTests` (or add to an existing app-hosted test bundle — defer until M2 decides whether `Runtime` stays inside the app target). Provisionally: the Runtime subfolder cannot host a `.unitTests` target directly because it's part of the `touch-code` app target; add `apps/mac/touch-code/Tests/RuntimeTests/` as a new `.unitTests` target that imports `@testable import touch_code`. (If this proves awkward — Tuist's `.unitTests` host-app configuration is fiddly — fall back to a dedicated `TouchCodeRuntimeKit` static-framework target. Flag as a decision to make at implementation time and record in Decision Log.)

Tests cover: `createWorktree` appends to `Project.worktrees`, sets `selectedWorktreeID`, calls `HierarchyRuntime.ensureSurface` zero times (M2: lazy); removing a non-existent ID throws `HierarchyError.notFound`; `splitPanel` inserts a new Panel + calls `ensureSurface` for it + preserves `Tab.validateInvariants`; `closePanel` on the only Panel in a Tab removes the Panel and leaves the Tab with an empty split tree (do **not** auto-close the Tab — empty-Tab UI state is handled in M5); pruning on load discards Worktrees whose `path` no longer exists on disk.

**Observable acceptance.** `xcodebuild test -scheme TouchCodeRuntimeTests` is all green. Running the app (still the hello-world from bootstrap) and manually calling `HierarchyManager.createSpace(name: "test")` via a debug hook in `TouchCodeApp.init` produces `~/.config/touch-code/catalog.json` containing `"version": 1` and the new Space UUID. Deleting the file and relaunching produces a freshly defaulted catalog.

**Expected commits.** `feat(runtime): CatalogStore with atomic-rename + debounce`, `feat(runtime): HierarchyManager headless with fake runtime`.

### Milestone 3: Re-enable GhosttyKit and render a single hardcoded Panel

**Goal after this milestone.** The app launches with a single libghostty-rendered terminal running the user's default shell. Typing works; output shows. No hierarchy integration yet — the Panel is built from a hardcoded Panel value inside `TouchCodeApp.init`. This is the first commit where touch-code is "a terminal" and the first time GhosttyKit ships in a binary.

This milestone **resolves the deferred work from bootstrap DEC-8**. It is the highest-risk milestone in the plan because of the upstream Zig dependency CDN issue. Derisking happens first (Concrete Steps below lists the priming ritual).

**Work.**

1. **Unblock GhosttyKit build.** Attempt `./apps/mac/scripts/build-ghostty.sh` fresh. If it still fails on Zig dep fetch (supacode and bootstrap plan DEC-8 both hit this), prime `.zig-global-cache` one-time by running `./apps/mac/scripts/prime-zig-cache.sh` (the primer script already exists per repo untracked state visible in `git status`; if it doesn't, create it following the recipe supacode used — `curl` each tarball listed in `apps/mac/ThirdParty/ghostty/build.zig.zon` into `~/.cache/zig` under its hash). Re-run `build-ghostty.sh`; it should finish with `.build/ghostty/GhosttyKit.xcframework/` populated.
2. **Re-enable the Tuist target.** In `apps/mac/Project.swift`, uncomment the `.foreignBuild(name: "GhosttyKit", …)` block (currently commented per bootstrap DEC-8) and add `.target(name: "GhosttyKit")` to the `touch-code` app target's `dependencies:`. Do **not** add GhosttyKit to `TouchCodeCore`, `TouchCodeIPC`, or `tc` — only the app target.
3. **`GhosttyRuntime`.** Under `apps/mac/touch-code/Runtime/Ghostty/`, create `GhosttyRuntime.swift` modelled on supaterm's (simpler, not supacode's which has a lot of surface-aware extras we don't need yet). Responsibilities: initialise `ghostty_config_t` with minimum config (pick up `~/.config/ghostty/config` if present; otherwise defaults), call `ghostty_app_new`, store the opaque handle, expose `createSurface(options: SurfaceOptions) throws -> PanelSurface`, manage `SurfaceReference` bookkeeping and callback dispatch (wakeup, action, clipboard, close). Stop at callback wiring — full action handling (key bindings, clipboard UI, deeplinks) is M4's job.
4. **`PanelSurface`.** `apps/mac/touch-code/Runtime/Ghostty/PanelSurface.swift` wraps one `ghostty_surface_t`. Public surface:

       @MainActor @Observable
       final class PanelSurface {
         let panelID: PanelID
         private(set) var state: State   // .initialising / .ready / .crashed(reason)
         var view: NSView { get }        // the ghostty SurfaceView, wrapped or direct
         func sendInput(_ text: String)  // M4 uses this; stub in M3
         func setFocus(_ focused: Bool)
         func close()                    // calls ghostty_surface_free; idempotent
         deinit                          // asserts state != .ready if close() wasn't called
       }

   In M3 this is instantiated once, hardcoded; M4 adds crash state + retry.
5. **`PanelHostView`.** `apps/mac/touch-code/App/PanelHostView.swift`: a `NSViewRepresentable` that takes a `PanelSurface` and installs its `view` into the SwiftUI hierarchy. Single panel, no split rendering in M3.
6. **Wire into `MainView`.** Replace the "Hello, touch-code!" `Text` with `PanelHostView(panelSurface: appState.temporaryPanel)` where `appState.temporaryPanel` is a single `PanelSurface` created at app launch from a hardcoded `Panel(id: PanelID(), workingDirectory: NSHomeDirectory(), initialCommand: nil)`.

**Observable acceptance.** `make mac-build && make mac-run-app` launches a window showing a live shell. Typing `echo hello\n` prints `hello`. Quitting and relaunching starts a fresh shell (no persistence yet). The app binary links `GhosttyKit.framework` (verified via `otool -L touch-code.app/Contents/MacOS/touch-code | grep Ghostty`).

**Known risk.** If Zig CDN priming still fails, escalate per [bootstrap plan DEC-8](0001-bootstrap-monorepo.md#decision-log) options: bump ghostty submodule to a newer commit with fixed deps; or pin a local mirror of the deps tarballs. Record chosen path in Decision Log.

**Expected commits.** `chore(bootstrap): prime zig cache and re-enable GhosttyKit`, `feat(runtime): GhosttyRuntime + PanelSurface bring-up`, `feat(app): render hardcoded Panel in MainView`.

### Milestone 4: TerminalEngine façade + event stream + crash isolation

**Goal after this milestone.** A single `TerminalEngine` façade composes `GhosttyRuntime`, `HierarchyManager`, and `CatalogStore`, exposes an `AsyncStream<TerminalEvent>`, and drives real Panel surfaces from hierarchy mutations. A crashing Panel replaces its view with a placeholder and survives retry; three crashes in 30s close the Tab.

**Work.** Under `apps/mac/touch-code/Runtime/`, create `TerminalEvent.swift` with the event enum exactly as listed in the design doc (§API Design — Event stream). Create `TerminalEngine.swift`:

    @MainActor
    final class TerminalEngine {
      init(store: CatalogStore, runtime: GhosttyRuntime)
      var hierarchy: HierarchyManager { get }
      func events() -> AsyncStream<TerminalEvent>
      func ensureSurface(for panel: Panel, in worktree: Worktree) throws
      func closeSurface(for panelID: PanelID)
      func sendInput(panelID: PanelID, text: String, raw: Bool) throws
    }

Replace `GhosttyBackedHierarchyRuntime` (stubbed in M2) with a real implementation that delegates to `TerminalEngine.ensureSurface` / `closeSurface`. Register callbacks from `PanelSurface` back into the engine: on "surface ready", emit `.panelReady`; on "output callback fired with N bytes", coalesce via a per-panel `PendingOutputBuffer` (flush every 16ms or when > 16KB buffered, whichever comes first); on "surface close from child exit", emit `.panelExited`; on "surface close from fault", emit `.panelCrashed` and transition `PanelSurface.state` to `.crashed(reason)`.

Crash policy. `HierarchyManager` holds a `@ObservationIgnored` per-panel ring buffer of crash timestamps (supaterm pattern). On `.panelCrashed`, append the timestamp, prune entries older than 30s; if the ring holds ≥ 3, remove the enclosing Tab via `removeTab` and post a `.tabAutoClosed(reason:)` event (new event variant) that M5's UI will render as a toast. Otherwise, keep the Panel entry, keep the leaf in `SplitTree`, and leave the UI to render a placeholder. Retry path: `TerminalEngine.retryPanel(id)` disposes the crashed `PanelSurface`, calls `GhosttyRuntime.createSurface` with the same Panel options, and emits `.panelReady` when the new surface is live.

Lazy surface creation. `HierarchyManager.selectWorktree(id)` does not open surfaces for every Panel on the Worktree — only for Panels in the currently selected Tab. `TerminalEngine.ensureSurface` is idempotent: calling it for a Panel whose surface is already alive is a no-op. Tab switch calls `ensureSurface` for every leaf in the incoming Tab's split tree.

Output coalescing details. `PendingOutputBuffer` is a small class per Panel with a `bytes: Data` accumulator and a `Task?` timer. First `append(bytes:)` arms `Task.sleep(nanoseconds: 16_000_000)` and, on wake, yields one `.panelOutput(panelID, Data)` event via the engine's `AsyncStream.Continuation`. Further `append` calls before wake fold into the same batch. A `flush()` method exists for synchronous drain on Panel close.

Add `TouchCodeRuntimeTests/TerminalEngineTests.swift` covering: event emission for open/close/exit in order; output coalescing (fire 1KB twice within 5ms → observe one `.panelOutput` of 2KB); crash-then-retry produces `.panelCrashed` then `.panelReady`; three crashes within 30s produce `.tabAutoClosed`.

**Observable acceptance.** Run the hardcoded-panel demo from M3 and kill the shell process via `pkill -KILL -f /bin/zsh` — the placeholder appears; clicking a debug "Retry" button brings the shell back. Sleeping the Panel (no input) for 30s produces no console log entries under `com.touch-code.runtime` at `.info` (idle-quiet verified).

**Expected commits.** `feat(runtime): TerminalEvent stream + output coalescing`, `feat(runtime): crash isolation with retry and Tab auto-close`, `feat(runtime): TerminalEngine facade wiring HierarchyManager + GhosttyRuntime`.

### Milestone 5: TCA clients, sidebar / tab bar / split view, full persistence round-trip

**Goal after this milestone.** The hardcoded Panel is gone. The app shell restores the persisted hierarchy on launch, lazily opens surfaces for visible Panels, and renders the full sidebar → tab bar → split viewport chrome. Users can create Spaces/Projects (via a debug command palette is fine for now), add Tabs, split Panels, switch between everything, close panels, quit, and relaunch — state preserved.

**Work.** Add TCA as an external dep in `apps/mac/Tuist/Package.swift` (per bootstrap DEC-3: deferred to "when first used" — now). Wire it into the `touch-code` target's dependencies.

Create `apps/mac/touch-code/App/Clients/HierarchyClient.swift` and `TerminalClient.swift` following supacode's `TerminalClient` pattern: `DependencyKey`-conforming function structs whose `liveValue` is built from the shared `TerminalEngine` instance, `testValue` uses in-memory fakes, and `previewValue` returns no-op implementations.

Create TCA features:

- `apps/mac/touch-code/App/Features/Root/RootFeature.swift` — root reducer with child states for sidebar, tab bar, split viewport, toast, launch-flow. Subscribes to `terminalClient.events()` and translates events to `Action.terminal(_)`.
- `apps/mac/touch-code/App/Features/Hierarchy/HierarchySidebarFeature.swift` — reads `HierarchyManager` bindings; renders Space → Project → Worktree tree. Actions for `selectSpace`, `addProject`, `createWorktree`, etc. — each fans out to `HierarchyClient`.
- `apps/mac/touch-code/App/Features/TabBar/TabBarFeature.swift` — reads the selected Worktree's Tabs; renders tab buttons; actions for create/close/rename/select.
- `apps/mac/touch-code/App/Features/Split/SplitViewportFeature.swift` — state is the selected Tab's `SplitTree<PanelID>`; reducer handles `splitPanel`, `closePanel`, `focusPanel`, `resizeSplit` by dispatching to `HierarchyClient`.

Create the views: `HierarchySidebarView`, `TabBarView`, `SplitView` (SwiftUI that recursively walks `SplitTree.Node` and installs `PanelHostView` for each leaf, using `NSSplitView` via `NSViewRepresentable` for the actual draggable divider). Replace `MainView` with a three-pane layout: sidebar (250pt), viewport (flex), optional inspector placeholder.

Launch flow. In `TouchCodeApp.init`, build one shared `TerminalEngine`, load the catalog, and inject it into the TCA store's dependency values. On `onAppear` of the root view, dispatch `.restore` — which iterates the catalog's selected Space → Project → Worktree → Tab and calls `terminalClient.ensureSurface` for each leaf in the active Tab's split tree. This is the lazy-creation hot path.

Window ↔ Space. `NSApplicationDelegate.applicationShouldHandleReopen` and `WindowGroup` are configured so that opening a new window creates a new `Catalog.Window` entry and presents a Space picker. v1 ships with one window per Space; more than one window per Space is rejected with a dialog (simpler than juggling a second "active panel" per window).

Test scaffolding. `TouchCodeRuntimeTests/HierarchyClientIntegrationTests.swift` covers: boot with empty catalog → create Space/Project/Worktree/Tab/Panel via `HierarchyClient` → verify `catalog.json` on disk; boot with pre-seeded catalog pointing at a non-existent Worktree path → verify pruning removes it.

**Observable acceptance.** Fresh install: launch → empty sidebar → click "New Space" → name "test" → click "Add Project" → pick this repo's path → see Worktree auto-discovered (M6 will make this real; for M5, manually point at the same path as Project root) → click "New Tab" → see an empty Tab → click "New Panel" → shell appears and is focused. Split the Panel horizontally with a keyboard shortcut (Cmd-D initially — design doc §Open Items has the final bindings for later). Type in each panel independently. Quit. Relaunch. See the two-panel split exactly as it was, shells freshly started.

**Expected commits.** `feat(app): HierarchyClient and TerminalClient TCA bridges`, `feat(app): sidebar + tab bar + split view UI`, `feat(app): launch restore with lazy surface creation`.

### Milestone 6: Git worktree CLI + non-git Project fallback

**Goal after this milestone.** The "Create Worktree" flow invokes `git worktree add` under the hood. Removing a Worktree optionally runs `git worktree remove`. Projects pointing at non-git directories get a synthetic single Worktree and the Worktree-create UI is disabled for them.

**Work.** Under `apps/mac/touch-code/Git/`, create `GitWorktreeCLI.swift`. The module exposes a single actor:

    actor GitWorktreeCLI {
      init(gitExecutable: URL = URL(fileURLWithPath: "/usr/bin/git"))
      func listWorktrees(repoPath: String) async throws -> [GitWorktreeEntry]
      func createWorktree(repoPath: String, branch: String, path: String) async throws
      func removeWorktree(repoPath: String, path: String, force: Bool) async throws
      func listBranches(repoPath: String) async throws -> [String]
      func discoverGitRoot(candidatePath: String) async throws -> String?  // `git rev-parse --show-toplevel`
    }

Implementation uses `Process` with a fixed argv array (never a shell string) — paths and branch names flow as separate argv entries, no interpolation. On non-zero exit, throw `GitCLIError.exitCode(Int, stderr: String)` preserving stderr verbatim.

Wire into `HierarchyManager.createWorktree`. Compute the target directory: `Project.worktreesDirectory ?? "<Project.rootPath>-worktrees/<branch>"`. If the directory already exists, disambiguate with a short UUID suffix and persist the resolved path. Call `GitWorktreeCLI.createWorktree`. On success, append a `Worktree` entry and mark the hierarchy dirty. On failure, surface the error to the UI without mutating state.

Wire into `HierarchyManager.removeWorktree(id, keepDirectory:)`. If `keepDirectory` is false, call `GitWorktreeCLI.removeWorktree`. On success (or if keeping the directory), remove the Worktree entry.

Non-git Projects. In `addProject`, resolve `gitRoot` via `GitWorktreeCLI.discoverGitRoot(candidatePath:)`. If nil, store `Project.gitRoot = nil` and create exactly one synthetic Worktree whose `path == Project.rootPath`, `branch == nil`. Surface a `Project.supportsWorktrees: Bool` predicate (as design doc Risks §R5 calls out) and gate the "Add Worktree" UI on it.

Tests. `apps/mac/touch-code/Tests/GitTests/GitWorktreeCLITests.swift` creates a temp repo fixture in `NSTemporaryDirectory`, exercises list / create / remove / list-branches / discover-root, and asserts expected state. Non-git Project test: point at `NSTemporaryDirectory` itself → `discoverGitRoot` returns nil.

**Observable acceptance.** Start from M5's state. Add the touch-code repo as a Project (`/Users/wanggang/dev/00/touch-code`). Click "Add Worktree" → enter branch name `exp/test` → directory `/Users/wanggang/dev/00/touch-code-worktrees/exp/test` appears on disk; `git -C … worktree list` lists it. Open a Panel in the new Worktree — its shell's `pwd` is the worktree directory. Remove the Worktree → directory disappears, `git worktree list` no longer shows it. Add a non-git directory (e.g. `/tmp`) as a Project → see a single synthetic Worktree named `/tmp`, no "Add Worktree" button.

**Expected commits.** `feat(git): GitWorktreeCLI with list/create/remove/discover`, `feat(runtime): integrate GitWorktreeCLI into HierarchyManager`, `feat(app): non-git Project support with synthetic Worktree`.

## Concrete Steps

Run every command from the repository root (`/Users/wanggang/dev/00/touch-code`) unless otherwise noted. Steps are grouped by milestone. Keep the Progress section updated as each step completes.

### M1 steps

    # 1. Generate workspace
    make mac-generate

    # 2. After writing sources + test target in Project.swift, regenerate
    make mac-generate

    # 3. Build and test
    DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
      xcodebuild test -workspace apps/mac/touch-code.xcworkspace \
                      -scheme TouchCodeCoreTests | xcbeautify
    # Expected tail: "Test Suite 'All tests' passed at ...\n    Executed N tests, with 0 failures"

    # 4. Lint
    make mac-lint
    # Expected: clean (no output)

### M2 steps

    make mac-generate
    DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
      xcodebuild test -workspace apps/mac/touch-code.xcworkspace \
                      -scheme TouchCodeRuntimeTests | xcbeautify
    # Manual persistence smoke (debug hook in TouchCodeApp.init):
    make mac-run-app
    ls -la ~/.config/touch-code/
    # Expected: catalog.json with "version": 1

### M3 steps

    # Attempt a clean ghostty build first
    cd apps/mac
    ./scripts/build-ghostty.sh
    # If it fails on Zig deps, prime the cache:
    ./scripts/prime-zig-cache.sh
    ./scripts/build-ghostty.sh
    # Expected: .build/ghostty/GhosttyKit.xcframework/macos-arm64/GhosttyKit.framework/ exists

    cd ../..
    make mac-generate
    make mac-build
    make mac-run-app
    # Expected: window opens, shell prompt visible, typing works

    # Verify linkage
    otool -L \
      ~/Library/Developer/Xcode/DerivedData/touch-code-*/Build/Products/Debug/touch-code.app/Contents/MacOS/touch-code \
      | grep Ghostty
    # Expected: @rpath/GhosttyKit.framework/... present

### M4 steps

    make mac-generate
    DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
      xcodebuild test -workspace apps/mac/touch-code.xcworkspace \
                      -scheme TouchCodeRuntimeTests | xcbeautify

    # Crash-isolation smoke (requires the debug "Retry" button from M4 UI):
    make mac-run-app
    # In another terminal:
    pkill -KILL -f "touch-code.*zsh"
    # Expected: placeholder in the panel; click Retry -> shell back

### M5 steps

    make mac-generate
    DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
      xcodebuild test -workspace apps/mac/touch-code.xcworkspace \
                      -scheme TouchCodeRuntimeTests | xcbeautify
    make mac-run-app
    # Exercise: New Space -> Add Project (repo root) -> New Tab -> New Panel -> split -> quit -> relaunch
    # Expected: sidebar, tab bar, and split all restored

### M6 steps

    make mac-generate
    DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
      xcodebuild test -workspace apps/mac/touch-code.xcworkspace \
                      -scheme TouchCodeRuntimeTests | xcbeautify

    # End-to-end worktree smoke:
    make mac-run-app
    # In the app: Add Worktree on branch exp/test
    # In a shell:
    git -C /Users/wanggang/dev/00/touch-code worktree list
    # Expected: exp/test worktree listed at <repo>-worktrees/exp/test

## Validation and Acceptance

After all six milestones land, a fresh contributor can perform the following and observe the exact outputs:

1. `make mac-bootstrap && make mac-generate && make mac-build && make mac-run-app`. The app window opens within 1 second of the `mac-run-app` invocation.
2. Create a Space named `work`. Add a Project pointing at `/Users/wanggang/dev/00/touch-code`. The app auto-detects the git root and creates a default Worktree on the current branch.
3. Click "Add Worktree", name it `exp/plan-0002`. Within 2 seconds, `/Users/wanggang/dev/00/touch-code-worktrees/exp/plan-0002/` exists and `git -C /Users/wanggang/dev/00/touch-code worktree list` lists it.
4. In the new Worktree's first Tab, open a Panel. The shell's `pwd` is `/Users/wanggang/dev/00/touch-code-worktrees/exp/plan-0002`.
5. Split the Panel horizontally. Both panels are alive and independently focused. Panel-to-panel switching completes in one frame (no visible flicker; confirmed via Instruments time profiler if needed).
6. Kill one Panel's shell externally (`pkill -KILL -f zsh` matching the specific PID). The placeholder appears in that Panel within 1 second; the other Panel is unaffected. Click "Retry" — a fresh shell appears in the same cell.
7. Cmd-Q the app. Relaunch. Every Space/Project/Worktree/Tab/Panel is present; shells are freshly started; split geometry matches exactly.
8. All test schemes pass: `xcodebuild test -scheme TouchCodeCoreTests`, `-scheme TouchCodeRuntimeTests`, `-scheme GitTests`.
9. `make mac-lint` is clean.

Failure on any of the above blocks sign-off; the plan is not complete until all nine are green.

## Idempotence and Recovery

Every milestone is designed to be re-runnable. The common recovery rituals:

- **Regenerate Xcode workspace.** `make mac-generate` is safe to run repeatedly; it is a pure function of `Project.swift` and Tuist config.
- **Clean build.** `make mac-clean-build` (or `rm -rf apps/mac/Derived && make mac-generate && make mac-build`) resets Derived Data without touching sources. Never `rm` `.build/ghostty/` unless you want a Ghostty rebuild — that is expensive.
- **Reset catalog.** `mv ~/.config/touch-code/catalog.json ~/.config/touch-code/catalog.json.bak` forces a fresh hierarchy on next launch. M1's load path backs broken files automatically, so this is rarely needed manually.
- **Re-prime Zig cache.** If `scripts/build-ghostty.sh` starts failing again (the bootstrap plan's DEC-8 condition), re-run `scripts/prime-zig-cache.sh`. The primer is idempotent — re-running after a successful build is a no-op.
- **Unwind a failed Worktree create.** M6's create path is transactional at the file-system level: if `git worktree add` fails, the hierarchy is not mutated. If it succeeds but the Worktree entry fails to persist (should be impossible given debounce + flush semantics, but for paranoia), the user can recover by manually running `git worktree remove <path>` and relaunching; M5's pruning will drop the dangling entry.
- **Reset Ghostty XCFramework.** `rm -rf apps/mac/.build/ghostty && make mac-build-ghostty`. One-shot rebuild.

None of the steps modify repository-wide state (no system `xcode-select`, no global Git config, no PATH mutation). Every command respects the `DEVELOPER_DIR` convention established in the bootstrap plan (DEC-10).

## Artifacts and Notes

Prototyping findings that inform this plan:

- **SplitTree port is shape-preserving.** Reading supaterm's `SplitTree<ViewType: NSView & Identifiable>` end-to-end confirmed the only type-parameter uses are in `Node.leaf(view:)`, `contains(_ view:)`, `find(id:)`, `inserting(view:at:direction:)`, and the `Spatial` compute (which needs view bounds). For our `SplitTree<PanelID>`, the first four map 1:1 with `view: PanelID` or `id: PanelID.ID` substitutions; the `Spatial` compute moves to the UI layer where the concrete `NSView` bounds are known. No algorithmic rework is needed.
- **Ghostty surface view is reusable.** Upstream `ghostty/macos/Sources/Ghostty/Surface View/SurfaceView_AppKit.swift` is a complete `NSView` subclass that handles key events, focus, drag-and-drop, and rendering. Embedding it via `NSViewRepresentable` is the path both reference projects take. We do not re-wrap it.
- **Persistence debounce pattern from supaterm.** supaterm's `TerminalSessionCatalog` uses a similar debounce-and-atomic-rename; direct translation to our `CatalogStore` is straightforward. The wall-clock behaviour is consistent with design doc §Persistence.
- **Crash isolation pattern is simpler than expected.** Ghostty's `close_surface_cb` already distinguishes clean exit (`processAlive == false` with zero) from faults; no additional signal handling is needed on our side.

## Interfaces and Dependencies

The following types, functions, and signatures must exist by plan completion. Names are binding — later plans will reference them.

**`TouchCodeCore`** (static framework; zero AppKit/SwiftUI/GhosttyKit imports):

    public struct SpaceID: Codable, Hashable, Sendable { public init(); public let raw: UUID }
    public struct ProjectID: Codable, Hashable, Sendable { … }
    public struct WorktreeID: Codable, Hashable, Sendable { … }
    public struct TabID: Codable, Hashable, Sendable { … }
    public struct PanelID: Codable, Hashable, Sendable { … }

    public struct Catalog: Codable, Equatable, Sendable {
      public static let currentVersion = 1
      public var version: Int
      public var windows: [CatalogWindow]
      public var spaces: [Space]
      public var selectedSpaceID: SpaceID?
      public static func defaultURL(home: String = NSHomeDirectory()) -> URL
    }

    public struct Space: Codable, Equatable, Sendable {
      public var id: SpaceID
      public var name: String
      public var projects: [Project]
      public var selectedProjectID: ProjectID?
    }

    public struct Project: Codable, Equatable, Sendable {
      public var id: ProjectID
      public var name: String
      public var rootPath: String
      public var gitRoot: String?
      public var worktreesDirectory: String?
      public var defaultEditor: String?
      public var worktrees: [Worktree]
      public var selectedWorktreeID: WorktreeID?
      public var supportsWorktrees: Bool { gitRoot != nil }
    }

    public struct Worktree: Codable, Equatable, Sendable { … }
    public struct Tab: Codable, Equatable, Sendable {
      public var id: TabID
      public var name: String?
      public var splitTree: SplitTree<PanelID>
      public var panels: [Panel]
      public func validateInvariants() throws  // debug-only callers
    }
    public struct Panel: Codable, Equatable, Sendable { … }

    public struct SplitTree<Leaf: Codable & Hashable & Sendable>: Codable, Equatable, Sendable {
      public indirect enum Node: Codable, Equatable, Sendable { case leaf(Leaf); case split(Split) }
      public struct Split: Codable, Equatable, Sendable { … }
      public enum Direction: Codable, Equatable, Sendable { case horizontal, vertical }
      // Operations mirror supaterm's API, adapted to Leaf-generic.
      public func inserting(_ leaf: Leaf, at anchor: Leaf, direction: NewDirection) throws -> Self
      public func removing(_ leaf: Leaf) -> Self
      public func replacing(_ old: Leaf, with new: Leaf) throws -> Self
      public func path(to leaf: Leaf) -> Path?
      public func leaves() -> [Leaf]
      // …
    }

    public enum AtomicFileStore {
      public static func read<T: Decodable>(_ type: T.Type, at url: URL, decoder: JSONDecoder = .default) throws -> T?
      public static func write<T: Encodable>(_ value: T, to url: URL, encoder: JSONEncoder = .default) throws
    }

**`apps/mac/touch-code/Runtime/`** (in-app module; depends on `TouchCodeCore` + `GhosttyKit`):

    @MainActor final class CatalogStore {
      init(fileURL: URL = Catalog.defaultURL())
      func load() throws -> Catalog
      func scheduleSave(_ catalog: Catalog)
      func saveNow(_ catalog: Catalog) throws
    }

    protocol HierarchyRuntime: AnyObject {
      func ensureSurface(for panel: Panel, in worktree: Worktree) throws
      func closeSurface(for panelID: PanelID)
    }

    @MainActor @Observable final class HierarchyManager {
      init(catalog: Catalog, store: CatalogStore, runtime: HierarchyRuntime)
      private(set) var catalog: Catalog
      // mutations: createSpace / addProject / createWorktree / removeWorktree /
      // createTab / closeTab / openPanel / splitPanel / closePanel / focusPanel /
      // swapPanels / resizeSplit / zoomPanel / unzoom — exact names in impl
    }

    @MainActor final class GhosttyRuntime {
      init() throws
      func createSurface(options: SurfaceOptions) throws -> PanelSurface
      // callbacks routed to PanelSurface internally
    }

    @MainActor @Observable final class PanelSurface {
      let panelID: PanelID
      enum State: Equatable { case initialising, ready, crashed(reason: String), exited(code: Int32) }
      private(set) var state: State
      var view: NSView { get }
      func sendInput(_ text: String, raw: Bool)
      func setFocus(_ focused: Bool)
      func close()
    }

    enum TerminalEvent: Sendable {
      case panelCreated(PanelID, TabID)
      case panelReady(PanelID)
      case panelOutput(PanelID, Data)       // coalesced, ≤ 16KB batches, ≤ 60Hz
      case panelIdle(PanelID, duration: TimeInterval)
      case panelExited(PanelID, code: Int32)
      case panelCrashed(PanelID, reason: String)
      case tabActivated(TabID)
      case tabAutoClosed(TabID, reason: String)
      case worktreeActivated(WorktreeID)
      case hierarchyMutated
    }

    @MainActor final class TerminalEngine {
      init(store: CatalogStore, runtime: GhosttyRuntime) throws
      var hierarchy: HierarchyManager { get }
      func events() -> AsyncStream<TerminalEvent>
      func sendInput(panelID: PanelID, text: String, raw: Bool) throws
      func retryPanel(id: PanelID) throws
    }

**`apps/mac/touch-code/App/Clients/`** (TCA bridge):

    struct HierarchyClient: Sendable {
      var send: @MainActor @Sendable (Command) -> Void
      var snapshot: @MainActor @Sendable () -> Catalog
      var events: @MainActor @Sendable () -> AsyncStream<TerminalEvent>
      enum Command: Equatable { case createSpace(name: String); /* … */ }
    }
    extension HierarchyClient: DependencyKey { static let liveValue: HierarchyClient; static let testValue: HierarchyClient }

    struct TerminalClient: Sendable {
      var sendInput: @MainActor @Sendable (PanelID, String, Bool) -> Void
      var retryPanel: @MainActor @Sendable (PanelID) -> Void
      var setFocus: @MainActor @Sendable (PanelID, Bool) -> Void
    }
    extension TerminalClient: DependencyKey { … }

**`apps/mac/touch-code/Git/`**:

    actor GitWorktreeCLI {
      init(gitExecutable: URL = URL(fileURLWithPath: "/usr/bin/git"))
      struct GitWorktreeEntry: Equatable, Sendable { let path: String; let branch: String?; let head: String }
      func listWorktrees(repoPath: String) async throws -> [GitWorktreeEntry]
      func createWorktree(repoPath: String, branch: String, path: String) async throws
      func removeWorktree(repoPath: String, path: String, force: Bool) async throws
      func listBranches(repoPath: String) async throws -> [String]
      func discoverGitRoot(candidatePath: String) async throws -> String?
    }

    enum GitCLIError: Error, Equatable { case exitCode(Int32, stderr: String); case executableNotFound; case invalidUTF8 }

**External dependencies added by this plan** (in `apps/mac/Tuist/Package.swift`):

- `swift-composable-architecture` from `https://github.com/pointfreeco/swift-composable-architecture`, version pinned to `1.20.0` or newer (whichever supacode currently uses; read from `/Users/wanggang/dev/opensource/supacode/Tuist/Package.swift` at implementation time).
- No other new external deps. No Sparkle yet (deferred to shipping plan).

**Tuist targets added by this plan**:

- `TouchCodeCoreTests` (`.unitTests`, host `TouchCodeCore`)
- `TouchCodeRuntimeTests` (`.unitTests`, host `touch-code` app — see M2 note about possibly falling back to a dedicated static-framework kit)
- `GitTests` (`.unitTests`, same host as Runtime tests)

`GhosttyKit` `.foreignBuild` target is re-enabled and added as a dependency of the `touch-code` app target (and *only* the app target — never `TouchCodeCore`, `TouchCodeIPC`, or `tc`).
