import Foundation

/// Appearance preference rendered in General settings. Persisted verbatim but does not yet
/// drive any theme engine (spec M4.1: "preview only"). The caption beside the picker makes
/// this clear to the user.
public nonisolated enum AppearancePreference: String, Equatable, Codable, Sendable, CaseIterable {
  case system
  case light
  case dark
}
