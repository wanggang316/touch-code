import Foundation

/// Stable identifier for an editor entry — either a built-in (e.g. `"vscode"`) or a user-defined
/// custom template. Stored in `Project.defaultEditor` and in `settings.json`. Validation (regex,
/// reserved-prefix checks) lives in `EditorValidators`.
public typealias EditorID = String

/// A template for spawning an external editor on a Worktree directory. The `args` array must
/// contain exactly one literal `"{dir}"` token (see `CommandTemplate.dirPlaceholder`); the
/// service layer substitutes it with the absolute Worktree path at spawn time.
///
/// There is no shell involved: each `args` element lands in one `argv` slot. Paths with spaces,
/// quotes, or shell metacharacters reach the editor verbatim.
public nonisolated struct CommandTemplate: Equatable, Hashable, Codable, Sendable {
  public static let dirPlaceholder = "{dir}"

  /// The binary to invoke. If it contains `/`, treated as an absolute path. Otherwise resolved
  /// on `$PATH` at spawn time.
  public var binary: String

  /// The arguments passed to `binary`. Exactly one element must equal `"{dir}"`.
  public var args: [String]

  public init(binary: String, args: [String]) {
    self.binary = binary
    self.args = args
  }
}

/// A user-defined editor entry persisted in `settings.json`. IDs are validated against
/// `EditorValidators.validateCustomEditorID`.
public nonisolated struct CustomEditor: Equatable, Hashable, Codable, Sendable, Identifiable {
  public var id: EditorID
  public var displayName: String
  public var template: CommandTemplate

  public init(id: EditorID, displayName: String, template: CommandTemplate) {
    self.id = id
    self.displayName = displayName
    self.template = template
  }
}
