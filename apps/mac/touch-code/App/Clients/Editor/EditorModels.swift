import Foundation
import TouchCodeCore
import TouchCodeIPC

/// App-tier descriptor for a single editor entry — built-in or user-defined, decorated with
/// the current installation status from `PathProber`. Converted to `EditorDescriptorDTO` for
/// IPC crossing in M7a.
public nonisolated struct EditorDescriptor: Equatable, Hashable, Sendable, Identifiable {
  public enum Origin: String, Equatable, Hashable, Sendable, Codable {
    case builtin
    case custom
  }

  public enum InstallationStatus: Equatable, Hashable, Sendable {
    case installed(resolvedBinary: URL)
    case missingBinary(expected: String)
  }

  public let id: EditorID
  public let displayName: String
  public let origin: Origin
  public let template: CommandTemplate
  public let installation: InstallationStatus

  public init(
    id: EditorID,
    displayName: String,
    origin: Origin,
    template: CommandTemplate,
    installation: InstallationStatus
  ) {
    self.id = id
    self.displayName = displayName
    self.origin = origin
    self.template = template
    self.installation = installation
  }

  public var isInstalled: Bool {
    if case .installed = installation { return true }
    return false
  }

  /// Bridge to the IPC DTO used in M7a for `editor.describe`.
  public func toDTO() -> EditorDescriptorDTO {
    let installationDTO: EditorInstallationStatusDTO
    switch installation {
    case .installed(let url): installationDTO = .installed(resolvedBinary: url)
    case .missingBinary(let expected): installationDTO = .missingBinary(expected: expected)
    }
    return EditorDescriptorDTO(
      id: id,
      displayName: displayName,
      origin: origin == .builtin ? .builtin : .custom,
      template: template,
      installation: installationDTO
    )
  }
}

/// Resolved editor + its argv at spawn time. Returned from `EditorService.open` on success.
/// Tests assert on this value to avoid needing a real `Process`.
public nonisolated struct EditorChoice: Equatable, Hashable, Sendable {
  public let id: EditorID
  public let displayName: String
  public let binaryPath: URL
  public let argv: [String]

  public init(id: EditorID, displayName: String, binaryPath: URL, argv: [String]) {
    self.id = id
    self.displayName = displayName
    self.binaryPath = binaryPath
    self.argv = argv
  }

  public func toDTO() -> EditorChoiceDTO {
    EditorChoiceDTO(id: id, displayName: displayName, binaryPath: binaryPath, argv: argv)
  }
}
