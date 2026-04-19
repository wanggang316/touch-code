# Mission complete — C7 + C8 design docs

Worktree: `design+c7-c8-viewer-editor` · Branch: `worktree-design+c7-c8-viewer-editor` · Date: 2026-04-20

## Deliverables

- `docs/design-docs/c7-git-viewer.md` (444 lines) — read-only git diff/history viewer.
- `docs/design-docs/c8-editor-integration.md` (430 lines) — external editor handoff.
- `docs/design-docs/README.md` index updated with both.

## C7 — key decisions

- Shell out to `git` via `Process` (not libgit2). 16 MiB output cap, 10 s timeout, env stripped of `GIT_*` redirectors.
- TCA feature (`GitViewerFeature`) + pure data layer in `touch-code/Git/` (protocol `GitService`, hand-rolled unified-diff parser).
- Worktree-scoped; no caching in v1. Plaintext monospace; `LazyVStack`; 50 000-line soft cap with "open externally" fallback.
- Keyboard-first: `j`/`k`/`g`/`G`/`Tab`/`Enter`/`r`/`1/2/3`/`.`/`/`. `Enter` delegates to C8.
- No IPC in v1; `git.*` namespace reserved as seam.

## C8 — key decisions (resolves Open Question #7)

- CLI wrappers over `Process` for everything: `code`, `cursor`, `zed`, `subl`, `open -a Xcode`, `open` (Finder). Launch Services used only to locate Xcode.
- `$PATH` probe at startup (cached; refreshed on Settings open / IPC `editor.describe`).
- Fallback chain: explicit → `Project.defaultEditor` → `Settings.defaultEditorID` → Finder. **No silent fallthrough** on missing preferred editor.
- User-defined templates: `binary` + `args` with exactly one `{dir}` placeholder; regex-validated ID.
- `tc open [--in <editor>] [<worktree>]` → IPC `editor.open` (worktree defaults to the invoking Panel's Worktree).
- Single `ProcessSpawner` seam for full mock-Process testability.

## Seams left for successor work

- C7: `git.*` IPC surface, LRU cache keyed on `(worktreeID, scope, HEAD)`, TreeSitter syntax highlighting, blame/graph log, commit-range diff.
- C8: file-level + line-level opens (`{file}`, `{line}` placeholders), per-editor "new window" flag, recent-editor memory.

## Notes for human review

- C8 mechanism diverges from supacode's Launch Services approach; rationale in Alternatives A1. Xcode is the one case where LS creeps back in because Xcode ships no CLI.
- Both docs follow the `_template.md` structure plus the existing `0001` doc's idioms (Resolved Items section, Seams subsection).
