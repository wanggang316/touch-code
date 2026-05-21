import Foundation

/// Reason a candidate notification was suppressed before reaching any sink.
/// Shared between `DetectionTranslator.Step.drop` (pure-layer translator
/// suppressions) and `NotificationCoordinator.Decision.dropped` (app-layer
/// policy suppressions). Case set is intentionally union of both layers; not
/// every value is emitted by every layer.
public nonisolated enum InboxDropReason: String, Equatable, Sendable, Codable {
  case sourceIsFocused             // coordinator only
  case inAppDisabled               // coordinator only
  case systemDisabled              // coordinator only
  case paneMuted                   // detector-side; coordinator never sees these
  case commandFinishedDisabled     // translator only (M4.T1)
  case commandFinishedShort        // translator only (M4.T1)
  case commandCancelled            // translator only (M4.T1)
  case userTypingRecently          // translator only (M4.T1; needs M5.T1 to actually fire)
  case authorizationDenied         // coordinator only
}
