# Design Doc: C3 — Lifecycle Hooks

**Status:** Draft
**Author:** Claude (autonomous, on behalf of Gump)
**Date:** 2026-04-20

## Context and Scope

[Capability C3](../product-spec.md#core-capabilities) of touch-code is the **programmable-events surface**. The app emits a typed stream of lifecycle events — a Panel was created, its surface became ready, it produced output that matched a user-provided pattern, it went idle for N seconds, it exited, its enclosing Tab was activated, its enclosing Worktree was activated — and user-configured **hook handlers** receive those events and can take action.

Hooks are the substrate that makes every later capability programmable:
- **C4 (CLI `tc`)** dispatches hooks by invoking RPC methods that trigger the same events handlers subscribe to, and exposes `tc hook …` to install / list / test subscriptions.
- **C6 (Agent notification aggregation)** is a pure consumer of Panel hooks — it ships a first-party handler that translates `panel.idle` / `panel.output-match` into OS notifications.
- **C5 (Published Agent Skill)** documents the hook vocabulary so coding agents can emit `tc` calls that mutate behavior at hook time.

Two sibling components already exist and this design must plug into them without cycles:
- `TouchCodeCore` (domain types: `Panel`, `Tab`, `Worktree`, `PanelID`, …) — leaf package, zero internal deps.
- `Runtime` (in-app module under `apps/mac/touch-code/Runtime/`) — owns `GhosttyRuntime`, `PanelSurface`, `TerminalEngine`, `HierarchyManager`, `CatalogStore`. Exposes `AsyncStream<TerminalEvent>` per [the C1+C2 design](0001-terminal-and-hierarchy.md) and [exec plan 0002](../exec-plans/0002-terminal-and-hierarchy.md).

The in-app module added by this doc is `apps/mac/touch-code/Hooks/`. Its sole responsibility is to translate `TerminalEvent`s (plus a few hierarchy-level signals) into typed `HookEvent` payloads, match them against a user-loaded subscription set, and dispatch matched subscriptions to out-of-process shell handlers with a defined JSON envelope.

Open Question #4 in [product-spec.md](../product-spec.md#open-questions) asks: **in-process scripting vs. out-of-process spawn, or both?** This doc resolves it: **out-of-process only for v1**, with a narrow path to in-process later. See [Decisions](#decisions) §D1.

Related but out of scope for this doc:
- CLI surface (`tc hook install / list / test …`) — owned by [C4 design](c4-cli.md); this doc defines the RPC methods those commands call.
- OS-notification aggregation (`C6`) — a consumer, not a producer; uses hooks without modifying them.
- Skill package content — lives in `touch-code-skill/`; independent of app runtime.

## Goals and Non-Goals

### Goals

- **Complete event coverage.** Every lifecycle the product spec lists (Panel created / ready / output match / idle / exit; Tab activated; Worktree activated) plus the subset the app already emits (`panelCrashed`, `tabAutoClosed`, `panelExited`) is a first-class `HookEvent` with a stable wire schema.
- **Language-agnostic handlers.** Users write handlers in any language — `#!/usr/bin/env bash`, Python, Node, Ruby, Go. The app only requires an executable on `PATH` (or an absolute path) that reads JSON on stdin and exits with a status code.
- **Self-closing feedback loop.** A handler can produce follow-up app actions by writing a small JSON DSL on stdout; the app interprets it and executes the same RPC verbs `tc` uses. No custom scripting language.
- **Deterministic schema.** Every event JSON contains `{version, event, timestamp, panel?, tab?, worktree?, space?, data}`. Consumers can discriminate on `event` and rely on field stability across patch releases; schema changes bump `version`.
- **Low-cost idle and output-match paths.** Idle timers are per-Panel single-shot tasks that rearm on I/O; output-match evaluates a compiled-regex batch per `panel.output` event, not a per-byte scan. Idle-cost is near zero when no output-match subscriptions exist.
- **Per-Panel crash isolation.** A hook handler that crashes, hangs, or writes garbage never affects the Panel, its Tab, or any other handler. Timeouts kill the handler process, not the app.
- **Headless-testable.** `HookDispatcher` unit-tests run without GhosttyKit, without AppKit, without Process — using a pluggable `HookExecutor` protocol so the tests pass JSON in and assert JSON out.
- **Config hot-reload.** `tc hook reload` (and file-system watch on `~/.config/touch-code/hooks.json`) picks up edits without restarting the app; in-flight handlers finish on the old config.

### Non-Goals

- **In-process scripting engines.** No embedded JavaScript, Lua, WASM, or AppleScript in v1. Deferred behind a stable JSON-DSL stdout contract so we can add an in-process path later without changing event schemas. See [Alternatives](#alternatives-considered) §A1.
- **Sandboxing or elevation of handlers.** Handlers run with the user's own privileges (same as typing the command in any Panel). [NFR Security row](../product-spec.md#non-functional-requirements) already codifies this.
- **Arbitrary event injection.** Only the app emits `HookEvent`s. A hook handler can request actions on stdout but cannot fabricate an event the dispatcher then fires — preventing infinite hook loops.
- **Persistent hook state across app restarts.** Handler processes are stateless from the app's perspective; if a handler wants state it writes its own file.
- **Hook rule DSL.** Subscription matching is a simple tuple: `(event, optional regex for output-match, optional panel/tab/worktree scope)`. No boolean combinators; no CEL; no jq.
- **User-facing UI to edit hooks.** v1 edits `hooks.json` directly (or uses `tc hook install`). A Settings UI is post-v1.
- **Non-Panel-anchored events.** v1 hooks are scoped to a Panel, Tab, or Worktree. Space-level and app-level hooks are deferred; the wire format reserves `space` for forward compatibility.

## Design

### Overview

Hooks are a thin in-app dispatcher that subscribes to the existing `AsyncStream<TerminalEvent>` (plus three extra hierarchy callbacks), folds in two synthesized streams (idle timers and output-match regexes), and fans matched events out to a bounded pool of user shell processes.

The pipeline is a single function per event:

```
TerminalEvent  ──►  HookEvent  ──►  match subscriptions  ──►  spawn handler
  (M4 stream)      (typed schema)      (hooks.json)             (Process)
                                                                     │
                                                                     ▼
                                                            optional stdout JSON
                                                             ─► HookActionDispatcher
                                                                     │
                                                                     ▼
                                                             same RPCs `tc` uses
                                                             (IPC.Method enum)
```

**Why this architecture fits the goals:**

- **Correctness first.** The typed schema + compiled-regex match path keeps the hot path (every byte of terminal output) in Swift with no subprocess, no JSON marshalling, no IPC. Only a *matched* event pays the subprocess cost.
- **Dependency direction is clean.** `Hooks` imports `TouchCodeCore` (for IDs and wire payload types) and `TouchCodeIPC` (for the action DSL mirror). It does **not** import `Runtime` directly — instead it is constructed *by* `Runtime` and handed `AsyncStream<TerminalEvent>`, so `Runtime` stays the only place aware of GhosttyKit. See [Component Boundaries](#component-boundaries).
- **Out-of-process handlers are the only thing that fit "language-agnostic".** Every reference project that solved this problem (supacode, supaterm, Ghostty's own config, Claude Code's settings hooks) shells out. See [Decisions](#decisions) §D1.
- **Stdout JSON DSL makes hooks *actionable*.** A handler that only logs is useful; a handler that can open a new Tab in reaction is why the capability matters. The DSL is deliberately the same verbs the `tc` CLI uses — one surface, not two.
- **Idle & output-match as synthesized events.** The stream the runtime emits has `panel.output` and `panel.idle` already (the idle event fires from the per-Panel timer Runtime owns). The Hooks layer adds a per-panel regex pass on top of `panel.output` to generate `panel.outputMatch`. No upstream changes required.

### System Context Diagram

```
┌────────────────────────┐   TerminalEvent     ┌─────────────────────────┐
│ Runtime.TerminalEngine │────────────────────►│ Hooks.HookDispatcher     │
│  (owns Ghostty + idle  │   (AsyncStream)     │  1) event → HookEvent    │
│   timers; produces      │                     │  2) regex match output   │
│   panel.*, tab.*,       │                     │  3) subscription lookup  │
│   worktree.*)           │                     │  4) spawn handler(s)     │
└────────────────────────┘                     └────────────┬────────────┘
                                                            │ Process
                                                            ▼
                                               ┌─────────────────────────┐
                                               │ user handler            │
                                               │ (bash / python / node)  │
                                               │  stdin  = JSON envelope │
                                               │  stdout = JSON actions  │
                                               │  exit   = 0 or non-zero │
                                               └────────────┬────────────┘
                                                            │ stdout actions
                                                            ▼
                                               ┌─────────────────────────┐
                                               │ HookActionDispatcher    │
                                               │  translates to the same │
                                               │  IPC.Method verbs `tc`  │
                                               │  uses                   │
                                               └────────────┬────────────┘
                                                            │
                                                            ▼
                                               ┌─────────────────────────┐
                                               │ HierarchyManager +      │
                                               │ TerminalEngine          │
                                               │ (existing writers)      │
                                               └─────────────────────────┘

     ~/.config/touch-code/hooks.json   ──► HookConfigStore ──► HookDispatcher
        (atomic-rename; FSEventStream watch)
```

### Event Taxonomy and Wire Schema

Event names are lowercase dotted strings. They are a union of (a) the events the product spec C3 row lists and (b) the Runtime events the M4 `TerminalEvent` enum already produces:

| Event name             | Fires when                                                                                     | Scope anchor |
|------------------------|------------------------------------------------------------------------------------------------|--------------|
| `panel.created`        | A new Panel is inserted into a Tab's split tree                                                | Panel        |
| `panel.ready`          | `PanelSurface.state` transitions `.initialising → .ready` (shell is reading input)             | Panel        |
| `panel.output`         | Coalesced output batch emitted (≤ 16KB, ≤ 60Hz — same cadence as Runtime's stream)             | Panel        |
| `panel.outputMatch`    | Synthesized: a compiled regex from a subscription matches a `panel.output` batch               | Panel        |
| `panel.idle`           | Panel has produced no output and received no input for ≥ `idleThreshold` seconds               | Panel        |
| `panel.exited`         | The underlying process exited cleanly (exit code available)                                    | Panel        |
| `panel.crashed`        | The Ghostty surface faulted (not a clean child exit)                                           | Panel        |
| `tab.activated`        | User switched to this Tab inside a Worktree                                                    | Tab          |
| `tab.deactivated`      | User switched away from this Tab (fires for the previously-selected Tab only)                  | Tab          |
| `tab.autoClosed`       | Crash-isolation policy closed the Tab after 3 crashes in 30s                                   | Tab          |
| `worktree.activated`   | User selected this Worktree (in a window) — fires after the previous one's `deactivated`        | Worktree     |
| `worktree.deactivated` | Worktree switch leaving context                                                                | Worktree     |
| `worktree.created`     | A new Worktree row was appended (whether or not the on-disk `git worktree add` succeeded)      | Worktree     |
| `worktree.removed`     | A Worktree was removed (app-side; does not imply `git worktree remove`)                        | Worktree     |

The canonical stdin envelope handlers receive:

```jsonc
{
  "version": 1,
  "event": "panel.outputMatch",
  "timestamp": "2026-04-20T12:34:56.789Z",

  // Exactly one of these four is the "anchor"; the rest may be present for context.
  "space":    { "id": "uuid",  "name": "work" },
  "project":  { "id": "uuid",  "name": "touch-code", "rootPath": "/Users/…/touch-code" },
  "worktree": { "id": "uuid",  "name": "exp/plan-0003", "path": "/Users/…/touch-code-worktrees/exp/plan-0003", "branch": "exp/plan-0003" },
  "tab":      { "id": "uuid",  "name": "agent",        "selectedPanelID": "uuid" },
  "panel":    { "id": "uuid",  "workingDirectory": "/Users/…", "initialCommand": null },

  // Event-specific payload, discriminated by `event`.
  "data": {
    "match":        "agent has completed",
    "matchedRange": { "start": 120, "length": 22 },
    "output":       "…last 4KB of matched batch, utf-8 replaced…",
    "outputBytes":  4096
  }
}
```

Per-event `data` schemas:

| Event                 | `data` fields                                                                                 |
|-----------------------|-----------------------------------------------------------------------------------------------|
| `panel.created`       | `{ createdVia: "cli"\|"ui"\|"restore" }`                                                     |
| `panel.ready`         | `{ pid?: Int, shell: String }`                                                                |
| `panel.input`         | *Not delivered to user handlers by default* (volume matches output). Only reachable with `event: "panel.input"` + explicit opt-in flag `allowRawInput: true`. Payload: `{ text: String, inputBytes: Int }`. |
| `panel.output`        | *Not delivered to user handlers by default* (too chatty). Only reachable with `event: "panel.output"` + explicit opt-in flag `allowRawOutput: true`. |
| `panel.outputMatch`   | `{ match: String, matchedRange: HookMatchRange, output: String, outputBytes: Int }`           |
| `panel.idle`          | `{ idleSeconds: Double, sinceLastOutput: Double, sinceLastInput: Double }`                    |
| `panel.exited`        | `{ exitCode: Int32 }`                                                                         |
| `panel.crashed`       | `{ reason: String }`                                                                          |
| `tab.activated`       | `{ previousTabID?: "uuid" }`                                                                  |
| `tab.deactivated`     | `{ nextTabID?: "uuid" }`                                                                      |
| `tab.autoClosed`      | `{ reason: String, crashCount: Int, windowSeconds: Int }`                                     |
| `worktree.activated`  | `{ previousWorktreeID?: "uuid" }`                                                             |
| `worktree.deactivated`| `{ nextWorktreeID?: "uuid" }`                                                                 |
| `worktree.created`    | `{ branch?: String, gitExit?: Int32 }`                                                         |
| `worktree.removed`    | `{ keepDirectory: Bool }`                                                                     |

Anchor rule. On the wire every `space / project / worktree / tab / panel` field is declared *optional* (encoded with `encodeIfPresent`) because some fields are absent for some events (e.g. `worktree.removed` carries no `panel`). But the following guarantees hold for every encoded envelope and are enforced by a debug-only `HookEnvelope.validateAnchors()` check on the encoder path:

| Event scope              | Fields guaranteed non-null                                      |
|--------------------------|-----------------------------------------------------------------|
| `panel.*`                | `panel`, `tab`, `worktree`, `project`, `space`                  |
| `tab.*`                  | `tab`, `worktree`, `project`, `space`                           |
| `worktree.*`             | `worktree`, `project`, `space`                                  |

Handlers can rely on these without null-checking. The extra context is cheap — a few hundred bytes per event — and saves a round trip through the RPC layer.

### API Design

#### `HookEvent` (in `TouchCodeCore`)

`TouchCodeCore` gains a `HookEvent` Codable enum so both the app side and the `tc` CLI can speak about events without the CLI importing `Runtime`.

```swift
// apps/mac/TouchCodeCore/Hooks/HookEvent.swift  (new)
public nonisolated enum HookEvent: String, Codable, Hashable, Sendable, CaseIterable {
  case panelCreated     = "panel.created"
  case panelReady       = "panel.ready"
  case panelInput       = "panel.input"
  case panelOutput      = "panel.output"
  case panelOutputMatch = "panel.outputMatch"
  case panelIdle        = "panel.idle"
  case panelExited      = "panel.exited"
  case panelCrashed     = "panel.crashed"
  case tabActivated     = "tab.activated"
  case tabDeactivated   = "tab.deactivated"
  case tabAutoClosed    = "tab.autoClosed"
  case worktreeActivated   = "worktree.activated"
  case worktreeDeactivated = "worktree.deactivated"
  case worktreeCreated     = "worktree.created"
  case worktreeRemoved     = "worktree.removed"

  public var scope: HookScope {
    switch self {
    case .panelCreated, .panelReady, .panelInput, .panelOutput, .panelOutputMatch,
         .panelIdle, .panelExited, .panelCrashed:
      return .panel
    case .tabActivated, .tabDeactivated, .tabAutoClosed:
      return .tab
    case .worktreeActivated, .worktreeDeactivated, .worktreeCreated, .worktreeRemoved:
      return .worktree
    }
  }
}

public nonisolated enum HookScope: String, Codable, Sendable { case panel, tab, worktree, space }

/// Byte offset + length into the matched panel output, portably Codable
/// (NSRange is not stable across platforms/JSON and is avoided on the wire).
public nonisolated struct HookMatchRange: Codable, Equatable, Sendable {
  public var start: Int
  public var length: Int
  public init(start: Int, length: Int) { self.start = start; self.length = length }
}
```

#### `HookEnvelope` wire payload (in `TouchCodeCore`)

```swift
public nonisolated struct HookEnvelope: Codable, Equatable, Sendable {
  public static let currentVersion = 1
  public var version: Int
  public var event: HookEvent
  public var timestamp: Date                  // ISO-8601 encoding via custom encoder config
  public var space: SpaceRef?
  public var project: ProjectRef?
  public var worktree: WorktreeRef?
  public var tab: TabRef?
  public var panel: PanelRef?
  public var data: HookEventData              // enum switching on `event`

  public struct SpaceRef:    Codable, Equatable, Sendable { public var id: SpaceID;    public var name: String }
  public struct ProjectRef:  Codable, Equatable, Sendable { public var id: ProjectID;  public var name: String; public var rootPath: String }
  public struct WorktreeRef: Codable, Equatable, Sendable { public var id: WorktreeID; public var name: String; public var path: String; public var branch: String? }
  public struct TabRef:      Codable, Equatable, Sendable { public var id: TabID;      public var name: String?; public var selectedPanelID: PanelID? }
  public struct PanelRef:    Codable, Equatable, Sendable { public var id: PanelID;    public var workingDirectory: String; public var initialCommand: String? }
}

public nonisolated enum HookEventData: Codable, Equatable, Sendable {
  case panelCreated(createdVia: String)
  case panelReady(pid: Int32?, shell: String)
  case panelInput(text: String, inputBytes: Int)
  case panelOutput(output: Data, outputBytes: Int)
  case panelOutputMatch(match: String, matchedRange: HookMatchRange, output: Data, outputBytes: Int)
  case panelIdle(idleSeconds: Double, sinceLastOutput: Double, sinceLastInput: Double)
  case panelExited(exitCode: Int32)
  case panelCrashed(reason: String)
  case tabActivated(previousTabID: TabID?)
  case tabDeactivated(nextTabID: TabID?)
  case tabAutoClosed(reason: String, crashCount: Int, windowSeconds: Int)
  case worktreeActivated(previousWorktreeID: WorktreeID?)
  case worktreeDeactivated(nextWorktreeID: WorktreeID?)
  case worktreeCreated(branch: String?, gitExit: Int32?)
  case worktreeRemoved(keepDirectory: Bool)
}
```

The Codable conformance is hand-rolled with a `"kind"` discriminator that mirrors the `event` field on the envelope — the envelope-level `event` and the data-level `kind` stay in sync or decoding throws.

#### `HookSubscription` (in `TouchCodeCore`)

```swift
public nonisolated struct HookSubscription: Codable, Equatable, Sendable, Identifiable {
  public var id: UUID
  public var event: HookEvent
  public var command: String                        // shell command, tokenised per §Execution
  public var matchPattern: String?                  // regex; only meaningful for .panelOutputMatch
  public var matchFlags: RegexFlags                 // caseInsensitive, multiline, utf8Only
  public var scope: Scope                           // optional scope filter
  public var timeoutSeconds: Double                 // default 5
  public var mode: Mode                             // .fireAndForget (default) | .awaitActions
  public var cwd: String?                           // overrides the anchor's path
  public var env: [String: String]                  // additive env; reserved keys rejected at load
  public var allowRawOutput: Bool                   // required to subscribe to .panelOutput (default false)
  public var allowRawInput: Bool                    // required to subscribe to .panelInput (default false)
  public var idleThresholdSeconds: Double?          // filter applied client-side for .panelIdle (default nil = 60s)
  public var disabled: Bool

  public enum Scope: Codable, Equatable, Sendable {
    case anyPanel
    case panelID(PanelID)
    case panelLabel(String)           // set via `tc label <panel> --tag foo`
    case tabID(TabID)
    case tabLabel(String)
    case worktreeID(WorktreeID)
    case worktreePathGlob(String)     // "**/exp/*"
  }

  public enum Mode: String, Codable, Sendable { case fireAndForget, awaitActions }
  public struct RegexFlags: OptionSet, Codable, Sendable { public let rawValue: Int
    public static let caseInsensitive = RegexFlags(rawValue: 1 << 0)
    public static let multiline       = RegexFlags(rawValue: 1 << 1)
    public static let dotAll          = RegexFlags(rawValue: 1 << 2)
  }
}
```

#### `HookConfig` file schema (in `~/.config/touch-code/hooks.json`)

```jsonc
{
  "version": 1,
  "recursionWindowMs": 250,
  "subscriptions": [
    {
      "id": "f6c4e5be-5a9b-4c8e-9a7e-3e9e0d5f9e1b",
      "event": "panel.outputMatch",
      "command": "~/bin/notify-agent-done",
      "matchPattern": "(?i)\\b(done|ready for review|approval required)\\b",
      "matchFlags": ["caseInsensitive", "multiline"],
      "scope": { "panelLabel": "agent" },
      "timeoutSeconds": 5,
      "mode": "fireAndForget",
      "env": { "AGENT_NAME": "claude" }
    },
    {
      "id": "1a2b3c4d-…",
      "event": "panel.idle",
      "command": "bash -c 'echo \"idle\" | osascript -e \"display notification \\\"\\$1 idle\\\"\"'",
      "timeoutSeconds": 2,
      "mode": "fireAndForget"
    }
  ]
}
```

Same atomic-rename + version-gated decoder pattern as `catalog.json` (see architecture §Persistence). Loader path is `Hooks.HookConfigStore.load()`; writer is `Hooks.HookConfigStore.save(_:)`.

#### `Hooks` in-app subfolder (`apps/mac/touch-code/Hooks/`)

`Hooks` is a subfolder of the `touch-code` app target, not a separate Tuist target (see [architecture §Codemap](../architecture.md#in-app-modules-subfolders-of-the-touch-code-target-not-separate-tuist-targets)). Its boundary with `Runtime`, `Git`, and `App` is enforced by folder convention + code review, exactly as the other in-app modules. The code below compiles into the `touch-code` app binary; no `import Hooks` exists anywhere.

```swift
// HookDispatcher.swift
@MainActor
public final class HookDispatcher {
  public init(
    config: HookConfig,
    store: HookConfigStore,
    executor: HookExecutor = ProcessHookExecutor(),
    actionDispatcher: HookActionDispatcher,
    maxConcurrency: Int = 8
  )

  /// Attach to the Runtime's event stream. Called once at app launch by `TerminalEngine`.
  public func attach(to events: AsyncStream<TerminalEvent>)

  /// Fire an event manually (used by `tc hook test`).
  public func fire(_ envelope: HookEnvelope) async

  /// Hot-reload from disk; in-flight handlers keep their old subscription record.
  public func reloadConfig() async throws
}

// HookExecutor.swift  (protocol — swappable for tests)
public protocol HookExecutor: Sendable {
  func run(
    subscription: HookSubscription,
    envelope: HookEnvelope
  ) async -> HookExecutionResult
}

public struct HookExecutionResult: Sendable {
  public let exitCode: Int32
  public let stdout: Data
  public let stderr: Data
  public let duration: TimeInterval
  public let timedOut: Bool
  public let actions: [HookAction]            // parsed from stdout if mode == .awaitActions
}

// HookAction.swift — the stdout DSL
public enum HookAction: Codable, Equatable, Sendable {
  case panelSend(PanelID, text: String, raw: Bool)
  case panelBroadcast(scope: BroadcastScope, text: String, raw: Bool)
  case panelOpen(in: WorktreeID, tab: TabID?, workingDirectory: String?, initialCommand: String?)
  case panelClose(PanelID)
  case tabActivate(TabID)
  case tabCreate(in: WorktreeID, name: String?)
  case worktreeActivate(WorktreeID)
  case notify(title: String, body: String?, panelID: PanelID?)
  case log(level: String, message: String)
  case setPanelLabels(PanelID, [String])
  public enum BroadcastScope: Codable, Equatable, Sendable {
    case tab(TabID); case worktree(WorktreeID); case matching(label: String)
  }
}
```

`HookActionDispatcher` is a thin adapter that translates each `HookAction` into an `IPC.Method` call against the same in-process handlers `SocketServer` uses for `tc`.

### Execution model

1. **Event arrives.** `HookDispatcher.attach(to:)` iterates `events` in a detached `Task`. Each `TerminalEvent` is mapped (synchronously) to a `HookEnvelope` via a `EventMapper` helper that enriches the payload by reading the current `HierarchyManager.catalog`. Output events are *not* converted to envelopes up-front — they stay as `(PanelID, Data)` until the output-match pass.

2. **Output-match pass.** For every `.panelOutput`, the dispatcher walks the pre-compiled regex table `[PanelID: [(Subscription, NSRegularExpression)]]`. Subscriptions not scoped to this panel are excluded from the table at config-load time, so the per-batch cost is `O(matching_subscriptions)`. On a hit, a `.panelOutputMatch` envelope is synthesized and the normal dispatch continues. The *raw* `.panelOutput` envelope is only produced for subscriptions with `allowRawOutput: true`.

3. **Subscription match.** A per-event index `[HookEvent: [HookSubscription]]` is consulted. For each candidate subscription, `scopeMatches(envelope)` tests the `scope` filter (panel id, label, tab id, path glob, etc.). Survivors go to the executor.

4. **Executor.** `ProcessHookExecutor` wraps `Foundation.Process`:
   - `launchPath`: `/bin/sh` (see [Decisions](#decisions) §D2 for why not direct exec).
   - `arguments`: `["-c", subscription.command]`.
   - `environment`: user env **plus** reserved keys `TOUCH_CODE_SOCKET_PATH`, `TOUCH_CODE_EVENT`, `TOUCH_CODE_VERSION`, and the appropriate `TOUCH_CODE_*_ID` for whichever anchors are present in the envelope. `TOUCH_CODE_PANEL_ID` is set iff `envelope.panel != nil`, etc.
   - `currentDirectoryURL`: `subscription.cwd ?? envelope.anchorPath` (Panel's `workingDirectory`, or Worktree's `path`, or user home).
   - `standardInput`: pipe; `JSONEncoder` writes the full `HookEnvelope` followed by EOF.
   - `standardOutput` / `standardError`: pipes; buffered up to 1MB each, truncated past that with a warning.
   - **Timeout**: a separate `Task` runs `Task.sleep(for: .seconds(subscription.timeoutSeconds))` and on wake calls `Process.terminate()` then `SIGKILL` after 2s grace.
   - **Return**: `HookExecutionResult` with `timedOut`, `exitCode`, parsed actions (only if `mode == .awaitActions`).

5. **Action dispatch.** If `mode == .awaitActions`, stdout is decoded as `{"actions": [HookAction]}` via `JSONDecoder`. Parse failure logs a warning and is treated as zero actions. Each action is routed to `HookActionDispatcher.execute(_:originatingFrom:)`, which calls the same method the `tc` CLI would (`hierarchyClient.send(.openPanel(...))` etc.). Action execution is **serial within a handler** and **does not fire new hooks** for the direct mutation — see [Decisions](#decisions) §D4.

6. **Concurrency.** A global `AsyncSemaphore` caps outstanding handler processes at `maxConcurrency` (default 8 per architecture Open Question #4 leaning). Subscriptions opting into `singleFlight: true` additionally serialise themselves; a second firing while the first is running is dropped (not queued) with a metric counter incremented.

### Output coalescing and idle timer — Hooks is a pure consumer

The M4 exec plan already gives Runtime a 16ms output coalescer and a per-Panel idle-detection path that emits `.panelIdle(PanelID, duration)` unconditionally ([exec-plan 0002 §Interfaces and Dependencies](../exec-plans/0002-terminal-and-hierarchy.md#interfaces-and-dependencies)). This design does **not** add a second coalescer and does **not** tell Runtime when to arm the idle timer:

- Runtime emits `.panelOutput(PanelID, Data)` batches. Hooks consumes those as-is for the match pass.
- Runtime emits `.panelIdle(PanelID, duration)` unconditionally whenever a Panel crosses a fixed default idle threshold (60s, configurable via `settings.json.runtime.idleThresholdSeconds`). Hooks subscribes to the event and filters by each `HookSubscription.idleThresholdSeconds` client-side; a subscription asking for "≥ 120s idle" simply drops `.panelIdle(…, duration: 60)` events and waits for one with `duration ≥ 120`.
- No `HookRuntimeBridge` protocol: Runtime does not read hook state, and Hooks does not push configuration into Runtime. Runtime → Hooks is a one-way `AsyncStream<TerminalEvent>` handed into `HookDispatcher.attach(to:)` at bootstrap.

Cost discussion. Unconditional idle-timer arming is cheap — one `Task.sleep` per Panel, rearmed on I/O. Even with 64 active Panels, that is 64 `Task` allocations, well under 1MB. The alternative (gated arming) saves on a cost that was never material; the dependency-cleanliness win of "Runtime is a pure producer" is the dominant consideration.

### Component Boundaries

Both `Hooks` and `Runtime` are subfolders of the single `touch-code` app target; they are not separate Tuist targets, and neither `import`s the other as a module. Boundaries are enforced by folder convention + code review ([architecture §Codemap](../architecture.md#in-app-modules-subfolders-of-the-touch-code-target-not-separate-tuist-targets)).

```
TouchCodeCore (static framework)            (leaf; HookEvent + envelope types added here)
    ▲                                        ─ real framework import edge ─
    │
    └── touch-code app target (single binary)
         ├── touch-code/Runtime/             (owns GhosttyKit, emits TerminalEvent)
         └── touch-code/Hooks/               (subscribes to TerminalEvent stream)
             ▲
             │ AsyncStream<TerminalEvent> handed in at app bootstrap
             │ (Runtime.TerminalEngine constructs HookDispatcher and passes it the stream)
```

- **`touch-code/Hooks/*.swift` may reference:** `TouchCodeCore` types, `TouchCodeIPC` types, `Foundation`.
- **`touch-code/Hooks/*.swift` must NOT reference:** anything from `touch-code/Runtime/`, `touch-code/Git/`, `touch-code/App/`, `GhosttyKit`, `AppKit`, `SwiftUI`, TCA. Folder convention rule; enforced in review, not by Tuist target edges.
- **`touch-code/Runtime/*.swift` may reference `Hooks` types** only for the construction wiring in `TerminalEngine.init` (`self.hookDispatcher = HookDispatcher(...)`). Runtime code elsewhere must not reach into hook state.
- **TCA features** receive `HookDispatcher` via a `HookClient` dependency (same pattern as `TerminalClient` and `HierarchyClient`), constructed in `apps/mac/touch-code/App/Clients/`.

This keeps Hooks headlessly unit-testable by the same mechanism that already keeps Runtime testable: test bundles `@testable import touch_code` and exercise Hooks types directly, substituting `FakeHookExecutor` + `FakeHookActionDispatcher` for the ProcessHookExecutor / real action dispatcher.

#### In-process consumer seam (peer of `hook.events` RPC)

First-party in-app consumers — C6 (notification aggregator) is the motivating one; future first-party subscribers (in-app logs pane, Settings "recent activity") share the path — consume hook events **in-process**, not through the `hook.events` RPC. The RPC stays targeted at third-party tooling (the `tc hook tail` CLI, external monitors); first-party code avoids the IPC round trip and the JSON encode/decode cost.

Two additions to `HookDispatcher`:

```swift
public extension HookDispatcher {
  /// In-process seam for first-party consumers (C6, in-app panes).
  /// Peer of the `hook.events` RPC, NOT a replacement: RPC is for third-party
  /// tooling, this stream is for same-process consumers that want zero IPC cost.
  /// Each call returns a fresh stream; buffering policy is bufferingNewest(64).
  func internalEventStream() -> AsyncStream<HookEnvelope>

  /// Register an in-process sentinel-route subscriber. Subscriptions whose
  /// `command` begins with `prefix` short-circuit the `ProcessHookExecutor`
  /// path and are delivered directly to the subscriber's `handle(envelope:)`.
  /// Used by C6 to install e.g. `__touch-code/internal:notifications:<uuid>`
  /// as the command of its Stop-hook subscription, so the hook shell-out
  /// pattern is compatible without actually forking for every event.
  /// Prefixes must begin with the reserved `__touch-code/internal:` namespace;
  /// registration with any other prefix throws.
  func register(subscriber: InternalHookSubscriber, for prefix: String) throws
  func unregister(prefix: String)
}

public protocol InternalHookSubscriber: AnyObject, Sendable {
  func handle(envelope: HookEnvelope) async
}
```

Routing rule inside `HookDispatcher`:

1. For each candidate subscription that matched the event, inspect its `command` string.
2. If `command` has a prefix for which an `InternalHookSubscriber` is registered, call `subscriber.handle(envelope:)` on the `@MainActor` and skip `ProcessHookExecutor` entirely. The recursion guard, rate limiter, and `hook.recent` bookkeeping still apply.
3. Otherwise, fall through to the normal out-of-process spawn.

The sentinel-prefix route keeps `hooks.json` as the single user-visible registry: a first-party in-app consumer is just another row in the file, and users can `tc hook list` / disable it exactly like a user subscription. The namespace is reserved — `HookConfigStore.load()` rejects user-authored subscriptions whose `command` starts with `__touch-code/internal:` unless the file was written by an app-side installer flagged with `authoredBy: "touch-code"`.

`internalEventStream()` and the sentinel-prefix route are **independent** paths. C6 uses both: the event stream feeds its global notification pipeline; the sentinel-prefix route lets it install a per-Panel "Stop" hook that shells out through the same dispatcher the user subscriptions do, without paying fork/exec cost for a notification that lives in-process anyway.

### IPC wire protocol additions

The `tc hook …` CLI lives in [C4](c4-cli.md); it drives these new RPC methods added to the `hook.*` namespace:

| Method                         | Params                                           | Result                                       |
|--------------------------------|--------------------------------------------------|----------------------------------------------|
| `hook.list`                    | `{ eventFilter?: HookEvent, panelID?: UUID }`    | `{ subscriptions: [HookSubscription] }`      |
| `hook.install`                 | `{ subscription: HookSubscription }`             | `{ id: UUID }`                               |
| `hook.remove`                  | `{ id: UUID }`                                   | `{ removed: Bool }`                          |
| `hook.enable`                  | `{ id: UUID, enabled: Bool }`                    | `{}`                                         |
| `hook.reload`                  | `{}`                                             | `{ loadedCount: Int, errors: [String] }`     |
| `hook.test`                    | `{ id: UUID, envelope: HookEnvelope }`           | `{ result: HookExecutionResult }`            |
| `hook.fire`                    | `{ event: HookEvent, panelID: UUID?, data: … }`  | `{ handlersRun: Int }`                       |
| `hook.recent`                  | `{ limit?: Int }`                                | `{ fires: [HookFireRecord] }`                |
| `hook.events`                  | *(streaming)* `{}`                               | *(streams `HookEnvelope`; used by `C6`)*     |

`hook.events` is a *server-streaming* RPC — the only one in the `hook.*` namespace. It follows the unified streaming termination contract defined in [C4 §Wire protocol](c4-cli.md#wire-protocol): the request carries `stream: true`, the response is a sequence of `{id, stream: true, result: <envelope>}` frames, and the stream ends when **either** side closes its write half. If the server ends the stream gracefully, it sends a final `{id, stream: false, error?: … }` frame before closing its write side; if the client is done, it shuts down its write side and the server flushes any in-flight frames before closing. C6 (notification aggregator) subscribes to `hook.events` instead of polling; the CLI's `tc hook tail` command does the same.

### Data model changes (`TouchCodeCore`)

- **New files under `TouchCodeCore/Hooks/`:** `HookEvent.swift`, `HookEnvelope.swift`, `HookEventData.swift`, `HookSubscription.swift`, `HookConfig.swift`.
- **No changes to existing `Panel`, `Tab`, `Worktree` types.** The enveloped `PanelRef` / `TabRef` / `WorktreeRef` are projections over the existing types — one-way only (envelope never updates a Panel).
- **New optional labels on `Panel`** (needed for `scope: .panelLabel`): `var labels: Set<String> = []`. This is an additive struct field; the version-gated `Catalog` decoder tolerates its absence on v1 files. Bumping Catalog to `version: 2` is **not** required for additive optional fields; the decoder already uses `decodeIfPresent`.
- **Single canonical writer for `Panel.labels`: `HierarchyManager.setPanelLabels(_:labels:replace:)`.** Three surfaces mutate labels in the product (the CLI's `tc panel label`, the hook action DSL's `HookAction.setPanelLabels`, and any future UI). All three route through this one method on the `@MainActor`-isolated `HierarchyManager`; no other code path mutates `labels`. This keeps the labels write path auditable, debounce-saves to `catalog.json` through the same `CatalogStore.scheduleSave` used by every other mutation, and ensures the `.labels` set and its corresponding alias index stay consistent. `HookAction.setPanelLabels` is a thin in-process call to the same method — not a second writer.
- **No schema bump.** `HookConfig.version` is its own file, starting at 1; independent of `Catalog.version`.

### Error handling model

| Failure mode                                 | Handling                                                                                     |
|----------------------------------------------|----------------------------------------------------------------------------------------------|
| `hooks.json` parse error                     | Back up to `hooks.json.broken-<ISO8601>`, log at `.error`, load zero subscriptions (not crash) |
| Bad regex in subscription                    | Reject subscription at load time with `HookConfigError.invalidRegex(id, pattern, message)`, load the rest |
| Reserved env var collision in `env`          | Reject subscription at load time with `HookConfigError.reservedEnv(key)`                     |
| Handler binary missing                       | `Process.run()` throws; record as `HookExecutionResult` with `exitCode = -1`, log at `.warn` |
| Handler exit code non-zero                   | Logged at `.info`; result retained in `hook.recent` ring buffer; no user notification        |
| Handler timed out                            | `timedOut = true`; process tree killed; logged at `.warn`                                    |
| Handler stdout is not valid JSON (`awaitActions`) | `actions = []`; logged at `.warn`; exit code still propagated                           |
| Handler emits an unknown `HookAction` type   | Decoder throws; the whole action list is dropped; logged at `.warn`; no partial apply        |
| Handler-emitted action references non-existent ID | `HookActionDispatcher` returns an error to the executor; logged at `.info`              |
| Recursion guard trips                        | Action dropped; logged at `.warn`; see [Decisions](#decisions) §D4                            |
| Socket unavailable during action             | Action queued up to 2s; then dropped; logged at `.warn`                                      |

Errors never crash the app. The `HookDispatcher` holds a bounded `[HookFireRecord]` ring buffer (default 256) that `tc hook recent` and Settings can page through for introspection; each record includes envelope, subscription id, duration, exit code, actions dispatched, actions refused.

### Rollout plan

| Phase            | What ships                                                                              | Flag / gate                                                   |
|------------------|-----------------------------------------------------------------------------------------|----------------------------------------------------------------|
| **R1 — scaffold**| `TouchCodeCore/Hooks/*.swift`, `HookConfigStore`, CLI `tc hook list` + `install`        | Unconditional; empty config loads to zero subscriptions       |
| **R2 — emit**    | `HookDispatcher.attach(to:)`, `panel.*` events (`created`, `ready`, `exited`, `crashed`, `outputMatch`) | Feature flag `hooks.enabled` in `settings.json` (default true) |
| **R3 — idle**    | Runtime idle timer + `panel.idle`                                                       | Flag `hooks.idleTimers` (default true)                        |
| **R4 — actions** | `awaitActions` mode; `HookActionDispatcher`; stdout DSL                                 | Flag `hooks.stdoutActions` (default true)                     |
| **R5 — stream**  | `hook.events` streaming RPC (unblocks C6)                                               | Flag `hooks.streamRpc` (default true)                         |
| **R6 — UI**      | Settings panel showing subscriptions + recent fires                                     | post-v1                                                       |

All flags live in `settings.json`, read at startup and on `tc hook reload`. Back-compat: an older app with an `hooks.json` containing a subscription for an `event` the app doesn't know (future forward-compat) drops that subscription with a warning and loads the rest.

### Testing strategy

- **Unit (`HooksTests`, new Tuist `.unitTests` target):**
  - `EventMapper` translates every `TerminalEvent` variant to an envelope with the right anchors.
  - `RegexMatcher` compiles all three `RegexFlags` combinations and matches on batch-level input; bad regex rejected.
  - `ScopeMatcher` honours `.anyPanel`, `.panelID`, `.panelLabel`, `.tabID`, `.worktreeID`, `.worktreePathGlob` with table-driven tests.
  - `FakeHookExecutor` records invocations; `HookDispatcher` dispatches the correct subscription for each envelope.
  - Config round-trip (JSON → struct → JSON bytes-equal); broken config backs up.
  - Action decode round-trip for every `HookAction` variant.
  - Timeout semantics via `FakeHookExecutor` that sleeps past the timeout.
  - Recursion guard: a handler that returns an action which would trigger the same subscription does not loop (dispatcher suppresses direct re-entry within `HookConfig.recursionWindowMs`, default 250ms).
- **Integration (`HooksIntegrationTests`):**
  - Real `ProcessHookExecutor` against a shipped `apps/mac/HooksTests/Fixtures/echo-envelope.sh` shell script (referenced by `Bundle.module.url(forResource:withExtension:)` via a `.target(name: "HooksTests", resources: [.copy("Fixtures")])` Tuist config). Assert stdin contents match encoded envelope. Assert stdout `actions` round-trip.
  - End-to-end: open a Panel via TCA, type `echo "READY FOR REVIEW"`, assert subscribed handler fires exactly once with the expected match.
- **Contract tests against `tc`:**
  - `tc hook list` JSON output matches `hook.list` RPC result schema.
  - `tc hook test <id>` invokes a handler and prints `HookExecutionResult` to stdout.
- **Observability:**
  - `hook.recent` ring buffer doubles as a golden-trace capture for debugging.
  - `os.Logger` subsystem `com.touch-code.hooks`, categories `dispatch`, `executor`, `config`.

## Alternatives Considered

### A1 — In-process scripting engine (JavaScript / Lua / WASM)

Embed JavaScriptCore (free on macOS) and expose the envelope/action DSL as a JS API. Handlers become JS functions loaded at startup.

**Trade-offs:** lower per-event latency (~microseconds vs. ~milliseconds), no fork/exec cost, uniform error surface. But: single-language lock-in; larger app process footprint; embedded-script debuggability is poor; `async` across the JS VM boundary is ugly; supaterm and supacode both ran into the `Process.environment` / `pty` / `exec` shape mismatch and gave up on their embedded JS experiments. Every comparable native-app-with-hooks product (Ghostty, iTerm, Hammerspoon) ships out-of-process as the *primary* surface.

**Verdict:** reject for v1. The stdout JSON DSL keeps the door open: an in-process handler in the future would simply be a faster path to the same action set.

### A2 — Apple Events / AppleScript

Every macOS app can already expose itself to AppleScript. Users would write `tell application "touch-code" to send text "ls" to panel id "…"`.

**Trade-offs:** zero subprocess cost; Apple-native; but AppleScript is sparsely documented, encodes types via `OSAKit`, and is effectively dead as a user-programming surface. Not cross-OS (future Linux port would need a shim). And it still doesn't answer *how events flow out to user code* — AppleScript is request-driven, not event-driven.

**Verdict:** reject. Will re-evaluate post-v1 as an optional scripting bridge layered on top of the JSON-DSL action surface.

### A3 — Hook handlers as a long-lived side-car process

Spawn one persistent user-configured process at app start; pipe every event to it as newline-delimited JSON; expect newline-delimited actions back. Model: one handler process, one socket.

**Trade-offs:** amortises fork/exec cost; handler can hold in-memory state (e.g., "am I already notifying?"). But: makes handlers long-running (memory, zombie risk); no per-event scoping (every handler sees every event); handler crash blocks all hooks until restart; doesn't compose with shell one-liners. Loses the ergonomic "write a bash script" property the out-of-process model gives.

**Verdict:** reject for v1. Post-v1 we could allow subscriptions to specify `mode: "persistent"` with an opt-in, but the default stays per-event spawn.

### A4 — Directly consume Ghostty's own event callbacks

libghostty fires its own callbacks (surface wakeup, close, action). Route user hooks off those callbacks directly, skipping our `TerminalEvent` abstraction.

**Trade-offs:** one fewer indirection. But: the hook taxonomy needs *hierarchy-level* events (tab activated, worktree activated, crash-auto-closed) that Ghostty has no concept of. Splitting the hook taxonomy across "Ghostty-native" and "our own" is worse than unifying on our `TerminalEvent` + a small idle-timer synthesis pass.

**Verdict:** reject. Keep `TerminalEvent` as the single stream.

### A5 — `jq`-style rule DSL for subscription matching

Support arbitrary predicates like `.output contains "PASS" and .panel.label == "tests"` instead of just `(event, regex, scope)`.

**Trade-offs:** more powerful routing. But: introduces either a parser dependency or a shelled-out `jq` call per event (which is exactly what we said we'd avoid on the hot path). Users who need this power already have it — they write their own filter at the top of their handler and exit 0 early to no-op.

**Verdict:** reject. Start simple. If the complexity emerges from real handler code, revisit.

## Cross-Cutting Concerns

### Security & privacy

- Handlers run as the user's uid; no privilege boundary. Documented in [NFR Security](../product-spec.md#non-functional-requirements).
- Handler **stdin is trusted app-produced JSON**, not user-typed text, so shell-injection via `command` strings is the handler author's responsibility. Example in docs warns that `command: "notify '$PANEL_ID'"` is unsafe; correct form is `command: "notify \"$TOUCH_CODE_PANEL_ID\""`.
- Handler **stdout is untrusted** by the app — parsed with a strict decoder; unknown fields rejected (not silently ignored). Prevents a rogue handler from trying to invoke nonexistent verbs.
- Handler **env additions** are restricted: keys matching `^TOUCH_CODE_.*` are reserved for the dispatcher and cannot be overridden by subscription `env` (load-time rejection).
- `hooks.json` paths referenced by `command` are resolved via `PATH` lookup at spawn time; the app does not pre-resolve and cache, so users can edit their PATH without restarting.

### Observability

- `hook.recent` ring buffer exposes fire history (envelope hash, subscription id, timings, exit code, actions dispatched).
- Structured logs under `com.touch-code.hooks.dispatch` include subscription id, event, matched? (bool), anchor ids, duration-ms, exit code, action count.
- Counters exposed via `hook.stats` RPC for Settings: total fires, match failures, timeouts, decode failures, recursion drops.

### Performance

- **Hot-path budget.** A `panel.output` batch must complete the regex pass in under 100 µs for the "no matching subscriptions" case, and under 1 ms with 10 compiled regexes on a 16KB batch. Measured via an XCTest micro-benchmark under `HooksBenchmarks` (opt-in via `mac-bench` Makefile target).
- **Spawn budget.** From envelope-ready to handler exec start: p95 ≤ 10 ms on M1 (mostly fork/exec cost). Target is *not* to beat the network — it's that idle CPU with no subscriptions stays at the same ~0% the architecture NFR row promises.
- **Memory.** Per-Panel regex table: `O(subscriptions for that panel)` * ~10 KB compiled regex. Envelope allocation: ~1-2 KB per fire. `hook.recent` ring at 256 entries ≤ 1 MB. None of these threaten the "< 50 MB per idle Panel" NFR.

### Migration

v0 ships with an empty `hooks.json`. There is no pre-existing state to migrate from — this doc is the initial design. Future schema bumps (add fields to `HookSubscription`) are additive; breaking bumps (e.g., change `matchPattern` → `matchRule`) require `HookConfig.version += 1` and a migration function in `HookConfigStore.migrate(from:to:)`.

### Rollback

The `hooks.enabled` flag in `settings.json` disables attachment. With the flag off, the runtime still emits events, the config still loads, but no handlers are invoked. A user hitting a pathological hook loop can set the flag, `killall touch-code`, restart, and reach a clean slate without editing `hooks.json`.

## Decisions

Every judgement call is recorded here with rationale. "Supacode-parallel" means the same choice supacode/supaterm made; "divergent" means we chose differently and why.

- **D1 — Out-of-process execution only in v1. (Resolves Open Q #4.)** *Supacode-parallel.* Language-agnostic; isolated; matches every comparable project; keeps the app process small; leaves in-process as a future optimisation behind the same stdout action DSL.
- **D2 — Spawn `/bin/sh -c` instead of parsing the command ourselves.** *Supacode-parallel.* Users expect to write `command: "~/bin/foo | tee ~/.log/foo.log"`. Parsing argv ourselves means we'd have to reimplement shell quoting, env-var expansion, tilde expansion, and pipe composition. `sh -c` is universally available on macOS and is what Ghostty config / Claude settings / Claude Code hooks all do.
- **D3 — `HookEvent` / `HookEnvelope` live in `TouchCodeCore`, not in `Hooks`.** *Divergent from supacode's location; pattern-consistent.* `tc` needs to speak the vocabulary (`tc hook test`, `tc hook install`) without importing `Runtime` or `Hooks`. `TouchCodeCore` is the designated shared ground. This is the same justification that already put `Panel`, `Tab`, `Worktree` there.
- **D4 — Recursion guard: handler-emitted actions do not fire hooks for the immediate mutation.** *New (supacode doesn't have stdout actions).* A handler that reacts to `panel.output` by sending text back to the same panel would loop indefinitely. The dispatcher tags actions with an originating envelope id; the event emitter for `panel.output` / `panel.input` drops firings whose immediate upstream cause is that tag within a configurable window (`HookConfig.recursionWindowMs`, default `250`). Tab / Worktree-level events do fire (necessary for legitimate "open a tab when idle" handlers). Documented as a limitation, not a general cycle breaker.
- **D5 — `HookAction` verbs are the minimum useful subset of what `tc` can do.** *Supacode-parallel.* Specifically: `panel.send`, `panel.broadcast`, `panel.open`, `panel.close`, `tab.activate`, `tab.create`, `worktree.activate`, `system.notify`, `system.log`, `panel.setLabels`. Excluded (for now): space creation, project add/remove, worktree create/remove, settings mutation. Rationale: those mutations should go through UI/`tc` with user intent, not a handler's decision.
- **D6 — No in-app UI for editing subscriptions in v1.** *Supacode-parallel.* `hooks.json` + `tc hook install/list/remove/test` is the full surface. Users who want GUI editing run their editor of choice on `hooks.json` (we're a terminal orchestrator for CLI-agent users; they have editors handy).
- **D7 — Timeout default is 5s.** *Divergent from supacode's 10s.* Touch-code hooks are scoped to Panel lifecycle where human-perceptible latency matters; 5s is enough for a quick `osascript` or `curl localhost`. Users override per subscription.
- **D8 — Handler concurrency cap is global (8), not per-subscription.** *Matches architecture Open Q #4 leaning.* Prevents a pathological "agent-output-match → run tests" handler with a 30-second `pytest` from spawning 30 copies in parallel.
- **D9 — `panel.output` raw subscription requires explicit `allowRawOutput: true`.** *Divergent (new).* Subscribing to every byte of terminal output would be a loaded footgun; the explicit opt-in documents that the user accepts the volume. Default-deny is a small cost paid against a worst case that is tempting but rarely what the user wants.
- **D10 — Panel labels (`Panel.labels`) are added now.** *Supaterm-parallel.* `scope: .panelLabel("agent")` is the most ergonomic way to target agent-hosting Panels without stable UUIDs in user configs. The Catalog decoder is already forward-compatible.
- **D11 — Config is JSON, not TOML.** *Divergent from supaterm (TOML); supacode-parallel.* Keeps us aligned with `catalog.json` / `settings.json`; lets the same `AtomicFileStore` + version-gated decoder serve all three. TOML's marginal readability win doesn't outweigh the consistency loss.
- **D12 — `hook.events` is a streaming RPC, not a polling RPC.** *Divergent from supacode (which polls settings files).* C6 must react to events in real-time; polling would add 100ms-1s latency to every OS notification. Adding one streaming RPC is cheaper than tolerating that latency.
- **D13 — `HookEventData` uses tagged-union Codable, not heterogeneous `[String: Any]`.** *Divergent from supacode, which has more permissive JSON.* Type safety across the CLI ↔ App boundary catches schema drift at compile time, and `tc hook test` can produce well-formed synthetic envelopes without ambiguity.
- **D14 — Hooks attach to the single Runtime event stream, not to Ghostty callbacks.** Keeps `Hooks` dependency-clean (no GhosttyKit import) and means Tab/Worktree events live alongside Panel events in the same taxonomy. See [Alternative A4](#a4--directly-consume-ghosttys-own-event-callbacks).
- **D15 — The action-execution path does not *itself* invoke the socket server.** *Architecture-driven.* `HookActionDispatcher` calls the in-process Swift handlers directly, same as the in-process dispatch of a `tc` method. Sending actions through the socket back to ourselves would waste a round trip and add a serialization hop.
- **D16 — First-party consumers (C6 and friends) get an in-process seam on `HookDispatcher` — `internalEventStream()` + sentinel-prefix `InternalHookSubscriber` routing — as a *peer* of `hook.events` RPC, not an alternative.** *New; C6-v2 contract.* Unblocks C6 without an IPC round-trip for in-app notification aggregation and without duplicating the subscription/config/recursion-guard/rate-limit machinery. The `__touch-code/internal:` command prefix is reserved; user subscriptions cannot claim it, and `hooks.json` remains the single visible registry. Third-party tooling (`tc hook tail`, external monitors) continues to use `hook.events`; the two paths are semantically equivalent from the event-taxonomy perspective.

## Risks

- **R1 — Handler storms on spurious output match.** A too-loose regex against a chatty agent spawns dozens of handler processes, hitting the concurrency cap and starving legit hooks.
  - *Mitigation:* per-subscription token bucket (default: 30 fires / 10s). Exceeding rate transitions the subscription to `disabled: true` with a `tc hook recent` entry saying "rate-limited". Users re-enable with `tc hook enable <id>`.
- **R2 — Zombie handler processes.** A handler that ignores SIGTERM and doesn't respect the timeout wastes a slot permanently.
  - *Mitigation:* 2-second SIGKILL grace after timeout; process group kill (`killpg`); recorded in `hook.recent` as `killed: true`.
- **R3 — Config reload during in-flight handlers.** A reloaded subscription that shares an id with an in-flight handler could change semantics mid-flight.
  - *Mitigation:* in-flight handlers retain a snapshot of their originating subscription; config reload atomically swaps only the table for *new* firings.
- **R4 — Schema drift between CLI `tc hook install` and the in-app decoder.** An older `tc` against a newer app (or vice versa) could silently drop fields.
  - *Mitigation:* `HookSubscription` Codable uses strict unknown-field rejection; `HookEnvelope.version` is checked; CLI prints a warning if the app reports `serverHookVersion > clientHookVersion`.
- **R5 — Recursion guard is time-based and therefore imperfect.** Two handlers that ping-pong through different subscriptions can still loop.
  - *Mitigation:* per-envelope-chain depth counter capped at 4; exceeding logs and drops further actions. Documented limitation in `tc hook` man page.
- **R6 — `panel.idle` timer leaks.** Creating/destroying Panels rapidly could accumulate stale `Task` handles.
  - *Mitigation:* `PanelSurface.close()` calls `idleTimers.cancel(panelID:)`; unit test covers rapid open/close.
- **R7 — JSON on stdin is large for `panel.output` subscriptions.** A 16KB batch × envelope overhead = ~20KB per fire; on a very active agent panel that is >1MB/s serialized.
  - *Mitigation:* `allowRawOutput: true` is the explicit gate (D9). Handlers subscribing to `.panelOutputMatch` receive only the matched region + short context (~a few KB), which is the common case.
- **R8 — Out-of-process cost on fast-fire events (`panel.ready`).** A user installing 20 `panel.ready` handlers spawns 20 shells per Panel creation — on restore, that's hundreds.
  - *Mitigation:* concurrency cap + observed telemetry in `hook.recent`; restore path batches `.panelCreated` and `.panelReady` events behind a 50ms debounce per panel (handlers still see both events, just grouped in dispatch).
- **R9 — Users write handlers that assume `pwd` is the Worktree root, but the dispatcher resolves `cwd` to `subscription.cwd ?? envelope.anchorPath`.** For Panel-scoped events, anchor is the Panel's `workingDirectory`, which could differ from the Worktree path.
  - *Mitigation:* document clearly; `cwd: null` is the default "panel's pwd"; `cwd: "$WORKTREE"` (expanded from `TOUCH_CODE_WORKTREE_PATH` env var) is the obvious override.
- **R10 — The `hook.events` streaming RPC has backpressure.** A slow subscriber (C6) falling behind a chatty agent panel would either lose events (bad for notifications) or OOM the app buffer.
  - *Mitigation:* per-connection bounded queue (architecture Open Q #5 default = 64); new events drop the oldest on overflow with a metric counter; C6 degrades to "summary notification" on observed drops.
