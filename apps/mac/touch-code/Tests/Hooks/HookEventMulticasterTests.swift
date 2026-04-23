import Foundation
import Testing

@testable import TouchCodeCore
@testable import touch_code

@MainActor
struct HookEventMulticasterTests {
  @Test
  func oneSubscriberReceivesPublishedEnvelope() async throws {
    let m = HookEventMulticaster()
    let (_, stream) = m.subscribe()
    let env = Self.makeEnvelope()
    m.publish(env)
    let received = await Self.collect(from: stream, expected: 1, timeout: .seconds(1))
    #expect(received.count == 1)
    #expect(received.first?.event == env.event)
  }

  @Test
  func threeSubscribersEachReceiveEveryEnvelope() async throws {
    let m = HookEventMulticaster()
    let s1 = m.subscribe().stream
    let s2 = m.subscribe().stream
    let s3 = m.subscribe().stream

    let envelopes = [Self.makeEnvelope(), Self.makeEnvelope(), Self.makeEnvelope()]
    for env in envelopes { m.publish(env) }

    async let r1 = Self.collect(from: s1, expected: envelopes.count, timeout: .seconds(1))
    async let r2 = Self.collect(from: s2, expected: envelopes.count, timeout: .seconds(1))
    async let r3 = Self.collect(from: s3, expected: envelopes.count, timeout: .seconds(1))
    let (a, b, c) = await (r1, r2, r3)
    #expect(a.count == envelopes.count)
    #expect(b.count == envelopes.count)
    #expect(c.count == envelopes.count)
  }

  @Test
  func unsubscribeStopsDelivery() throws {
    let m = HookEventMulticaster()
    let (id, _) = m.subscribe()
    #expect(m.subscriberCount == 1)
    m.unsubscribe(id: id)
    #expect(m.subscriberCount == 0)
    // Publishing after unsubscribe is a silent no-op (must not crash).
    m.publish(Self.makeEnvelope())
  }

  @Test
  func slowSubscriberDoesNotBlockFastSubscriber() async throws {
    // Both subscribers have a small buffer; we publish within the buffer
    // size, so the fast subscriber sees every event even if the slow one
    // never consumes. (Publishing past the buffer size is a separate
    // "drop newest" scenario and isn't what this test asserts.)
    let m = HookEventMulticaster(bufferPerSubscriber: 4)
    let fast = m.subscribe().stream
    _ = m.subscribe()  // slow — never consumed; must not block publish

    let N = 3
    for _ in 0..<N { m.publish(Self.makeEnvelope()) }

    let received = await Self.collect(from: fast, expected: N, timeout: .seconds(1))
    #expect(received.count == N)
  }

  // MARK: - Helpers

  static func makeEnvelope() -> HookEnvelope {
    HookEnvelope(
      event: .paneReady,
      space: .init(id: SpaceID(), name: "s"),
      project: .init(id: ProjectID(), name: "p", rootPath: "/"),
      worktree: .init(id: WorktreeID(), name: "w", path: "/"),
      tab: .init(id: TabID()),
      pane: .init(id: PaneID(), workingDirectory: "/"),
      data: .paneReady(pid: nil, shell: "/bin/sh")
    )
  }

  static func collect(
    from stream: AsyncStream<HookEnvelope>,
    expected: Int,
    timeout: Duration
  ) async -> [HookEnvelope] {
    await withTaskGroup(of: [HookEnvelope].self) { group in
      group.addTask {
        var out: [HookEnvelope] = []
        for await env in stream {
          out.append(env)
          if out.count >= expected { break }
        }
        return out
      }
      group.addTask {
        try? await Task.sleep(for: timeout)
        return []
      }
      let first = await group.next() ?? []
      group.cancelAll()
      return first
    }
  }
}
