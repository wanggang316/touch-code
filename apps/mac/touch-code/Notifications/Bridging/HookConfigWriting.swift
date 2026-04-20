import Foundation
import TouchCodeCore

/// Narrow protocol `RuleStore` uses to materialise detection rules as C3
/// `HookSubscription`s in `hooks.json` without importing the C3-owned
/// `HookConfigStore` directly. Matches C3's existing `HookConfigStore`
/// surface (load + save) — no new upsert API required (per DEC-P1).
///
/// When C3 M2 lands `HookConfigStore`, the app shell wires a concrete
/// `HookConfigStoreAdapter` (not shipped yet — awaiting that milestone)
/// that delegates these two calls. Tests use `FakeHookConfigWriter`.
@MainActor
public protocol HookConfigWriting: AnyObject {
  func load() throws -> HookConfig
  func save(_ config: HookConfig) throws
}
