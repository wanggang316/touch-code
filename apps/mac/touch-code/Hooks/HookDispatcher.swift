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
    recent: HookRecentRing = HookRecentRing()
  ) {
    self.config = config
    self.store = store
    self.executor = executor
    self.actionDispatcher = actionDispatcher
    self.multicaster = multicaster
    self.maxConcurrency = maxConcurrency
    self.recent = recent
  }

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
  public func fire(_ envelope: HookEnvelope) async {
    multicaster.publish(envelope)
    let matches = config.subscriptions.filter { sub in
      !sub.disabled && sub.event == envelope.event
    }
    for sub in matches {
      await dispatch(sub, envelope: envelope)
    }
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

    let result = await executor.run(subscription: snapshot, envelope: envelope)
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
