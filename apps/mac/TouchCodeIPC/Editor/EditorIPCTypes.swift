import Foundation
import TouchCodeCore

// TODO(C8a Phase 4c): the IPC wire types below still reflect the C8 Process-based shape
// (argv, CommandTemplate, InstallationStatusDTO). Phase 4c rewrites them to match the
// NSWorkspace-backed descriptor (bundleIdentifier, launchMode, appURL). Kept here as
// minimal, compilable placeholders for Phase 3 so the socket module continues to build.

/// Stub wire type for the `editor.describe` response's per-editor entries. Phase 4c
/// replaces with the real C8a shape (launchMode, appURL, bundleIdentifier).
public nonisolated struct EditorDescriptorDTO: Equatable, Hashable, Codable, Sendable, Identifiable {
  public var id: EditorID
  public var displayName: String

  public init(id: EditorID, displayName: String) {
    self.id = id
    self.displayName = displayName
  }
}

/// Stub wire type for the `editor.open` response.
public nonisolated struct EditorChoiceDTO: Equatable, Hashable, Codable, Sendable {
  public var id: EditorID
  public var displayName: String

  public init(id: EditorID, displayName: String) {
    self.id = id
    self.displayName = displayName
  }
}

// MARK: - Request / Response envelopes

public nonisolated struct EditorDescribeResponse: Equatable, Codable, Sendable {
  public var descriptors: [EditorDescriptorDTO]

  public init(descriptors: [EditorDescriptorDTO]) {
    self.descriptors = descriptors
  }
}

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

public nonisolated struct EditorOpenResponse: Equatable, Codable, Sendable {
  public var choice: EditorChoiceDTO
  public var worktreePath: String

  public init(choice: EditorChoiceDTO, worktreePath: String) {
    self.choice = choice
    self.worktreePath = worktreePath
  }
}

public nonisolated struct EditorSetDefaultRequest: Equatable, Codable, Sendable {
  public var projectID: UUID
  public var editorID: EditorID?

  public init(projectID: UUID, editorID: EditorID?) {
    self.projectID = projectID
    self.editorID = editorID
  }
}

public nonisolated struct EditorSetDefaultResponse: Equatable, Codable, Sendable {
  public init() {}
}
