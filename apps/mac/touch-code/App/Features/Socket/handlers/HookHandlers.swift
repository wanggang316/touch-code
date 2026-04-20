import Foundation
import TouchCodeCore
import TouchCodeIPC

/// Handlers for the `hook.*` method namespace. Backed by a shared
/// `HookDispatcher` + `HookConfigStore`.
@MainActor
public final class HookHandlers {
  private let dispatcher: HookDispatcher
  private let store: HookConfigStore

  public init(dispatcher: HookDispatcher, store: HookConfigStore) {
    self.dispatcher = dispatcher
    self.store = store
  }

  // MARK: - Param payloads

  public struct ListParams: Codable, Sendable {
    public let eventFilter: HookEvent?
    public let panelID: PanelID?
    public init(eventFilter: HookEvent? = nil, panelID: PanelID? = nil) {
      self.eventFilter = eventFilter
      self.panelID = panelID
    }
  }

  public struct InstallParams: Codable, Sendable {
    public let subscription: HookSubscription
    public init(subscription: HookSubscription) {
      self.subscription = subscription
    }
  }

  public struct RemoveParams: Codable, Sendable {
    public let id: UUID
    public init(id: UUID) { self.id = id }
  }

  public struct EnableParams: Codable, Sendable {
    public let id: UUID
    public let enabled: Bool
    public init(id: UUID, enabled: Bool) {
      self.id = id
      self.enabled = enabled
    }
  }

  public struct TestParams: Codable, Sendable {
    public let id: UUID
    public let envelope: HookEnvelope
    public init(id: UUID, envelope: HookEnvelope) {
      self.id = id
      self.envelope = envelope
    }
  }

  public struct FireParams: Codable, Sendable {
    public let envelope: HookEnvelope
    public init(envelope: HookEnvelope) { self.envelope = envelope }
  }

  public struct RecentParams: Codable, Sendable {
    public let limit: Int?
    public init(limit: Int? = nil) { self.limit = limit }
  }

  // MARK: - Handlers

  /// `hook.list` — return the loaded subscription table, optionally
  /// filtered by event or by panel scope.
  public func list(_ params: JSONValue) async -> RouterOutcome {
    await Task.yield()
    let filter = (try? params.decoded(as: ListParams.self)) ?? ListParams()
    var subs = dispatcher.loadedConfig.subscriptions
    if let event = filter.eventFilter {
      subs = subs.filter { $0.event == event }
    }
    if let panelID = filter.panelID {
      subs = subs.filter { sub in
        switch sub.scope {
        case .anyPanel: return true
        case .panelID(let id): return id == panelID
        default: return false
        }
      }
    }
    do {
      let encoded = try JSONValue.encoded(["subscriptions": subs])
      return .unary(encoded)
    } catch {
      return .failed(.internal("encode list: \(error)"))
    }
  }

  /// `hook.install` — persist a new subscription.
  public func install(_ params: JSONValue) async -> RouterOutcome {
    let payload: InstallParams
    do {
      payload = try params.decoded(as: InstallParams.self)
    } catch {
      return .failed(.invalidParams(message: "hook.install requires a subscription", path: nil))
    }
    // Reject reserved-prefix subscriptions at the RPC boundary — only the
    // in-process `upsertInternal(_:)` path may install them.
    if payload.subscription.command.hasPrefix(touchCodeInternalPrefix) {
      return .failed(.conflict(reason: "reserved __touch-code/internal: prefix"))
    }
    do {
      var config = (try? store.load()) ?? .empty
      config.subscriptions.removeAll { $0.id == payload.subscription.id }
      config.subscriptions.append(payload.subscription)
      try store.save(config)
      try await dispatcher.reloadConfig()
      return .unary(.object(["id": .string(payload.subscription.id.uuidString)]))
    } catch {
      return .failed(.internal("hook.install persist: \(error)"))
    }
  }

  /// `hook.remove` — drop a subscription by id.
  public func remove(_ params: JSONValue) async -> RouterOutcome {
    let payload: RemoveParams
    do {
      payload = try params.decoded(as: RemoveParams.self)
    } catch {
      return .failed(.invalidParams(message: "hook.remove requires an id", path: nil))
    }
    do {
      var config = (try? store.load()) ?? .empty
      let before = config.subscriptions.count
      config.subscriptions.removeAll { $0.id == payload.id }
      let removed = before != config.subscriptions.count
      if !removed {
        return .failed(.notFound(kind: "subscription", id: payload.id.uuidString))
      }
      try store.save(config)
      try await dispatcher.reloadConfig()
      return .unary(.object(["removed": .bool(true)]))
    } catch {
      return .failed(.internal("hook.remove persist: \(error)"))
    }
  }

  /// `hook.enable` — flip a subscription's `disabled` flag. The RPC takes
  /// `enabled: Bool`; the stored field is `disabled: Bool` — handler
  /// inverts before writing (per M1.x follow-up #1).
  public func enable(_ params: JSONValue) async -> RouterOutcome {
    let payload: EnableParams
    do {
      payload = try params.decoded(as: EnableParams.self)
    } catch {
      return .failed(.invalidParams(message: "hook.enable requires id + enabled", path: nil))
    }
    do {
      var config = (try? store.load()) ?? .empty
      guard let idx = config.subscriptions.firstIndex(where: { $0.id == payload.id }) else {
        return .failed(.notFound(kind: "subscription", id: payload.id.uuidString))
      }
      config.subscriptions[idx].disabled = !payload.enabled
      try store.save(config)
      try await dispatcher.reloadConfig()
      return .unary(.object([:]))
    } catch {
      return .failed(.internal("hook.enable persist: \(error)"))
    }
  }

  /// `hook.reload` — re-read `hooks.json`, re-validate, swap the in-memory
  /// table.
  public func reload(_ params: JSONValue) async -> RouterOutcome {
    do {
      try await dispatcher.reloadConfig()
      return .unary(.object([
        "loadedCount": .int(Int64(dispatcher.loadedConfig.subscriptions.count)),
        "errors": .array([]),
      ]))
    } catch {
      return .failed(.internal("hook.reload: \(error)"))
    }
  }

  /// `hook.test` — invoke one subscription against a synthetic envelope
  /// without firing it through the real match pass.
  public func test(_ params: JSONValue) async -> RouterOutcome {
    let payload: TestParams
    do {
      payload = try params.decoded(as: TestParams.self)
    } catch {
      return .failed(.invalidParams(message: "hook.test requires id + envelope", path: nil))
    }
    guard dispatcher.loadedConfig.subscriptions.contains(where: { $0.id == payload.id }) else {
      return .failed(.notFound(kind: "subscription", id: payload.id.uuidString))
    }
    await dispatcher.fire(payload.envelope)
    return .unary(.object(["fired": .bool(true)]))
  }

  /// `hook.fire` — fire an envelope through the normal match path. Used
  /// by CLI development (`tc hook fire`) and by tests.
  public func fire(_ params: JSONValue) async -> RouterOutcome {
    let payload: FireParams
    do {
      payload = try params.decoded(as: FireParams.self)
    } catch {
      return .failed(.invalidParams(message: "hook.fire requires an envelope", path: nil))
    }
    let before = dispatcher.recentFires.count
    await dispatcher.fire(payload.envelope)
    let handlersRun = dispatcher.recentFires.count - before
    return .unary(.object(["handlersRun": .int(Int64(handlersRun))]))
  }

  /// `hook.recent` — return the most recent fire records from the ring.
  public func recent(_ params: JSONValue) async -> RouterOutcome {
    await Task.yield()
    let payload = (try? params.decoded(as: RecentParams.self)) ?? RecentParams()
    let fires = dispatcher.recentFires.recent(limit: payload.limit)
    do {
      return .unary(try JSONValue.encoded(["fires": fires]))
    } catch {
      return .failed(.internal("encode recent: \(error)"))
    }
  }

  /// `hook.events` — streaming RPC. Subscribes a fresh multicaster slot
  /// and re-emits every envelope as a JSON frame. The `SocketConnection`
  /// owns the per-frame wire encoding and the close-on-EOF handling.
  public func events(_ params: JSONValue) -> RouterOutcome {
    // Subscribe on the main actor (dispatcher is @MainActor); hand the
    // captured stream to the .streaming closure. `@Sendable` on the
    // closure forbids touching the dispatcher again from there.
    let stream = dispatcher.internalEventStream()
    return .streaming {
      AsyncStream<JSONValue> { continuation in
        let task = Task {
          for await envelope in stream {
            if let encoded = try? JSONValue.encoded(envelope) {
              continuation.yield(encoded)
            }
          }
          continuation.finish()
        }
        continuation.onTermination = { _ in task.cancel() }
      }
    }
  }
}
