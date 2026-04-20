import Foundation
import TouchCodeCore

/// Concrete `HookConfigWriting` implementation that delegates to C3's
/// `HookConfigStore` (plan 0003 M2). Production wiring constructs one of
/// these in the app shell; tests keep using `FakeHookConfigWriter`.
///
/// C3's reserved-namespace API already enforces the
/// `__touch-code/internal:` prefix, serialises writes through the same
/// `AtomicFileStore` used by the rest of the project, and skips the
/// internal-namespace filter on its own internal-load path — so there
/// is no retry logic, no prefix validation, and no version-conflict
/// handling to duplicate on this side.
@MainActor
final class HookConfigStoreAdapter: HookConfigWriting {
  private let store: HookConfigStore

  init(store: HookConfigStore) {
    self.store = store
  }

  func upsertInternal(_ subscriptions: [HookSubscription]) throws {
    try store.upsertInternal(subscriptions)
  }

  func removeInternal(idsPrefixed prefix: String) throws {
    try store.removeInternal(idsPrefixed: prefix)
  }
}
