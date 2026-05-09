# ExecPlan: Redesign `tc` CLI Surface

**Status:** Completed
**Author:** Codex
**Date:** 2026-05-09

This is a living document. The Progress, Surprises & Discoveries, Decision Log, and Outcomes & Retrospective sections must be kept up to date as work proceeds.

## Purpose

After this change, `tc` exposes a smaller, more predictable command surface aligned with <https://clig.dev/>: concise help, consistent verbs, machine-readable JSON on stdout, human diagnostics on stderr, and clear exit codes. The CLI is not backward compatible with the old command names. It remains a stateless thin RPC client over the existing `TouchCodeIPC` methods.

## Progress

- [x] Review current CLI implementation and clig.dev guidance — 2026-05-09
- [x] Choose Option A: redesign CLI surface while preserving app-side IPC — 2026-05-09
- [x] Add testable command helper logic — 2026-05-09
- [x] Replace top-level command surface and split command files by resource — 2026-05-09
- [x] Regenerate shell completions — 2026-05-09
- [x] Validate with tests, build, and lint — 2026-05-09

## Surprises & Discoveries

- The current CLI uses ArgumentParser and a shared renderer already, but most hierarchy, terminal, tag, and RPC commands live in one large `HierarchyCommands.swift` file. The main risk is not parser technology; it is information architecture and drift-prone command implementation.
- Running `xcodebuild` against `touch-code.xcodeproj` skips SwiftPM dependencies generated into the workspace. CLI validation must use `touch-code.xcworkspace`, otherwise `ArgumentParser` cannot be resolved.
- The first `make mac-generate` in this worktree built Ghostty and took several minutes. Subsequent `tc` and `tcKit` builds were incremental.
- Repository-wide SwiftLint is currently blocked by pre-existing app and core test violations outside the redesigned CLI surface. A changed-file SwiftLint pass was used to validate this CLI patch.
- Manual CLI testing exposed two follow-up issues: `tc send --stdin` could wait on terminal stdin when text arguments were also present, and the app IPC server was not binding a live terminal input sink, so `terminal.sendInput` always reported no Ghostty runtime.
- Follow-up comparison with Prowl and Supacode showed the redesigned CLI still made discovery too stepwise. Prowl's effective pattern is a single tree listing plus current-pane defaults for terminal control; Supacode keeps resource groups but relies on focused context for common actions.

## Decision Log

- **DEC-1:** Keep `TouchCodeIPC` method names and app-side handlers unchanged. This limits the blast radius to the CLI and avoids coupling a UX redesign to socket server behavior.
- **DEC-2:** Prefer singular resource command groups for every entity operation, including list (`tc project list`, `tc worktree list`, `tc tab list`, `tc pane list`). Keep `tc ls` as the cross-entity discovery shortcut.
- **DEC-3:** Rename shell integration from `tc system completions` to `tc completion <shell>`, and expose common app status commands at the top level (`tc status`, `tc launch`, `tc doctor`).
- **DEC-4:** Remove the `tc rpc` escape hatch from the public CLI surface. The typed command tree is the supported interface; raw RPC access is kept internal.

## Outcomes & Retrospective

The CLI now presents a resource-oriented, clig.dev-aligned command tree:

- App commands: `tc status`, `tc launch`, `tc doctor`, `tc completion <shell>`.
- Resource list commands: `tc project list`, `tc worktree list`, `tc tab list`, `tc pane list`.
- One-shot discovery: `tc ls` lists Projects, Worktrees, Tabs, and Panes in one hierarchy.
- Mutation command groups: `tc project`, `tc worktree`, `tc tab`, `tc pane`.
- Terminal IO commands: `tc send` and `tc broadcast`, both with `--stdin` support.
Raw RPC access is intentionally not exposed as a CLI command.

The app-side IPC protocol was intentionally preserved. The old CLI surface is removed rather than shimmed.

Follow-up testing hardened the first-run CLI behavior:

- `tc send` and `tc broadcast` now reject mixed text arguments plus `--stdin` before reading stdin.
- `--stdin` now reports a clear error when stdin is an interactive terminal instead of blocking indefinitely.
- The running app now binds `terminal.sendInput` to `TerminalEngine` when Ghostty runtime is live, so CLI terminal input reaches app panes after rebuilding and relaunching the app.
- `tc send` now follows Prowl's common case: one argument sends text to the current pane, two arguments are target plus text, `-p/--pane` supplies an explicit target, and trailing Enter is sent by default unless `--no-enter` is set.
- `tc pane focus <pane-id>` and related pane locator commands now infer Project, Worktree, and Tab from the catalog when a pane id is enough.
- The terminal Enter byte is now carriage return (`\r`), matching terminal input semantics. Plain newline could visibly wrap without executing the command in Ghostty-backed panes.
- `tag` and `tags` are not part of the current CLI surface.

## Context and Orientation

Related documents:
- Architecture: `docs/architecture.md`
- Original CLI design: `docs/design-docs/c4-cli.md`
- Completed CLI implementation plan: `docs/exec-plans/0003-hooks-and-cli.md`

Key source files:
- `apps/mac/tc/TouchCodeCLI.swift` — ArgumentParser root and global options.
- `apps/mac/tc/Commands/HierarchyCommands.swift` — current large command aggregate; to be replaced by resource-specific files.
- `apps/mac/tc/Commands/SystemCommand.swift` — current system command group and shared CLI session/error helpers.
- `apps/mac/tc/Commands/OpenCommand.swift` — editor handoff command; retained with clearer top-level help.
- `apps/mac/tcKit/Transport/RPCClient.swift` — shared JSON-RPC client; unchanged except for any small helper additions needed by tests.
- `apps/mac/tcKit/Render/Renderer.swift` — shared stdout renderer; unchanged unless needed for clig.dev output consistency.

## Plan of Work

Milestone 1 creates small pure helpers for command text handling so parser behavior that does not require a socket can be tested in `tcKitTests`. This includes joining variadic command text and validating exactly-one scope rules.

Milestone 2 replaces the command surface. The new root commands are `status`, `launch`, `doctor`, `completion`, `open`, `ls`, `project`, `worktree`, `tab`, `pane`, `send`, and `broadcast`. List operations live under their singular entity groups, e.g. `tc project list` and `tc pane list`.

Milestone 3 splits implementation files by resource: system/app commands, projects, worktrees, tabs, panes, terminal IO, and open. Shared CLI session and error handling move out of `SystemCommand.swift` into a common file.

Milestone 4 regenerates bash, zsh, and fish completion resources from the new ArgumentParser tree.

## Concrete Steps

Run from repository root:

```bash
xcodebuild test -scheme tcKit -destination 'platform=macOS'
xcodebuild build -scheme tc -destination 'platform=macOS'
make mac-lint
```

If generated Xcode project state is stale, run:

```bash
make mac-generate
```

## Validation and Acceptance

Acceptance:
- `tc --help` lists the redesigned top-level commands.
- `tc completion zsh` prints a completion script for the redesigned command tree.
- `tc send` and `tc broadcast` preserve existing RPC behavior while adding stdin-friendly argument handling.
- JSON mode remains stdout-only and error paths remain stderr-only.
- `tcKit` tests pass and `tc` builds.

## Idempotence and Recovery

The work is source-only and can be repeated safely. Completion files are generated artifacts from the current command tree and may be regenerated after any parser change. No persistence migration is involved.

## Artifacts and Notes

- Replaced `apps/mac/tc/Commands/HierarchyCommands.swift` and `apps/mac/tc/Commands/SystemCommand.swift` with smaller resource-specific command files.
- Added `apps/mac/tcKit/CLIArgumentHelpers.swift` and focused parser/helper tests.
- Regenerated `apps/mac/tc/Resources/completions/tc.bash`, `tc.fish`, and `tc.zsh`.
- Validation passed:
  - `xcodebuild test -workspace touch-code.xcworkspace -scheme tcKit -destination 'platform=macOS'`
  - `xcodebuild build -workspace touch-code.xcworkspace -scheme tc -destination 'platform=macOS'`
  - `xcodebuild build -workspace touch-code.xcworkspace -scheme touch-code -destination 'platform=macOS'`
  - Changed Swift files linted with SwiftLint script input mode.
  - Built `tc --help` shows the redesigned top-level commands.
  - Built `tc send -h` documents current-pane targeting, target-plus-text usage, and `--no-enter`.
  - Built `tc ls -h` documents one-shot hierarchy discovery.
  - Built `tc completion zsh` emits a completion script for the redesigned command tree.
- `TouchCodeTests` targeted app tests could not be run through the current `touch-code` scheme because the test target is not included in the selected scheme/test plan.
- Repository-wide `make mac-lint` still fails on unrelated existing violations under `touch-code/App/...` and `TouchCodeCoreTests/...`.

## Interfaces and Dependencies

Use Apple ArgumentParser for all parser behavior. Continue using `tcKit.RPCClient`, `tcKit.Renderer`, `TouchCodeCore`, and `TouchCodeIPC`; do not import app-side modules from `tc`.
