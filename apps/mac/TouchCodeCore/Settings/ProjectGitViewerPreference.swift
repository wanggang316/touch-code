import Foundation

/// Per-Project override for "which Git Viewer does the ⌘⌥G chord open?". The
/// wrapping `Optional` on `ProjectSettings.defaultGitViewer` carries the
/// "inherit `GeneralSettings.defaultGitViewerID`" state (`nil`); this enum
/// names the two explicit overrides:
///
/// - `.builtin`  — force the in-app Git Viewer overlay even when the global
///                 default points at an external client.
/// - `.external` — open the worktree in the named git client (one of the IDs
///                 from `EditorRegistry.gitClientPriority`).
///
/// Codable shape is a single JSON string so `settings.json` stays human
/// readable: `"builtin"` for the in-app overlay, otherwise the raw
/// `EditorID`. `EditorRegistry` IDs are lowerCamelCase application names
/// (`"cursor"`, `"githubDesktop"`, …) and cannot collide with the `"builtin"`
/// sentinel; a future registry rename that tried to introduce a clashing ID
/// would still encode safely (it'd round-trip as `.external("builtin")`) but
/// would lose the in-band sentinel — guard against that at registry-edit
/// time, not here.
public enum ProjectGitViewerPreference: Equatable, Hashable, Sendable {
  case builtin
  case external(EditorID)

  /// Sentinel string used by the single-value Codable encoding for
  /// `.builtin`. Exposed so callers building hand-written JSON in tests or
  /// migrations can mirror the same constant.
  public static let builtinSentinel: String = "builtin"
}

extension ProjectGitViewerPreference: Codable {
  public init(from decoder: Decoder) throws {
    let container = try decoder.singleValueContainer()
    let raw = try container.decode(String.self)
    if raw == Self.builtinSentinel {
      self = .builtin
    } else {
      self = .external(raw)
    }
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.singleValueContainer()
    switch self {
    case .builtin:
      try container.encode(Self.builtinSentinel)
    case .external(let id):
      try container.encode(id)
    }
  }
}
