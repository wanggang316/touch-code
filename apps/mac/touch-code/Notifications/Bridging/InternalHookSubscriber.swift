import Foundation
import TouchCodeCore

/// Callback protocol C3's `HookDispatcher` invokes for subscriptions whose
/// `command` starts with a reserved internal sentinel prefix
/// (`__touch-code/internal:`). The dispatcher short-circuits
/// `ProcessHookExecutor` for these subscriptions and delivers the envelope
/// directly to the registered subscriber on the MainActor (C3 DEC-16).
///
/// This file ships the protocol shape from the C3 design doc so C6 can
/// implement it before C3's M2 (`HookDispatcher` + `register(subscriber:for:)`)
/// lands. When C3 M2 lands the authoritative declaration under its own
/// `touch-code/Hooks/` module, this file collapses to a `typealias` or
/// is removed — identifier stays `InternalHookSubscriber` either way so
/// `DetectionRouter`'s conformance is unchanged.
@MainActor
public protocol InternalHookSubscriber: AnyObject {
  func handle(envelope: HookEnvelope) async
}
