import ComposableArchitecture
import Foundation
import TouchCodeCore
import TouchCodeIPC

/// Server-side handler for the `editor.*` IPC surface. Bridges the transport-layer wire types
/// to the app-tier `EditorClient` + `HierarchyClient` + `SettingsStore`.
///
/// C8a Phase 4c implements four methods:
///
/// - `editor.describe` — returns the installed-only descriptor list (`EditorClient.describe`).
/// - `editor.open` — canonicalizes the caller's path, applies the per-Project override if the
///   caller did not supply `preferred`, and delegates to `EditorClient.open`.
/// - `editor.setGlobalDefault` — writes `settings.general.defaultEditorID` via `SettingsStore`.
/// - `editor.setProjectDefault` — writes `Project.defaultEditor` via
///   `HierarchyClient.setRepositoryDefaultEditor`.
///
/// The handler is the only place the IPC layer touches `HierarchyClient` + `SettingsStore`; the
/// `EditorService` itself never sees a `ProjectID` (design doc §"Resolution chain — split across
/// two layers").
@MainActor
final class EditorHandlers {
  private let editor: EditorClient
  private let hierarchy: HierarchyClient
  private let settings: SettingsStore

  init(editor: EditorClient, hierarchy: HierarchyClient, settings: SettingsStore) {
    self.editor = editor
    self.hierarchy = hierarchy
    self.settings = settings
  }

  // MARK: - describe

  func describe() async -> EditorDescribeResponse {
    // Refresh the service cache on every IPC call (R4): a user who installed Cursor while the
    // app was running sees it in their next `tc open` without restarting.
    await editor.clearCache()
    let descriptors = await editor.describe()
    return EditorDescribeResponse(descriptors: descriptors.map(Self.dto(from:)))
  }

  // MARK: - open

  func open(_ request: EditorOpenRequest) async throws -> EditorOpenResponse {
    // Normalize the path through `HierarchyManager.canonicalPath` so symlinks (`/tmp` →
    // `/private/var/folders/...`) resolve to the same form `Project.rootPath` stores. Without
    // this the `isPathRegistered` lookup silently misses every macOS temp directory.
    let canonical = HierarchyManager.canonicalPath(request.path)

    // Validate shape up front so the caller gets a clean `.notADirectory` rather than a launch
    // failure deep inside NSWorkspace. The service re-checks, but surfacing the error here is
    // cheaper and the error code on the wire is identical either way.
    var isDir: ObjCBool = false
    let exists = FileManager.default.fileExists(atPath: canonical, isDirectory: &isDir)
    guard exists, isDir.boolValue else {
      throw EditorIPCError.notADirectory
    }

    // Per-Project override (lenient): only applied when the caller did not supply `preferred`.
    // If the override is uninstalled, silently fall through to the service's global-default
    // cascade — design doc §Resolution chain, "lenient" tier.
    var preferred = request.preferred
    if preferred == nil {
      preferred = await Self.projectOverride(
        for: canonical,
        hierarchy: hierarchy,
        editor: editor
      )
    }

    let directory = URL(fileURLWithPath: canonical, isDirectory: true)
    do {
      let choice = try await editor.open(directory, preferred)
      return EditorOpenResponse(choice: Self.dto(from: choice))
    } catch let error as EditorError {
      throw Self.ipcError(for: error)
    }
  }

  // MARK: - setGlobalDefault

  func setGlobalDefault(_ request: EditorSetGlobalDefaultRequest) -> EditorSetGlobalDefaultResponse {
    // Atomic write via SettingsStore's convenience setter (matches the appearance / mute
    // patterns the Settings pane uses; persistence is debounced through scheduleSave).
    settings.setDefaultEditorID(request.editorID)
    return EditorSetGlobalDefaultResponse()
  }

  // MARK: - setProjectDefault

  func setProjectDefault(
    _ request: EditorSetProjectDefaultRequest
  ) throws -> EditorSetProjectDefaultResponse {
    let projectID = ProjectID(raw: request.projectID)
    do {
      try hierarchy.setRepositoryDefaultEditor(projectID, request.editorID)
    } catch {
      // `HierarchyError.notFound` for an unknown projectID is the only expected throw here; any
      // other error still rolls up to `.internal` via the router's default mapping.
      throw EditorIPCError.unknownProject
    }
    return EditorSetProjectDefaultResponse()
  }

  // MARK: - Helpers

  /// Look up the per-Project default editor for the given canonical path. Returns the ID only
  /// when (a) the path resolves to the root or a subdirectory of a registered Project, (b)
  /// that Project has a `defaultEditor` override, AND (c) the override is currently installed
  /// per `editor.describe`. Otherwise returns nil so the service cascades to the global
  /// default.
  ///
  /// Uses `projectContaining` rather than `isPathRegistered` so `tc open` run from a
  /// subdirectory (e.g. `/repo/Sources/`) still honors the Project's override. Exact-match
  /// lookup would silently miss every subdirectory call site.
  private static func projectOverride(
    for canonicalPath: String,
    hierarchy: HierarchyClient,
    editor: EditorClient
  ) async -> EditorID? {
    guard let (_, projectID) = hierarchy.projectContaining(canonicalPath) else {
      return nil
    }
    let catalog = hierarchy.snapshot()
    guard let project = Self.findProject(in: catalog, id: projectID) else {
      return nil
    }
    guard let projectDefault = project.defaultEditor else {
      return nil
    }
    let installed = await editor.describe()
    guard installed.contains(where: { $0.id == projectDefault }) else {
      return nil
    }
    return projectDefault
  }

  private static func findProject(in catalog: Catalog, id projectID: ProjectID) -> Project? {
    for space in catalog.spaces {
      if let project = space.projects.first(where: { $0.id == projectID }) {
        return project
      }
    }
    return nil
  }

  // MARK: - DTO mapping

  private static func dto(from descriptor: EditorDescriptor) -> EditorDescriptorDTO {
    EditorDescriptorDTO(
      id: descriptor.id,
      displayName: descriptor.displayName,
      bundleIdentifier: descriptor.bundleIdentifier,
      launchMode: dto(from: descriptor.launchMode),
      appURL: descriptor.appURL,
      alternateBundleIdentifiers: descriptor.alternateBundleIdentifiers
    )
  }

  private static func dto(from mode: EditorDescriptor.LaunchMode) -> EditorDescriptorDTO.LaunchModeDTO {
    switch mode {
    case .directory: return .directory
    case .applicationWithArguments: return .applicationWithArguments
    case .shellEditor: return .shellEditor
    }
  }

  private static func dto(from choice: EditorChoice) -> EditorChoiceDTO {
    EditorChoiceDTO(
      id: choice.id,
      displayName: choice.displayName,
      binaryPath: choice.binaryPath
    )
  }

  /// Translate app-tier `EditorError` to the wire-safe `EditorIPCError`. Keeps app-tier types
  /// from crossing the socket.
  private static func ipcError(for error: EditorError) -> EditorIPCError {
    switch error {
    case .notInstalled: return .notInstalled
    case .launchFailed: return .launchFailed
    case .notADirectory: return .notADirectory
    }
  }
}
