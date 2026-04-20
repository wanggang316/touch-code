import Foundation
import TouchCodeCore

/// In-memory `EditorService` for tests. Records every `open` call; returns a caller-provided
/// descriptor list from `describe`; drives resolution through the same algorithm as the live
/// service so fallback-chain tests stay honest.
actor TestEditorService: EditorService {
  private var descriptors: [EditorDescriptor]
  private(set) var openCalls: [OpenCall] = []
  private var openResult: Result<EditorChoice, EditorError>?

  struct OpenCall: Equatable, Sendable {
    var directory: URL
    var preferred: EditorID?
    var projectID: ProjectID?
  }

  init(descriptors: [EditorDescriptor] = []) {
    self.descriptors = descriptors
  }

  func setDescriptors(_ descriptors: [EditorDescriptor]) {
    self.descriptors = descriptors
  }

  func setOpenResult(_ result: Result<EditorChoice, EditorError>) {
    self.openResult = result
  }

  func describe() -> [EditorDescriptor] { descriptors }

  func resolve(preferred: EditorID?, projectID: ProjectID?) -> EditorDescriptor {
    if let id = preferred, let match = descriptors.first(where: { $0.id == id }) {
      return match
    }
    // Test service doesn't model global default / project override — callers drive the
    // resolution by supplying `preferred` directly or by setting descriptors.
    return descriptors.first(where: { $0.id == "finder" }) ?? descriptors.first ?? Self.finderFallback
  }

  func open(directory: URL, preferred: EditorID?, projectID: ProjectID?) throws -> EditorChoice {
    openCalls.append(OpenCall(directory: directory, preferred: preferred, projectID: projectID))
    if let result = openResult {
      switch result {
      case .success(let choice): return choice
      case .failure(let error): throw error
      }
    }
    let descriptor = resolve(preferred: preferred, projectID: projectID)
    return EditorChoice(
      id: descriptor.id,
      displayName: descriptor.displayName,
      binaryPath: URL(fileURLWithPath: "/usr/bin/open"),
      argv: ["/usr/bin/open", directory.path]
    )
  }

  private static let finderFallback = EditorDescriptor(
    id: "finder",
    displayName: "Finder",
    origin: .builtin,
    template: CommandTemplate(binary: "open", args: ["{dir}"]),
    installation: .installed(resolvedBinary: URL(fileURLWithPath: "/usr/bin/open"))
  )
}
