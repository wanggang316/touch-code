import Foundation

/// Thrown by the M3 `EditorServiceFacade.liveValue` before M5 lands the real `EditorService`.
/// The case exists so the UI surfaces a real `Result.failure` (→ toast) rather than crashing
/// via `fatalError`, and so production code paths stay complete from M3 onward. See 0005
/// exec-plan DEC-1.
///
/// M5 replaces the facade's live implementation; after that this error becomes benign-unused.
/// Optional M6 cleanup may remove it.
public nonisolated enum EditorPlaceholderError: Error, Equatable, Sendable {
  case notYetImplemented
}
