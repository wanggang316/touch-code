import Foundation
import TouchCodeCore
import os

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

  /// Per-subscription compiled regex cache. Rebuilt on every config swap
  /// (`setConfig` / `reloadConfig`). Bypasses the per-fire
  /// `NSRegularExpression(pattern:)` compile that dominated the
  /// `.paneOutput` hot path. Entries are keyed by subscription id; a
  /// `nil` value means the pattern failed to compile (still cached so we
  /// don't retry on every event).
  private var regexCache: [UUID: NSRegularExpression?] = [:]

  /// Pane/Tab/Worktree anchor index. Rebuilt lazily on first use after
  /// `invalidate()`; the dispatcher's `attach` path invalidates whenever
  /// a `.hierarchyMutated` event arrives.
  private let anchorCache = EventMapperCache()

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
    rebuildRegexCache()
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
  /// are reflected immediately — a pane that moves tabs between event A
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
        // `.hierarchyMutated` carries no hook surface but tells us the
        // catalog shape changed — drop the cached anchor index so the
        // next pane/tab/worktree event rebuilds from the fresh
        // catalog snapshot.
        if case .hierarchyMutated = event {
          self.anchorCache.invalidate()
          continue
        }
        let cache = self.anchorCache
        guard
          let envelope = EventMapper.map(
            event,
            catalog: catalog(),
            cache: cache
          )
        else {
          continue
        }
        logger.debug(
          "attach: fire \(envelope.event.rawValue, privacy: .public) id=\(envelope.id.uuidString, privacy: .public)")
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
  /// For `.paneOutput` envelopes the dispatcher also scans every
  /// `.paneOutputMatch` subscription whose `matchPattern` hits the
  /// output bytes, and fires a synthesized `.paneOutputMatch` envelope
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

    // Output-match fan-out. Only runs for pane.output events that
    // carry raw bytes; subscriptions with a matchPattern are evaluated
    // against the bytes, and a hit synthesises a `.paneOutputMatch`
    // envelope that is re-entered through the normal fire path.
    if envelope.event == .paneOutput,
      case .paneOutput(let output, let bytes) = envelope.data
    {
      for sub in config.subscriptions
      where !sub.disabled
        && sub.event == .paneOutputMatch
        && (sub.matchPattern?.isEmpty == false)
      {
        guard let cached = regexCache[sub.id],
          let regex = cached,
          let (matchString, range) = Self.firstRegexHit(
            regex: regex,
            in: output
          )
        else {
          continue
        }
        let synthesised = HookEnvelope(
          event: .paneOutputMatch,
          space: envelope.space,
          project: envelope.project,
          worktree: envelope.worktree,
          tab: envelope.tab,
          pane: envelope.pane,
          data: .paneOutputMatch(
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

  /// First-match against the UTF-8 decoding of `data` using a
  /// pre-compiled `regex` from the cache. Returns `nil` when the bytes
  /// are not valid UTF-8 or nothing matches.
  static func firstRegexHit(
    regex: NSRegularExpression,
    in data: Data
  ) -> (String, HookMatchRange)? {
    guard let text = String(data: data, encoding: .utf8) else { return nil }
    let range = NSRange(text.startIndex..<text.endIndex, in: text)
    guard let match = regex.firstMatch(in: text, options: [], range: range),
      let matchRange = Range(match.range, in: text)
    else {
      return nil
    }
    return (
      String(text[matchRange]),
      HookMatchRange(start: match.range.location, length: match.range.length)
    )
  }

  /// Compile a subscription's `matchPattern` into an `NSRegularExpression`
  /// with the declared flags. Returns `nil` when the pattern is empty or
  /// malformed — the caller caches the `nil` so repeated events don't
  /// re-attempt compilation.
  static func compileRegex(for sub: HookSubscription) -> NSRegularExpression? {
    guard let pattern = sub.matchPattern, !pattern.isEmpty else { return nil }
    var options: NSRegularExpression.Options = []
    if sub.matchFlags.contains(.caseInsensitive) { options.insert(.caseInsensitive) }
    if sub.matchFlags.contains(.multiline) { options.insert(.anchorsMatchLines) }
    if sub.matchFlags.contains(.dotAll) { options.insert(.dotMatchesLineSeparators) }
    return try? NSRegularExpression(pattern: pattern, options: options)
  }

  private func rebuildRegexCache() {
    var fresh: [UUID: NSRegularExpression?] = [:]
    fresh.reserveCapacity(config.subscriptions.count)
    for sub in config.subscriptions where sub.matchPattern?.isEmpty == false {
      fresh[sub.id] = Self.compileRegex(for: sub)
    }
    regexCache = fresh
  }

  /// Hot-reload from disk. In-flight dispatches retain their captured
  /// snapshot (exec-plan 0003 DEC-7) — the table swap only affects
  /// *new* firings after this call returns. `async` is retained for M3's
  /// eventual in-flight-drain; the M2 stub yields to the scheduler so the
  /// signature is stable.
  public func reloadConfig() async throws {
    await Task.yield()
    config = try store.load()
    rebuildRegexCache()
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
    rebuildRegexCache()
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
