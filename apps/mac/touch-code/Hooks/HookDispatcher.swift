import Foundation
import os
import TouchCodeCore

/// Central orchestrator for hook event delivery. Consumes the Runtime's
/// `AsyncStream<TerminalEvent>` via `attach(to:)`, matches each event
/// against the loaded subscription table, routes each match to either the
/// executor (user shell command), a registered `InternalHookSubscriber`
/// (sentinel-prefix route), or both depending on `HookSubscription.command`,
/// and publishes every fired envelope to the multicaster so in-process
/// consumers (C6) and the `hook.events` RPC can observe in real time.
///
/// M2 lands the public surface and the non-hot-path plumbing: loaded-table
/// snapshot, fire + attach event mapping for lifecycle events, sentinel
/// routing, multicaster wiring. The execution hot path — output-match
/// regex evaluation, recursion guard, rate limiter, idle-threshold
/// client-side filter, and the `TerminalEvent` → `HookEnvelope` mapper
/// — lands in exec-plan 0003 M2.1 follow-up (tracked in that plan's
/// Progress section; see below for the attach-path stub location).
@MainActor
public final class HookDispatcher {
  public static let defaultMaxConcurrency = 8

  private var config: HookConfig
  private let store: HookConfigStore
  private let executor: HookExecutor
  private let actionDispatcher: HookActionDispatcher
  private let multicaster: HookEventMulticaster
  private let maxConcurrency: Int
  private let semaphore: AsyncSemaphore
  private let recent: HookRecentRing
  private var attachedTask: Task<Void, Never>?
  private var internalSubscribers: [(prefix: String, subscriber: any InternalHookSubscriber)] = []
  private let logger = Logger(subsystem: "com.touch-code.hooks", category: "dispatch")

  public init(
    config: HookConfig,
    store: HookConfigStore,
    executor: HookExecutor,
    actionDispatcher: HookActionDispatcher,
    multicaster: HookEventMulticaster = HookEventMulticaster(),
    maxConcurrency: Int = HookDispatcher.defaultMaxConcurrency,
    semaphore: AsyncSemaphore? = nil,
    recent: HookRecentRing = HookRecentRing()
  ) {
    self.config = config
    self.store = store
    self.executor = executor
    self.actionDispatcher = actionDispatcher
    self.multicaster = multicaster
    self.maxConcurrency = maxConcurrency
    self.semaphore = semaphore ?? AsyncSemaphore(permits: maxConcurrency)
    self.recent = recent
  }

  /// Shared concurrency gate. Exposed so `ProcessHookExecutor`'s
  /// `fireAndForget` branch can re-acquire after the dispatcher releases
  /// on `executor.run` return (the dispatcher permit bounds scheduling;
  /// the executor permit bounds the actual `/bin/sh` spawn).
  public var concurrencySemaphore: AsyncSemaphore { semaphore }

  // MARK: - Public API

  /// Subscribe to a Runtime `TerminalEvent` stream. Each event is passed
  /// through `EventMapper` (which reads the supplied `catalog` closure to
  /// enrich anchor refs) and fired against the loaded subscription table.
  /// Callers must not call `attach` twice; detaching happens on the
  /// dispatcher's release or when the caller retains and cancels the
  /// task via `stop()`.
  ///
  /// The `catalog` closure is re-invoked per event so hierarchy mutations
  /// are reflected immediately — a panel that moves tabs between event A
  /// and event B picks up the new tab anchor on event B.
  public func attach(
    to events: AsyncStream<TerminalEvent>,
    catalog: @escaping @MainActor () -> Catalog
  ) {
    guard attachedTask == nil else {
      logger.warning("attach called while already attached; ignoring second stream")
      return
    }
    attachedTask = Task { [weak self, logger] in
      for await event in events {
        guard let self else { return }
        let snapshot = catalog()
        guard let envelope = EventMapper.map(event, catalog: snapshot) else {
          // Unmapped events (e.g. `.hierarchyMutated`) have no hook surface.
          continue
        }
        logger.debug("attach: fire \(envelope.event.rawValue, privacy: .public) id=\(envelope.id.uuidString, privacy: .public)")
        await self.fire(envelope)
      }
    }
  }

  /// Stop the attached event pump. Idempotent.
  public func stop() {
    attachedTask?.cancel()
    attachedTask = nil
  }

  /// Manually fire an envelope against the loaded subscription table. Used
  /// by `hook.test` / `hook.fire` RPCs and by unit tests. Also published
  /// to the multicaster so `hook.events` / `internalEventStream()` see the
  /// firing.
  ///
  /// For `.panelOutput` envelopes the dispatcher also scans every
  /// `.panelOutputMatch` subscription whose `matchPattern` hits the
  /// output bytes, and fires a synthesized `.panelOutputMatch` envelope
  /// per match. This keeps `EventMapper` pure (one inbound event →
  /// exactly one envelope) while giving user regexes a fire path that
  /// consumers like `hook.events` can observe.
  public func fire(_ envelope: HookEnvelope) async {
    multicaster.publish(envelope)
    let matches = config.subscriptions.filter { sub in
      !sub.disabled && sub.event == envelope.event
    }
    for sub in matches {
      await dispatch(sub, envelope: envelope)
    }

    // Output-match fan-out. Only runs for panel.output events that
    // carry raw bytes; subscriptions with a matchPattern are evaluated
    // against the bytes, and a hit synthesises a `.panelOutputMatch`
    // envelope that is re-entered through the normal fire path.
    if envelope.event == .panelOutput,
       case .panelOutput(let output, let bytes) = envelope.data {
      for sub in config.subscriptions
        where !sub.disabled
          && sub.event == .panelOutputMatch
          && (sub.matchPattern?.isEmpty == false) {
        guard let pattern = sub.matchPattern,
              let (matchString, range) = Self.firstRegexHit(
                pattern: pattern,
                flags: sub.matchFlags,
                in: output
              ) else {
          continue
        }
        let synthesised = HookEnvelope(
          event: .panelOutputMatch,
          space: envelope.space,
          project: envelope.project,
          worktree: envelope.worktree,
          tab: envelope.tab,
          panel: envelope.panel,
          data: .panelOutputMatch(
            match: matchString,
            matchedRange: range,
            output: output,
            outputBytes: bytes
          )
        )
        multicaster.publish(synthesised)
        await dispatch(sub, envelope: synthesised)
      }
    }
  }

  /// Best-effort first-match on `pattern` against the UTF-8 decoding of
  /// `data`. Returns `nil` when the pattern is invalid or the bytes
  /// are not valid UTF-8 (the hot path pre-compiles these in M2.1.1.1;
  /// M2.1.1 compiles per-fire for simplicity).
  static func firstRegexHit(
    pattern: String,
    flags: HookSubscription.RegexFlags,
    in data: Data
  ) -> (String, HookMatchRange)? {
    guard let text = String(data: data, encoding: .utf8) else { return nil }
    var options: NSRegularExpression.Options = []
    if flags.contains(.caseInsensitive) { options.insert(.caseInsensitive) }
    if flags.contains(.multiline) { options.insert(.anchorsMatchLines) }
    if flags.contains(.dotAll) { options.insert(.dotMatchesLineSeparators) }
    guard let regex = try? NSRegularExpression(pattern: pattern, options: options) else {
      return nil
    }
    let range = NSRange(text.startIndex..<text.endIndex, in: text)
    guard let match = regex.firstMatch(in: text, options: [], range: range),
          let matchRange = Range(match.range, in: text) else {
      return nil
    }
    return (
      String(text[matchRange]),
      HookMatchRange(start: match.range.location, length: match.range.length)
    )
  }

  /// Hot-reload from disk. In-flight dispatches retain their captured
  /// snapshot (exec-plan 0003 DEC-7) — the table swap only affects
  /// *new* firings after this call returns. `async` is retained for M3's
  /// eventual in-flight-drain; the M2 stub yields to the scheduler so the
  /// signature is stable.
  public func reloadConfig() async throws {
    await Task.yield()
    config = try store.load()
  }

  /// Fresh in-process subscription to every subsequent envelope. Peer of
  /// the `hook.events` streaming RPC (exec-plan 0003 DEC-10).
  public func internalEventStream() -> AsyncStream<HookEnvelope> {
    multicaster.subscribe().stream
  }

  /// Register an `InternalHookSubscriber` for a sentinel-prefix route.
  /// The prefix must begin with `touchCodeInternalPrefix`, otherwise this
  /// throws `HookConfigError.reservedPrefixRequired`.
  public func register(subscriber: any InternalHookSubscriber, for prefix: String) throws {
    guard prefix.hasPrefix(touchCodeInternalPrefix) else {
      throw HookConfigError.reservedPrefixRequired(id: UUID(), command: prefix)
    }
    internalSubscribers.append((prefix, subscriber))
  }

  /// Unregister every subscriber matching `prefix`. Idempotent.
  public func unregister(prefix: String) {
    internalSubscribers.removeAll { $0.prefix == prefix }
  }

  /// Snapshot access for `hook.recent`.
  public var recentFires: HookRecentRing { recent }

  /// Snapshot access for `hook.list`.
  public var loadedConfig: HookConfig { config }

  // MARK: - Test-visible

  /// Replace the in-memory config table without touching disk. Used by
  /// `HookDispatcherTests` to install subscriptions directly.
  public func setConfig(_ config: HookConfig) {
    self.config = config
  }

  // MARK: - Dispatch

  private func dispatch(_ subscription: HookSubscription, envelope: HookEnvelope) async {
    // DEC-7: snapshot subscription at dispatch time. M2.1 adds recursion
    // guard, rate limit, and concurrency cap around this call.
    let snapshot = subscription
    let start = Date()
    if let match = internalSubscribers.first(where: { snapshot.command.hasPrefix($0.prefix) }) {
      await match.subscriber.handle(envelope: envelope)
      let record = HookFireRecord(
        envelope: envelope,
        subscriptionID: snapshot.id,
        duration: Date().timeIntervalSince(start),
        exitCode: 0
      )
      recent.append(record)
      return
    }

    await semaphore.acquire()
    let result = await executor.run(subscription: snapshot, envelope: envelope)
    await semaphore.release()
    var dispatched = 0
    var refused = 0
    for action in result.actions {
      do {
        try await actionDispatcher.execute(action, originatingFrom: envelope.id)
        dispatched += 1
      } catch {
        refused += 1
        logger.warning("action dispatch failed: \(String(describing: error), privacy: .public)")
      }
    }
    let record = HookFireRecord(
      envelope: envelope,
      subscriptionID: snapshot.id,
      duration: Date().timeIntervalSince(start),
      exitCode: result.exitCode,
      actionsDispatched: dispatched,
      actionsRefused: refused,
      timedOut: result.timedOut
    )
    recent.append(record)
  }
}
