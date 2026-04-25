import Foundation
import Testing
import TouchCodeCore

@testable import touch_code

@MainActor
struct HookConfigClientUpsertDeleteTests {
  private func makeLiveClient() -> (HookConfigClient, HookConfigStore) {
    let tempURL = FileManager.default.temporaryDirectory
      .appending(component: UUID().uuidString + ".json")
    let store = HookConfigStore(fileURL: tempURL, debounceSeconds: 0)
    return (HookConfigClient.live(store: store), store)
  }

  @Test
  func upsertAppendsNewSubscription() async throws {
    let (client, store) = makeLiveClient()
    let sub = HookSubscription(event: .paneReady, command: "echo ready")
    try await client.upsert(sub)
    try store.flush()

    let loaded = try await client.load()
    #expect(loaded.subscriptions.count == 1)
    #expect(loaded.subscriptions.first?.id == sub.id)
    #expect(loaded.subscriptions.first?.command == "echo ready")
  }

  @Test
  func upsertReplacesExistingSubscriptionByID() async throws {
    let (client, store) = makeLiveClient()
    let id = UUID()
    let original = HookSubscription(id: id, event: .paneReady, command: "echo v1")
    try await client.upsert(original)
    try store.flush()

    let updated = HookSubscription(id: id, event: .paneReady, command: "echo v2")
    try await client.upsert(updated)
    try store.flush()

    let loaded = try await client.load()
    #expect(loaded.subscriptions.count == 1)
    #expect(loaded.subscriptions.first?.id == id)
    #expect(loaded.subscriptions.first?.command == "echo v2")
  }

  @Test
  func upsertRefusesInternalNamespaceCommands() async throws {
    let (client, _) = makeLiveClient()
    let sub = HookSubscription(
      event: .paneReady,
      command: "__touch-code/internal:not-allowed"
    )
    await #expect(throws: HookConfigError.self) {
      try await client.upsert(sub)
    }
  }

  @Test
  func deleteRemovesSubscriptionByID() async throws {
    let (client, store) = makeLiveClient()
    let a = HookSubscription(event: .paneReady, command: "echo a")
    let b = HookSubscription(event: .paneReady, command: "echo b")
    try await client.upsert(a)
    try await client.upsert(b)
    try store.flush()

    try await client.delete(a.id)
    try store.flush()

    let loaded = try await client.load()
    #expect(loaded.subscriptions.count == 1)
    #expect(loaded.subscriptions.first?.id == b.id)
  }

  @Test
  func deleteIsNoOpForUnknownID() async throws {
    let (client, store) = makeLiveClient()
    let sub = HookSubscription(event: .paneReady, command: "echo a")
    try await client.upsert(sub)
    try store.flush()

    try await client.delete(UUID())  // unknown id
    try store.flush()

    let loaded = try await client.load()
    #expect(loaded.subscriptions.count == 1)
  }

  @Test
  func upsertRejectsInvalidRegexBeforePersist() async throws {
    let (client, _) = makeLiveClient()
    let sub = HookSubscription(
      event: .paneOutputMatch,
      command: "echo bad",
      matchPattern: "(?P<unclosed"
    )
    await #expect(throws: HookConfigError.self) {
      try await client.upsert(sub)
    }
  }
}
