import Foundation

/// Category of a `ScriptDefinition`. Drives the default name, SF Symbol icon,
/// and tint colour when the user does not override them. `.custom` is the only
/// kind whose `systemImage` / `tintColor` fields on `ScriptDefinition` are
/// honoured by the resolver — predefined kinds always render with their kind
/// default ("kind is the contract").
public enum ScriptKind: String, Codable, Sendable, CaseIterable {
  case run
  case test
  case deploy
  case lint
  case format
  case custom

  /// User-facing default name when `ScriptDefinition.name` is empty.
  public var defaultName: String {
    switch self {
    case .run: return "Run"
    case .test: return "Test"
    case .deploy: return "Deploy"
    case .lint: return "Lint"
    case .format: return "Format"
    case .custom: return "Custom"
    }
  }

  /// SF Symbol name resolved by the view layer. Predefined kinds use these
  /// directly; `.custom` uses `ScriptDefinition.systemImage` when set.
  public var defaultSystemImage: String {
    switch self {
    case .run: return "play.fill"
    case .test: return "checkmark.seal.fill"
    case .deploy: return "paperplane.fill"
    case .lint: return "magnifyingglass"
    case .format: return "wand.and.stars"
    case .custom: return "terminal.fill"
    }
  }

  /// Tint colour resolved by the view layer. `.custom` uses
  /// `ScriptDefinition.tintColor` when set.
  public var defaultTintColor: ScriptTintColor {
    switch self {
    case .run: return .green
    case .test: return .yellow
    case .deploy: return .blue
    case .lint: return .purple
    case .format: return .teal
    case .custom: return .gray
    }
  }
}
