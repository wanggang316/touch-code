# Product Spec: touch-code

**Last Updated:** 2026-04-19

## Product Overview

### Problem

Developers who already live inside CLI coding agents (Claude Code, Codex CLI, aider, etc.) are forced to work in environments that treat the agent as a second-class citizen. They juggle multiple projects across tiled OS windows, run parallel features through git worktrees that each need their own terminal setup, and receive agent output scattered across disconnected terminal sessions with no unified orchestration. Today they cope with tmux scripts, window managers, and shell aliases — none of which understand projects, worktrees, or agent lifecycles as first-class concepts.

### Solution

A native macOS application, built on libghostty, that treats **terminals as the primary surface** and orchestrates them into a five-level hierarchy: Space → Project → Worktree → Tab → Panel. It exposes terminal lifecycle hooks and a CLI so coding agents become first-class citizens — their output can be aggregated, their completion can trigger cross-panel actions, and their worktree-per-feature workflow takes zero ceremony. A lightweight read-only diff/history viewer handles quick git inspection in-app. **touch-code is deliberately not an IDE** — for reading or editing code, it opens the user's preferred external editor (VSCode, Cursor, Zed, Xcode, Sublime Text, Finder, etc.) with one command or click.

## Target Users

| Role | Scenario | Core Need |
|---|---|---|
| CLI-agent power user (solo dev / senior engineer) | Actively works on 3+ projects per day; uses git worktrees to run multiple features in parallel within a single project; drives most coding through a CLI agent | Unified orchestration of projects and worktrees; frictionless worktree creation; aggregated agent notifications; scriptable CLI control over every Panel |

**Explicitly not targeted (v1):**
- Developers who prefer GUI-first IDE workflows (VSCode / JetBrains users without CLI agent adoption)
- Teams needing collaborative / shared sessions
- Windows-native users (covered in Future Consideration)

## Core Capabilities

| # | Capability | Description | Status | Maturity |
|---|---|---|---|---|
| C1 | Terminal engine | libghostty-based multi-panel terminal rendering and lifecycle management | Planned | Alpha |
| C2 | Space / Project / Worktree / Tab / Panel hierarchy | Five-level organization: Space groups Projects; Project maps to a git repo; Worktree maps to a `git worktree`; a Worktree holds one or more Tabs; a Tab holds one or more Panels (split layouts); a Panel is a single libghostty-rendered terminal session. Switching at any level is instant and stateful | Planned | Alpha |
| C3 | Lifecycle hooks | Programmable hooks at Panel create / ready / output / idle / exit, plus Tab and Worktree activation events; enables agent notifications, command injection, custom automation | Planned | Alpha |
| C4 | CLI (`tc`) | A command-line interface for controlling Spaces, Projects, Worktrees, Tabs, and Panels from inside any Panel — including cross-panel messaging | Planned | Alpha |
| C5 | Skills system | Pluggable capability modules (borrowed conceptually from supaterm): packaged bundles of hooks, CLI commands, and UI surfaces | Planned | Alpha |
| C6 | Agent notification aggregation | Detect agent completion / blocking-on-input states via hooks; surface as OS notifications, badge counts, and in-app inbox | Planned | Alpha |
| C7 | Git diff / history viewer | Read-only viewer for diffs and commit history of the current Worktree — a quick inspection surface, not a code-review or editing tool; no write operations | Planned | Alpha |
| C8 | External editor integration | Open the current Worktree directory in an external editor or file manager (VSCode / Cursor / Zed / Xcode / Sublime Text / Finder, etc.) via CLI (`tc open`) or a button on the Worktree header; default editor configurable globally and per-Project. Worktree-level only — no file-level or diff-level open in v1 | Planned | Alpha |

### Capability Dependencies

```
C1 Terminal engine (libghostty)
 ├── C2 Space / Project / Worktree / Tab / Panel hierarchy
 │    ├── C7 Git diff / history viewer    (reads the Worktree C2 selects)
 │    └── C8 External editor integration  (opens the current Worktree directory)
 └── C3 Lifecycle hooks
      ├── C4 CLI (`tc`)                   (invokes hooks, dispatches across Panels; also exposes `tc open`)
      │    └── C5 Skills system           (skills register CLI subcommands + hooks)
      └── C6 Agent notification aggregation   (consumer of hooks)
```

**Reading the graph:** C1 is the foundation. C2 and C3 sit directly on it and are independent of each other — the hierarchy model doesn't need hooks, and hooks don't need the hierarchy. C4 is the programmable surface layer on top of C3. C5 formalizes the contribution model shared by C3 + C4. C6 is the first built-in consumer of C3 (and validates the hook design). C7 and C8 are independent specialized consumers of C2's Worktree context: C7 handles diff/history inspection, C8 is a simple Worktree-level handoff to an external editor or file manager. The two do not interact in v1.

## Product Boundaries

### In Scope

- Native macOS application; universal binary (Apple Silicon + Intel)
- libghostty-backed terminal rendering with full escape sequence support (inherits ghostty's capability)
- Within a Worktree: multiple Tabs; within a Tab: multiple Panels via split layouts (tiling and stacking)
- Persistent Space / Project / Worktree / Tab / Panel state across restarts (including split geometry)
- Git worktree creation, listing, switching, and removal from within the app
- Lifecycle hooks (Panel created / ready / output match / idle / exit; Tab activated; Worktree activated)
- `tc` CLI auto-injected into every Panel's PATH
- Cross-panel messaging via CLI (e.g. `tc send <panel-id> <cmd>`, `tc broadcast --tab <tab-id> ...`)
- Skill packaging, discovery, install, enable/disable
- OS notifications for agent completion / attention-required
- In-app notification inbox with per-Panel provenance
- Read-only git diff viewer (working tree, staged, per-commit)
- Read-only git history viewer (log, commit details, file-level changes)
- External editor / file manager integration at the Worktree level: open the current Worktree directory in VSCode / Cursor / Zed / Xcode / Sublime Text / Finder and similar; configurable default editor (global and per-Project); CLI entry point (`tc open [--in <editor>]`); UI button on the Worktree header. File-level and diff-level open are explicitly out of scope for v1

### Out of Scope

**touch-code is deliberately not an IDE.** It does not read or edit source code as an IDE does. Every code-reading or code-editing need is handled by delegating to an external tool via C8, not by growing an editor surface inside touch-code. The exclusions below reinforce this boundary.

| Exclusion | Reason |
|---|---|
| Text editor / LSP / syntax-aware editing / in-app code reading | Vim, Neovim, Helix, VSCode, Cursor, Zed, Xcode, Sublime Text already solve this. C8 integrates with them; we do not reimplement them. The in-app git viewer (C7) is deliberately limited to diff/history inspection, not full-file reading |
| Self-built coding agent | Users already have Claude Code / Codex CLI / aider; we build the **environment** they run in, not another agent |
| Git write operations (commit, merge, rebase, stash UI) | Terminal-first product; `git` CLI and `lazygit` already cover this; adding write UI dilutes focus |
| Team collaboration / shared sessions / co-editing | Individual power-user tool; collaboration is a different product with different architectural constraints |
| Windows-native support (v1) | Author and primary target are macOS users; covering Windows natively before validating the concept is premature |
| Web / remote / SSH / dev-container first-class support (v1) | Local-first product; remote workflows add IPC, auth, and latency concerns that would distort the v1 design |
| Building our own terminal emulator | libghostty exists and is excellent; reinventing tty/GPU rendering is a multi-year distraction |
| Package manager / dependency management | Out of scope — users invoke `npm`, `cargo`, `uv`, etc. inside Panels like they always have |

### Future Consideration

- **Git write operations** — after the read-only viewer proves useful, evaluate selective write UI (stage/unstage, quick commit from diff)
- **Linux support** — after macOS version validates the product; libghostty is cross-platform so porting cost is moderate
- **Remote / SSH / dev-container workflows** — Spaces that live on remote hosts, with local Panels that attach transparently
- **Windows support** — evaluate after macOS + Linux; depends on libghostty Windows maturity
- **Team / shared sessions** — only if demand emerges from solo usage; would be a major architecture shift

## Key Concepts

| Term | Definition | Not to Be Confused With |
|---|---|---|
| Space | Top-level workspace grouping; contains one or more Projects. Roughly one Space per role/context (e.g. "day job", "side project", "research") | macOS "Spaces" (virtual desktops) — unrelated |
| Project | A single git repository tracked by touch-code; lives inside one Space | A VSCode "workspace" — touch-code Projects are always git-backed and scoped to one repo |
| Worktree | A `git worktree` of a Project; each Worktree has its own directory, branch checkout, and Tab/Panel layout | A "branch" — a Worktree is a concrete checkout on disk; switching Worktrees switches directories, not just HEAD |
| Tab | A named grouping of Panels inside a Worktree; one Tab is visible at a time per Worktree. Roughly "one Tab per concurrent task" (e.g. "dev server", "agent", "test watcher") | A browser tab — touch-code Tabs are scoped to a Worktree, not to the whole app |
| Panel | A single terminal session rendered by libghostty; lives inside a Tab. Multiple Panels per Tab form split layouts | A tmux/iTerm "pane" — same idea, but touch-code uses the term "Panel" consistently; also not an OS window |
| Hook | A programmable callback fired at defined Panel / Tab / Worktree lifecycle events | A shell hook (e.g. zsh `preexec`) — touch-code hooks are app-level and cross-Panel-aware |
| Skill | A packaged module contributing hooks, CLI subcommands, and optional UI | A Claude Code "skill" — conceptually similar but scoped to touch-code's runtime |
| CLI (`tc`) | The command-line interface injected into every Panel; controls the app from inside a shell | A system command like `tmux` — `tc` talks to the running touch-code app, not to a separate server |

## Non-Functional Requirements

| Category | Requirement | Target |
|---|---|---|
| Performance | Cold start time | < 1.0s to first interactive Panel on M1+ |
| Performance | Panel / Tab switch latency | < 16ms (single frame at 60Hz) |
| Performance | Terminal rendering | Full libghostty throughput; no regression vs. standalone Ghostty |
| Resource | Idle CPU usage | ~0% with 8 idle Panels |
| Resource | Memory per idle Panel | < 50MB |
| Reliability | Panel crash isolation | A single Panel crash must not bring down other Panels, its Tab, or the app |
| Reliability | State durability | App-level crash must not lose Space / Project / Worktree / Tab / Panel configuration |
| Compatibility | macOS version floor | macOS 13 (Ventura) or higher, aligned with libghostty minimum |
| Compatibility | Architecture | Universal binary (arm64 + x86_64) |
| Security | Hook / Skill sandboxing | Skills run with user privileges; no elevated sandbox needed for v1, but skill source must be inspectable before install |

## Success Metrics

| Metric | Target | Current | Measurement |
|---|---|---|---|
| Personal daily driver | Author (Gump) uses touch-code as primary terminal for ≥ 5 days/week, fully replacing prior terminal + IDE terminal usage | N/A (pre-build) | Self-report, weekly check-in during dogfooding phase |
| Worktree workflow adoption | Avg. active Worktrees per Project ≥ 2 across the user's projects | N/A | App telemetry (local only, opt-in) |
| Agent notification effectiveness | ≥ 80% of agent-completion notifications lead to the user returning to the correct Panel within 30s | N/A | Local telemetry correlating notification delivery with Panel focus events |
| Skill ecosystem (long-term) | ≥ 5 third-party Skills published within 6 months of public release | N/A | Skill registry count |
| Retention (long-term) | DAU / MAU ≥ 0.7 among installed users | N/A | Opt-in anonymous telemetry |

## Open Questions

1. **CLI binary name** — `tc` is short and ergonomic but collides with common aliases (e.g. traffic control on Linux, generic "this code"). Alternatives: `touch`, `tch`, `tcode`. **Blocks:** packaging, documentation. *Leaning: `tc` with collision check on install; fallback `tcode`.*
2. **Skill distribution model** — Git-URL-based install (like Claude Code skills) vs. a centralized registry vs. both. **Blocks:** skill system API design. *Leaning: Git-URL first, registry later.*
3. **Non-git Projects** — Do we allow a "Project" that isn't a git repo (e.g. a scratch folder)? If yes, what happens to Worktree-related UI? **Blocks:** Project model definition. *Leaning: allow, but Worktree features become inert.*
4. **Hook execution model** — In-process (JS-like scripting) vs. out-of-process (spawn a user-chosen binary with env vars) vs. both. **Blocks:** hook API and skill architecture. *Leaning: out-of-process first for simplicity and language-agnostic skills; in-process as optimization later.*
5. **Agent detection heuristic** — How does C6 know a Panel is running a "coding agent" vs. a plain shell? Options: explicit Panel labeling, known binary allowlist (`claude`, `codex`, `aider`), or hook-driven opt-in per Skill. **Blocks:** C6 implementation. *Leaning: hook-driven opt-in via Skills; no magic detection.*
6. **Worktree storage layout** — Where do new worktrees live on disk? Under the main repo's `.git/worktrees`? A sibling directory? User-configurable? **Blocks:** C2 implementation and user file-system expectations. *Leaning: sibling `<repo>-worktrees/<branch>` by default, configurable per Project.*
7. **External editor discovery & invocation (C8)** — How does the app discover installed editors, and what's the invocation contract for opening a Worktree *directory*? Options: built-in allowlist using documented CLI wrappers (`code <dir>`, `cursor <dir>`, `subl <dir>`, `zed <dir>`, `open -a Xcode <dir>`, `open <dir>` for Finder), macOS Launch Services lookup, or user-defined shell commands only. **Blocks:** C8 implementation and onboarding UX. *Leaning: ship a small built-in allowlist (VSCode, Cursor, Zed, Xcode, Sublime Text, Finder) with known directory-open CLI contracts; allow arbitrary user-defined templates in config for anything else. Simple because v1 only opens directories — no file + line number mapping needed.*
