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
