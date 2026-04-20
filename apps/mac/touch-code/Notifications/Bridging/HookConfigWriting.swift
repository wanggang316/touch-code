import Foundation
import TouchCodeCore

/// Narrow protocol `RuleStore` uses to materialise detection rules as C3
/// `HookSubscription`s in `hooks.json`. C3 M2's `HookConfigStore` exposes
/// **dedicated reserved-namespace APIs** for first-party internal
/// subscriptions (`__touch-code/internal:*` commands). Per the revised
/// DEC-P1, we ride those APIs instead of load/save — C3's `load()`
/// silently filters reserved-prefix rows as a security-hardening
/// measure, so a load-filter-append-save loop would drop its own
/// sentinel rows on every reload.
///
/// Semantics:
/// - `upsertInternal(_:)` atomically replaces the reserved-prefix
///   subscriptions matching each passed `HookSubscription.command`
///   prefix with the supplied set. C3 validates prefixes and persists
///   atomically — no retry-on-conflict dance on this side.
/// - `removeInternal(idsPrefixed:)` removes every reserved-prefix
///   subscription whose `command` starts with the given string.
///
/// When C3 M2 lands the concrete adapter, the app shell wires it in.
/// Tests use `FakeHookConfigWriter` (in `RuleStoreTests.swift`).
@MainActor
public protocol HookConfigWriting: AnyObject {
  /// Replace the set of reserved-prefix subscriptions with the supplied
  /// ones. C3 detects the prefix from each subscription's `command`.
  func upsertInternal(_ subscriptions: [HookSubscription]) throws

  /// Remove every reserved-prefix subscription whose `command` starts
  /// with `prefix`. Used by `RuleStore.reloadAndRematerialise` when the
  /// rule file is missing and C6 should clear its side of `hooks.json`.
  func removeInternal(idsPrefixed prefix: String) throws
}
