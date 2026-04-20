import ComposableArchitecture
import Foundation
import TouchCodeCore
import TouchCodeIPC

/// Minimal placeholder facade for the editor-open hand-off in M3. Replaced in
/// M6 by the real `EditorClient` over `LiveEditorService`. See 0005 plan
/// DEC-1: the live implementation throws `EditorPlaceholderError.notYetImplemented`
/// so `.openInEditorRequested` produces a clean `Result.failure` (→ toast)
/// rather than a crash or silent success.
///
/// The facade carries the minimum shape `GitViewerFeature` needs:
/// - `openDirectory(URL, preferred: EditorID?, projectID: ProjectID?)`
///   returning `EditorChoiceDTO` for wire compatibility with the M5 service.
nonisolated struct EditorServiceFacade: Sendable {
  var openDirectory: @Sendable (URL, EditorID?, ProjectID?) async throws -> EditorChoiceDTO
}

extension EditorServiceFacade: DependencyKey {
  static let liveValue: EditorServiceFacade = EditorServiceFacade(
    openDirectory: { _, _, _ in
      throw EditorPlaceholderError.notYetImplemented
    }
  )

  static let testValue: EditorServiceFacade = EditorServiceFacade(
    openDirectory: unimplemented(
      "EditorServiceFacade.openDirectory",
      placeholder: EditorChoiceDTO(
        id: "finder",
        displayName: "Finder",
        binaryPath: URL(fileURLWithPath: "/usr/bin/open"),
        argv: ["/usr/bin/open"]
      )
    )
  )
}

extension DependencyValues {
  var editorFacade: EditorServiceFacade {
    get { self[EditorServiceFacade.self] }
    set { self[EditorServiceFacade.self] = newValue }
  }
}
