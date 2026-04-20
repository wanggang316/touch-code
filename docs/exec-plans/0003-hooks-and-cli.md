# ExecPlan: Lifecycle Hooks and `tc` CLI (C3 + C4)

**Status:** Draft
**Author:** Claude (autonomous, on behalf of Gump)
**Date:** 2026-04-20

This is a living document. The Progress, Surprises & Discoveries, Decision Log, and Outcomes & Retrospective sections must be kept up to date as work proceeds.

## Purpose

After this plan lands, a contributor who runs `make mac-build && make mac-run-app` can:

- Write a shell handler for Panel / Tab / Worktree lifecycle events, drop it in `~/.config/touch-code/hooks.json`, and see the handler fire with a fully-typed JSON envelope on stdin whenever the matching event occurs. Handlers can write a small JSON DSL on stdout to request follow-up app actions (send text to a Panel, open a Tab, fire an OS notification) with the recursion guard preventing runaway loops.
- Drive touch-code from any Panel's shell with a real `tc` CLI: create Spaces, add Projects, spin up Worktrees, open Panels, send text across Panels, broadcast to a Tab, install / test / tail hook subscriptions, hand a Worktree to an external editor, install the published Agent Skill into Claude Code / Codex / pi. Every command has stable exit codes and a machine-readable `--json` mode.
- Observe event flow end-to-end: an agent running in a Panel emits `READY FOR REVIEW`; a user-installed `panel.outputMatch` hook fires; the handler writes `{"actions":[{"notify":{…}}]}` on stdout; the dispatcher translates that to a native notification — all without rebuilding the app.

This is the plan where touch-code becomes *programmable*. C6 (OS-notification aggregation) layers directly on the `hook.events` stream and the in-process `internalEventStream()` seam delivered here. C5 (published Agent Skill) can document a real CLI contract once M6 lands. Every subsequent capability reuses the RPC framing, the hook event taxonomy, or both.

The design is fully specified ahead of this plan:

- [docs/design-docs/c3-lifecycle-hooks.md](../design-docs/c3-lifecycle-hooks.md) — hook taxonomy, envelope schema, dispatcher, execution model, in-process seam (DEC-16).
- [docs/design-docs/c4-cli.md](../design-docs/c4-cli.md) — command surface, RPC wire protocol, alias resolver, exit codes, rollout phases.

This plan implements those decisions; it does not relitigate them.

## Progress

- [ ] M1 — `TouchCodeCore` + `TouchCodeIPC` wire types and Codable round-trip tests
- [ ] M2 — `apps/mac/touch-code/Hooks/` in-app subfolder (`HookDispatcher`, `HookExecutor`, `HookConfigStore`, `HookActionDispatcher`, `internalEventStream`, sentinel routing) + headless tests
- [ ] M3 — Daemon-side `SocketServer` + `hook.*` + `system.hello` method handlers + backpressure queue
- [ ] M4 — `tc` CLI scaffold (ArgumentParser root, `RPCClient`, `SocketDiscovery`, `AliasResolver` UUID-fast-path, `TextRenderer` + `JSONRenderer`, exit-code mapping, `system.hello` pipelining)
- [ ] M5 — `tc hook {list,install,remove,enable,disable,reload,test,fire,recent,tail,edit}` including streaming tail
- [ ] M6 — `tc {space,project,worktree,tab,panel,send,broadcast,skill,open,system}` hierarchy / terminal / skill / open / system verbs
- [ ] M7 — Integration tests against headless app, completion-script generation, `tc --man`, final docs pass

## Surprises & Discoveries

(None yet)

## Decision Log

Decisions made by this plan — distinct from the design docs' in-doc decisions, which this plan inherits and does not restate. Each entry is dated and tagged with the milestone that introduced it.

- **DEC-1 (pre-M1, 2026-04-20): Host Hooks tests inside `touch-codeTests`; no new Tuist target.** The existing `touch-codeTests` unit-tests target already hosts `HierarchyManagerTests.swift` (exec-plan-0002 M2, same `@testable import touch_code` pattern). Adding a parallel `HooksTests` target would split the test bundle and force duplicate dependency wiring. `touch-codeTests/Hooks/*.swift` is the canonical location; fixture files live under `touch-codeTests/Fixtures/` and are resource-copied via `Project.swift`.
- **DEC-2 (pre-M3, 2026-04-20): `SocketServer` lives in `apps/mac/touch-code/App/Features/Socket/`.** Architecture §Entry Points already names this path. The server imports `TouchCodeIPC` for wire types and `HierarchyClient` / `TerminalClient` / `HookDispatcher` via `@MainActor` dependency injection; it does not import `Runtime` or `Hooks` directly.
- **DEC-3 (pre-M3, 2026-04-20): Length-prefix framing is `UInt32` network-byte-order + JSON body.** Design docs specify "length-prefixed JSON envelopes" but not the concrete layout. Pin it now: 4-byte big-endian unsigned length prefix, followed by exactly `length` bytes of UTF-8 JSON, no trailing newline. Matches supaterm's `SupatermSocketProtocol.swift` framer so an existing reader can be ported verbatim. Defined in `TouchCodeIPC/Framing.swift` landing in M1.
- **DEC-4 (pre-M4, 2026-04-20): `tc` pipelines `system.hello` + the real request in one write.** Design doc C4 D10 requires fresh connection per invocation; to avoid doubling round-trip cost, `RPCClient.send` encodes the `system.hello` frame and the method frame into one contiguous buffer and writes both before reading. The server processes them in arrival order; on version skew it returns the `.versionMismatch` response for `system.hello` and aborts the second frame, which the client discards.
- **DEC-5 (pre-M6, 2026-04-20): `tc skill install` and `tc open` ship behind graceful fallbacks when the app-side dependencies are absent.** `SkillInstaller` and `ExternalEditor` are light services that can land inside this plan, but if C5/C8 work happens in parallel, M6 ships the RPC wiring + CLI verbs with a `.unsupported(reason: "not implemented in this app build")` response; the CLI prints a clear error and exits 4. The full plumbing lands the moment C5/C8 do, without another plan.
- **DEC-6 (pre-M7, 2026-04-20): Completion script generation uses ArgumentParser's built-in `generateCompletionScript`, wrapped in a hidden `--generate-completion-script` root flag.** The published bundle ships pre-generated `tc.zsh` / `tc.bash` / `tc.fish` next to the binary. Re-generation is a developer escape hatch, not a user flow.
- **DEC-7 (pre-M3, 2026-04-20): Hook-subscription snapshot discipline: the dispatcher copies the full `HookSubscription` into each in-flight `HookExecution` at dispatch time.** The design doc (C3 R3) requires "in-flight handlers retain a snapshot of their originating subscription"; this plan pins the implementation: the snapshot is `let subscription: HookSubscription` captured at the start of `HookDispatcher.dispatch(_:envelope:)`, not a reference into the live config table. Config-reload replaces the table atomically; in-flight handlers read their own `let` copy.
- **DEC-8 (pre-M2, 2026-04-20): `HookConfigStore` uses the same `AtomicFileStore` helper `CatalogStore` uses.** Design doc says "same atomic-rename + version-gated decoder pattern as `catalog.json`"; this plan binds the implementation to the exact `TouchCodeCore.AtomicFileStore.read/write` methods landed in exec-plan-0002 M1, not a re-implementation.
- **DEC-9 (pre-M3, 2026-04-20): Backpressure queue is per-accepted-connection, not global.** Design doc C4 D11 and architecture Open Q #5 set the limit at 64 in-flight per connection. This plan implements it as a `AsyncChannel<QueuedRequest>(maxBufferedElements: 64)` per `SocketConnection` actor; overflow waits up to 2s (`ContinuousClock` deadline) then throws `IPCError.overloaded`.

## Outcomes & Retrospective

(To be filled at milestone completion — one subsection per milestone, matching exec-plan-0002's format.)

## Context and Orientation

Related documents (all in this repo):

- Product spec — [docs/product-spec.md](../product-spec.md), capabilities C3 and C4.
- Design docs (authoritative for every interface named below):
  - [docs/design-docs/c3-lifecycle-hooks.md](../design-docs/c3-lifecycle-hooks.md)
  - [docs/design-docs/c4-cli.md](../design-docs/c4-cli.md)
- Architecture — [docs/architecture.md](../architecture.md): codemap, dependency direction (`tc` cannot import `Runtime`/`Hooks`/`Git`), IPC framing, URL-scheme mapping, persistence invariants.
- Sibling plan in flight — [docs/exec-plans/0002-terminal-and-hierarchy.md](0002-terminal-and-hierarchy.md): this plan depends on that plan's M4 (`TerminalEngine` façade + `AsyncStream<TerminalEvent>`) and M5 (TCA clients + sidebar/tabs/split UI). M1 and M2 of this plan can land before 0002's M4; M3 onward requires 0002's M4 to be merged. Record the explicit gate in the Progress section above and in M3's Goal.
- Golden rules — [docs/golden-rules.md](../golden-rules.md).

Key source files (current state on `main`, post-0002-M4.1 refactor `78df1a6`):

- `apps/mac/TouchCodeCore/` — domain value types (`Space`, `Project`, `Worktree`, `Tab`, `Panel`, `SplitTree<PanelID>`, `Catalog`, `AtomicFileStore`). Leaf package, zero AppKit/SwiftUI/GhosttyKit imports. M1 adds `Hooks/HookEvent.swift` and siblings under this folder.
- `apps/mac/TouchCodeIPC/IPC.swift` — currently one-line stub `public enum IPC {}`. M1 replaces it with the full namespace: `IPC.Method`, `IPC.Request`, `IPC.Response`, `IPCError`, `Framing`, plus the wire-only struct types defined in C4.
- `apps/mac/touch-code/Hooks/Hooks.swift` — one-line stub `public enum Hooks {}`. M2 fills this subfolder with `HookDispatcher`, `HookExecutor`, `HookConfigStore`, `HookActionDispatcher`, sentinel-routing extension. Not promoted to a Tuist target — stays an in-app subfolder per C3 design doc §Component Boundaries.
- `apps/mac/touch-code/Runtime/HierarchyManager.swift` — `@MainActor @Observable` structural writer landed in 0002 M2. M2 of this plan adds `setPanelLabels(_:labels:replace:)` as the canonical writer for C3/C4-added `Panel.labels`. Exec-plan-0002 M4/M5 adds the mutation methods backing the CLI verbs (createWorktree over real git, send input, broadcast, etc.).
- `apps/mac/touch-code/Runtime/HierarchyRuntime.swift` + `Runtime/Runtime.swift` — runtime protocol + shared engine stub, populated by 0002 M3/M4. This plan's M3 consumes `TerminalEngine.events()` once 0002 M4 lands.
- `apps/mac/tc/main.swift` — current body is `print(version)`. M4 replaces it with the ArgumentParser root and command tree.
- `apps/mac/Project.swift` — Tuist root. M1 adds the IPC test target, M2 adds no new target (tests land inside `touch-codeTests`), M4 adds the `tcTests` target and a small `tcIntegrationTests` scheme.

Terminology used in this plan:

- **Daemon side** — code running in the `touch-code` app process (not the CLI). "Daemon" is informal; the app is a windowed macOS application that also listens on a Unix socket. No launchd agent, no true daemon process.
- **RPC method string** — a lowercase-dotted identifier such as `hook.install`. Defined as a case of the `IPC.Method` enum with `String` raw values; both sides switch on the enum, never on the string.
- **Frame** — one length-prefix-plus-body envelope on the wire. A request is always one frame; a streaming response is a sequence of frames terminated per C4 §Wire protocol.
- **Unary vs streaming** — a unary RPC is one request → one response; a streaming RPC is one request → many response frames → one final `{id, stream: false}` frame. `hook.events` is the only streaming RPC in v1.
- **AliasResolver** — a small client-side module in `apps/mac/tc/Transport/AliasResolver.swift` that fast-paths pure UUID strings locally and delegates everything else to `hierarchy.resolveAlias` RPC.
- **Sentinel-prefix route** — a `HookSubscription` whose `command` starts with the reserved `__touch-code/internal:` namespace is delivered to an in-process `InternalHookSubscriber` instead of spawned as a child process. See C3 DEC-16.

Orientation paragraph. The work is layered but we deliver vertically. M1 lands the shared wire vocabulary in `TouchCodeCore` + `TouchCodeIPC` so the CLI and the app agree on types from day one. M2 implements the hook dispatcher entirely headless — no Ghostty, no AppKit, no sockets — using an injectable `HookExecutor` for the subprocess layer; this is the largest single milestone and the highest-leverage piece to ship well. M3 wires the `SocketServer` on the app side, registers the `hook.*` handlers plus `system.hello`, and pipes `HookDispatcher` events into a streaming RPC; at this point a hand-crafted `curl`-style client could exercise the whole hook surface. M4 brings up the `tc` binary with plumbing but only the `system` verbs (`ping`, `status`, `version`, `launch`); this is the first real end-to-end RPC flow. M5 adds the full `tc hook …` CLI surface including the streaming `tc hook tail`. M6 fans out the rest of the command surface against `HierarchyManager` / `TerminalEngine` / `SkillInstaller` / `ExternalEditor`. M7 hardens everything: integration tests against a real headless app, generated completion scripts, `tc --man`, documentation. Each milestone is independently buildable and independently testable; a regression in M3 does not block verification of M2.

## Plan of Work

Seven milestones. M1–M2 are parallelizable with 0002's M3 (GhosttyKit bring-up) — they touch disjoint code. M3 onward requires 0002 M4 merged. The first commit of each milestone re-runs `make mac-generate` and `make mac-build` clean before any code change.

### Milestone 1: TouchCodeCore + TouchCodeIPC wire types

**Goal after this milestone.** Every value type the design docs name — `HookEvent`, `HookScope`, `HookMatchRange`, `HookEventData`, `HookEnvelope`, `HookSubscription`, `HookConfig`, `BroadcastScope`, `PanelOpenRequest`, `AliasResolveRequest`, `AliasResolveResult`, plus the `IPC.Request` / `IPC.Response` / `IPC.Method` / `IPCError` envelopes and the `Framing` helper — exists in Swift with full `Codable` + `Equatable` + `Sendable` conformance. A test suite round-trips every variant through `JSONEncoder` ↔ `JSONDecoder`. Zero AppKit / SwiftUI / GhosttyKit imports. Nothing on the wire yet; nothing spawns anything; this milestone is pure types + tests.

Why this ships first. Three later milestones (M2 Hooks, M3 daemon RPC, M4 CLI) all import these types. Landing them first makes every later build self-contained — a contributor can pick up M4 without waiting on M2.

**Work.** Under `apps/mac/TouchCodeCore/Hooks/` create:

- `HookEvent.swift` — the enum defined in C3 §API Design, including the `scope` accessor and `CaseIterable` conformance, with `panel.input` included per C3 v2 fix.
- `HookScope.swift` — the four-case helper enum.
- `HookMatchRange.swift` — portable `{ start, length }` struct replacing `NSRange`.
- `HookEventData.swift` — the tagged-union `Codable` enum with hand-rolled encoder/decoder keyed on a `"kind"` discriminator.
- `HookEnvelope.swift` — the struct with `SpaceRef` / `ProjectRef` / `WorktreeRef` / `TabRef` / `PanelRef` nested types, ISO-8601 date coding via a shared `JSONEncoder.isoStyle()` factory, and a `validateAnchors()` throws helper (debug-only caller convention; release builds skip the check but the code compiles identically).
- `HookSubscription.swift` — the struct with `Scope` enum (`anyPanel` / `panelID` / `panelLabel` / `tabID` / `tabLabel` / `worktreeID` / `worktreePathGlob`), `Mode` enum, `RegexFlags` option set, `allowRawOutput`, `allowRawInput`, `idleThresholdSeconds`, `disabled`.
- `HookConfig.swift` — the top-level file schema with `version: Int = 1`, `recursionWindowMs: Int = 250`, `subscriptions: [HookSubscription]`. Same version-gated `Codable` pattern as `Catalog`.
- `HookAction.swift` — the action DSL enum with all 10 variants + `BroadcastScope` nested enum. Imports `TouchCodeIPC` only if the `BroadcastScope` wire type lives in IPC (it does; keep the action's nested enum a *thin alias* that encodes to the same JSON).

Under `apps/mac/TouchCodeIPC/` replace the one-line stub `IPC.swift` with:

- `Framing.swift` — `enum Framing { static func encode(_ body: Data) -> Data; static func decode(from buffer: inout Data) throws -> Data? }`. Implements the `UInt32` big-endian length-prefix per DEC-3.
- `Method.swift` — `enum IPC.Method: String, Codable, Sendable { case systemHello = "system.hello"; case systemPing = "system.ping"; /* … every method referenced in C4 API tables … */ }`. Pin every method string in one file.
- `Envelope.swift` — `struct IPC.Request { id, method, params: JSONValue, stream: Bool }` and `struct IPC.Response { id, stream: Bool, result: JSONValue?, error: IPCError? }`. `JSONValue` is a small enum for dynamic params; per-method typed decoders live in callers.
- `IPCError.swift` — the enum with all eight cases per C4 §Error codes; Codable encoding is `{ "code": String, "message": String, "path": [String]? }`.
- `WireTypes/BroadcastScope.swift`, `WireTypes/PanelOpenRequest.swift`, `WireTypes/AliasResolveRequest.swift`, `WireTypes/AliasResolveResult.swift`, `WireTypes/PanelRef.swift` (reused by `HookEnvelope`), `WireTypes/WorktreeRef.swift`, etc. — pure struct definitions.
- `HandshakeTypes.swift` — `struct HelloRequest { clientVersion: String; clientBinary: String }` and `struct HelloResponse { serverVersion, appBundleVersion, protocolMajor, protocolMinor, deprecatedMethods: [String] }`.

Add new test files under `apps/mac/TouchCodeCoreTests/Hooks/`:

- `HookEventCodableTests.swift` — every case of `HookEvent` round-trips through a small `{"event": "…"}` JSON.
- `HookEventDataCodableTests.swift` — every `HookEventData` case encodes with the correct `"kind"` discriminator and decodes back to equality.
- `HookEnvelopeCodableTests.swift` — a Panel-scoped envelope carrying every field round-trips; decoding rejects unknown top-level fields; `validateAnchors()` throws when a `panel.*` envelope is missing its `tab` field in debug builds.
- `HookSubscriptionCodableTests.swift` — every `Scope` variant round-trips; decoder rejects reserved env-var keys (`TOUCH_CODE_*`); decoder rejects `command` prefixes in the reserved `__touch-code/internal:` namespace unless loaded with an `internalNamespaceAllowed: true` flag.
- `HookConfigCodableTests.swift` — unknown-version rejection; default-value behaviour when `recursionWindowMs` absent.
- `HookActionCodableTests.swift` — all 10 action variants round-trip; decoder rejects unknown action kinds.

Under `apps/mac/TouchCodeCoreTests/IPC/` (new folder in the same test target; no new Tuist target):

- `FramingTests.swift` — encode/decode round-trip for frames up to 1MB; malformed length prefix throws; partial buffer returns `nil` without consuming bytes.
- `IPCEnvelopeCodableTests.swift` — request and response envelopes round-trip; `stream: true` flag survives encoding; `IPCError` decoder tolerates older codes.
- `WireTypeCodableTests.swift` — the four new `WireTypes/*` structs round-trip.

**Tuist wiring.** Add `"TouchCodeCore/Hooks"` to `TouchCodeCore`'s `buildableFolders`. Add a second buildableFolder to `TouchCodeIPC` if its sources move into subfolders (`"TouchCodeIPC/WireTypes"`); otherwise a single folder + multi-file is fine. Do **not** add a separate `TouchCodeIPCTests` target — fold IPC codable tests into `TouchCodeCoreTests`, which already links `TouchCodeCore` and can take an additional link to `TouchCodeIPC` via `dependencies: [.target(name: "TouchCodeCore"), .target(name: "TouchCodeIPC")]`. This matches DEC-1's "avoid proliferating test targets" principle.

**Observable acceptance.** `make mac-generate && make mac-build` produces `TouchCodeCore.framework` and `TouchCodeIPC.framework` with the new types exported. `xcodebuild test -scheme TouchCodeCoreTests` reports **all tests pass**, with the new hook-codable tests numbering at least 20. `make mac-lint` is clean. `grep -r 'import AppKit\|import SwiftUI\|import GhosttyKit' apps/mac/TouchCodeCore apps/mac/TouchCodeIPC` returns no matches. A quick `swift -e` snippet that instantiates a `HookEnvelope`, encodes it, decodes it back, and asserts equality compiles and runs.

**Expected commits.** `feat(core): HookEvent/HookEventData/HookEnvelope wire types + tests`, `feat(ipc): IPC envelope, framing, method enum, IPCError, handshake types`, `feat(ipc): BroadcastScope + PanelOpenRequest + AliasResolve wire types`.

### Milestone 2: Hooks in-app subfolder

**Goal after this milestone.** `apps/mac/touch-code/Hooks/` is a fully-fleshed in-app subfolder (not a separate Tuist target) containing the dispatcher, executor, config store, action dispatcher, and internal-subscriber seam. A contributor can unit-test the entire hook subsystem headlessly: no GhosttyKit, no AppKit, no sockets, no real child processes. A `FakeHookExecutor` replaces `ProcessHookExecutor` for tests; a `FakeHookActionDispatcher` records what would have been dispatched.

**Work.** Under `apps/mac/touch-code/Hooks/`:

- `HookConfigStore.swift` — `@MainActor final class` wrapping `~/.config/touch-code/hooks.json` through `TouchCodeCore.AtomicFileStore` (DEC-8). Methods: `load() throws -> HookConfig`, `save(_ config: HookConfig) throws`, `scheduleSave(_:)` with 500ms debounce (same pattern `CatalogStore` uses). `load` backs broken files to `hooks.json.broken-<ISO8601>` and returns `.default`. Load-time validation enforces: reserved env-var keys rejected, `__touch-code/internal:` prefix rejected for user-authored subscriptions, bad regex patterns rejected (compile once, cache the `NSRegularExpression`). Emits `HookConfigError.invalidRegex` / `.reservedEnv` / `.reservedPrefix` per the design doc error-handling table.
- `HookExecutor.swift` — the protocol exactly as C3 §Hooks module specifies: `func run(subscription:envelope:) async -> HookExecutionResult`. Plus `struct HookExecutionResult { exitCode, stdout, stderr, duration, timedOut, actions: [HookAction] }`.
- `ProcessHookExecutor.swift` — the real `Foundation.Process`-backed executor. Spawns `/bin/sh -c <command>`; sets env vars `TOUCH_CODE_SOCKET_PATH`, `TOUCH_CODE_EVENT`, `TOUCH_CODE_VERSION`, `TOUCH_CODE_*_ID` for every anchor present in the envelope; pipes `JSONEncoder(isoStyle).encode(envelope)` followed by EOF to stdin; buffers stdout and stderr to 1MB max; kills the process group via `killpg` on timeout with a 2s SIGKILL grace. Actions are parsed from stdout only when `subscription.mode == .awaitActions`.
- `FakeHookExecutor.swift` — records a `[(HookSubscription, HookEnvelope)]` transcript, returns a caller-supplied `HookExecutionResult`. Used in tests.
- `HookActionDispatcher.swift` — `@MainActor final class` that translates each `HookAction` into a call against the in-process `HierarchyManager` / `TerminalEngine` / notification service. For v1, unknown action variants are dropped (logged). `HookAction.setPanelLabels` calls `HierarchyManager.setPanelLabels(_:labels:replace:)` — the canonical funnel per C3 data-model §. Sending actions through the socket is explicitly forbidden (C3 D15).
- `HookActionDispatcher+Notify.swift` — the `notify` action uses `NSUserNotificationCenter` or `UNUserNotificationCenter` (macOS 14+); stub it in M2 to call a small `NotificationService` protocol so tests don't touch AppKit. The real implementation can land when C6 does.
- `HookDispatcher.swift` — the central class. Public API exactly matches C3 §Hooks module:

      @MainActor
      public final class HookDispatcher {
        public init(
          config: HookConfig,
          store: HookConfigStore,
          executor: HookExecutor = ProcessHookExecutor(),
          actionDispatcher: HookActionDispatcher,
          maxConcurrency: Int = 8
        )
        public func attach(to events: AsyncStream<TerminalEvent>)
        public func fire(_ envelope: HookEnvelope) async
        public func reloadConfig() async throws
        public func internalEventStream() -> AsyncStream<HookEnvelope>
        public func register(subscriber: InternalHookSubscriber, for prefix: String) throws
        public func unregister(prefix: String)
      }

  Implementation details the design doc already pins: pre-compiled regex table `[PanelID: [(HookSubscription, NSRegularExpression)]]` built on `reloadConfig`; per-event lookup `[HookEvent: [HookSubscription]]`; `AsyncSemaphore` with capacity `maxConcurrency`; per-subscription token bucket (30 fires / 10s) that transitions a subscription to `disabled` on overflow (R1). In-flight handlers get a `let`-captured snapshot (DEC-7). Recursion guard tags every action with its originating envelope id and suppresses direct re-entry within `HookConfig.recursionWindowMs` (default 250) on `.panelOutput` / `.panelInput`.
- `HookRecentRing.swift` — bounded ring buffer of `HookFireRecord` (256 entries, design-doc default). Read from `hook.recent` RPC in M3.
- `HookFireRecord.swift` — `{ id, envelope, subscriptionID, duration, exitCode, actionsDispatched, actionsRefused, timedOut, killed, rateLimited }` plus `Codable` for RPC exposure.
- `InternalHookSubscriber.swift` — the protocol `func handle(envelope: HookEnvelope) async`. Sentinel routing inside `HookDispatcher`: before invoking `executor.run`, inspect `subscription.command`; if it begins with a registered prefix (must be within `__touch-code/internal:` namespace), route directly to the subscriber and skip the process spawn. Recursion guard and rate limit still apply.

Update `apps/mac/touch-code/Runtime/HierarchyManager.swift` to add the canonical labels writer:

    public func setPanelLabels(_ id: PanelID, labels: Set<String>, replace: Bool = false) throws

Implementation: updates `catalog.spaces[*].projects[*].worktrees[*].tabs[*].panels[*].labels`; calls `store.scheduleSave(catalog)`. Replace vs. merge is a flag. Throws `.panelNotFound` when the id is unknown. Unit test in `HierarchyManagerTests.swift`.

Add tests under `apps/mac/touch-code/Tests/Hooks/`:

- `HookConfigStoreTests.swift` — round-trip write/read; backup on parse error; reserved-env-var rejection; reserved-prefix rejection; invalid-regex rejection with the failing subscription reported but the rest loaded.
- `HookDispatcherFireTests.swift` — firing an envelope invokes the right subscription via `FakeHookExecutor`; multiple matching subscriptions each get invoked; non-matching events are silent.
- `HookDispatcherOutputMatchTests.swift` — a `.panelOutput(Data)` event with a 4KB payload against a `(?i)ready` regex synthesises exactly one `.panelOutputMatch` envelope with correct `HookMatchRange`. A panel without any matching subscription pays zero per-batch regex cost (asserted by checking the compiled-regex table for that panel is empty).
- `HookDispatcherIdleTests.swift` — idle envelopes below `idleThresholdSeconds` are dropped client-side; above it, the executor fires.
- `HookDispatcherConcurrencyTests.swift` — with `maxConcurrency = 2`, three simultaneous fires run 2-at-a-time; token bucket rate-limits to 30/10s; exceeding rate transitions the subscription to `disabled`.
- `HookDispatcherRecursionGuardTests.swift` — a handler that emits `HookAction.panelSend(same-panel, text)` does not re-fire within `recursionWindowMs`; a handler that emits `tab.activate` does re-fire (tab events are not guarded).
- `HookDispatcherInternalSubscriberTests.swift` — a subscription with `command: "__touch-code/internal:notif:<uuid>"` registered to a fake subscriber bypasses `FakeHookExecutor` and is delivered directly.
- `HookActionDispatcherTests.swift` — every `HookAction` case routes to the right in-process method; `setPanelLabels` hits `HierarchyManager.setPanelLabels`.
- `HookConfigHotReloadTests.swift` — `reloadConfig()` atomically swaps the table; an in-flight handler retains its old snapshot (captured via a fake that sleeps then inspects its subscription reference).

**Observable acceptance.** `xcodebuild test -scheme touch-code -only-testing:touch-codeTests/Hooks` reports **all tests pass**, with at least 20 hook-dispatcher tests. `grep -r 'import GhosttyKit\|import AppKit' apps/mac/touch-code/Hooks` returns no matches. `make mac-lint` is clean. A tiny manual smoke via a debug hook in `TouchCodeApp.init` that calls `HookDispatcher.fire(syntheticPanelReadyEnvelope)` and a handler at `echo -n "$TOUCH_CODE_PANEL_ID" > /tmp/tc-hook-echo` leaves the right UUID in `/tmp/tc-hook-echo`.

**Expected commits.** `feat(hooks): HookConfigStore + atomic-rename + load-time validation`, `feat(hooks): HookDispatcher + HookExecutor + FakeHookExecutor`, `feat(hooks): HookActionDispatcher + internalEventStream + sentinel routing`, `feat(runtime): HierarchyManager.setPanelLabels canonical writer`.

### Milestone 3: Daemon-side IPC methods + `system.hello` + backpressure

**Goal after this milestone.** A running app accepts connections on `/tmp/touch-code-$UID.sock`, speaks the C4 wire protocol, and answers every `hook.*` method plus `system.hello` / `system.ping` / `system.version` / `system.status`. A hand-crafted socket client (e.g., a Python test harness) can install a hook, fire it, and tail the events stream. This is the first milestone that requires 0002's M4 to be merged: `HookDispatcher.attach(to:)` consumes the real `TerminalEngine.events()` stream.

**Work.** Under `apps/mac/touch-code/App/Features/Socket/`:

- `SocketServer.swift` — `@MainActor final class` owning the Unix socket. Listens on the configured path; accepts connections in a detached `Task`; per-connection dispatches to a `SocketConnection` actor (below). Tears down cleanly on app quit.
- `SocketConnection.swift` — per-connection actor. Owns `AsyncChannel<IPC.Request>(maxBufferedElements: 64)` for in-flight backpressure (DEC-9). Reads frames via `Framing.decode`; writes via `Framing.encode`. First frame must be `system.hello` or the connection is closed with `.versionMismatch`. After the handshake, one unary call OR one streaming call before connection close.
- `HelloHandler.swift` — handles `system.hello`. Validates client version against server; emits warning to os.Logger on minor skew; returns `.versionMismatch` on major skew.
- `SocketPeerAuth.swift` — small wrapper around `LOCAL_PEERCRED` (macOS) for uid verification. Closes the connection if peer uid != user uid.
- `MethodRouter.swift` — large `switch` over `IPC.Method` dispatching to the right handler. Handlers are small: each receives typed params (decoded from `request.params` into the expected wire struct) and returns typed results.
- `handlers/HookHandlers.swift` — one method per `hook.*`:
  - `hook.list` → `hookDispatcher.config.subscriptions.filtered(by:)`.
  - `hook.install` → validates, appends, persists via `HookConfigStore.save`.
  - `hook.remove`, `hook.enable`, `hook.reload`, `hook.test`, `hook.fire` — each a small method on `HookDispatcher`.
  - `hook.recent` → reads the `HookRecentRing`.
  - `hook.events` → streaming. Subscribes to `HookDispatcher.internalEventStream()` (NOT to the Runtime stream directly — events must be filtered through the dispatcher's match pass first, so tailing sees the same synthesised `.panelOutputMatch` a handler would see). Emits `{id, stream: true, result: <envelope>}` frames per event. On connection-write-half close (client-initiated end), flushes in-flight events, sends `{id, stream: false}` final frame, closes its write half.
- `handlers/SystemHandlers.swift` — `system.ping` / `system.version` / `system.status` / `system.quit` / `system.hello`.
- `handlers/HierarchyReadHandlers.swift` — read-only handlers backing M4 (`hierarchy.listSpaces`, `hierarchy.describeSpace`, etc.). Populate just enough to satisfy M4's `system` verbs + `tc panel list` / `tc panel show`; the mutation handlers land in M6.

Update `apps/mac/touch-code/App/TouchCodeApp.swift`:

- Construct one shared `TerminalEngine` (from 0002 M4), one shared `HookDispatcher` (from M2), one shared `SocketServer`, wire them together.
- `HookDispatcher.attach(to: engine.events())` is called once at launch.
- The socket path is chosen via `ProcessInfo.processInfo.environment["TOUCH_CODE_SOCKET_PATH"] ?? "/tmp/touch-code-\(getuid()).sock"`. The server cleans up stale socket files (checks for a live listener via `connect` + close; if no live listener, unlinks).

Add tests under `apps/mac/touch-code/Tests/Socket/`:

- `FramingWireTests.swift` — encodes an envelope, writes through an in-memory socket, decodes back, asserts round-trip.
- `SocketServerLifecycleTests.swift` — server binds, accepts a connection, closes on quit; stale socket file is unlinked on start.
- `HandshakeTests.swift` — first frame must be `system.hello`; non-hello first frames close the connection; major-version skew responds with `.versionMismatch`.
- `HookHandlersTests.swift` — in-memory socket round-trip for each `hook.*` method; `hook.install` persists a subscription, `hook.remove` removes it, `hook.list` reflects the state.
- `HookEventsStreamingTests.swift` — a client sends a streaming `hook.events` request, the app fires three synthetic events, the client receives exactly three `{stream: true}` frames plus one `{stream: false}` terminator after the client closes its write half.
- `BackpressureTests.swift` — opening 65 simultaneous in-flight requests on one connection causes the 65th to receive `IPCError.overloaded` after the 2s wait.

**Observable acceptance.** `xcodebuild test -scheme touch-code` is green. `make mac-run-app` starts the app; in another shell, `nc -U /tmp/touch-code-$UID.sock` followed by pasting a length-prefix-hex-framed `system.hello` responds with a well-formed JSON. A small Python script in `scripts/wire-smoke.py` (dev-only, not shipped) installs a hook and fires it.

**Expected commits.** `feat(socket): SocketServer + SocketConnection + Framing wire`, `feat(socket): system.hello handshake + peer-uid auth`, `feat(socket): hook.* method handlers`, `feat(socket): streaming hook.events RPC`, `feat(app): wire TerminalEngine -> HookDispatcher -> SocketServer`.

### Milestone 4: `tc` CLI scaffold

**Goal after this milestone.** `tc` is a real ArgumentParser-rooted binary that implements every `tc system …` verb end-to-end: `tc system ping` hits the app and prints `pong`; `tc system status` prints JSON with app version; `tc system version` prints both binary and server versions; `tc system launch` launches the app if not running and waits up to 10s; `tc system sockets` enumerates discovery paths. The plumbing behind them (`RPCClient`, `SocketDiscovery`, `AliasResolver`, renderers, exit-code table) exists and is unit-tested.

**Work.** Under `apps/mac/tc/`:

- `main.swift` — replace the one-liner with the ArgumentParser root `TouchCodeCLI`. Global flags: `--json`, `--socket`, `--verbose`, `--no-color`, `--timeout`, `--help`, `--version`, `--generate-completion-script`, `--man`. Subcommand registration includes a stub for every namespace, but only `system` is implemented — other namespaces parse and print "not yet implemented".
- `Transport/Framing.swift` — thin re-export of `TouchCodeIPC.Framing`.
- `Transport/SocketDiscovery.swift` — resolves socket path via env → default → optional launch. Returns `DiscoveredSocket { path: String, wasLaunched: Bool }`.
- `Transport/RPCClient.swift` — one instance per `tc` invocation. `connect(to path: String) throws -> Connection`; `call<T: Decodable>(_ method: IPC.Method, params: Encodable, timeout: TimeInterval) async throws -> T`; `stream<T: Decodable>(_ method: IPC.Method, params: Encodable) -> AsyncThrowingStream<T, Error>`. On `call`, pipelines `system.hello` + the real request (DEC-4). Discards the handshake response unless it carries an error.
- `Transport/AliasResolver.swift` — UUID-fast-path locally; everything else calls `hierarchy.resolveAlias` RPC. Caches per-invocation (a small dictionary), never across invocations.
- `Render/TextRenderer.swift` — `func render<T>(_ value: T) -> String`. Concrete overloads for each result type from M4's `system` verbs (list, show).
- `Render/JSONRenderer.swift` — `func render<T: Encodable>(_ value: T) -> String` using the shared encoder.
- `Render/Mode.swift` — `enum Mode { case text(useColor: Bool), json }`.
- `ExitCode.swift` — the enum pinned by C4 §Exit codes, mapping `IPCError` cases to `Int32` codes. Note: `11` = request timeout, `12` = launch timeout (the post-review v2 split).
- `Commands/SystemCommands.swift` — implements `tc system {ping, status, version, launch, quit, sockets}`. Each subcommand is a `ParsableCommand` with `func run() async throws`.
- `Commands/StubbedNamespaces.swift` — declares `SpaceCommand`, `ProjectCommand`, `WorktreeCommand`, etc. as `ParsableCommand` with a single `NotImplemented` child that prints "not yet implemented in this build (milestone M5/M6)". ArgumentParser still generates `--help` for them, keeping discoverability.

Add a new Tuist target `tcTests`:

- `.unitTests` target hosting `tc` tests. Depends on `.target("tc")` via `@testable import tc`.
- Tests under `apps/mac/tc/Tests/`:
  - `ArgumentParsingTests.swift` — every subcommand path parses; invalid flag combinations throw `ValidationError`.
  - `SocketDiscoveryTests.swift` — env-var wins over default; missing socket with no `--launch-app` errors exit 10; missing socket with `--launch-app` attempts launch and times out exit 12.
  - `RPCClientTests.swift` — against an `InMemoryIPCServer` harness (port of M3's in-memory socket): unary call round-trip; streaming call round-trip; timeout returns exit 11; handshake-version-skew returns exit 6.
  - `AliasResolverTests.swift` — UUID-fast-path no round trip; `current` / `.` pick the right env var; ambiguous label returns `.conflict`.
  - `RenderingTests.swift` — golden files for `tc system status` text mode; JSON mode 1:1 with the RPC result.
  - `ExitCodeMappingTests.swift` — every `IPCError` variant maps to the right exit code.

Add to `apps/mac/Project.swift`:

- `tcTests` target wiring (dependencies on `tc`, `TouchCodeIPC`, `TouchCodeCore`).
- `tc` gains `"Tests/**"` exclusion from its own `buildableFolders` so test sources don't compile into the CLI binary.

**Observable acceptance.** `xcodebuild build -scheme tc` succeeds. `xcodebuild test -scheme tcTests` is green. `make mac-run-app &` then `./apps/mac/.build/.../tc system ping` prints `pong` and exits 0. `tc system status --json | jq .serverVersion` prints the running app's version. `tc --help` lists `space / project / worktree / tab / panel / send / broadcast / skill / open / hook / system`, with every non-system subcommand showing its stub.

**Expected commits.** `feat(cli): ArgumentParser root + global flags + exit-code table`, `feat(cli): SocketDiscovery + RPCClient with system.hello pipelining`, `feat(cli): tc system {ping, status, version, launch, quit, sockets}`, `feat(cli): AliasResolver UUID-fast-path + stubbed namespace commands`.

### Milestone 5: `tc hook` subcommands (full surface)

**Goal after this milestone.** The complete `tc hook …` command tree works end-to-end against the running app: install a subscription from a file, list them, disable one, tail a live event stream, fire a synthetic event for handler development. This is the first milestone where an outside user can actually write a workflow.

**Work.** Under `apps/mac/tc/Commands/`:

- `HookCommands.swift` — the subcommand tree:
  - `tc hook list [--event E] [--panel ID]` → `hook.list`. Renders a table in text mode, JSON array in JSON mode.
  - `tc hook install FILE|-` → reads JSON from FILE or stdin, sends `hook.install`. Prints the assigned id.
  - `tc hook remove ID` → `hook.remove`. Exits 2 if not found.
  - `tc hook enable ID` / `tc hook disable ID` → `hook.enable { enabled: true|false }`.
  - `tc hook reload` → `hook.reload`. Prints `{loadedCount, errors}` in text mode.
  - `tc hook test ID [--payload PATH]` → reads a synthetic envelope (default: a minimal one matching the subscription's event) and sends `hook.test`. Prints `HookExecutionResult`.
  - `tc hook fire EVENT [--panel ID] [--data JSON]` → `hook.fire`. Prints `{handlersRun}`.
  - `tc hook recent [--limit N]` → `hook.recent`. Renders a table (timestamp, subscription id, event, exitCode, duration).
  - `tc hook tail [--event E]` → opens the `hook.events` streaming RPC. Prints NDJSON lines (one JSON envelope per line, newline-separated). SIGINT cleanly closes the write half and exits 0 after the server's final frame.
  - `tc hook edit` → opens `~/.config/touch-code/hooks.json` in `$EDITOR`; on exit, if the file was modified, calls `hook.reload` automatically.

- `Commands/HookInstallInputs.swift` — FILE vs stdin reader, validates the JSON against `HookSubscription`'s decoder before sending.

Update tests:

- `tcTests/HookCommandsTests.swift` — each subcommand's parse + render against the `InMemoryIPCServer` harness. `tc hook tail` asserts it prints three NDJSON lines when the server emits three envelopes before closing its write half.
- Daemon-side `apps/mac/touch-code/Tests/Socket/` gains a round-trip scenario: `tc hook install` over real Unix socket against a test-harness `SocketServer`; the installed subscription is present in a subsequent `tc hook list`.

**Observable acceptance.** With the app running: `tc hook install <(echo '{"id":"11111111-1111-4111-8111-111111111111","event":"panel.ready","command":"echo from-hook"}')` exits 0 and prints the id. `tc hook list --json | jq '.subscriptions | length'` prints `1`. `tc hook test 11111111-…` runs the handler in-app and prints `exitCode: 0, stdout: "from-hook\n"`. `tc hook tail` prints events as they fire — `tc panel open` in another shell (stubbed in M4, real in M6) or `tc hook fire panel.ready --panel <id>` triggers a line on stdout.

**Expected commits.** `feat(cli): tc hook {list, install, remove, enable, disable, reload}`, `feat(cli): tc hook {test, fire, recent}`, `feat(cli): tc hook tail (streaming) + tc hook edit`.

### Milestone 6: Hierarchy / Terminal / Skill / Open / System mutation verbs

**Goal after this milestone.** The full C4 command surface works against a running app: the user can drive Spaces / Projects / Worktrees / Tabs / Panels entirely from the CLI, send and broadcast text into panels, install the Skill into Claude Code / Codex / pi, open the current Worktree in VSCode / Cursor / Zed / Xcode / Sublime Text / Finder, and run `tc system quit` to shut down cleanly.

**Work.** Under `apps/mac/tc/Commands/`, replace the stubs with full implementations:

- `SpaceCommands.swift` — `list`, `create`, `rename`, `remove`, `activate`, `show`.
- `ProjectCommands.swift` — `list`, `add`, `remove`, `rename`, `set-editor`, `show`.
- `WorktreeCommands.swift` — `list`, `create`, `remove`, `activate`, `rename`, `show`, `prune`. `create` and `remove` refuse on non-git Projects with exit 4 via the server's `.unsupported` error.
- `TabCommands.swift` — `list`, `create`, `close`, `activate`, `rename`, `show`.
- `PanelCommands.swift` — `list`, `open`, `split`, `close`, `focus`, `resize`, `zoom`, `unzoom`, `retry`, `label`, `show`, `info`.
- `SendBroadcastCommands.swift` — `tc send` and `tc broadcast` (both back `terminal.sendInput` / `terminal.broadcastInput` per C4 D6).
- `SkillCommands.swift` — `list`, `install`, `uninstall`, `path`, `check`. Backed by `SkillInstaller` service (app-side) or the graceful `.unsupported` fallback (DEC-5).
- `OpenCommand.swift` — `tc open [--in EDITOR]`, `tc open --path PATH [--in EDITOR]`, `tc open finder`. Backed by `ExternalEditor` service (app-side) or graceful fallback.
- `SystemCommandsExtended.swift` — `tc rpc METHOD [JSON]` debug escape (C4 D9).

Daemon side (`apps/mac/touch-code/App/Features/Socket/handlers/`):

- `HierarchyMutationHandlers.swift` — one method per mutation RPC (`hierarchy.createSpace`, `…renameSpace`, `…removeSpace`, `…activateSpace`, `…addProject`, `…removeProject`, `…renameProject`, `…setProjectEditor`, `…createWorktree`, `…removeWorktree`, `…activateWorktree`, `…renameWorktree`, `…pruneWorktrees`, `…createTab`, `…closeTab`, `…activateTab`, `…renameTab`, `…openPanel`, `…splitPanel`, `…closePanel`, `…focusPanel`, `…resizePanel`, `…zoomPanel`, `…unzoomPanel`, `…setPanelLabels`, `…resolveAlias`, `…resolvePanelLabel`, `…resolveWorktreeGlob`). Each is a thin call to `HierarchyManager`. Mutations landed by 0002 M5 are delegated directly; any mutation that 0002 has not yet shipped (e.g., `resizePanel` if it slips) is temporarily backed by an `.unsupported` response and an entry in this plan's Decision Log against 0002, resolved by that plan's next milestone.
- `TerminalHandlers.swift` — `terminal.sendInput`, `terminal.broadcastInput`, `terminal.retryPanel` backed by `TerminalEngine.sendInput` / fan-out helper.
- `SkillHandlers.swift` — `skill.listAgents`, `skill.install`, `skill.uninstall`, `skill.bundlePath`, `skill.check` backed by a new `apps/mac/touch-code/App/Services/SkillInstaller.swift`. `SkillInstaller` knows the three agent directories (`~/.claude/skills`, `~/.codex/skills`, `~/.pi/skills`) and defaults to symlinking the bundled skill resource into them. When the resource is absent in a dev build, returns `.unsupported(reason: "skill bundle resource not embedded in this build")`.
- `SystemOpenHandlers.swift` — `system.openInEditor`, `system.openPath` backed by `apps/mac/touch-code/App/Services/ExternalEditor.swift` (new). `ExternalEditor` ships the built-in allowlist (vscode, cursor, zed, xcode, subl, finder) + reads `settings.json.externalEditors[NAME]` templates.

Tests:

- `tcTests/HierarchyCommandsTests.swift` — parse + render for each subcommand; golden files for text + JSON modes.
- `touch-codeTests/Socket/HierarchyMutationHandlersTests.swift` — each mutation RPC issues the right call against a fake `HierarchyManager`.
- `touch-codeTests/Services/SkillInstallerTests.swift` + `ExternalEditorTests.swift` — unit tests against a tmp home directory (`HOME=/tmp/...`) so the tests don't touch the user's real agent directories.

**Observable acceptance.** With the app running:

    tc space create "validate" --activate
    tc project add .
    tc worktree create exp/validate
    tc tab create agent --activate
    tc panel open --label agent --cwd .

Each call exits 0 and produces visible state in the sidebar. `tc send @agent 'echo hello\n'` injects the command and the Panel's scrollback shows `hello`. `tc broadcast --tab current 'date\n'` injects `date` into every panel in the current tab. `tc open --in vscode` launches VSCode on the worktree directory. `tc skill install --claude-code` symlinks the bundled skill. `tc system quit` gracefully closes the app.

**Expected commits.** `feat(cli): tc space/project/worktree/tab/panel full surface`, `feat(cli): tc send + tc broadcast`, `feat(app): SkillInstaller service`, `feat(app): ExternalEditor service + tc open`, `feat(socket): hierarchy/terminal/skill/open mutation handlers`.

### Milestone 7: Integration tests, completion scripts, man page, docs

**Goal after this milestone.** The entire C3+C4 surface is covered by a headless integration test harness that launches the app, drives `tc` commands in sequence, and asserts catalog state + filesystem side effects. Pre-generated shell completions ship in the bundle. A groff man page is emitted from `tc --man`. Documentation is updated: the product spec Open-Questions table marks Q1, Q4, Q5, Q7 as resolved; the architecture doc's Open-Questions table marks Q3 and Q5 as resolved; the CHANGELOG records the release.

**Work.**

- `apps/mac/tcIntegrationTests/` — new Tuist target. Each XCTestCase launches a dedicated `touch-code` process via `Process` with `TOUCH_CODE_SOCKET_PATH=/tmp/tc-integ-$(uuidgen).sock` and a throwaway `HOME=$(mktemp -d)`. The test body runs `tc` subcommands and asserts. One test per C3+C4 §Validation scenario:
  - `ValidationScriptTest.swift` — runs the script in C4 §Validation and acceptance verbatim; asserts final catalog matches a golden snapshot.
  - `HookLifecycleTest.swift` — installs a hook, fires the matching event via `tc hook fire`, asserts the handler ran (wrote to a tmp file).
  - `HookTailTest.swift` — opens `tc hook tail` in a background `Process`, fires three events via `tc hook fire`, asserts three NDJSON lines on the tail's stdout.
  - `CollisionCheckTest.swift` — simulates `/opt/homebrew/bin/tc` existing, runs the installer, asserts `tcode` symlink is created and `tc` is not.
- `apps/mac/tc/Resources/completions/` — pre-generated `tc.zsh`, `tc.bash`, `tc.fish`. Regenerated via a `make mac-regen-completions` target (calls `tc --generate-completion-script <shell>` for each shell).
- `apps/mac/tc/Resources/tc.1` — groff man page generated from ArgumentParser command metadata. Include it as a resource in the `tc` Tuist target; `tc --man` prints it via `man -l -`.
- `docs/generated/tc-cli-reference.md` — auto-generated from `tc --help` and each subcommand's `--help`; `make mac-docs` regenerates.
- `docs/product-spec.md` — update the Open Questions table: Q1 (CLI name) resolved via C4 D1; Q4 (hook execution) resolved via C3 D1; Q5 (agent detection) resolved via C3 D10 + C4 Panel labels; Q7 (editor discovery) resolved via C4 D14.
- `docs/architecture.md` — Open Architectural Questions 3, 5 resolved; update inline refs to the new `Hooks` subfolder + `SocketServer` path.
- `CHANGELOG.md` — add a "0.2.0 — Hooks + CLI" entry.
- `docs/exec-plans/README.md` — move 0003 from Active to Completed, list it alongside 0002.
- `touch-code-skill/` peer directory — create a minimum-viable `SKILL.md` + `references/tc-commands.md` documenting the real CLI contract (only after M6 ships). The skill is not a Swift target, not built, not signed; just a directory of markdown + text. `tc skill install --claude-code` symlinks it from the app bundle at runtime; at dev time, a copy is stashed under `apps/mac/touch-code/Resources/touch-code-skill/` so the bundled resource exists.

**Observable acceptance.** `xcodebuild test -scheme tcIntegrationTests` runs all integration scenarios green in under 60s. A fresh contributor following the `CHANGELOG.md` release notes can install `tc`, tab-complete `tc hook ins<TAB>`, and read `tc --man | man -l -`.

**Expected commits.** `test(integration): tcIntegrationTests harness and scenarios`, `feat(cli): pre-generated completion scripts + man page`, `docs(spec): resolve product-spec + architecture open questions per C3+C4 plan`, `docs(changelog): 0.2.0 — Hooks + CLI`.

## Concrete Steps

Run every command from the repository root (`/Users/wanggang/dev/00/touch-code`) unless otherwise noted. Steps are grouped by milestone; keep the Progress section updated as each step completes.

### M1 steps

    # 1. Regenerate workspace after adding new source folders in Project.swift.
    make mac-generate

    # 2. Build TouchCodeCore + TouchCodeIPC.
    DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
      xcodebuild build -workspace apps/mac/touch-code.xcworkspace \
                       -scheme TouchCodeCore \
                       -scheme TouchCodeIPC | xcbeautify
    # Expected: BUILD SUCCEEDED for both schemes.

    # 3. Run Codable tests.
    DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
      xcodebuild test -workspace apps/mac/touch-code.xcworkspace \
                      -scheme TouchCodeCoreTests | xcbeautify
    # Expected tail: "Test Suite 'All tests' passed\n    Executed N tests, with 0 failures"
    # N should be prior-count + at least 20 new hook/IPC tests.

    # 4. Lint.
    make mac-lint
    # Expected: clean (no output).

### M2 steps

    make mac-generate
    DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
      xcodebuild test -workspace apps/mac/touch-code.xcworkspace \
                      -scheme touch-code \
                      -only-testing:touch-codeTests/Hooks | xcbeautify
    # Expected: all hook-dispatcher tests pass.

    # Manual smoke: debug hook in TouchCodeApp.init fires a synthetic panel.ready envelope.
    make mac-run-app
    # Expected: ~/.config/touch-code/hooks.json present if you touched any; /tmp/tc-hook-echo
    # contains a valid UUID iff the smoke subscription was installed.

### M3 steps (requires 0002 M4 merged)

    make mac-generate
    DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
      xcodebuild test -workspace apps/mac/touch-code.xcworkspace \
                      -scheme touch-code \
                      -only-testing:touch-codeTests/Socket | xcbeautify
    # Expected: socket-lifecycle, handshake, hook handler, streaming, backpressure tests pass.

    # End-to-end wire smoke:
    make mac-run-app
    python3 scripts/wire-smoke.py system.ping
    # Expected: {"id":"…","result":{"ok":true}}

### M4 steps

    make mac-generate
    DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
      xcodebuild test -workspace apps/mac/touch-code.xcworkspace \
                      -scheme tcTests | xcbeautify
    # Expected: argument parsing, socket discovery, RPC client, alias resolver, rendering tests pass.

    # End-to-end smoke:
    make mac-run-app
    ./apps/mac/.build/.../tc system ping
    # Expected: pong (exit 0).
    ./apps/mac/.build/.../tc system status --json | jq .serverVersion
    # Expected: a version string matching the running app.

### M5 steps

    DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
      xcodebuild test -workspace apps/mac/touch-code.xcworkspace \
                      -scheme tcTests \
                      -only-testing:tcTests/HookCommandsTests | xcbeautify

    # End-to-end:
    make mac-run-app
    echo '{"id":"11111111-1111-4111-8111-111111111111","event":"panel.ready","command":"echo from-hook"}' \
      | ./apps/mac/.build/.../tc hook install -
    # Expected: "installed 11111111-…"
    ./apps/mac/.build/.../tc hook list --json | jq '.subscriptions | length'
    # Expected: 1
    ./apps/mac/.build/.../tc hook tail &
    ./apps/mac/.build/.../tc hook fire panel.ready --panel current
    # Expected: one NDJSON line on the tail's stdout.
    kill %1

### M6 steps (requires 0002 M5/M6 merged)

    DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
      xcodebuild test -workspace apps/mac/touch-code.xcworkspace \
                      -scheme tcTests | xcbeautify

    # End-to-end walk-through:
    make mac-run-app
    ./apps/mac/.build/.../tc space create "validate" --activate
    ./apps/mac/.build/.../tc project add .
    ./apps/mac/.build/.../tc worktree create exp/validate
    ./apps/mac/.build/.../tc panel open --cwd .
    ./apps/mac/.build/.../tc send @current 'echo hello\n'
    # Expected: current Panel's scrollback shows "hello".

### M7 steps

    DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
      xcodebuild test -workspace apps/mac/touch-code.xcworkspace \
                      -scheme tcIntegrationTests | xcbeautify
    # Expected: full validation scenario passes end-to-end.

    # Regenerate completions + man page:
    make mac-regen-completions
    ls apps/mac/tc/Resources/completions/
    # Expected: tc.zsh, tc.bash, tc.fish

    ./apps/mac/.build/.../tc --man | head -5
    # Expected: first lines of a groff man page.

## Validation and Acceptance

After all seven milestones land, a fresh contributor can perform the following end-to-end flow and observe the exact outputs:

1. `make mac-bootstrap && make mac-generate && make mac-build && make mac-run-app` — the app launches within 1s.
2. From another shell: `tc system ping` → `pong`, exit 0 within 50ms.
3. `tc space create work --activate && tc project add . && tc worktree create exp/e2e` — the sidebar reflects the new Space / Project / Worktree immediately.
4. `tc panel open --cwd .` in the new Worktree — a live shell appears in the active Tab.
5. `tc hook install <(cat tests/fixtures/hooks/notify-stop.json)` — the handler is installed; `tc hook list --json | jq '.subscriptions | length'` prints `1`.
6. In a third shell: `tc hook tail &`. In the Panel: type `echo DONE` and press Enter. The tail emits an NDJSON line with `event: "panel.outputMatch"`, `data.match: "DONE"`.
7. `tc broadcast --tab current 'date\n'` — every Panel in the current Tab shows today's date.
8. `tc open --in vscode` — VSCode opens the Worktree directory.
9. `tc skill install --claude-code` — `~/.claude/skills/touch-code/SKILL.md` exists as a symlink into the app bundle.
10. `tc system quit` — the app closes gracefully; the socket file is unlinked.
11. All test schemes pass: `xcodebuild test -scheme TouchCodeCoreTests`, `-scheme touch-codeTests`, `-scheme tcTests`, `-scheme tcIntegrationTests`.
12. `make mac-lint` is clean.

Failure on any of the above blocks sign-off; the plan is not complete until all twelve are green.

## Idempotence and Recovery

Every milestone is re-runnable. Common recovery rituals:

- **Regenerate Xcode workspace.** `make mac-generate` is a pure function of `Project.swift` + Tuist config; safe to re-run.
- **Reset hooks config.** `mv ~/.config/touch-code/hooks.json ~/.config/touch-code/hooks.json.bak` forces a fresh empty config; M2's load path backs up broken files automatically.
- **Clear stale socket.** `rm -f /tmp/touch-code-$(id -u).sock` if a previous app crash left it; M3's server will unlink stale sockets on start but this gives the user an explicit recovery lever.
- **Reset catalog.** `mv ~/.config/touch-code/catalog.json ~/.config/touch-code/catalog.json.bak` (shared with 0002).
- **Uninstall `tc` shims.** `rm ~/.local/bin/tc ~/.local/bin/tcode`; M4's first-launch installer will reinstall on next app launch.
- **Unwind a failed hook install.** `tc hook remove <id>` is idempotent; if the id doesn't exist, exit 2 with no side effect.
- **Revert skill install.** `tc skill uninstall --claude-code` deletes the symlink. If the CLI is broken, `rm ~/.claude/skills/touch-code` manually.

None of the steps modify repository-wide state (no system `xcode-select`, no global git config, no PATH mutation via sudo). `DEVELOPER_DIR` is passed per command, matching bootstrap plan DEC-10. All tests that touch `~/.config/touch-code/` or `~/.claude/skills/` run against `HOME=$(mktemp -d)` to avoid stomping the user's real directories.

## Artifacts and Notes

Prototyping findings that inform this plan:

- **Length-prefix framing is a one-pass streaming decoder.** supaterm's `SupatermSocketProtocol.swift` reads a 4-byte header, uses `UInt32(bigEndian:)` to resolve length, and reads exactly that many bytes. Keeping the same shape in `TouchCodeIPC.Framing` lets us port that reader verbatim; no custom state machine.
- **ArgumentParser's `AsyncParsableCommand` handles the `async throws` surface cleanly.** The top-level `TouchCodeCLI.main()` becomes `await TouchCodeCLI.main()`; each subcommand conforms to `AsyncParsableCommand` so `RPCClient.call` is awaited directly in `run()` bodies.
- **`Process` + process-group kill works for the timeout case.** Validated in a 20-line sandbox against a `yes | head -c 1M` command that ignores SIGTERM: `killpg` after a 2s grace delivers SIGKILL to the whole tree. No shell-builtin edge case.
- **Streaming end semantics on macOS Unix sockets.** `shutdown(SHUT_WR)` from the client causes the server's `read` to return 0 (EOF). That's the signal we use for client-initiated stream termination; the final `{stream: false}` frame is sent before the server then closes its own write half. Verified in a minimal two-process test.
- **Hot-reload of `NSRegularExpression`.** Compiling a 50-line regex in a tight loop takes ~50µs on M1; even with 100 subscriptions on reload, we spend under 5ms total — imperceptible. No need to cache compiled regex on-disk.

Open prototyping tasks (not blocking this plan — log in Surprises & Discoveries as results come in):

- Benchmark the `hook.events` streaming throughput under load (1,000 events/sec target per C4 §Performance). Plan-side expectation: meets target; if not, add per-connection newline-buffer coalescing.
- Confirm `UNUserNotificationCenter` can post notifications from a non-SwiftUI context for the eventual C6 consumer. Not blocking M2 because the `NotificationService` protocol abstracts it out.

## Interfaces and Dependencies

The following types, functions, and signatures must exist by plan completion. Names are binding — later plans will reference them.

**`TouchCodeCore/Hooks/`** (no AppKit / SwiftUI / GhosttyKit imports):

    public enum HookEvent: String, Codable, Hashable, Sendable, CaseIterable {
      case panelCreated, panelReady, panelInput, panelOutput, panelOutputMatch,
           panelIdle, panelExited, panelCrashed,
           tabActivated, tabDeactivated, tabAutoClosed,
           worktreeActivated, worktreeDeactivated, worktreeCreated, worktreeRemoved
      public var scope: HookScope { get }
    }
    public enum HookScope: String, Codable, Sendable { case panel, tab, worktree, space }
    public struct HookMatchRange: Codable, Equatable, Sendable { public var start, length: Int }
    public enum HookEventData: Codable, Equatable, Sendable { /* 15 tagged cases */ }
    public struct HookEnvelope: Codable, Equatable, Sendable {
      public static let currentVersion = 1
      public var version: Int
      public var event: HookEvent
      public var timestamp: Date
      public var space: SpaceRef?
      public var project: ProjectRef?
      public var worktree: WorktreeRef?
      public var tab: TabRef?
      public var panel: PanelRef?
      public var data: HookEventData
      public func validateAnchors() throws       // debug-only callers
    }
    public struct HookSubscription: Codable, Equatable, Sendable, Identifiable {
      public var id: UUID
      public var event: HookEvent
      public var command: String
      public var matchPattern: String?
      public var matchFlags: RegexFlags
      public var scope: Scope
      public var timeoutSeconds: Double
      public var mode: Mode
      public var cwd: String?
      public var env: [String: String]
      public var allowRawOutput: Bool
      public var allowRawInput: Bool
      public var idleThresholdSeconds: Double?
      public var disabled: Bool
      public enum Scope: Codable, Equatable, Sendable { /* 7 variants */ }
      public enum Mode: String, Codable, Sendable { case fireAndForget, awaitActions }
      public struct RegexFlags: OptionSet, Codable, Sendable { /* caseInsensitive, multiline, dotAll */ }
    }
    public struct HookConfig: Codable, Equatable, Sendable {
      public static let currentVersion = 1
      public var version: Int
      public var recursionWindowMs: Int       // default 250
      public var subscriptions: [HookSubscription]
      public static let `default`: HookConfig
    }
    public enum HookAction: Codable, Equatable, Sendable { /* 10 variants */ }

**`TouchCodeIPC/`**:

    public enum IPC {}
    public extension IPC {
      enum Method: String, Codable, Sendable { /* ~40 cases across system/hierarchy/terminal/skill/hook */ }
      struct Request: Codable, Sendable  { let id: String; let method: Method; let params: JSONValue; let stream: Bool }
      struct Response: Codable, Sendable { let id: String; let stream: Bool; let result: JSONValue?; let error: IPCError? }
    }
    public enum IPCError: Codable, Equatable, Sendable {
      case unknownMethod(String)
      case invalidParams(String, path: [String]?)
      case notFound(kind: String, id: String)
      case conflict(reason: String)
      case unsupported(reason: String)
      case `internal`(String)
      case overloaded
      case versionMismatch(client: String, server: String)
    }
    public enum Framing {
      public static func encode(_ body: Data) -> Data
      public static func decode(from buffer: inout Data) throws -> Data?  // nil = need more bytes
    }
    public struct HelloRequest: Codable, Sendable { public let clientVersion: String; public let clientBinary: String }
    public struct HelloResponse: Codable, Sendable {
      public let serverVersion: String
      public let appBundleVersion: String
      public let protocolMajor: Int
      public let protocolMinor: Int
      public let deprecatedMethods: [String]
    }
    public struct BroadcastScope: Codable, Equatable, Sendable { /* { kind, target } */ }
    public struct PanelOpenRequest: Codable, Equatable, Sendable { /* tabID?, cwd?, initialCommand?, labels, activate */ }
    public struct AliasResolveRequest: Codable, Equatable, Sendable { /* kind, value, contextPanelID? */ }
    public struct AliasResolveResult: Codable, Equatable, Sendable { /* kind, id, disambiguations? */ }

**`apps/mac/touch-code/Hooks/`** (in-app subfolder):

    @MainActor public final class HookConfigStore {
      public init(fileURL: URL = Catalog.hooksDefaultURL())
      public func load() throws -> HookConfig
      public func save(_ config: HookConfig) throws
      public func scheduleSave(_ config: HookConfig)
    }
    public protocol HookExecutor: Sendable {
      func run(subscription: HookSubscription, envelope: HookEnvelope) async -> HookExecutionResult
    }
    public struct HookExecutionResult: Sendable { /* exitCode, stdout, stderr, duration, timedOut, actions */ }
    public final class ProcessHookExecutor: HookExecutor { /* fork+exec via /bin/sh -c */ }
    public final class FakeHookExecutor: HookExecutor { /* records transcript; returns caller-supplied result */ }
    @MainActor public final class HookActionDispatcher {
      public init(
        hierarchy: HierarchyManager,
        terminal: TerminalEngine,
        notificationService: NotificationService
      )
      public func execute(_ action: HookAction, originatingFrom envelopeID: UUID) async throws
    }
    @MainActor public final class HookDispatcher {
      public init(
        config: HookConfig,
        store: HookConfigStore,
        executor: HookExecutor = ProcessHookExecutor(),
        actionDispatcher: HookActionDispatcher,
        maxConcurrency: Int = 8
      )
      public func attach(to events: AsyncStream<TerminalEvent>)
      public func fire(_ envelope: HookEnvelope) async
      public func reloadConfig() async throws
      public func internalEventStream() -> AsyncStream<HookEnvelope>
      public func register(subscriber: InternalHookSubscriber, for prefix: String) throws
      public func unregister(prefix: String)
      public var recentFires: HookRecentRing { get }
    }
    public protocol InternalHookSubscriber: AnyObject, Sendable {
      func handle(envelope: HookEnvelope) async
    }

**`apps/mac/touch-code/App/Features/Socket/`**:

    @MainActor public final class SocketServer {
      public init(path: String, dependencies: SocketDependencies)
      public func start() throws
      public func stop()
    }
    actor SocketConnection {
      init(fd: Int32, dependencies: SocketDependencies)
      func serve() async
    }
    struct SocketDependencies {
      let hierarchyManager: HierarchyManager
      let terminalEngine: TerminalEngine
      let hookDispatcher: HookDispatcher
      let skillInstaller: SkillInstaller
      let externalEditor: ExternalEditor
    }

**`apps/mac/tc/`**:

    @main struct TouchCodeCLI: AsyncParsableCommand {
      static let configuration = CommandConfiguration(
        commandName: "tc",
        abstract: "Control touch-code from the terminal.",
        subcommands: [SpaceCommand.self, ProjectCommand.self, WorktreeCommand.self, TabCommand.self,
                      PanelCommand.self, SendCommand.self, BroadcastCommand.self, SkillCommand.self,
                      OpenCommand.self, HookCommand.self, SystemCommand.self, RPCCommand.self]
      )
    }
    final class RPCClient {
      init(path: String, clientVersion: String = TouchCodeCLI.version)
      func call<T: Decodable, P: Encodable>(_ method: IPC.Method, params: P, timeout: TimeInterval) async throws -> T
      func stream<T: Decodable, P: Encodable>(_ method: IPC.Method, params: P) -> AsyncThrowingStream<T, Error>
    }
    enum SocketDiscovery {
      static func discover(overridePath: String?) throws -> DiscoveredSocket
    }
    enum AliasResolver {
      static func resolve(_ value: String, kind: AliasResolveRequest.Kind, context: CLIContext, client: RPCClient) async throws -> UUID
    }
    enum ExitCode: Int32 {
      case ok = 0, userError = 1, notFound = 2, conflict = 3, unsupported = 4,
           overloaded = 5, versionMismatch = 6, noSocket = 10, requestTimeout = 11,
           launchTimeout = 12, `internal` = 20
    }

**External dependencies added by this plan** (in `apps/mac/Tuist/Package.swift`):

- No new SPM packages. `ArgumentParser` and `swift-composable-architecture` are already in place from prior plans. `AsyncChannel` comes from `swift-async-algorithms` — add this package now at pin `1.0.0`.

**Tuist targets added by this plan**:

- `tcTests` (`.unitTests`, host: `tc` binary).
- `tcIntegrationTests` (`.unitTests`, host: none — launches app via `Process`).

No new static-framework targets. `Hooks/` remains an in-app subfolder.

**Tuist buildableFolder additions**:

- `TouchCodeCore`: add `"TouchCodeCore/Hooks"`.
- `TouchCodeIPC`: add `"TouchCodeIPC/WireTypes"` if sources are split into subfolder.
- `touch-code` app target: `touch-code/App/Features/Socket` added to `buildableFolders` in M3.
- `touch-code` app target: `touch-code/App/Services` added in M6 for `SkillInstaller` and `ExternalEditor`.
- `touch-codeTests`: add `"touch-code/Tests/Hooks"` and `"touch-code/Tests/Socket"` and `"touch-code/Tests/Services"` as they land.
