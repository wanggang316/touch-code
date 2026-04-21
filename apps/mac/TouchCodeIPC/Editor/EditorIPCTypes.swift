import Foundation
import TouchCodeCore

/// Wire type for the `editor.describe` response's per-editor entries.
public nonisolated struct EditorDescriptorDTO: Equatable, Hashable, Codable, Sendable, Identifiable {
  public enum Origin: String, Equatable, Hashable, Codable, Sendable {
    case builtin
    case custom
  }

  public var id: EditorID
  public var displayName: String
  public var origin: Origin
  public var template: CommandTemplate
  public var installation: EditorInstallationStatusDTO

  public init(
    id: EditorID,
    displayName: String,
    origin: Origin,
    template: CommandTemplate,
    installation: EditorInstallationStatusDTO
  ) {
    self.id = id
    self.displayName = displayName
    self.origin = origin
    self.template = template
    self.installation = installation
  }
}

/// Wire type for the `editor.open` response.
public nonisolated struct EditorChoiceDTO: Equatable, Hashable, Codable, Sendable {
  public var id: EditorID
  public var displayName: String
  public var binaryPath: URL
  public var argv: [String]

  public init(id: EditorID, displayName: String, binaryPath: URL, argv: [String]) {
    self.id = id
    self.displayName = displayName
    self.binaryPath = binaryPath
    self.argv = argv
  }
}

/// Installation status for an editor entry, carried in `EditorDescriptorDTO`.
public nonisolated enum EditorInstallationStatusDTO: Equatable, Hashable, Codable, Sendable {
  case installed(resolvedBinary: URL)
  case missingBinary(expected: String)
}

// MARK: - Request / Response envelopes (M7a)

/// `editor.describe` has no parameters. Response carries the current registry.
public nonisolated struct EditorDescribeResponse: Equatable, Codable, Sendable {
  public var descriptors: [EditorDescriptorDTO]

  public init(descriptors: [EditorDescriptorDTO]) {
    self.descriptors = descriptors
  }
}

/// `editor.open` request.
///
/// Worktree resolution order (handler-side):
///   1. `worktreeID` — explicit UUID wins.
///   2. `panelID` — resolve through `HierarchyManager.panel(byID:).parentWorktreeID`.
///   3. Neither → `EditorIPCError.unresolvedWorktree`.
///
/// `preferred` wire field is the editor the caller explicitly asked for (e.g. `tc open --in zed`).
/// Omit to let the handler walk the 4-tier precedence chain (Project override → global default →
/// Finder).
///
/// `path` is an optional absolute path the caller wants opened instead of the resolved Worktree
/// root. The handler validates it lies within the resolved Worktree's directory (standardised
/// path prefix match) before passing it to the spawner; out-of-tree paths fail with
/// `EditorIPCError.notADirectory`. Worktree resolution still runs first so per-Project editor
/// overrides apply even when a sub-path is targeted.
public nonisolated struct EditorOpenRequest: Equatable, Codable, Sendable {
  public var worktreeID: UUID?
  public var preferred: EditorID?
  public var panelID: UUID?
  public var path: String?

  public init(
    worktreeID: UUID? = nil,
    preferred: EditorID? = nil,
    panelID: UUID? = nil,
    path: String? = nil
  ) {
    self.worktreeID = worktreeID
    self.preferred = preferred
    self.panelID = panelID
    self.path = path
  }
}

/// `editor.open` response. Carries the resolved choice so the CLI can pretty-print
/// `opened <path> in <displayName>`.
public nonisolated struct EditorOpenResponse: Equatable, Codable, Sendable {
  public var choice: EditorChoiceDTO
  public var worktreePath: String

  public init(choice: EditorChoiceDTO, worktreePath: String) {
    self.choice = choice
    self.worktreePath = worktreePath
  }
}

/// `editor.setDefault` request. `editorID == nil` unsets the per-Project override.
public nonisolated struct EditorSetDefaultRequest: Equatable, Codable, Sendable {
  public var projectID: UUID
  public var editorID: EditorID?

  public init(projectID: UUID, editorID: EditorID?) {
    self.projectID = projectID
    self.editorID = editorID
  }
}

/// `editor.setDefault` response — empty struct for explicit "success" semantics on the wire.
public nonisolated struct EditorSetDefaultResponse: Equatable, Codable, Sendable {
  public init() {}
}
