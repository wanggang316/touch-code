# Mission done: PR #4 REQUEST_CHANGES fixes (C7 + C8)

PR: https://github.com/wanggang316/touch-code/pull/7 (branch `worktree-fix+c7-c8-viewer-editor` → `main`).

Four commits landed, each addressing one review deliverable:

1. **820e0ef** `feat(editor)`: unified `tc open` ↔ server wire on canonical `EditorOpenRequest`/`Response`; added `path` field with in-worktree validation in `EditorHandlers`; added missing `.editorDescribe`/`.editorSetDefault` to `IPC.Method`; round-trip + legacy-payload tests.
2. **5f56940** `feat(editor)`: constructed `EditorHandlers` in `TouchCodeApp.startIPC` from the shared `EditorClient`, extended `MethodRouter` to dispatch `editor.*`, mapped `EditorIPCError` → `IPCError`. Unblocks `tc open --in` / `--path` end-to-end.
3. **da39504** `fix(viewer)`: threaded originating `DiffScope` through `logSucceeded`/`diffSucceeded`/failed actions; reducer drops stale-scope deliveries (Option A). Added tests for the race.
4. **2a2884b** `fix(git)`: XY/path separator guard in `GitOutputParser`; `rev-parse --is-inside-work-tree` stdout parse; stderr preferred over `outputTooLarge`; `LargeDiffCommand` SHA precondition; renamed duplicate `Tests/NotificationsTests/SettingsStoreTests.swift` (C6 leftover blocking `build-for-testing`).

<<<<<<< Updated upstream
## C7 — key decisions

- Shell out to `git` via `Process` (not libgit2). 16 MiB output cap, 10 s timeout, env stripped of `GIT_*` redirectors.
- TCA feature (`GitViewerFeature`) + pure data layer in `touch-code/Git/` (protocol `GitService`, hand-rolled unified-diff parser).
- Worktree-scoped; no caching in v1. Plaintext monospace; `LazyVStack`; 50 000-line soft cap with "open externally" fallback (`cd <abs-path> && git ...` copy-command, POSIX-quoted).
- Keyboard-first: `j`/`k`/`g`/`G`/`Tab`/`Enter`/`r`/`1/2/3`/`.`/`/`. `Enter` delegates to C8 — opens the Worktree **directory**, not the selected file (no file-level hand-off in v1).
- No IPC in v1; `git.*` namespace reserved as seam.

## C8 — key decisions (resolves Open Question #7)

- CLI wrappers over `Process` for everything: `code`, `cursor`, `zed`, `subl`, `open -a Xcode`, `open` (Finder). Launch Services used only to locate Xcode.
- `$PATH` probe at startup (cached; refreshed on Settings open / IPC `editor.describe`).
- Fallback chain: explicit → `Project.defaultEditor` → `Settings.defaultEditorID` → Finder. **No silent fallthrough** on missing preferred editor.
- Worktree resolution for `tc open`: explicit `<worktree>` → `TOUCH_CODE_PANE_ID` env lookup → **error** (no heuristic fallback).
- User-defined templates: `binary` + `args` with exactly one `{dir}` placeholder; ID matches `[a-z][a-z0-9_-]{1,31}`.
- Spawn contract: wait up to 5 s; exit 0 = success, non-zero = `.nonZeroExit`, still running at 5 s = `.timedOut` (SIGTERM then SIGKILL). No "assume-detached" heuristic.
- Env whitelist: `PATH`, `HOME`, `LC_ALL` only (aligned with C7; `SHELL` dropped).
- Single `ProcessSpawner` seam for full mock-Process testability.

## Round 2 — review feedback applied

- **C8 spawn contract** rewritten: removed the 250 ms fire-and-forget heuristic; single-rule contract (exit 0 / non-zero / 5 s timeout). Error table, R6, Resolved Items #6, and testing-strategy assertions all updated.
- **`.timedOut`** is now a real user-visible error case with retry toast (was previously marked silent-success).
- **C8 Worktree resolution** spelled out for `tc open`: no `TOUCH_CODE_PANE_ID` and no `<worktree>` arg → `EditorError.unresolvedWorktree`, CLI exits 2 with an explicit message. Does not fall through to Finder.
- **`SHELL` dropped** from the C8 env whitelist (aligned with C7's env stripping).
- **C7 `-M -C` only**; aliases `--find-renames --find-copies` removed (`-M -C` carry the same semantics).
- **C7 editor hand-off** renamed `openPath` → `openDirectory`, and the doc now explicitly says `Enter` opens the Worktree directory, not the file under the cursor.
- **C7 "Copy command"** now pastes `cd <absolute-worktree-path> && git …` with POSIX-single-quoted paths. Working / staged / commit variants documented.
- **C7 `shortID`** is now a computed property (`id.prefix(7)`), SHA-256-safe.
- **C7 "1.5× raw byte size"** speculation dropped.
- **C8 custom-editor ID regex** widened to `[a-z][a-z0-9_-]{1,31}` (underscores allowed).
- **C8 `Features/WorktreeHeader/`** tagged as a new feature folder not yet in architecture.md.

## Seams left for successor work

- C7: `git.*` IPC surface, LRU cache keyed on `(worktreeID, scope, HEAD)`, TreeSitter syntax highlighting, blame/graph log, commit-range diff.
- C8: file-level + line-level opens (`{file}`, `{line}` placeholders), per-editor "new window" flag, recent-editor memory.

## Notes for human review

- C8 mechanism diverges from supacode's Launch Services approach; rationale in Alternatives A1. Xcode is the one case where LS creeps back in because Xcode ships no CLI.
- Both docs follow the `_template.md` structure plus the existing `0001` doc's idioms (Resolved Items section, Seams subsection).
=======
Verified: `xcodebuild -scheme touch-code build` and `-scheme tc build` succeed; `-scheme touch-code test` passes 454/454 (including new `EditorHandlers` path + `GitViewerFeature` stale-scope tests); `-scheme TouchCodeCore test` passes 184/184. Base was already post-C6 merge (`caba2bd`) — no rebase needed.
>>>>>>> Stashed changes
