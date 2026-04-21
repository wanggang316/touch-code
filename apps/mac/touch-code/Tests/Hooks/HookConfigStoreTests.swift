import Foundation
import Testing

@testable import touch_code
@testable import TouchCodeCore

@MainActor
struct HookConfigStoreTests {
  @Test
  func emptyLoadWhenFileMissing() throws {
    let url = Self.temporaryURL()
    let store = HookConfigStore(fileURL: url)
    let config = try store.load()
    #expect(config.subscriptions.isEmpty)
  }

  @Test
  func roundTripSaveLoad() throws {
    let url = Self.temporaryURL()
    defer { try? FileManager.default.removeItem(at: url) }
    let store = HookConfigStore(fileURL: url)
    let sub = HookSubscription(event: .panelReady, command: "echo ready")
    try store.save(HookConfig(subscriptions: [sub]))
    let loaded = try store.load()
    #expect(loaded.subscriptions.map(\.id) == [sub.id])
  }

  @Test
  func brokenFileIsBackedUpAndEmptyReturned() throws {
    let url = Self.temporaryURL()
    defer { try? FileManager.default.removeItem(at: url) }
    try "not json".write(to: url, atomically: true, encoding: .utf8)
    let store = HookConfigStore(fileURL: url)
    let config = try store.load()
    #expect(config.subscriptions.isEmpty)
    let siblings = (try? FileManager.default.contentsOfDirectory(atPath: url.deletingLastPathComponent().path)) ?? []
    #expect(siblings.contains { $0.hasPrefix(url.lastPathComponent) && $0.contains(".broken-") })
  }

  @Test
  func reservedEnvKeyIsRejectedOnLoad() throws {
    let url = Self.temporaryURL()
    defer { try? FileManager.default.removeItem(at: url) }
    let bad = HookSubscription(
      event: .panelReady, command: "echo",
      env: ["TOUCH_CODE_FOO": "bar"]
    )
    try HookConfigStore(fileURL: url).save(HookConfig(subscriptions: [bad]))
    let loaded = try HookConfigStore(fileURL: url).load()
    #expect(loaded.subscriptions.isEmpty) // silently dropped, not thrown — sibling user subs continue
  }

  @Test
  func reservedPrefixIsRejectedOnLoad() throws {
    let url = Self.temporaryURL()
    defer { try? FileManager.default.removeItem(at: url) }
    let bad = HookSubscription(
      event: .panelReady, command: "__touch-code/internal:notifications:x"
    )
    try HookConfigStore(fileURL: url).save(HookConfig(subscriptions: [bad]))
    let loaded = try HookConfigStore(fileURL: url).load()
    #expect(loaded.subscriptions.isEmpty)
  }

  @Test
  func upsertInternalAdmitsReservedPrefix() throws {
    let url = Self.temporaryURL()
    defer { try? FileManager.default.removeItem(at: url) }
    let store = HookConfigStore(fileURL: url)
    let internalSub = HookSubscription(
      event: .panelOutputMatch,
      command: "__touch-code/internal:notifications:abc"
    )
    try store.upsertInternal([internalSub])
    // upsertInternal bypasses user-load validation; raw on-disk payload has it.
    let raw = try AtomicFileStore.read(HookConfig.self, at: url)
    #expect(raw?.subscriptions.map(\.id) == [internalSub.id])
  }

  @Test
  func upsertInternalRejectsNonReservedCommand() throws {
    let url = Self.temporaryURL()
    defer { try? FileManager.default.removeItem(at: url) }
    let store = HookConfigStore(fileURL: url)
    let ordinary = HookSubscription(event: .panelReady, command: "/usr/bin/echo")
    #expect(throws: HookConfigError.self) {
      try store.upsertInternal([ordinary])
    }
  }

  @Test
  func removeInternalDropsMatchingPrefix() throws {
    let url = Self.temporaryURL()
    defer { try? FileManager.default.removeItem(at: url) }
    let store = HookConfigStore(fileURL: url)
    let keep = HookSubscription(
      event: .panelReady,
      command: "__touch-code/internal:other:x"
    )
    let drop = HookSubscription(
      event: .panelReady,
      command: "__touch-code/internal:notifications:x"
    )
    try store.upsertInternal([keep, drop])
    try store.removeInternal(idsPrefixed: "__touch-code/internal:notifications:")
    let raw = try AtomicFileStore.read(HookConfig.self, at: url)
    #expect(raw?.subscriptions.map(\.id) == [keep.id])
  }

  @Test
  func removeInternalRejectsNonReservedPrefix() throws {
    let url = Self.temporaryURL()
    defer { try? FileManager.default.removeItem(at: url) }
    #expect(throws: HookConfigError.self) {
      try HookConfigStore(fileURL: url).removeInternal(idsPrefixed: "echo")
    }
  }

  @Test
  func upsertInternalIsAdditiveToUserSubscriptions() throws {
    let url = Self.temporaryURL()
    defer { try? FileManager.default.removeItem(at: url) }
    let userSub = HookSubscription(event: .panelReady, command: "echo ready")
    try HookConfigStore(fileURL: url).save(HookConfig(subscriptions: [userSub]))
    let store = HookConfigStore(fileURL: url)
    let internalSub = HookSubscription(
      event: .panelOutputMatch,
      command: "__touch-code/internal:notifications:z"
    )
    try store.upsertInternal([internalSub])
    let raw = try AtomicFileStore.read(HookConfig.self, at: url)
    #expect(Set(raw?.subscriptions.map(\.id) ?? []) == Set([userSub.id, internalSub.id]))
  }

  @Test
  func flushDrainsPendingScheduledSaveSynchronously() throws {
    let url = Self.temporaryURL()
    defer { try? FileManager.default.removeItem(at: url) }
    // Long enough debounce that the async write absolutely has not fired
    // by the time flush() runs.
    let store = HookConfigStore(fileURL: url, debounceSeconds: 60)
    let sub = HookSubscription(event: .panelReady, command: "echo flushed")
    store.scheduleSave(HookConfig(subscriptions: [sub]))

    // Nothing on disk yet — the debounce timer has not fired.
    #expect(!FileManager.default.fileExists(atPath: url.path))

    try store.flush()
    #expect(FileManager.default.fileExists(atPath: url.path))
    let reloaded = try HookConfigStore(fileURL: url).load()
    #expect(reloaded.subscriptions.map(\.id) == [sub.id])
  }

  @Test
  func flushIsNoopWhenNothingPending() throws {
    let url = Self.temporaryURL()
    let store = HookConfigStore(fileURL: url)
    try store.flush()
    #expect(!FileManager.default.fileExists(atPath: url.path))
  }

  // MARK: - Helpers

  private static func temporaryURL() -> URL {
    let base = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
      .appendingPathComponent("touch-code-hook-tests-\(UUID().uuidString)", isDirectory: true)
    try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
    return base.appendingPathComponent("hooks.json")
  }
}
