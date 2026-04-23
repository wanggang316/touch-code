import Foundation
import Testing
import TouchCodeCore

@testable import touch_code

@MainActor
struct HookConfigClientTests {
  private func makeLiveClient() -> (HookConfigClient, HookConfigStore) {
    let tempURL = FileManager.default.temporaryDirectory
      .appending(component: UUID().uuidString + ".json")
    let store = HookConfigStore(fileURL: tempURL, debounceSeconds: 0)
    return (HookConfigClient.live(store: store), store)
  }

  // MARK: - load() tests

  @Test
  func loadReturnsEmptyWhenFileIsMissing() async throws {
    let (client, _) = makeLiveClient()
    let config = try await client.load()
    #expect(config.subscriptions.isEmpty)
  }

  @Test
  func loadReturnsSubscriptionsWhenFileExists() async throws {
    let (client, store) = makeLiveClient()
    let sub = HookSubscription(
      event: .paneCreated,
      command: "echo 'test'"
    )
    let config = HookConfig(subscriptions: [sub])
    try store.save(config)

    let loaded = try await client.load()
    #expect(loaded.subscriptions.count == 1)
    #expect(loaded.subscriptions[0].command == "echo 'test'")
  }

  @Test
  func loadFiltersOutSubscriptionsWithInvalidRegex() async throws {
    let (client, store) = makeLiveClient()
    let validSub = HookSubscription(
      event: .paneCreated,
      command: "echo 'valid'"
    )
    let invalidRegexSub = HookSubscription(
      id: UUID(),
      event: .paneCreated,
      command: "echo 'invalid'",
      matchPattern: "(?P<invalid>unclosed"  // Invalid regex
    )
    let config = HookConfig(subscriptions: [validSub, invalidRegexSub])
    try store.save(config)

    let loaded = try await client.load()
    // Invalid subscription is filtered out; only the valid one remains.
    #expect(loaded.subscriptions.count == 1)
    #expect(loaded.subscriptions[0].command == "echo 'valid'")
  }

  @Test
  func loadFiltersOutSubscriptionsWithReservedEnv() async throws {
    let (client, store) = makeLiveClient()
    let validSub = HookSubscription(
      event: .paneCreated,
      command: "echo 'valid'"
    )
    let reservedEnvSub = HookSubscription(
      id: UUID(),
      event: .paneCreated,
      command: "echo 'reserved'",
      env: ["TOUCH_CODE_SECRET": "value"]
    )
    let config = HookConfig(subscriptions: [validSub, reservedEnvSub])
    try store.save(config)

    let loaded = try await client.load()
    // Reserved env subscription is filtered out; only the valid one remains.
    #expect(loaded.subscriptions.count == 1)
    #expect(loaded.subscriptions[0].command == "echo 'valid'")
  }

  @Test
  func loadFiltersOutInternalNamespaceSubscriptions() async throws {
    let (client, store) = makeLiveClient()
    let userSub = HookSubscription(
      event: .paneCreated,
      command: "echo 'user'"
    )
    let internalSub = HookSubscription(
      id: UUID(),
      event: .paneCreated,
      command: "__touch-code/internal:some-command"
    )
    let config = HookConfig(subscriptions: [userSub, internalSub])
    try store.save(config)

    let loaded = try await client.load()
    // Internal namespace subscription is filtered out when loading user config.
    #expect(loaded.subscriptions.count == 1)
    #expect(loaded.subscriptions[0].command == "echo 'user'")
  }

  // MARK: - ensureExists() tests

  @Test
  func ensureExistsCreatesEmptyFileWhenMissing() async throws {
    let tempURL = FileManager.default.temporaryDirectory
      .appending(component: UUID().uuidString + ".json")
    let store = HookConfigStore(fileURL: tempURL, debounceSeconds: 0)
    let client = HookConfigClient.live(store: store)

    #expect(!FileManager.default.fileExists(atPath: tempURL.path))
    try await client.ensureExists()
    #expect(FileManager.default.fileExists(atPath: tempURL.path))

    let loaded = try await client.load()
    #expect(loaded.subscriptions.isEmpty)
  }

  @Test
  func ensureExistsIsNoOpWhenFileAlreadyExists() async throws {
    let (client, store) = makeLiveClient()
    let sub = HookSubscription(
      event: .paneCreated,
      command: "echo 'original'"
    )
    let config = HookConfig(subscriptions: [sub])
    try store.save(config)

    // ensureExists should not overwrite the existing file.
    try await client.ensureExists()

    let loaded = try await client.load()
    #expect(loaded.subscriptions.count == 1)
    #expect(loaded.subscriptions[0].command == "echo 'original'")
  }

  @Test
  func ensureExistsAndLoadRoundTrip() async throws {
    let (client, _) = makeLiveClient()

    // File does not exist yet.
    try await client.ensureExists()

    // Load should return empty config.
    let loaded = try await client.load()
    #expect(loaded.subscriptions.isEmpty)
  }
}
