# Architecture

## Overview

touch-code is a native macOS application that orchestrates terminals into a five-level hierarchy (Space → Project → Worktree → Tab → Panel) for CLI-agent power users. See [Product Spec](product-spec.md) for capabilities and boundaries.

The system is a **Tuist-managed monorepo** because the product ships three co-versioned artifacts — the Mac app, the `tc` CLI, and the published Agent Skill — whose development benefits from atomic cross-cutting changes (protocol edits, CLI contract changes, domain-model evolution) and shared tooling.

Architecture is adapted from two reference projects the user maintains and encourages borrowing from: **supacode** and **supaterm**. See [References](#references) for file anchors. The structural shape — Swift 6, Tuist, libghostty-via-submodule, hybrid TCA + `@Observable`, JSON-RPC over Unix socket, out-of-process shell hooks — is lifted from these projects because they have already validated the pattern on the same workload touch-code targets.

## Codemap

### Apps

| Package | Purpose |
|---|---|
| `apps/mac` | Main macOS app (`@main TouchCodeApp.swift`). Hosts UI, libghostty runtime, IPC server, and all features |
| `apps/cli` | `tc` binary (ArgumentParser). Communicates with the running app over a Unix domain socket using JSON-RPC |

### Packages

| Package | Purpose |
|---|---|
| `packages/Core` | Pure domain types: Space/Project/Worktree/Tab/Panel models, `SplitTree`, stable UUID identifiers. Zero external dependencies. |
| `packages/IPC` | JSON-RPC wire protocol: Request/Response envelopes, Method constants, payload types, socket discovery helpers. Shared between app and CLI. |
| `packages/Runtime` | libghostty integration: GhosttyKit Swift bindings, Panel lifecycle management, Surface rendering adapter, `@Observable` runtime state. |
| `packages/Hooks` | Lifecycle event taxonomy (Panel created / ready / output match / idle / exit; Tab activated; Worktree activated), hook registration, out-of-process shell handler dispatch. |
| `packages/Git` | Read-only git data access: diff parsing, log enumeration, commit detail extraction. No write operations. |

### Non-Swift directories at the repo root

| Path | Purpose |
|---|---|
| `touch-code-skill/` | A Claude Code / Codex / pi Agent Skill (`SKILL.md` + `references/` + `agents/`). Co-located for version alignment with the CLI but **not a Swift target** — not imported by anything, not built, not signed. Distributed to coding agents via `tc skill install` or `npx skills add`. |
| `ThirdParty/ghostty` | Git submodule pointing at `ghostty-org/ghostty`. Built into `.build/ghostty/GhosttyKit.xcframework` by `scripts/build-ghostty.sh` using Zig (pinned via `mise.toml`). |
| `scripts/` | Build and release scripts (`build-ghostty.sh`, release tooling) |
| `docs/` | Project documentation (this file, product-spec, design-docs, exec-plans, references) |
| `mise.toml` | Pinned versions for `tuist`, `zig`, `swiftlint`, `xcbeautify` |
| `Project.swift`, `Workspace.swift`, `Tuist/` | Tuist project definitions |

## Dependency Direction

```
packages/Core                               (leaf — zero internal deps)
    │
    ├── packages/IPC                        (Core)
    ├── packages/Hooks                      (Core)
    ├── packages/Runtime                    (Core + GhosttyKit.xcframework)
    └── packages/Git                        (Core)
                │
                ├── apps/mac                (Core, IPC, Hooks, Runtime, Git + external deps)
                └── apps/cli                (Core, IPC — nothing else)

touch-code-skill/                           (orthogonal — no Swift dependency;
                                             consumed by coding agents, not by the app)
```

**Rules:**
- `apps/cli` must NEVER depend on `Runtime`, `Hooks`, or `Git` — it is a thin RPC client; no libghostty, no hook dispatch, no git parsing in the CLI binary
- `apps/mac` and `apps/cli` must NEVER import each other; they communicate only through `packages/IPC`
- `packages/Core` must have zero imports from any other internal package — it is the universal leaf
- No circular dependencies between packages
- `touch-code-skill/` must not import or reference any Swift target — it is pure markdown + reference content

**Enforcement:**
- Tuist target `dependencies:` lists in `Project.swift` — each target declares exactly which packages it depends on
- CI job runs `make inspect-dependencies` (matches supacode's target) to catch implicit cross-imports
- SwiftLint custom rule blocking `import Runtime` / `import Hooks` / `import Git` in any file under `apps/cli/`
- Code review: PRs that add a forbidden edge are rejected

## Architectural Invariants

Rules not visible in code. Violating any of these will not fail tests immediately but will rot the system.

- **Panel state mutability is localized to `Runtime`.** Panel scrollback, cursor, and selection are mutable only inside `packages/Runtime`. Other layers read via `@Observable` bindings or event streams; they must not call mutators directly.
- **All cross-process communication goes through `packages/IPC`.** No other channel between `apps/cli` and `apps/mac`. No HTTP, no TCP, no file-based queues, no shared memory.
- **Hooks are out-of-process only in v1.** Hook handlers execute as shell commands fork-exec'd by the app, receiving JSON on stdin and returning JSON on stdout. In-process handlers (embedded JS, WASM) are explicitly deferred.
- **State management is hybrid by design, with a clear boundary.** High-frequency terminal state uses `@Observable`; app flow state uses TCA. Mixing the two patterns within a single feature is a red flag. See [State Management](#state-management-hybrid-tca--observable).
- **Persistence is atomic-rename JSON with a top-level `version: Int`.** All files under `~/.config/touch-code/` include a schema version. Readers that encounter an unknown version abort rather than silently upgrade. Writers write to a temp file and rename over the original.
- **`tc` is stateless.** The CLI has no persistent state of its own. All truth lives in the running app; `tc` is a thin RPC client. Adding file reads/writes in `apps/cli` requires a design doc.
- **Identifiers are UUIDs.** Every Space, Project, Worktree, Tab, Panel has a stable UUID. Index-based addressing (`tc panel focus 1/2/3`) is convenience sugar resolved to a UUID before any state mutation. Internal code must use UUIDs.
- **Agent Skill is consumed, never loaded.** The app must not parse, index, or invoke `SKILL.md`. The only skill-related runtime code is the `tc skill install` helper, which copies files to the agent's skill directory.
- **`packages/Runtime` is TCA-free.** Runtime exposes `@Observable` classes and AsyncStream events. TCA bridging lives in `apps/mac` (the `*Client` types). This keeps Runtime independently testable and portable.

## Cross-Cutting Concerns

### State Management: Hybrid TCA + `@Observable`

**TCA (The Composable Architecture)** is used for:
- App shell (root reducer, launch flow)
- Feature flows: Settings, CommandPalette, GitViewer, HierarchyCatalog, Updates
- Socket server lifecycle
- Deeplink dispatch

**Swift Observation (`@Observable`)** is used for:
- `Runtime.PanelState` — libghostty surface, scrollback, cursor
- `Runtime.TerminalEngine` — manages N panels
- `HierarchyManager` — mutable tree of Spaces/Projects/Worktrees/Tabs/Panels

**Bridge:** `apps/mac/Clients/*Client.swift` exposes:
- **Commands** (TCA → runtime): `terminalClient.openPanel(in: worktree)`, `terminalClient.sendInput(panel, text)`
- **Events** (runtime → TCA): `terminalClient.events()` returns an `AsyncStream<TerminalEvent>` the root reducer subscribes to and maps to `Action.terminal(...)`

Rationale: agent-heavy panels produce thousands of output events per second; routing every byte through a TCA reducer is a known anti-pattern (value-type state diffs, Effect allocation, Equatable checks). Both reference projects ended at this split — supacode explicitly; supaterm implicitly via reference-type state within TCA.

### IPC

- **Transport:** Unix domain socket, one per running app instance, at `/tmp/touch-code-$UID.sock` by default; overridable via `TOUCH_CODE_SOCKET_PATH`
- **Wire protocol:** length-prefixed JSON envelopes. Framing: `\n`-terminated length header followed by the JSON body. Envelope shapes defined in `packages/IPC/Protocol.swift`:
  - Request: `{"id": "uuid", "method": "terminal.open_panel", "params": {...}}`
  - Success: `{"id": "uuid", "result": {...}}`
  - Error: `{"id": "uuid", "error": {"code": Int, "message": "…"}}`
- **Methods:** namespaced (`terminal.*`, `hierarchy.*`, `git.*`, `skill.*`, `system.*`)
- **Discovery in `apps/cli`:** env var `TOUCH_CODE_SOCKET_PATH` → default path probe → (optional) launch app and wait up to 10s
- **Context panel id:** the app sets `TOUCH_CODE_PANEL_ID` in each Panel's environment so `tc` commands run inside a Panel can default to that Panel's UUID without an explicit flag (mirrors `SUPATERM_PANE_ID`)

### URL scheme

- Scheme: `touch-code://`
- Examples: `touch-code://worktree/<id>/focus`, `touch-code://panel/<id>/send?text=...`
- Parsed by `apps/mac/Features/Deeplink/DeeplinkParser.swift`; maps onto the same IPC methods used by `tc`
- Routed through `DeeplinkConfirmationFeature` for user approval on sensitive actions (send, exec)

### Persistence

Files under `~/.config/touch-code/` (JSON, UTF-8, pretty-printed with sorted keys for determinism):

| File | Contents |
|---|---|
| `catalog.json` | Space → Project → Worktree → Tab → Panel tree with UUIDs, split geometry, current selection at every level |
| `settings.json` | User preferences (default external editor per Project, hook paths, feature toggles) |
| `hooks.json` | User-configured hook subscriptions (event → shell command + options) |

Writers always go through `packages/Core/Persistence.swift`:
1. Encode to temp file in the same directory
2. `fsync` temp file
3. `rename(2)` over original

Readers abort on unknown `version` field.

### Logging

- `os.Logger` with subsystem `com.touch-code.*`
- Per-package category: `com.touch-code.runtime`, `com.touch-code.ipc`, etc.
- `apps/cli` logs to stderr only; `--verbose` flag controls level
- No custom logger layer; no file-based logs in v1

### Error handling

- `packages/IPC` defines a small `IPCError` enum (e.g., `.unknownMethod`, `.invalidParams`, `.panelNotFound`, `.internal`)
- Domain errors stay inside their package; converted to `IPCError` only at the IPC boundary
- Panics (Swift fatalError) are reserved for invariant violations, never for user input

### Build toolchain

- `mise.toml` pins `tuist`, `zig`, `swiftlint`, `xcbeautify`
- `scripts/build-ghostty.sh` runs Zig to build `GhosttyKit.xcframework` from the submodule; uses fingerprint-based caching (git HEAD + local diff + mise.toml hash)
- Top-level `Makefile` orchestrates: `make bootstrap` (submodules + mise), `make build-ghostty`, `make generate` (Tuist), `make build`, `make test`

## Technology Choices

| Technology | Scope | Purpose | Rationale |
|---|---|---|---|
| Swift 6 | all | Language | Native macOS; libghostty has first-class Swift/C interop via GhosttyKit; aligns with both reference projects |
| Tuist 4 | workspace | Project + target generation | Modular Xcode workspace; cacheable builds via `warm-cache`; internal targets (`apps/*`, `packages/*`) declared in `Project.swift`. Same pattern as supacode/supaterm |
| SPM (via Tuist `Package.swift`) | workspace | External dependencies | Standard tool for fetching third-party libraries (TCA, ArgumentParser, Sparkle); integrated into Tuist |
| mise | workspace | Tool version pinning | Committed `mise.toml` pins `tuist`, `zig`, `swiftlint`, `xcbeautify`; guarantees reproducible first-clone builds |
| libghostty (via `ThirdParty/ghostty` submodule → Zig → `GhosttyKit.xcframework`) | `packages/Runtime` | Terminal emulator | Best macOS-native terminal renderer with a stable C API; building from submodule (not prebuilt XCFramework) matches supacode/supaterm and lets us patch Ghostty if needed |
| The Composable Architecture | `apps/mac` | App/UI state | Testable unidirectional flows for features (Settings, CommandPalette, GitViewer); proven in both reference projects |
| Swift Observation (`@Observable`) | `packages/Runtime`, parts of `apps/mac` | Runtime state | Hybrid complement to TCA for high-frequency terminal state; native Swift 6 feature; proven in supacode |
| ArgumentParser | `apps/cli` | CLI parsing | Apple's official CLI framework; same as both reference projects |
| Sparkle | `apps/mac` | Auto-update | De facto standard for macOS app updates; same as supacode |
| SwiftLint + swift-format | workspace | Lint + format | Style consistency; enforced in CI; configured via `.swiftlint.yml` and `.swift-format.json` |

## Entry Points

| Surface | File | Responsibility |
|---|---|---|
| App launch | `apps/mac/App/TouchCodeApp.swift` | `@main`, root TCA store construction, window lifecycle |
| CLI launch | `apps/cli/main.swift` | `ArgumentParser` root; dispatches to subcommand |
| Socket server | `apps/mac/Features/Socket/SocketServer.swift` | Accepts Unix socket connections, routes JSON-RPC to IPC methods |
| libghostty bootstrap | `packages/Runtime/GhosttyRuntime.swift` | Initializes `ghostty_app_t`, registers callbacks |
| Hook dispatcher | `packages/Hooks/HookDispatcher.swift` | Fan-out of lifecycle events to configured handlers |
| Deeplink handler | `apps/mac/Features/Deeplink/DeeplinkRouter.swift` | Receives `touch-code://` URLs, converts to IPC-equivalent actions |
| Persistence boundary | `packages/Core/Persistence.swift` | Atomic-rename JSON read/write with version checks |

## References

### Reference projects — borrow first, deviate with reason

- **supaterm** — `/Users/wanggang/dev/opensource/supaterm`
  - JSON-RPC wire protocol: `apps/mac/SupatermCLIShared/SupatermSocketProtocol.swift`
  - Agent hook JSON format: `apps/mac/SupatermCLIShared/SupatermAgentHook.swift`
  - `SplitTree<ViewType>` generic: `apps/mac/supaterm/Features/Terminal/Models/`
  - Persistence pattern + schema version: `apps/mac/supaterm/Features/Terminal/Models/TerminalSession.swift`
  - Ghostty submodule build: `apps/mac/scripts/build-ghostty.sh`

- **supacode** — `/Users/wanggang/dev/opensource/supacode`
  - Hybrid TCA + `@Observable` bridge: `supacode/Clients/Terminal/TerminalClient.swift`
  - AgentHookSocketServer: `supacode/Infrastructure/AgentHookSocketServer.swift`
  - Worktree terminal manager: `supacode/Features/Terminal/BusinessLogic/WorktreeTerminalManager.swift`
  - Deeplink parser: `supacode/Domain/Deeplink*`
  - `mise.toml` + `scripts/build-ghostty.sh` with fingerprint cache
  - Tuist modular targets: `Project.swift`

- **supaterm-skills** — `/Users/wanggang/dev/opensource/supaterm-skills`
  - Reference layout for our `touch-code-skill/`: `SKILL.md` + `references/` + `agents/`

### External references

- matklad, *ARCHITECTURE.md* — <https://matklad.github.io/2021/02/06/ARCHITECTURE.md.html>
- The Composable Architecture — <https://github.com/pointfreeco/swift-composable-architecture>
- Swift Observation — <https://developer.apple.com/documentation/observation>
- Ghostty — <https://ghostty.org>
- mise — <https://mise.jdx.dev>
- Tuist — <https://tuist.dev>

## Open Architectural Questions

1. **Internal Tuist target granularity in `apps/mac`.** Split each Feature into its own framework target (supacode pattern — slower clean build, better cache) vs. single app target with folder-level organization. **Blocks:** initial Tuist configuration. *Leaning:* separate framework targets for heavy features (Terminal, Hierarchy, GitViewer); single target for the rest.

2. **Multi-window semantics.** macOS users expect multiple windows. Does each window get its own Space selection, or is Space selection global? **Blocks:** hierarchy state design + persistence schema. *Leaning:* window ↔ Space 1:1; Spaces are window-scoped; multi-window opens new Space from a chooser.

3. **CLI binary distribution.** Auto-symlink `tc` to `/usr/local/bin/` on first app launch (requires Admin) vs. require manual `tc install-cli` (stash a copy in `~/.local/bin` and offer to update PATH). **Leaning:** manual install to `~/.local/bin` on first launch prompt; avoid touching system paths.

4. **Hook handler execution policy.** Serial per event vs. concurrent with a cap. **Blocks:** `packages/Hooks` scheduler. *Leaning:* concurrent with a global cap (default 8); single-handler-at-a-time flag per hook subscription as opt-in.

5. **IPC backpressure.** If a CLI client issues requests faster than the app can process, do we queue unbounded, drop, or block? *Leaning:* per-connection bounded queue (e.g. 64 in-flight); new requests wait.

6. **Runtime crash recovery.** A single Panel's libghostty surface crashes — should Runtime restart just the Panel, surface the crash to the user, or tear down the whole Tab? *Leaning:* per-Panel restart with a user-visible placeholder showing the error; 3 crashes in 30s escalates to Tab tear-down.

7. **Worktree storage layout defaults.** Where do new worktrees live? Per product-spec Q6. **Blocks:** `apps/mac/Features/Hierarchy` Worktree creator. *Leaning:* sibling `<repo>-worktrees/<branch>/` by default, per-Project override.
