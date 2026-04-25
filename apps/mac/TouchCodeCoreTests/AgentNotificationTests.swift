import Foundation
import Testing

@testable import TouchCodeCore

struct AgentNotificationTests {
  @Test
  func codableRoundTripPreservesAllFields() throws {
    let created = Date(timeIntervalSince1970: 1_700_000_000)
    let read = Date(timeIntervalSince1970: 1_700_000_100)
    let dismissed = Date(timeIntervalSince1970: 1_700_000_200)
    let original = AgentNotification(
      id: UUID(),
      paneID: PaneID(),
      agent: "claude",
      kind: .blockedOnInput,
      title: "Claude is waiting for your approval",
      body: "Do you want to proceed?",
      createdAt: created,
      readAt: read,
      dismissedAt: dismissed
    )

    let data = try JSONEncoder().encode(original)
    let decoded = try JSONDecoder().decode(AgentNotification.self, from: data)

    #expect(decoded == original)
  }

  @Test
  func unreadWhenBothTimestampsAreNil() {
    let notification = Self.makeNotification(readAt: nil, dismissedAt: nil)
    #expect(notification.isUnread == true)
  }

  @Test
  func notUnreadWhenReadAtIsSet() {
    let notification = Self.makeNotification(readAt: Date(), dismissedAt: nil)
    #expect(notification.isUnread == false)
  }

  @Test
  func notUnreadWhenDismissedAtIsSet() {
    let notification = Self.makeNotification(readAt: nil, dismissedAt: Date())
    #expect(notification.isUnread == false)
  }

  @Test
  func notUnreadWhenBothTimestampsAreSet() {
    let notification = Self.makeNotification(readAt: Date(), dismissedAt: Date())
    #expect(notification.isUnread == false)
  }

  @Test
  func allKindsRoundTripThroughJSON() throws {
    for kind in AgentNotification.Kind.allCases {
      let notification = Self.makeNotification(kind: kind)
      let data = try JSONEncoder().encode(notification)
      let decoded = try JSONDecoder().decode(AgentNotification.self, from: data)
      #expect(decoded.kind == kind)
    }
  }

  /// `dedupKey` is optional and defaults to nil — old `notifications.json`
  /// files written before v2 do not carry the field and must decode
  /// without error. v2 D3 / DEC-V3.
  @Test
  func legacyJSONWithoutDedupKeyDecodesAsNil() throws {
    let original = Self.makeNotification()  // dedupKey: nil
    let payload = try JSONEncoder().encode(original)
    // Strip dedupKey from the JSON to mimic a pre-v2 on-disk shape.
    var dict = try #require(
      try JSONSerialization.jsonObject(with: payload) as? [String: Any]
    )
    dict.removeValue(forKey: "dedupKey")
    let stripped = try JSONSerialization.data(withJSONObject: dict)
    let decoded = try JSONDecoder().decode(AgentNotification.self, from: stripped)
    #expect(decoded.dedupKey == nil)
    #expect(decoded.id == original.id)
  }

  @Test
  func dedupKeyRoundTripsThroughJSON() throws {
    let original = Self.makeNotification(dedupKey: "claude:stop:abc")
    let data = try JSONEncoder().encode(original)
    let decoded = try JSONDecoder().decode(AgentNotification.self, from: data)
    #expect(decoded.dedupKey == "claude:stop:abc")
  }

  // MARK: - Helpers

  private static func makeNotification(
    kind: AgentNotification.Kind = .completed,
    readAt: Date? = nil,
    dismissedAt: Date? = nil,
    dedupKey: String? = nil
  ) -> AgentNotification {
    AgentNotification(
      paneID: PaneID(),
      agent: "claude",
      kind: kind,
      title: "t",
      body: "b",
      createdAt: Date(timeIntervalSince1970: 0),
      readAt: readAt,
      dismissedAt: dismissedAt,
      dedupKey: dedupKey
    )
  }
}
