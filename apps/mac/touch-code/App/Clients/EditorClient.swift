import ComposableArchitecture
import Foundation
import TouchCodeCore

/// TCA dependency-injection bridge over `EditorService`. Replaces the M3 `EditorServiceFacade`
/// placeholder (which threw `EditorPlaceholderError.notYetImplemented`) with a real surface
/// wired to `LiveEditorService` from M5. The live factory closes over `SettingsStore` and
/// `HierarchyManager` for the global default + per-Project override reads.
///
/// The two tier-changing methods (`setDefaultEditorID`, `setPerProjectDefaultEditor`) live on
/// `SettingsStore` and `HierarchyClient` respectively — they mutate persistent state and
/// don't belong on a read/dispatch client.
nonisolated struct EditorClient: Sendable {
  var describe: @Sendable () async -> [EditorDescriptor]
  var resolve: @Sendable (_ preferred: EditorID?, _ projectID: ProjectID?) async -> EditorDescriptor
  var open: @Sendable (_ directory: URL, _ preferred: EditorID?, _ projectID: ProjectID?) async throws -> EditorChoice
}

extension EditorClient {
  /// Constructs a client that forwards to a `LiveEditorService`. The closures capture the
  /// settings + hierarchy reads; pass `nil` for either to use the safe defaults (no global
  /// default, no project override).
  @MainActor
  static func live(
    settings: SettingsStore?,
    hierarchy: HierarchyManager?
  ) -> EditorClient {
    let service = LiveEditorService(
      spawner: FoundationProcessSpawner(),
      prober: LivePathProber(),
      globalDefault: { [weak settings] in
        // @MainActor-isolated read; SettingsStore is @Observable on MainActor.
        MainActor.assumeIsolated { settings?.settings.defaultEditorID }
      },
      customEditors: { [weak settings] in
        MainActor.assumeIsolated { settings?.settings.customEditors ?? [] }
      },
      projectOverride: { [weak hierarchy] projectID in
        MainActor.assumeIsolated {
          guard let hierarchy else { return nil }
          return EditorClient.findProjectDefault(in: hierarchy.catalog, projectID: projectID)
        }
      }
    )
    return EditorClient(
      describe: { await service.describe() },
      resolve: { preferred, projectID in
        await service.resolve(preferred: preferred, projectID: projectID)
      },
      open: { directory, preferred, projectID in
        try await service.open(directory: directory, preferred: preferred, projectID: projectID)
      }
    )
  }

  /// Walks the catalog for the Project and returns its `defaultEditor`. `nil` if the
  /// project can't be found or has no override.
  fileprivate static func findProjectDefault(in catalog: Catalog, projectID: ProjectID) -> EditorID? {
    for space in catalog.spaces {
      for project in space.projects where project.id == projectID {
        return project.defaultEditor
      }
    }
    return nil
  }
}

extension EditorClient: DependencyKey {
  /// `liveValue` is intentionally unusable — missing wiring is a programmer error, not a
  /// silent fallback. `TouchCodeApp.bringUp()` overrides via `.withDependencies { $0.editorClient = .live(...) }`.
  /// If you see one of these fatalErrors, the real factory wasn't applied at app startup.
  /// Matches `HierarchyClient.liveValue` / `TerminalClient.liveValue` conventions.
  static let liveValue: EditorClient = EditorClient(
    describe: {
      fatalError("EditorClient.liveValue not configured; wire via `.withDependencies` at app startup with `.live(settings:hierarchy:)`")
    },
    resolve: { _, _ in
      fatalError("EditorClient.liveValue not configured")
    },
    open: { _, _, _ in
      fatalError("EditorClient.liveValue not configured")
    }
  )

  static let testValue: EditorClient = EditorClient(
    describe: unimplemented("EditorClient.describe", placeholder: []),
    resolve: unimplemented(
      "EditorClient.resolve",
      placeholder: EditorDescriptor(
        id: "finder",
        displayName: "Finder",
        origin: .builtin,
        template: CommandTemplate(binary: "open", args: ["{dir}"]),
        installation: .installed(resolvedBinary: URL(fileURLWithPath: "/usr/bin/open"))
      )
    ),
    open: unimplemented(
      "EditorClient.open",
      placeholder: EditorChoice(
        id: "finder",
        displayName: "Finder",
        binaryPath: URL(fileURLWithPath: "/usr/bin/open"),
        argv: ["/usr/bin/open"]
      )
    )
  )
}

extension DependencyValues {
  var editorClient: EditorClient {
    get { self[EditorClient.self] }
    set { self[EditorClient.self] = newValue }
  }
}
