import Foundation
import TouchCodeCore

/// In-process consumer of hook envelopes for a reserved-prefix route.
///
/// Peer of the `hook.events` streaming RPC (exec-plan 0003 DEC-10): C6 and
/// other first-party consumers register a subscriber against a command
/// prefix in the reserved `__touch-code/internal:` namespace, and the
/// dispatcher short-circuits matching subscriptions directly to
/// `handle(envelope:)` instead of spawning a child process.
public protocol InternalHookSubscriber: AnyObject, Sendable {
  func handle(envelope: HookEnvelope) async
}

/// The reserved prefix for in-process sentinel-route commands. User
/// subscriptions authored via `hooks.json` or `tc hook install` are
/// rejected at load time if their `command` starts with this prefix; only
/// the app-side-owned `HookConfigStore.upsertInternal(_:)` path admits them.
public let touchCodeInternalPrefix = "__touch-code/internal:"
