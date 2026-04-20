# ExecPlan: Read-Only Git Viewer (C7) + External Editor Integration (C8)

**Status:** Draft
**Author:** Gump (with Claude)
**Date:** 2026-04-20

This is a living document. The Progress, Surprises & Discoveries, Decision Log, and Outcomes & Retrospective sections must be kept up to date as work proceeds.

## Purpose

After this plan lands, a contributor who `make mac-build && make mac-run-app` can inspect their Git state and hand off to their editor without leaving touch-code:

- Selecting any Git-backed Worktree in the sidebar surfaces a **read-only** viewer showing working-tree diff, staged diff, the last 100 commits, and the diff of any commit the user clicks. Keyboard navigation (`j`/`k`/`Tab`/`Enter`) works throughout. A 1 000-line diff renders in under 200 ms from the moment `git` returns; a 50 000-line diff is replaced by a placeholder with a one-click "Copy command" that produces `cd '<abs-path>' && git …` on the clipboard.
- A dropdown on the Worktree header ("Open in ▾") and a `tc open [--in <editor>] [<worktree>]` CLI both open the current Worktree **directory** in the user's default editor (VSCode / Cursor / Zed / Xcode / Sublime / Finder, or any user-defined template). The default is resolvable globally and per-Project; Settings exposes the registry with an installed/missing marker for each editor. Errors (editor CLI not on `PATH`, non-zero exit, 5-second timeout, unresolved Worktree in `tc open`) surface as toasts or CLI stderr — no silent fallthrough.
- Both features are wired to C2's `HierarchyManager` as pure consumers — they read `Worktree.path` and `Project.defaultEditor`, and they mutate nothing about the hierarchy. A crash, timeout, or malformed `git` output in one never affects the other.

This is the first plan that gives touch-code real workflow value beyond "a terminal orchestrator": a user can inspect changes and hop to their editor in-app, which closes the loop with a CLI coding-agent session.

## Progress

- [ ] M1 — Pure data models in `TouchCodeCore` + `TouchCodeIPC` (Git + Editor value types; Codable round-trip tests; template/ID validators)
- [ ] M2 — `touch-code/Git/` service layer (`GitService` protocol, `LiveGitService` with `Process`, `DiffParser`, `GitOutputParser`, env stripping, output caps, timeout, error surface)
- [ ] M3 — `GitViewerFeature` TCA reducer + `GitServiceClient` DependencyKey + `TestStore`-driven reducer tests (no UI yet)
- [ ] M4 — SwiftUI viewer (`GitViewerView`, `CommitLogView`, `FileChangeListView`, `UnifiedDiffView`, keyboard bindings, 50k-line cap, POSIX-quoted Copy-command) and viewer-region wiring
- [ ] M5 — `touch-code/App/Clients/Editor/` service layer (`EditorService`, `EditorRegistry`, `PathProber`, `ProcessSpawner`, env whitelist, 5 s spawn contract)
- [ ] M6 — `EditorFeature` TCA + Settings editor section + per-Project override + Worktree header `Open in ▾` button + `SettingsStore` wiring
- [ ] M7 — `editor.*` IPC namespace in `TouchCodeIPC`, `SocketServer` dispatch, `tc open [--in <editor>] [<worktree>]` with Worktree-resolution order (explicit → `TOUCH_CODE_PANEL_ID` → error exit 2)
- [ ] M8 — Cross-feature integration tests, performance smoke (1 000-line diff < 200 ms signpost), acceptance walkthrough, and doc clean-up (update `architecture.md` codemap, close Open Question #7)

## Surprises & Discoveries

(None yet)

## Decision Log

(None yet)

## Outcomes & Retrospective

(To be filled at milestone completion)

## Context and Orientation

Related documents (all in this repo):

- **Product spec** — [docs/product-spec.md](../product-spec.md), capabilities C7 and C8; Open Question #7 (editor discovery) is resolved by C8.
- **Design docs — authoritative for every decision; this plan implements, it does not relitigate:**
  - [docs/design-docs/c7-git-viewer.md](../design-docs/c7-git-viewer.md)
  - [docs/design-docs/c8-editor-integration.md](../design-docs/c8-editor-integration.md)
- **Architecture** — [docs/architecture.md](../architecture.md). Relevant invariants: hybrid TCA + `@Observable` with TCA for feature flows; atomic-rename JSON with top-level `version`; `tc` is stateless and talks to the app over `TouchCodeIPC`; all identifiers are UUIDs.
- **Upstream plan — prerequisite for M3–M8:** [docs/exec-plans/0002-terminal-and-hierarchy.md](0002-terminal-and-hierarchy.md). M2 of that plan has landed (`CatalogStore`, `HierarchyManager`); M3–M6 are pending and bring up `GhosttyKit`, `TerminalEngine`, TCA wiring, the sidebar, and Git worktree operations. M3 of *this* plan (the first TCA-touching milestone) must not start before 0002's M5 has added TCA to `Tuist/Package.swift`.

Reference projects (read-only; borrow first, deviate with a stated reason):

- **supacode** — `/Users/wanggang/dev/opensource/supacode`
  - `supacode/Clients/Git/GitClient.swift` — shell-out `git` pattern (only aggregate line counts today; we generalise the shape)
  - `supacode/Clients/Workspace/WorkspaceClient.swift` — Launch-Services editor open (rejected as primary mechanism in C8 A1; we use `Process` wrappers)
  - `supacode/SupacodeSettingsShared/Domain/OpenWorktreeAction.swift` — shape of the allowlist enum (we take the *shape*, not the LS mechanism)
  - `supacode/Clients/Terminal/TerminalClient.swift` — the `DependencyKey` pattern we reuse for `GitServiceClient` and `EditorClient`
- **supaterm** — `/Users/wanggang/dev/opensource/supaterm` (no editor or git viewer code; confirmed during design)

Repository state at plan start:

- `apps/mac/Project.swift` already defines `TouchCodeCore`, `TouchCodeCoreTests`, `TouchCodeIPC`, `GhosttyKit` (foreignBuild, currently enabled via `0002 DEC-8` follow-up), `tc`, `touch-code`, `touch-codeTests`.
- `apps/mac/touch-code/Git/` contains exactly one file: `Git.swift` with `public enum Git {}`. Every Git-module source in M2 lands here.
- `apps/mac/touch-code/App/Clients/` does not yet exist. It is created by this plan (first by `0002 M5` for `HierarchyClient` / `TerminalClient`; this plan adds `GitServiceClient.swift` and `Editor/` alongside).
- `apps/mac/TouchCodeIPC/IPC.swift` contains `public enum IPC {}` only. M7 is the first substantive content.
- `apps/mac/tc/main.swift` is the ArgumentParser root with only a `--version` print. M7 adds the first subcommand.

**Terminology used in this plan** (defined once; used as-is below):

- **C7 viewer** / **viewer** — the read-only Git diff + log surface specified in `c7-git-viewer.md`.
- **C8 editor service** / **editor service** — `EditorService` and its allowlist; specified in `c8-editor-integration.md`.
- **Scope** — the viewer's mode enum: `.working` (working-tree diff), `.staged` (staged diff), `.log` (paginated commit list), `.commit(sha:)` (diff of a specific commit). Defined as `DiffScope` in Swift since a `Scope` identifier is too generic.
- **Worktree-scoped state** — feature state that invalidates when the selected `WorktreeID` changes. The viewer is worktree-scoped; the editor service is not (it is a pure function of its inputs).
- **Fire-and-forget** — *not used.* The C8 design explicitly removed the fire-and-forget heuristic during review (see `c8-editor-integration.md` §Spawn contract, Resolved Item #6). The spawn contract is: wait up to 5 s for the child; exit 0 → success; non-zero exit → `.nonZeroExit`; still running at 5 s → `.timedOut` (SIGTERM then SIGKILL).
- **`{dir}` substitution** — the literal four-character token `{dir}` inside a `CommandTemplate.args` array, replaced at spawn time with the absolute Worktree path. Substitution is at the argv-slot level; there is no shell, no quoting, no expansion.
- **POSIX-quoted path** — `'…'` single-quoted with internal `'` rewritten as `'\''`. Applied only to the path inside a `cd`-prefixed Copy-command string on the clipboard; never to argv.

**Orientation paragraph.** The plan slices vertically where each slice is user-visible, and horizontally where a shared data layer needs a separate acceptance bar. M1 is a horizontal foundation (pure types, no UI) that both features draw from, because both want the same Codable/Equatable/Sendable guarantees and the same test story. M2 and M5 are the two "service layer" slices — one per feature, each ending with a service that can be driven from tests without any UI. M3/M4 then build C7's TCA feature then its SwiftUI view, ending at the moment the user sees a working viewer inside the app shell. M6 mirrors that for C8 with the Worktree-header button and Settings editor section. M7 extends to the CLI and IPC surface so `tc open` works from inside any Panel. M8 is the acceptance milestone: cross-feature integration tests, a performance smoke, and a dogfooding checklist. Each milestone produces at least one commit matching the repo's post-feature-commit cadence (per [Memory](../../.claude/projects/-Users-wanggang-dev-00-touch-code/memory/feedback_commit_cadence.md)).

## Plan of Work

### Milestone 1: Pure data models in TouchCodeCore + TouchCodeIPC

**Goal after this milestone.** Every Codable value type shared by C7, C8, and the IPC wire lives in the two leaf frameworks. `TouchCodeCore` holds the Git domain types and the editor-storage types (because `settings.json` persists them). `TouchCodeIPC` holds the two editor DTOs (`EditorDescriptor`, `EditorChoice`) the CLI deserialises from the socket. No file touches the app target. Zero imports of AppKit / SwiftUI / GhosttyKit / `Foundation.Process`.

This milestone is deliberately schema-heavy and logic-light. Its job is to pin every `Codable` shape before any runtime code depends on it, and to prove that validators (template, editor ID, SHA) are correct before a UI can mis-route bad input.

**Work.**

Under `apps/mac/TouchCodeCore/Git/` (new subfolder; the existing folder layout is flat, but per [architecture.md](../architecture.md) a Git subfolder is idiomatic), create:

- `GitModels.swift` — `Commit`, `DiffScope`, `UnifiedDiff`, `FileChange` (and nested `FileChange.Kind`), `DiffHunk`, `DiffLine` (and nested `DiffLine.Kind`), `LogPage` (and nested `LogPage.Cursor`), `WorkingTreeStatus` (and nested `WorkingTreeStatus.Entry`). All `public`, all `Equatable`, `Hashable` where it composes, `Sendable`, and `Codable`. `Commit.shortID` is a **computed property** (`String(id.prefix(7))`), per the design's review-round fix — never stored, always derived.
- `GitShaValidator.swift` — `public enum GitShaValidator { public static func isValid(_ s: String) -> Bool }` returning true iff `s` matches `^[0-9a-fA-F]{7,64}$`. Pure function. Callers: the service layer (M2) before issuing `git show <sha>` and the reducer (M3) before emitting `.commitSelected`.

Under `apps/mac/TouchCodeCore/Editor/` (new subfolder), create:

- `EditorStorageModels.swift` — `public typealias EditorID = String`, `public struct CommandTemplate: Equatable, Sendable, Codable { let binary: String; let args: [String] }`, `public struct CustomEditor: Equatable, Sendable, Codable, Identifiable { var id: EditorID; var displayName: String; var template: CommandTemplate }`.
- `EditorValidators.swift` — two validators: `CustomEditor.validatedID(_:) throws -> EditorID` (matches `^[a-z][a-z0-9_-]{1,31}$` per design Resolved Item #9), and `CommandTemplate.validate() throws` (non-empty `binary`; `args` contains **exactly one** literal `"{dir}"` element). Both throw a new `public enum EditorTemplateError: Error, Equatable { case emptyBinary; case missingDirPlaceholder; case duplicateDirPlaceholder; case invalidID(String) }`.

Under `apps/mac/TouchCodeIPC/Editor/` (new subfolder), create:

- `EditorIPCTypes.swift` — `public struct EditorDescriptorDTO`, `public struct EditorChoiceDTO`, `public struct EditorInstallationStatusDTO` (enum with `.installed(resolvedBinary: URL)` and `.missingBinary(expected: String)`). These are the wire types returned from `editor.describe` and `editor.open`. Codable, Equatable, Sendable. No methods beyond initialisers.
- `EditorIPCMethods.swift` — `public enum EditorIPCMethod { public static let describe = "editor.describe"; public static let open = "editor.open"; public static let setDefault = "editor.setDefault" }`. String constants; the full JSON-RPC envelope lives in later plans (CLI design doc will pin that; we declare only the method names so `tc` and the app agree).

No Git IPC types in M1 (the design's Seam §`git.*` IPC namespace says the IPC surface is deferred to a later plan; we do not populate it).

Tests under `apps/mac/TouchCodeCoreTests/`:

- `GitModelsCodableTests.swift` — round-trip every struct with both minimal and fully populated fixtures. One fixture per `FileChange.Kind` case, one per `DiffLine.Kind` case, `LogPage` with a merge commit (two parents) and a root commit (zero parents). Assert `Commit.shortID == id.prefix(7)` for SHA-1 (40 chars) and SHA-256 (64 chars) inputs.
- `GitShaValidatorTests.swift` — accept: 7-char lowercase, 7-char uppercase, 40-char SHA-1, 64-char SHA-256. Reject: 6-char, 65-char, non-hex (`g`), empty, whitespace-padded.
- `EditorValidatorsTests.swift` — accept `CommandTemplate(binary: "code", args: ["{dir}"])`, `(binary: "open", args: ["-a", "Xcode", "{dir}"])`. Reject: empty binary, zero `{dir}` tokens, two `{dir}` tokens. Accept IDs `"vscode"`, `"my-editor"`, `"a_b_c"`; reject `"1abc"` (leading digit), `"Vscode"` (uppercase), `""`, `"a"` (too short — below 2-char minimum), `"a\(String(repeating: \"a\", count: 32))"` (33 chars).

No tests for `TouchCodeIPC` DTOs in M1 beyond a single Codable round-trip covering both variants of `EditorInstallationStatusDTO`. (Deeper IPC tests arrive with M7.)

**Observable acceptance.** From the repo root, `make mac-generate && DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild test -workspace apps/mac/touch-code.xcworkspace -scheme TouchCodeCoreTests | xcbeautify` ends with `Test Suite 'All tests' passed` and the test count increases by the number of new cases above. `make mac-lint` is clean. A grep that would catch a regression: `grep -r 'import AppKit\|import SwiftUI\|import GhosttyKit\|import Foundation.Process' apps/mac/TouchCodeCore apps/mac/TouchCodeIPC` returns zero matches.

**Expected commit.** `feat(core): Git and editor data models + validators`.

### Milestone 2: Git service layer in touch-code/Git/

**Goal after this milestone.** A protocol-backed `GitService` exists in `touch-code/Git/`; a live implementation shells out to `git` with the design's exact argv, applies output caps and timeouts, strips `GIT_*` env, and returns the M1 value types. A pure `DiffParser` turns `git diff` bytes into a `UnifiedDiff`. A pure `GitOutputParser` turns null-delimited `git log` and `git status --porcelain=v1 -z` bytes into their M1 shapes. All of this runs under unit tests with no app-target dependency.

This milestone is a horizontal slice inside C7 only. It ends with a service we can drive from the reducer in M3 without touching any UI.

**Work.**

Under `apps/mac/touch-code/Git/`, create the files named in [c7-git-viewer.md §Component Boundaries](../design-docs/c7-git-viewer.md#component-boundaries):

- `GitService.swift` — the `public protocol GitService: Sendable` from the design (§API Design). Five async-throws methods: `log`, `workingTreeDiff`, `stagedDiff`, `commitDiff`, `status`.
- `GitCommand.swift` — `enum GitCommand { static func log(limit: Int, skip: Int) -> [String]; static func diff(kind: DiffKind, sha: String?, ignoreWhitespace: Bool) -> [String]; static func status() -> [String] }`. Produces argv arrays (without the leading executable) using the exact strings from the design doc §API Design table. `DiffKind` is a local enum (`.workingTree`, `.staged`, `.commit(sha:)`) hidden inside this file.
- `LiveGitService.swift` — the `Process`-backed implementation. Constructor takes a `gitExecutableURL: URL` (default `/usr/bin/env git` resolved to `/usr/bin/env` with `arguments: ["git", …]`). Each method: validate inputs (SHA via `GitShaValidator`); build argv via `GitCommand`; spawn `Process` with `currentDirectoryURL` set to the Worktree path; install pipes on stdout/stderr with the **16 MiB** cap (tracked in a `DataAccumulator` helper that rejects past-cap chunks with `GitError.outputTooLarge`); arm a **10 s** wall-clock timer via `Task.sleep` racing the process exit; on exit, if code != 0 → `.exec(code, stderr)`; on timeout → `process.terminate()` then `.timedOut`; on success, hand bytes to the parser layer.
- `GitProcessEnv.swift` — `enum GitProcessEnv { static let whitelist: [String] = ["PATH", "HOME"]; static let forced: [String: String] = ["LC_ALL": "C.UTF-8"]; static let forbidden: Set<String> = ["GIT_DIR", "GIT_WORK_TREE", "GIT_EDITOR", "GIT_PAGER", "GIT_EXTERNAL_DIFF", "GIT_EXEC_PATH", "GIT_CONFIG", "GIT_CONFIG_SYSTEM", "GIT_CONFIG_GLOBAL", "GIT_SSH", "GIT_ASKPASS"]; static func build(from parent: [String: String]) -> [String: String] }`. The builder takes the current process env, filters to the whitelist, overlays `forced`, and asserts none of `forbidden` appear in the output. Used exclusively by `LiveGitService`.
- `DiffParser.swift` — `enum DiffParser { static func parse(_ bytes: Data, scope: DiffScope) throws -> UnifiedDiff }`. Pure. Consumes unified-diff output line-by-line (splitting on `\n`, respecting no-newline-at-eof with `\ No newline at end of file`), emits one `FileChange` per `diff --git a/… b/…` block, populates `Kind` from the `new file mode` / `deleted file mode` / `rename from/to` / `copy from/to` lines, and fills hunks from `@@` headers. Enforces the 50 000-line cutoff from the design: on the 50 001st parsed line, throw `GitError.diffTooLarge`.
- `GitOutputParser.swift` — two static methods: `parseLog(_ bytes: Data) throws -> [Commit]` (splits by `\x00`, reads six fields per commit) and `parseStatus(_ bytes: Data) throws -> WorkingTreeStatus` (porcelain-v1 `-z` parsing). Both pure.
- `GitModels+Git.swift` — `Git` namespace extensions that bridge M1 types to this module: mostly `internal` typealiases so the files above stay compact.
- `GitError.swift` — `public enum GitError: Error, Equatable { case notARepo; case gitMissing; case outputTooLarge; case diffTooLarge; case timedOut; case exec(code: Int32, stderr: String); case invalidInput(String) }`.

Update `Git.swift` (currently `public enum Git {}`) to re-export the service factory: `public extension Git { static func makeService(gitExecutable: URL? = nil) -> any GitService }`. No behaviour change for existing callers.

Tests under `apps/mac/touch-code/Tests/GitTests/` (new subfolder of the existing `touch-code/Tests/` which already hosts `HierarchyManagerTests.swift`; the `touch-codeTests` Tuist target's `buildableFolders` is `["touch-code/Tests"]` so the subfolder is picked up automatically):

- `DiffParserTests.swift` — fixture-driven. Fixtures under `apps/mac/touch-code/Tests/GitTests/Fixtures/`: `diff-added.txt`, `diff-deleted.txt`, `diff-modified.txt`, `diff-renamed.txt`, `diff-copied.txt`, `diff-binary.txt`, `diff-modechange.txt`, `diff-empty-newfile.txt`, `diff-no-newline-eof.txt`, `diff-merge-combined.txt`, `diff-crlf-mixed.txt`, `diff-too-large.txt` (50 001 lines). Assert the `UnifiedDiff` matches an embedded Swift literal expected value.
- `GitOutputParserTests.swift` — fixtures `log-linear.txt`, `log-merge.txt`, `log-root-only.txt`, `status-clean.txt`, `status-mixed.txt`, `status-utf8-paths.txt`. Assert parsed values.
- `GitProcessEnvTests.swift` — pass in a parent env with all forbidden keys set; assert output has only `PATH`, `HOME`, `LC_ALL`; assert a precondition failure when one leaks through (guarded by `#if DEBUG`).
- `LiveGitServiceIntegrationTests.swift` — gated behind `TC_RUN_GIT_INTEGRATION_TESTS=1` (skip via `try XCTSkipIf` reading `ProcessInfo.environment`). Creates a temp repo under `NSTemporaryDirectory()/touch-code-git-<UUID>/`, runs `git init`, writes files, commits them, and asserts `service.log` / `service.workingTreeDiff` / `service.commitDiff` return expected values. Cleans up via `FileManager.default.removeItem` in a `tearDown`.

**Observable acceptance.** `xcodebuild test -scheme touch-codeTests` includes the new parser-test cases and all pass. Integration tests pass locally under `TC_RUN_GIT_INTEGRATION_TESTS=1`. `make mac-lint` clean. A grep that guards the module's purity: `grep -rn 'import AppKit\|import SwiftUI\|import ComposableArchitecture\|import GhosttyKit' apps/mac/touch-code/Git` returns zero matches.

**Expected commits.** `feat(git): GitService protocol + LiveGitService over Process`, `feat(git): unified-diff + log parsers with fixtures`.

### Milestone 3: C7 TCA feature (reducer, no UI)

**Goal after this milestone.** A `GitViewerFeature` reducer exists in `apps/mac/touch-code/App/Features/GitViewer/`, a `GitServiceClient` `DependencyKey` sits next to the other clients added by `0002 M5`, and `TestStore`-driven tests prove scope transitions, pagination, request cancellation on scope change, error surfacing, and editor-open action delegation. No SwiftUI yet.

**Prerequisite.** `0002 M5` must have landed. That plan is the one that adds `swift-composable-architecture` to `apps/mac/Tuist/Package.swift` and introduces `apps/mac/touch-code/App/Clients/HierarchyClient.swift` + `TerminalClient.swift`. If M3 here is attempted before that, abandon and wait — do not add TCA ourselves, per the Decision Log discipline from `0002 DEC-3`.

**Work.**

Under `apps/mac/touch-code/App/Clients/`, create `GitServiceClient.swift`:

    import ComposableArchitecture
    import Foundation

    struct GitServiceClient: Sendable {
      var log: @Sendable (URL, LogPage.Cursor) async throws -> LogPage
      var workingTreeDiff: @Sendable (URL) async throws -> UnifiedDiff
      var stagedDiff: @Sendable (URL) async throws -> UnifiedDiff
      var commitDiff: @Sendable (URL, String) async throws -> UnifiedDiff
      var status: @Sendable (URL) async throws -> WorkingTreeStatus
    }
    extension GitServiceClient: DependencyKey {
      static let liveValue: GitServiceClient = …  // built from Git.makeService()
      static let testValue: GitServiceClient = …  // unimplemented() stubs, XCTFail on call
      static let previewValue: GitServiceClient = …  // canned fixtures
    }
    extension DependencyValues { var gitService: GitServiceClient { … } }

Under `apps/mac/touch-code/App/Features/GitViewer/`, create `GitViewerFeature.swift` implementing the reducer sketched in [c7-git-viewer.md §API Design](../design-docs/c7-git-viewer.md#api-design). Concrete contents:

- `@Reducer struct GitViewerFeature` with the exact `State` and `Action` from the design, plus two TCA cancellation IDs (`LogCancelID`, `DiffCancelID`) used to cancel stale effects when scope changes.
- `LogState = .idle | .loading | .loaded(LogPage) | .error(GitError)` and `DiffState = .idle | .loading | .loaded(UnifiedDiff) | .error(GitError)` nested enums.
- `PaneFocus = .list | .files | .hunks` and `Direction = .up | .down | .home | .end` nested enums.
- Body: scope changes cancel any in-flight request and issue the new one via `@Dependency(\.gitService)`. `.fileSelected` updates `selectedFilePath` (no git invocation). `.commitSelected(sha:)` transitions to `.commit(sha:)` scope after `GitShaValidator.isValid` passes. `.openInEditorRequested` delegates to `@Dependency(\.editorService)` **without blocking** the reducer — fire-and-forget effect, but the effect itself awaits the service call so errors surface via `.editorOpenResult(Result<EditorChoice, EditorError>)` (a new action added here for completeness; the service is introduced in M5 so M3 wires to a protocol + `@Dependency` placeholder that M5 fills).

To avoid a forward dependency on M5's `EditorService`, M3 defines a *minimal* placeholder `protocol EditorServiceFacade: Sendable { func openDirectory(_ url: URL, preferred: EditorID?, projectID: ProjectID?) async throws -> EditorChoiceDTO }` in `apps/mac/touch-code/App/Clients/EditorServiceFacade.swift`. The `testValue` implementation is `unimplemented()`; the `liveValue` throws `EditorError.notYetImplemented` (a new error case added to M1 as a placeholder? — no, keep M1 stable; instead, the facade's live default in M3 returns a `fatalError` that M5 replaces). This keeps M3 reviewable without waiting on M5.

Tests under `apps/mac/touch-code/Tests/GitViewerTests/` (new subfolder):

- `GitViewerFeatureTests.swift` using `TestStore`:
  - `test_worktreeSelected_triggersStatusAndLog`: dispatch `.worktreeSelected(wt.id)`, assert effects request `status` and `log(offset: 0)`.
  - `test_scopeChange_cancelsPriorEffect`: dispatch `.scopeChanged(.working)` → `.scopeChanged(.staged)` quickly; assert the first effect is cancelled and only the staged response is observed.
  - `test_commitSelected_validatesSha`: dispatch with `"notahex"`; assert no effect fires and state stays in `.log`.
  - `test_paginationRequest`: dispatch `.logScrolledToBottom`, assert `.log(cursor: offset=100, limit=100)` fires.
  - `test_fileSelected_updatesWithoutGitCall`: dispatch `.fileSelected("README.md")`, assert no service call.
  - `test_openInEditorRequested_delegatesToFacade`: use a fake `EditorServiceFacade` that records the call; dispatch `.openInEditorRequested`; assert `openDirectory(worktreeURL, preferred: nil, projectID: projectID)` was invoked once.
  - `test_error_toasts`: inject a `GitError.exec(1, "fatal: not a git repository")`; assert state ends in `.diff(.error(...))`.
  - `test_worktreeReselected_clearsStaleState`: changing Worktree while a diff is loaded must reset state before issuing new effects.

**Observable acceptance.** `xcodebuild test -scheme touch-codeTests` adds the viewer tests and all pass. `make mac-build` still succeeds (the app compiles even though no view consumes the feature yet). No runtime user-visible change.

**Expected commits.** `feat(app): GitServiceClient dependency + EditorServiceFacade placeholder`, `feat(app): GitViewerFeature TCA reducer + TestStore coverage`.

### Milestone 4: C7 SwiftUI viewer + app-shell wiring

**Goal after this milestone.** The user sees a working read-only viewer inside the running app. Selecting any Worktree in the sidebar populates the viewer; keyboard shortcuts navigate; a commit click renders its diff; the `Enter` key calls the editor facade (which is still the M3 placeholder until M5 replaces it with the real service); the 50 000-line cutoff renders a placeholder with a POSIX-quoted `cd` copy command.

**Work.**

Under `apps/mac/touch-code/App/Features/GitViewer/Views/` (new subfolder), create:

- `GitViewerView.swift` — root three-pane `SwiftUI.View`. Uses `@State private var store: StoreOf<GitViewerFeature>` (or Bindable / observation as `0002 M5` establishes). Pane layout: left column 280 pt (list), center 300 pt (file list; only when scope is `.log` with a commit selected, otherwise hidden), right column flex (hunks). Scope switcher sits at the top as a segmented control bound to `.scope`.
- `CommitLogView.swift` — `List` over `state.log.page?.commits ?? []`. Each row is `Commit.shortID` (monospace, dimmed), `authorName`, `subject` (truncating tail), `date` (relative-time formatter). `.onAppear` of the last row dispatches `.logScrolledToBottom`.
- `FileChangeListView.swift` — `List` over `state.diff.unifiedDiff?.files ?? []`. Row is `[kindGlyph] [path]  +N −M`. Glyphs: `A`, `M`, `D`, `R→`, `C→`, `T`. Selection drives `.fileSelected(path:)`.
- `UnifiedDiffView.swift` — `ScrollView` with a single `LazyVStack(spacing: 0)` over the selected file's `hunks.flatMap(\.lines)`. Each line is an `HStack { oldLineNumber; newLineNumber; marker; Text(line.text).monospaced() }`. Marker is `+` / `-` / ` ` / `\` (no-newline). Colour via `Theme.git.{added,removed,context}` tokens (a new `Theme.git` namespace introduced in this milestone under `apps/mac/touch-code/App/Theme/ThemeGit.swift`).
- `GitViewerKeybindings.swift` — a `.focused` / `.onKeyPress` modifier chain wired to `Direction` actions: `j`/`k` → `.keyboardNavigation(.up/.down)`, `g` → `.home`, `G` → `.end`, `Tab` → `.paneFocusCycled`, `Enter` → `.commitSelected(shortID)` in log, `.openInEditorRequested` in files/hunks, `r` → `.refreshRequested`, `1`/`2`/`3` → `.scopeChanged(.working|.staged|.log)`, `.` → `.whitespaceToggled`, `/` → `.filterFocused`.
- `LargeDiffPlaceholderView.swift` — renders when `diffState == .error(GitError.diffTooLarge)`. Shows per-file summary rows plus a "Copy command" button. Clipboard text is computed by a pure helper in `GitViewer/LargeDiffCommand.swift`: `func largeDiffCommand(scope: DiffScope, worktreePath: String, sha: String?) -> String`. The helper POSIX-quotes `worktreePath` (single-quotes wrapping, internal `'` → `'\''`) and emits the exact strings from [c7-git-viewer.md §Rendering](../design-docs/c7-git-viewer.md#rendering).

App-shell wiring (relies on the sidebar / tab bar from `0002 M5` already existing):

- Add a new pane slot to `RootFeature`'s state: `var gitViewer: GitViewerFeature.State = .init()`. A presentation modifier (sheet, or a right-pane inspector) hosts `GitViewerView`. In v1 ship it as a toggle in the Worktree-header area (the same area M6 will add the "Open in" button to) so activation is explicit and the user sees the viewer on demand.
- `RootFeature` subscribes to `HierarchyManager` selection changes; on a new `selectedWorktreeID`, dispatch `.gitViewer(.worktreeSelected(…))`.

Snapshot tests under `apps/mac/touch-code/Tests/GitViewerTests/Snapshots/`:

- Four happy-path snapshots: log (populated), working diff (10-file fixture), commit diff (rename + binary + added file), `.notARepo` empty state.
- Two error-path snapshots: `.diffTooLarge` placeholder (verifies the Copy-command string reflects POSIX quoting for a path with a space).

Snapshot library: re-use whichever snapshot harness `0002 M5` adopted; if none (likely for v1), use `pointfreeco/swift-snapshot-testing` by adding it to `Tuist/Package.swift` (document as a decision).

Pure-helper tests:

- `LargeDiffCommandTests.swift` — fixture table:
  | Worktree path | Scope | Expected |
  |---|---|---|
  | `/Users/gump/x` | `.working` | `cd '/Users/gump/x' && git diff --no-color` |
  | `/tmp/with space` | `.staged` | `cd '/tmp/with space' && git diff --no-color --cached` |
  | `/a/b's/c` | `.commit(sha:"deadbee")` | `cd '/a/b'\''s/c' && git show --no-color deadbee` |
  | `/x` | `.log` | (helper throws — log never hits the cutoff) |

**Observable acceptance.** `make mac-build && make mac-run-app`. Add a Project pointing at this repo (using M5's sidebar from 0002), select a Worktree, hit the Git-viewer toggle on the header. See the commit log populate within ~500 ms on a warm cache. Type `j`/`k` to navigate; press `Enter` on a commit to see its diff. Press `r` to refresh. Type `3` to switch to log scope, `1` to working, `2` to staged. In a large-diff scenario (e.g. `git commit -m big …` with a 60 000-line generated file), the placeholder appears and pressing "Copy command" places the exact `cd '<path>' && git show --no-color <sha>` text on the pasteboard (verify via `pbpaste`). No mouse interaction is required to reach any state.

**Expected commits.** `feat(app): GitViewer SwiftUI view + keybindings`, `feat(app): large-diff placeholder with POSIX-quoted Copy command`, `test(app): GitViewer snapshot coverage`.

### Milestone 5: C8 editor service layer

**Goal after this milestone.** `touch-code/App/Clients/Editor/` exists with a complete `EditorService`, its live implementation, the six-entry allowlist, a pure `PathProber`, and a `ProcessSpawner` that isolates `Foundation.Process` for testability. Every path — resolution, spawn, error — is unit-tested without invoking a real editor, plus a single integration test invokes `/usr/bin/open`.

This milestone is symmetric to M2 but for C8: it ends with a service ready to drive, and it does not touch the UI.

**Work.**

Under `apps/mac/touch-code/App/Clients/Editor/`, create the files named in [c8-editor-integration.md §Component Boundaries](../design-docs/c8-editor-integration.md#component-boundaries):

- `EditorService.swift` — the protocol. Three async methods (`describe`, `resolve`, `open`).
- `EditorService+Live.swift` — `LiveEditorService` (struct holding a `ProcessSpawner`, a `PathProber`, and closures that read the global default + custom editors from `SettingsStore` and the per-Project override from `HierarchyManager`). `resolve` implements the four-tier fallback chain from the design with **no silent fallthrough**. `open` runs the resolved template through `ProcessSpawner`.
- `EditorService+Test.swift` — in-memory implementation records every `open` call into an array; `describe` returns a caller-supplied array.
- `EditorRegistry.swift` — the six `EditorDescriptor` entries exactly as in [c8-editor-integration.md §Built-in allowlist](../design-docs/c8-editor-integration.md#built-in-allowlist-hard-coded-versioned-with-the-app). A `merged(with customs: [CustomEditor]) -> [EditorDescriptor]` helper that rejects ID collisions with a thrown error.
- `EditorModels.swift` — `EditorDescriptor`, `EditorChoice`, `InstallationStatus`, `EditorDescriptor.Origin`. These are **App-tier** types; the IPC-crossing DTOs in M1 are distinct so the live EditorService can carry richer state (e.g., an `@Observable` installation cache) without that state leaking to the wire. Bridging helpers `EditorDescriptor.toDTO() -> EditorDescriptorDTO` and symmetric `EditorChoice.toDTO()` are added here for M7.
- `EditorError.swift` — `public enum EditorError: Error, Equatable { case notInstalled(id: EditorID, binary: String); case spawnFailed(reason: String); case nonZeroExit(code: Int32, stderr: String); case timedOut; case badTemplate(id: EditorID, reason: String); case notADirectory(path: String); case unresolvedWorktree }`. Every case directly from the design's error table.
- `ProcessSpawner.swift` — the protocol:

      protocol ProcessSpawner: Sendable {
        func spawnForOpen(
          argv: [String],
          env: [String: String],
          cwd: URL,
          timeout: Duration
        ) async -> ProcessOutcome
      }

      enum ProcessOutcome: Equatable {
        case exited(code: Int32, stderr: String)
        case timedOut  // child was still alive at timeout; spawner sent SIGTERM then SIGKILL
        case spawnFailed(reason: String)
      }

  Two implementations: `FoundationProcessSpawner` (default, uses `Foundation.Process` with `Process.terminate()` + a 1 s polling wait before `kill(-9)`) and `RecordingProcessSpawner` (test double that records `(argv, env, cwd)` and returns a caller-canned `ProcessOutcome`).
- `PathProber.swift` — `protocol PathProber: Sendable { func locate(binaryName: String) -> URL? }`. `LivePathProber` consults `$PATH` by `realpath`-stat-ing `${dir}/${binaryName}` for each `:`-separated `$PATH` entry; returns the first readable/executable match. Caches results in a `@MainActor`-confined dictionary. Refresh triggers: `refresh()` is called (a) when `SettingsEditorSection` becomes visible (M6), (b) when a custom editor is added/removed (M6), (c) on `editor.describe` IPC (M7).
- `EditorEnv.swift` — `enum EditorEnv { static let whitelist: [String] = ["PATH", "HOME"]; static let forced: [String: String] = ["LC_ALL": "C.UTF-8"]; static let forbidden: Set<String> = ["SHELL", "EDITOR", "VISUAL", "GIT_DIR", "GIT_CONFIG", "GIT_CONFIG_SYSTEM", "GIT_CONFIG_GLOBAL", "GIT_ASKPASS", "JAVA_TOOL_OPTIONS"]; static func build(from parent: [String: String]) -> [String: String] }`. Symmetric to `GitProcessEnv` (M2); keeps the env-stripping discipline visible side-by-side so a reviewer can see both are aligned (per C8 review feedback — `SHELL` is stripped here; this was fixed in the design's round-2 review).
- `SpawnContract.swift` — `enum SpawnContract { static let timeout: Duration = .seconds(5); static let sigtermGrace: Duration = .seconds(1) }`. One source of truth for both numbers.

Tests under `apps/mac/touch-code/Tests/EditorTests/` (new subfolder):

- `EditorRegistryTests.swift` — assert the six built-in descriptors match the design's table byte-for-byte (IDs, display names, argv templates). Assert `merged(with:)` rejects `CustomEditor(id: "vscode", …)` with `.invalidID("vscode")` error surfaced as `EditorError.badTemplate`.
- `EditorValidatorsTests.swift` — already covered in M1; no duplication here.
- `PathProberTests.swift` — protocol-based FakeFileSystem that returns predetermined listings; assert `LivePathProber` picks the first PATH entry, skips non-executable, returns nil on not-found.
- `EditorServiceResolutionTests.swift` — TCA-free, driven by `LiveEditorService` with a `RecordingProcessSpawner`. Cases:
  1. `preferred = "vscode"` with vscode installed → resolves to vscode.
  2. `preferred = nil`, `project.defaultEditor = "cursor"`, cursor installed → cursor.
  3. `preferred = nil`, project override nil, `settings.defaultEditorID = "zed"`, zed installed → zed.
  4. `preferred = nil`, all nil → finder.
  5. `preferred = "vscode"`, vscode **not** installed → throws `.notInstalled`; **no silent fallthrough** to a next tier.
- `EditorServiceSpawnTests.swift` — `RecordingProcessSpawner`-driven:
  - argv matches the template for each built-in ID (six cases).
  - `{dir}` substitution is literal; a path with spaces reaches argv as a single argument, unquoted (no shell).
  - `env` has exactly `{"PATH", "HOME", "LC_ALL"}` for each spawn.
  - `cwd` is the absolute worktree URL.
  - `.exited(code: 0)` → success return.
  - `.exited(code: 1, stderr: "bad")` → `EditorError.nonZeroExit(1, "bad")`.
  - `.timedOut` → `EditorError.timedOut`.
  - `.spawnFailed(reason: "ENOENT")` → `EditorError.spawnFailed(reason: "ENOENT")`.
- `LiveProcessSpawnerIntegrationTests.swift` — gated by `TC_RUN_EDITOR_INTEGRATION_TESTS=1`. Spawns `/usr/bin/open` with argv `["open", NSTemporaryDirectory()]` and asserts `ProcessOutcome.exited(code: 0, …)`.

**Observable acceptance.** `xcodebuild test -scheme touch-codeTests` runs the editor tests; all pass. Under `TC_RUN_EDITOR_INTEGRATION_TESTS=1`, the live-spawn smoke test launches Finder on the tmp directory and passes. `make mac-lint` clean. No UI change yet.

**Expected commits.** `feat(editor): EditorService + allowlist + ProcessSpawner`, `feat(editor): PathProber + env whitelist + spawn contract`.

### Milestone 6: C8 TCA feature + Settings section + Worktree-header button

**Goal after this milestone.** The user sees an "Open in ▾" dropdown on the Worktree header, clicks it, and the current Worktree opens in the chosen editor. The Settings window has an "Editors" section with the six built-in entries (each marked installed / missing), a custom-editor list with add/edit/remove, and a global-default picker. Per-Project overrides persist in `catalog.json` (via `HierarchyClient`), custom editors + global default persist in `settings.json` (via a new `SettingsStore`).

**Work.**

Under `apps/mac/touch-code/App/Clients/`:

- `EditorClient.swift` — parallel to `GitServiceClient`. `DependencyKey`-conforming struct with `describe`, `resolve`, `open` closures. `liveValue` is built from `LiveEditorService` plus the project/settings lookup closures.
- Replace the M3 placeholder `EditorServiceFacade` with a real one backed by `EditorClient.open`. Delete `EditorServiceFacade.swift` and update `GitViewerFeature` to `@Dependency(\.editorClient)` directly.

Under `apps/mac/touch-code/App/Features/Editor/`:

- `EditorFeature.swift` — a small TCA reducer that owns the "describe + resolve" state for the dropdown and Settings section. `State` carries `available: [EditorDescriptor]`, `globalDefault: EditorID?`, `customEditors: [CustomEditor]`. Actions: `.onAppear`, `.describeResponse(...)`, `.setGlobalDefault(EditorID?)`, `.addCustomEditor(CustomEditor)`, `.updateCustomEditor(id: EditorID, CustomEditor)`, `.removeCustomEditor(EditorID)`. The reducer persists changes through `SettingsStore`.

Under `apps/mac/touch-code/App/Features/Settings/`:

- `SettingsStore.swift` — `@MainActor @Observable` class managing `~/.config/touch-code/settings.json` via `AtomicFileStore`. Stores `{ version: 1, defaultEditorID: String?, customEditors: [CustomEditor] }`. Debounces writes with the same 500 ms pattern as `CatalogStore` (0002 M2). Decode failure backs up to `settings.json.broken-<ISO8601>`.
- `SettingsEditorSection.swift` — SwiftUI form. A `Picker` bound to the global default. A `List` of custom editors with a sheet-based editor supporting inline validation against `CommandTemplate.validate` and `CustomEditor.validatedID`. A "Refresh editor detection" button that calls `editorClient.describe` and re-renders installed/missing markers.
- `SettingsFeature.swift` (if this does not already exist from 0002 M5, create minimally; otherwise add the editor section as a child).

Under `apps/mac/touch-code/App/Features/WorktreeHeader/` (new feature folder; documented in design as "not yet in architecture.md" per the C8 review fix):

- `WorktreeHeaderOpenButton.swift` — A `Menu` view that renders `editorFeature.state.available` as rows (disabled rows for `.missingBinary`), plus a "Custom…" sub-menu surfacing `customEditors`, plus a "Set as default…" action. Clicking a row dispatches `.openInEditor(id)` which resolves to `editorClient.open(directory: worktree.path, preferred: id, projectID: project.id)`. The dropdown's current label is the resolved editor's `displayName` for the active Worktree (obtained via `editorClient.resolve`).

Per-Project override writes:

- Add `HierarchyClient.setDefaultEditor(projectID: ProjectID, editorID: EditorID?)` to the command enum. `liveValue` dispatches to `HierarchyManager.setDefaultEditor(_:for:)` which mutates `Project.defaultEditor` and triggers a debounced save.

Wiring:

- `RootFeature` gains `var editor: EditorFeature.State` and `var settings: SettingsFeature.State`. `.onAppear` dispatches `.editor(.onAppear)` so `describe` runs once on launch.
- `GitViewerFeature.openInEditorRequested` now resolves through the real `editorClient.open`; the test suite's fake from M3 is replaced by the `EditorClient.testValue` canned from M5's `EditorService+Test`.

Tests:

- `EditorFeatureTests.swift` — TCA `TestStore`. Cover: `.onAppear` issues `describe`; `.setGlobalDefault("vscode")` calls `settingsStore.setDefaultEditorID` and bounces back through state; `.addCustomEditor` with invalid template surfaces a validation error without mutating state; `.removeCustomEditor` writes through.
- `SettingsStoreTests.swift` — round-trip writes and reads under a tmp HOME; corrupt file → backup + default.
- `WorktreeHeaderOpenButtonTests.swift` — `TestStore` with a recording `EditorClient.testValue` asserting `.openInEditor("cursor")` produces an `open(.cursor, project: …)` call.
- One snapshot test of the dropdown with three built-ins installed + two missing + one custom.

**Observable acceptance.** Launch the app, select a Worktree, click "Open in ▾". See the six built-ins; missing ones are disabled with the design's explicit label ("CLI `code` not found on PATH"). Pick Finder → Finder opens `<worktree-path>`. Pick Cursor (if installed) → Cursor opens the directory. In Settings → Editors, set global default to Zed; click outside Settings; relaunch; confirm persistence. Add a custom editor "helix" with template `("hx", ["{dir}"])`; assert it appears in the dropdown if `hx` is on `PATH`. Right-click a Worktree in the sidebar → "Set default editor for this Project" → VSCode; assert `catalog.json` now contains `"defaultEditor": "vscode"` under that Project.

**Expected commits.** `feat(editor): EditorClient TCA bridge + EditorFeature`, `feat(settings): SettingsStore + editors section`, `feat(app): Worktree-header Open-in dropdown`, `feat(runtime): setDefaultEditor through HierarchyClient`.

### Milestone 7: `editor.*` IPC + `tc open` subcommand

**Goal after this milestone.** `tc open [--in <editor>] [<worktree>]` works from inside any Panel. It prints `"opened <Worktree name> in <Editor name>"` on success; on unresolved Worktree it exits 2 with a precise stderr message; on every other error it exits non-zero with the error's message on stderr.

**Work.**

Under `apps/mac/TouchCodeIPC/Editor/`:

- Expand `EditorIPCTypes.swift` (created in M1) with request/response envelopes:

      public struct EditorOpenRequest: Codable, Equatable, Sendable {
        public var worktreeID: UUID?           // nil means: resolve via TOUCH_CODE_PANEL_ID
        public var preferred: EditorID?
        public var panelID: UUID?              // app uses this to resolve worktreeID when above is nil
      }
      public struct EditorOpenResponse: Codable, Equatable, Sendable {
        public var choice: EditorChoiceDTO
      }
      public struct EditorDescribeResponse: Codable, Equatable, Sendable {
        public var descriptors: [EditorDescriptorDTO]
      }
      public struct EditorSetDefaultRequest: Codable, Equatable, Sendable {
        public var projectID: UUID
        public var editorID: EditorID?         // nil unsets the override
      }

- `EditorIPCError.swift` — wraps the app's `EditorError` into wire-safe codes: `.unresolvedWorktree = 100`, `.notInstalled = 101`, `.nonZeroExit = 102`, `.timedOut = 103`, `.spawnFailed = 104`, `.badTemplate = 105`, `.notADirectory = 106`. The JSON-RPC `{ error: { code, message } }` envelope re-uses the code table.

Under `apps/mac/touch-code/App/Features/Socket/` (this feature is created by a future plan for `0002 M4+` socket-server bring-up; if not yet present, this plan adds a minimal `SocketServer` focused on `editor.*` — flag in Decision Log if we land that early):

- Dispatch `editor.describe` → call `editorClient.describe()` → wrap in `EditorDescribeResponse`.
- Dispatch `editor.open` → if `request.worktreeID == nil`, resolve via `request.panelID → HierarchyManager.panel(byID: …).parentWorktreeID`; if still nil, return `EditorIPCError.unresolvedWorktree`. Otherwise resolve the `Worktree.path`, call `editorClient.open(directory:preferred:projectID:)`, wrap in `EditorOpenResponse`.
- Dispatch `editor.setDefault` → call `HierarchyClient.setDefaultEditor`.

Under `apps/mac/tc/Commands/` (new subfolder — update `tc` target's `buildableFolders` accordingly if needed):

- `OpenCommand.swift` — `ArgumentParser` subcommand:

      struct OpenCommand: ParsableCommand {
        static let configuration = CommandConfiguration(
          commandName: "open",
          abstract: "Open the current Worktree directory in an external editor."
        )
        @Option(name: .customLong("in"))  var editorID: String?
        @Argument(help: "Worktree name or UUID; optional inside a Panel.")
        var worktree: String?
        func run() throws { /* … */ }
      }

  `run()` resolves the Worktree ID in order: (1) explicit `--worktree`/positional; (2) `ProcessInfo.processInfo.environment["TOUCH_CODE_PANEL_ID"]` → IPC `system.get_context` → Worktree ID; (3) neither → `FoundationError.notUserInteractable` — print `"error: no worktree (pass <worktree> or run from inside a touch-code Panel)"` to stderr and `throw ExitCode(2)`. Then issues `editor.open` via a lightweight `IPCClient` helper (under `apps/mac/tc/IPCClient.swift`).
- `main.swift` is updated to include `OpenCommand.self` in its subcommands array.

Tests:

- `OpenCommandTests.swift` under `apps/mac/tc/Tests/` (new `.unitTests` target `tcTests` if one does not exist — if adding the target is a material change, flag in Decision Log and prefer hosting the tests in `touch-codeTests`):
  - Parse `tc open --in vscode main-worktree` → `OpenCommand(editorID: "vscode", worktree: "main-worktree")`.
  - Parse `tc open` with `TOUCH_CODE_PANEL_ID` set → asserts `IPCClient` is invoked with `panelID` populated.
  - Parse `tc open` with no `TOUCH_CODE_PANEL_ID` → expected: stderr contains `"no worktree"`, exit code 2, zero IPC calls.
- `SocketServerEditorDispatchTests.swift` under `touch-codeTests` — feed a synthetic `editor.open` JSON-RPC envelope through the dispatcher with a fake `EditorClient.testValue` that records calls; assert the call payload and the envelope result matches `EditorOpenResponse`.

**Observable acceptance.** Build `tc` via `make mac-build-cli`, then from inside a touch-code Panel:

    tc open
    # expected stdout: "opened <Worktree name> in <Editor display>"
    # exit code 0

    tc open --in zed
    # opens Zed on the current Worktree directory

    tc open some-other-worktree --in finder
    # opens Finder on the named Worktree

From outside a Panel (regular terminal, `TOUCH_CODE_PANEL_ID` unset), `tc open` prints `error: no worktree (pass <worktree> or run from inside a touch-code Panel)` to stderr and exits 2 — confirmed by `echo $?`.

**Expected commits.** `feat(ipc): editor.* method dispatch + wire DTOs`, `feat(tc): open subcommand with TOUCH_CODE_PANEL_ID fallback`, `feat(app): SocketServer editor dispatch`.

### Milestone 8: Cross-feature integration + performance + docs close-out

**Goal after this milestone.** A contributor can run the nine-step acceptance walkthrough end-to-end with every step green; performance assertions hold; the architecture codemap and the product spec's Open Question #7 are updated to reflect the shipped design.

**Work.**

Tests:

- `apps/mac/touch-code/Tests/Integration/GitViewerEditorIntegrationTests.swift` — `TestStore` spanning `RootFeature` with real `GitViewerFeature`, real `EditorFeature`, real `HierarchyManager`, and a `RecordingProcessSpawner` + mock `GitService`. Scenario: launch → select Worktree → scope `.log` → pick commit → press `Enter` → assert the editor dispatcher is called with the resolved editor ID and the Worktree path.
- `apps/mac/touch-code/Tests/Performance/GitViewerPerformanceTests.swift` — uses a synthetic 1 000-line `git diff` fixture; measures parse + reducer-state-update wall-clock via `ContinuousClock.Instant`. Asserts **< 80 ms for parse** and **< 20 ms for reducer dispatch**, leaving headroom within the design's 200 ms budget. Runs under `TC_RUN_PERFORMANCE_TESTS=1`.
- `apps/mac/touch-code/Tests/Integration/EditorFallbackChainTests.swift` — end-to-end exercises the fallback chain: (a) per-project override set + editor installed → opens the override; (b) per-project override set + editor missing → surfaces `.notInstalled` without falling through to global; (c) no override, global set, installed → opens global; (d) nothing set → opens Finder.
- `apps/mac/touch-code/Tests/Integration/IPCEditorTests.swift` — spins up a real `SocketServer` on a temp socket path, runs `tc open` as a subprocess against it with a `TOUCH_CODE_SOCKET_PATH` override, asserts the response envelope round-trip.

Documentation close-out:

- `docs/architecture.md` — add `touch-code/Git/` and `touch-code/App/Clients/Editor/` to the in-app module table; add `touch-code/App/Features/WorktreeHeader/` to the features list (per C8 review note).
- `docs/product-spec.md` — update Open Question #7 entry to `(Resolved by docs/design-docs/c8-editor-integration.md.)`; mark C7 and C8 as `Beta` in the capability maturity column once the acceptance walkthrough passes.
- `docs/design-docs/README.md` — no change (already updated).
- `docs/exec-plans/README.md` — confirm 0005 is listed with a one-line description.

Dogfooding acceptance walkthrough (to be appended to `Outcomes & Retrospective` once run):

1. `make mac-generate && make mac-build && make mac-run-app`.
2. Add the touch-code repo as a Project; select the current branch's Worktree.
3. Toggle the Git viewer. See the last 100 commits in < 500 ms on a warm cache.
4. Press `1` → working-tree diff; `2` → staged; `3` → log; `Enter` on a commit → its diff. All transitions under one frame.
5. Press `Enter` on a file row → Worktree opens in the default editor (Finder on a fresh install).
6. Open Settings → Editors → pick Zed as global default (if installed) → confirm `settings.json` updates.
7. Right-click the Project → "Set default editor" → Cursor → confirm `catalog.json` updates.
8. Click the Worktree-header "Open in ▾" → Cursor → Cursor opens the directory.
9. From a Panel: `tc open` → editor opens; `tc open --in finder` → Finder opens; `exit` the panel, run `tc open` from a regular shell → exit 2 with the documented stderr line.

**Observable acceptance.** All tests pass (including the gated performance + integration ones). Every step above is green. Architecture and product-spec changes land in a single commit alongside the test additions.

**Expected commits.** `test(integration): cross-feature GitViewer + Editor paths`, `test(perf): 1000-line diff parse + dispatch budgets`, `docs: update architecture codemap and close product-spec OQ7`.

## Concrete Steps

Run every command from the repository root (`/Users/wanggang/dev/00/touch-code`) unless otherwise noted. Steps are grouped by milestone. Keep the Progress section updated as each step completes.

### M1 steps

    # Write sources under TouchCodeCore/Git, TouchCodeCore/Editor, TouchCodeIPC/Editor; update Project.swift if needed
    make mac-generate

    DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
      xcodebuild test -workspace apps/mac/touch-code.xcworkspace \
                      -scheme TouchCodeCoreTests | xcbeautify
    # Expected tail: "Test Suite 'All tests' passed at ..."

    make mac-lint
    # Expected: clean (no output)

### M2 steps

    # Assumes 0002 M3+ has landed (GhosttyKit enabled; app target builds).
    make mac-generate
    DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
      xcodebuild test -workspace apps/mac/touch-code.xcworkspace \
                      -scheme touch-codeTests | xcbeautify

    # Integration smoke (needs `git`):
    TC_RUN_GIT_INTEGRATION_TESTS=1 \
    DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
      xcodebuild test -workspace apps/mac/touch-code.xcworkspace \
                      -scheme touch-codeTests \
                      -only-testing touch-codeTests/LiveGitServiceIntegrationTests | xcbeautify

### M3 steps

    # Prerequisite: 0002 M5 has landed (TCA is in Package.swift).
    make mac-generate
    DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
      xcodebuild test -workspace apps/mac/touch-code.xcworkspace \
                      -scheme touch-codeTests \
                      -only-testing touch-codeTests/GitViewerFeatureTests | xcbeautify

### M4 steps

    make mac-generate
    make mac-build
    make mac-run-app
    # Manual: toggle the Git viewer on the active Worktree's header; verify keybindings.

    DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
      xcodebuild test -workspace apps/mac/touch-code.xcworkspace \
                      -scheme touch-codeTests \
                      -only-testing touch-codeTests/LargeDiffCommandTests | xcbeautify

### M5 steps

    make mac-generate
    DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
      xcodebuild test -workspace apps/mac/touch-code.xcworkspace \
                      -scheme touch-codeTests \
                      -only-testing touch-codeTests/EditorServiceResolutionTests \
                      -only-testing touch-codeTests/EditorServiceSpawnTests | xcbeautify

    TC_RUN_EDITOR_INTEGRATION_TESTS=1 \
    DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
      xcodebuild test -workspace apps/mac/touch-code.xcworkspace \
                      -scheme touch-codeTests \
                      -only-testing touch-codeTests/LiveProcessSpawnerIntegrationTests | xcbeautify

### M6 steps

    make mac-generate
    make mac-run-app
    # Manual: verify dropdown, settings section, per-Project override persistence.

    DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
      xcodebuild test -workspace apps/mac/touch-code.xcworkspace \
                      -scheme touch-codeTests \
                      -only-testing touch-codeTests/EditorFeatureTests \
                      -only-testing touch-codeTests/SettingsStoreTests | xcbeautify

### M7 steps

    make mac-build          # builds tc + app
    # Launch the app, open a Panel, then inside it:
    tc open
    # Expected: stdout "opened <name> in Finder", exit 0.

    # From a regular terminal (TOUCH_CODE_PANEL_ID unset):
    tc open
    # Expected: stderr "error: no worktree (pass <worktree> or run from inside a touch-code Panel)"
    # Expected exit code: 2.
    echo $?

### M8 steps

    DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
      xcodebuild test -workspace apps/mac/touch-code.xcworkspace \
                      -scheme touch-codeTests | xcbeautify

    TC_RUN_PERFORMANCE_TESTS=1 \
    DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
      xcodebuild test -workspace apps/mac/touch-code.xcworkspace \
                      -scheme touch-codeTests \
                      -only-testing touch-codeTests/GitViewerPerformanceTests | xcbeautify

    # Run the dogfooding walkthrough from the Milestone 8 section above.

## Validation and Acceptance

After all eight milestones land, a fresh contributor can observe:

1. `make mac-bootstrap && make mac-generate && make mac-build && make mac-run-app` — app launches in < 1 s.
2. Select a Git-backed Worktree. Toggle the Git viewer. Log populates in < 500 ms on a warm cache.
3. `j`/`k` navigate the log; `Enter` opens a commit's diff; `1`/`2`/`3` switch scope; `r` refreshes; `.` toggles whitespace-ignore; `/` filters file names; all under one frame.
4. A 1 000-line diff parses and renders in under 200 ms (measured by the performance test).
5. A synthetic 60 000-line diff shows the placeholder with a "Copy command" button whose output is the expected `cd '<abs-path>' && git …` (with POSIX-quoted paths for paths containing spaces or apostrophes).
6. Clicking "Open in ▾" on the Worktree header lists the six built-ins with accurate installed/missing state, plus any configured custom editors.
7. Choosing an installed editor opens the Worktree **directory** in that editor within 5 s; choosing a missing built-in shows the exact design-mandated error ("Visual Studio Code CLI (`code`) not found on PATH. Install via 'Shell Command: Install code command in PATH' in VSCode's Command Palette.").
8. From inside a Panel, `tc open` opens the default editor; `tc open --in zed` opens Zed; `tc open some-other-worktree` targets a named Worktree. From a regular shell, `tc open` exits 2 with the exact stderr line.
9. Settings → Editors shows the registry, allows adding a custom editor with validation, and persists through relaunch.
10. `xcodebuild test -scheme TouchCodeCoreTests` and `-scheme touch-codeTests` all green. `make mac-lint` clean.

Failure on any of the above blocks sign-off.

## Idempotence and Recovery

Every milestone is re-runnable.

- **Regenerate workspace.** `make mac-generate` is idempotent; safe after any `Project.swift` edit.
- **Reset settings.** `mv ~/.config/touch-code/settings.json ~/.config/touch-code/settings.json.bak` forces default settings on next launch. A corrupt file is automatically backed up to `settings.json.broken-<timestamp>`.
- **Reset the viewer's in-flight work.** The viewer is stateless across launches; no reset needed. If a `git` subprocess hangs (should be caught by the 10 s timeout), `pkill -f '^git ' -n` kills the most recent child.
- **Reset the path-probe cache.** No on-disk state; the cache is process-local. Relaunch the app or open Settings → Editors → "Refresh editor detection".
- **Recover from a custom-editor template that breaks the dropdown.** Edit `~/.config/touch-code/settings.json` manually to remove the offending `customEditors` entry; relaunch.
- **Unwind a failed `tc open`.** No rollback needed; the command is spawn-only and never mutates state.
- **Recover from an accidentally-committed `GIT_*` env leak.** The `GitProcessEnv.build` assertions fail-fast in debug; any leak is surfaced immediately during testing.

None of the steps modify global state (no `xcode-select`, no PATH mutation, no `launchctl` entries).

## Artifacts and Notes

No prototyping was required beyond what the design docs already establish:

- **Unified-diff parser.** `git diff`'s output shape is stable and well-documented; the parser is a routine state machine over `diff --git`, `index`, `---`, `+++`, `@@`, and per-hunk lines. The design's fixture list (M2 test plan) covers every branch the parser handles.
- **Launch Services vs. CLI wrappers.** Decided in design round 1; confirmed in round 2. `NSWorkspace.open` is used exclusively for Xcode (no CLI) via the `open -a Xcode {dir}` wrapper.
- **Spawn contract.** Round-2 review simplified the contract to a single rule (exit-code or timeout); no "assume detached" heuristic.

When work begins, log in Decision Log any adjustment to these assumptions. Planned transcripts (e.g. `pbpaste` output confirming the Copy-command string) will be captured here as each milestone completes.

## Interfaces and Dependencies

The following types, functions, and signatures must exist by plan completion. Names are binding — later plans reference them.

**`TouchCodeCore/Git/`** (pure Swift; zero platform imports):

    public struct Commit: Equatable, Hashable, Codable, Sendable, Identifiable {
      public let id: String                  // full SHA-1 or SHA-256
      public let authorName: String
      public let authorEmail: String
      public let date: Date
      public let subject: String
      public let parents: [String]
      public var shortID: String { String(id.prefix(7)) }
    }
    public enum DiffScope: Equatable, Codable, Sendable {
      case working; case staged; case log; case commit(sha: String)
    }
    public struct UnifiedDiff: Equatable, Codable, Sendable {
      public var scope: DiffScope
      public var files: [FileChange]
    }
    public struct FileChange: Equatable, Codable, Sendable, Identifiable {
      public enum Kind: Equatable, Codable, Sendable {
        case added, deleted, modified, renamed(from: String), copied(from: String), typeChanged
      }
      public var id: String
      public var kind: Kind
      public var isBinary: Bool
      public var linesAdded: Int
      public var linesRemoved: Int
      public var hunks: [DiffHunk]
    }
    public struct DiffHunk: Equatable, Codable, Sendable { … }
    public struct DiffLine: Equatable, Codable, Sendable {
      public enum Kind: Equatable, Codable, Sendable { case context, added, removed, noNewlineMarker }
      public var kind: Kind
      public var text: String
    }
    public struct LogPage: Equatable, Codable, Sendable {
      public struct Cursor: Equatable, Codable, Sendable { public let offset: Int; public let limit: Int }
      public var cursor: Cursor
      public var commits: [Commit]
      public var hasMore: Bool
    }
    public struct WorkingTreeStatus: Equatable, Codable, Sendable {
      public struct Entry: Equatable, Codable, Sendable { … }
      public var entries: [Entry]
      public var isClean: Bool { entries.isEmpty }
    }
    public enum GitShaValidator { public static func isValid(_ s: String) -> Bool }

**`TouchCodeCore/Editor/`**:

    public typealias EditorID = String
    public struct CommandTemplate: Equatable, Codable, Sendable {
      public let binary: String
      public let args: [String]
      public func validate() throws    // throws EditorTemplateError
    }
    public struct CustomEditor: Equatable, Codable, Sendable, Identifiable {
      public var id: EditorID; public var displayName: String; public var template: CommandTemplate
      public static func validatedID(_ raw: String) throws -> EditorID
    }
    public enum EditorTemplateError: Error, Equatable {
      case emptyBinary; case missingDirPlaceholder; case duplicateDirPlaceholder; case invalidID(String)
    }

**`TouchCodeIPC/Editor/`**:

    public struct EditorDescriptorDTO: Codable, Equatable, Sendable { … }
    public struct EditorChoiceDTO: Codable, Equatable, Sendable { … }
    public enum EditorInstallationStatusDTO: Codable, Equatable, Sendable {
      case installed(resolvedBinary: URL)
      case missingBinary(expected: String)
    }
    public struct EditorOpenRequest: Codable, Equatable, Sendable { … }
    public struct EditorOpenResponse: Codable, Equatable, Sendable { … }
    public struct EditorDescribeResponse: Codable, Equatable, Sendable { … }
    public struct EditorSetDefaultRequest: Codable, Equatable, Sendable { … }
    public enum EditorIPCMethod {
      public static let describe = "editor.describe"
      public static let open = "editor.open"
      public static let setDefault = "editor.setDefault"
    }

**`touch-code/Git/`** (app-target; imports `TouchCodeCore` + Foundation):

    public protocol GitService: Sendable {
      func log(at path: URL, page: LogPage.Cursor) async throws -> LogPage
      func workingTreeDiff(at path: URL) async throws -> UnifiedDiff
      func stagedDiff(at path: URL) async throws -> UnifiedDiff
      func commitDiff(at path: URL, sha: String) async throws -> UnifiedDiff
      func status(at path: URL) async throws -> WorkingTreeStatus
    }
    public enum GitError: Error, Equatable { … }
    public extension Git { static func makeService(gitExecutable: URL? = nil) -> any GitService }

**`touch-code/App/Clients/`**:

    struct GitServiceClient: Sendable { … }                         // DependencyKey
    struct EditorClient: Sendable { … }                             // DependencyKey
    extension HierarchyClient {
      var setDefaultEditor: @MainActor @Sendable (ProjectID, EditorID?) -> Void { get set }
    }

**`touch-code/App/Clients/Editor/`**:

    public protocol EditorService: Sendable {
      func describe() async -> [EditorDescriptor]
      func resolve(preferred: EditorID?, projectID: ProjectID?) async -> EditorChoice
      @discardableResult func open(directory: URL, preferred: EditorID?, projectID: ProjectID?) async throws -> EditorChoice
    }
    public struct EditorDescriptor: Equatable, Sendable, Identifiable { … }
    public struct EditorChoice: Equatable, Sendable { … }
    public enum InstallationStatus: Equatable, Sendable { … }
    public enum EditorError: Error, Equatable {
      case notInstalled(id: EditorID, binary: String)
      case spawnFailed(reason: String)
      case nonZeroExit(code: Int32, stderr: String)
      case timedOut
      case badTemplate(id: EditorID, reason: String)
      case notADirectory(path: String)
      case unresolvedWorktree
    }
    protocol ProcessSpawner: Sendable { func spawnForOpen(argv: [String], env: [String: String], cwd: URL, timeout: Duration) async -> ProcessOutcome }
    enum ProcessOutcome: Equatable { case exited(code: Int32, stderr: String); case timedOut; case spawnFailed(reason: String) }
    protocol PathProber: Sendable { func locate(binaryName: String) -> URL? }

**`touch-code/App/Features/GitViewer/`**:

    @Reducer struct GitViewerFeature {
      struct State: Equatable { … }
      enum Action { … }
    }
    struct GitViewerView: View { let store: StoreOf<GitViewerFeature>; var body: some View }

**`touch-code/App/Features/Editor/`**:

    @Reducer struct EditorFeature { … }

**`touch-code/App/Features/WorktreeHeader/`**:

    struct WorktreeHeaderOpenButton: View { … }

**`touch-code/App/Features/Settings/`**:

    @MainActor @Observable final class SettingsStore {
      init(fileURL: URL = Settings.defaultURL())
      var defaultEditorID: EditorID?
      var customEditors: [CustomEditor]
      func scheduleSave()
      func saveNow() throws
    }
    struct SettingsEditorSection: View { … }

**`tc/Commands/`**:

    struct OpenCommand: ParsableCommand { … }

**External dependencies added by this plan**: none beyond what `0002 M5` already brings in (`swift-composable-architecture`, `swift-snapshot-testing` if not already added).

**Tuist targets added by this plan**: none. All tests land under the existing `TouchCodeCoreTests` and `touch-codeTests` targets, whose `buildableFolders` pick up new subfolders automatically. If M7 elects a dedicated `tcTests` target, that becomes a deliberate Decision Log entry at implementation time.

**Prerequisite ordering.** M1 and M2 can begin before `0002` completes because they do not touch the app target. M3 through M8 require `0002 M5` (TCA wired, sidebar landed). M7 requires a minimal `SocketServer`; if `0002` has not brought one up by M7-time, this plan lands a narrow editor-only dispatcher and flags the expansion for the IPC/CLI plan.
