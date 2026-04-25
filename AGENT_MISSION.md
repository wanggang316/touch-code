# Mission: PR #4 REQUEST_CHANGES fixes (C7 viewer + C8 editor wire-in)

You are an autonomous agent in git worktree `fix+c7-c8-viewer-editor` (branch `worktree-fix+c7-c8-viewer-editor`, based on `main`). The user is asleep; make best-judgement calls.

## Context — URGENT

PR #4 (merged commit `caba2bd`) shipped C7 viewer + C8 editor. Two runtime BLOCKERS + one TCA race:

1. **`editor.*` IPC is not wired.** `TouchCodeApp.swift:174-182` builds `MethodRouter` with only hook/system/hierarchy/terminal handlers. `EditorHandlers` is instantiated nowhere outside tests. `tc open` falls through to `notWired`.
2. **CLI↔server wire mismatch for `editor.open`.** `apps/mac/tc/Commands/OpenCommand.swift` sends `EditorOpenParams { worktreeID, path, editor }`. Server wire is `EditorOpenRequest { worktreeID, preferred, panelID }` (`apps/mac/TouchCodeIPC/Editor/EditorIPCTypes.swift:74-88`). `tc open --in zed` silently drops preference; `tc open --path` has no target field on the wire.
3. **`GitViewerFeature` scope-switch stale-result race.** Late `.logSucceeded` after user switched to `.working` paints stale state.

Critical findings + file:line anchors are embedded below — no other review doc to read.

## Dependency

`fix+c6-agent-notifications` also edits `TouchCodeApp.swift`. **Order: after C6 merges, rebase on main; resolve conflicts in `bringUp()` / `startIPC`.** Until merged, base off current main; resolve at end.

## Your deliverables (each its own commit)

### Commit 1 — Unify editor IPC DTOs (BLOCKER part 1)

**Files:**
- `apps/mac/tc/Commands/OpenCommand.swift` (lines 56, 88-92)
- `apps/mac/TouchCodeIPC/Editor/EditorIPCTypes.swift`
- `apps/mac/TouchCodeIPC/Method.swift` (line ~21 — confirm `editorDescribe`/`editorSetDefault` cases exist or add)

**Fix:**
- Delete ad-hoc `EditorOpenParams` / response struct in `OpenCommand.swift`. Import `EditorOpenRequest` + `EditorOpenResponse` from `TouchCodeIPC`; use across the wire.
- Extend `EditorOpenRequest` with `path: String?` (optional). `EditorHandlers.open` must handle it — when present, open that path instead of snapshot root. Validate path within worktree root (reuse `EditorService+Live.swift:139-145` guard pattern).
- CLI decodes canonical server `EditorOpenResponse { choice, worktreePath }`.
- Add round-trip test: `EditorOpenRequest` JSON encode/decode stability at IPC boundary.

### Commit 2 — Wire EditorHandlers into MethodRouter (BLOCKER part 2)

<<<<<<< Updated upstream
1. Run `/hs-design` for C3 first. Resolve **Open Question #4** (hook execution model) inside the doc — recommend out-of-process-first (spawn user binary with env + JSON stdin) and explain why. Reference ghostty event hooks + supacode hooks if they exist.
2. Run `/hs-design` for C4. Resolve **Open Question #1** (CLI name) — keep `tc`, fallback `tcode` — and document collision check plan. Define the full command surface: `tc space|project|worktree|tab|pane|send|broadcast|skill|open|hook`. Anchor every command to an HierarchyManager/CatalogStore operation in TouchCodeCore.
3. Each doc must include:
   - Scope & non-goals (align with product-spec exclusions)
   - Public interfaces (Swift types, exact signatures, IPC wire protocol additions)
   - Data model changes (`TouchCodeCore` types to add)
   - Dependency direction (no cycles with Runtime / Ghostty / IPC)
   - Error handling model
   - Rollout plan (flag gates, back-compat)
   - **Decisions** section: every judgement call with rationale (supacode-parallel or not)
   - Testing strategy
   - Open risks
=======
**File:** `apps/mac/touch-code/App/TouchCodeApp.swift`
>>>>>>> Stashed changes

**Fix:**
- In `startIPC`, after `TerminalHandlers` construction (~line 170-173), construct `EditorHandlers(editor: editorClient, hierarchy: manager)` (read actual init signature first).
- Pass to `MethodRouter(...)`. Extend `MethodRouter` init to accept `editorHandlers`; route `.editorOpen` / `.editorDescribe` / `.editorSetDefault` to it.
- `editorClient` is already constructed in `bringUp()` around line 128 — pass that same instance into `startIPC`; DO NOT re-construct.

⚠ Keep edits localized to `startIPC`. `fix+c6-agent-notifications` also edits this file — your changes must not reformat unrelated blocks.

### Commit 3 — GitViewerFeature scope race fix

**File:** `apps/mac/touch-code/App/Features/GitViewer/GitViewerFeature.swift:164-176, 201, 274-282`

**Fix (pick simpler of two):**
- **Option A (recommended):** Change `.logSucceeded` / `.diffSucceeded` payload to carry originating `scope`. In reducer, guard `guard scope == state.scope else { return .none }`.
- **Option B:** On `scopeChanged`, also emit the OPPOSITE `.cancel(id:)`.
- Test: advance reducer with stale-scope result action, assert state unchanged.

### Commit 4 — Polish (pick 2+)

- `Git/GitOutputParser.swift:86-93` — add `guard chars[2] == " "` before `chars[3...]`.
- `Git/LiveGitService.swift:92-101` — `ensureIsRepo` parse stdout, require `"true"`.
- `Git/LiveGitService.swift:117-118` — when stderr present and exit != 0, prefer that error over `outputTooLarge`.
- `App/Features/GitViewer/LargeDiffCommand.swift:26` — `precondition(GitShaValidator.isValid(resolved))`.
- `App/Features/Settings/SettingsStore.swift:152-164` — sanitize per-user custom editor IDs colliding with built-ins on load.

Skip symlink-mode→regular file type-change detection in `DiffParser` (hard, low impact).

## Guardrails

- **Scope:** `apps/mac/tc/Commands/OpenCommand.swift`, `apps/mac/TouchCodeIPC/`, `apps/mac/touch-code/App/Features/Socket/EditorHandlers.swift`, `apps/mac/touch-code/App/Features/GitViewer/`, `apps/mac/touch-code/Git/`, `apps/mac/touch-code/App/Features/Settings/`, tests. NOT `Notifications/`, `Hooks/`, `App/Clients/InboxClient.swift`.
- `TouchCodeApp.swift` — additive edits only in `startIPC`. Must rebase against C6 PR at end.
- **Do NOT commit** changes to `AGENT_MISSION.md` / `AGENT_MISSION_DONE.md` / `CLAUDE.md`.
- Commit prefixes: `feat(editor)`, `fix(editor)`, `fix(viewer)`, `fix(git)`, `test(editor)`.

## Completion

1. Wait for C6 PR merge signal OR rebase defensively.
2. Run tests locally.
3. `git pull --rebase origin main` (if C6 merged).
4. `git push -u origin worktree-fix+c7-c8-viewer-editor`
5. `gh pr create --base main --head worktree-fix+c7-c8-viewer-editor`
6. Overwrite `AGENT_MISSION_DONE.md` with 15-line summary.

Start now.
