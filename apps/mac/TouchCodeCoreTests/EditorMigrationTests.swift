import Foundation
import Testing

@testable import TouchCodeCore

/// C8a Phase 6.4 — editor-ID migration coverage. Exercises the two value-domain normalizers
/// added in Phase 5: `Settings.garbageCollectEditors(knownIDs:)` and
/// `Catalog.garbageCollectEditors(knownIDs:)`. Both:
///   - Reset IDs that are not in the caller-supplied registry to `nil`.
///   - Leave valid IDs untouched.
///   - Return `true` iff any field was mutated (so callers skip spurious writes).
///
/// Neither helper imports the app-tier `EditorRegistry`, so `knownIDs` is passed explicitly.
struct EditorMigrationTests {
  private static let known: Set<EditorID> = ["vscode", "cursor", "zed", "finder", "editor"]

  // MARK: - Settings.garbageCollectEditors

  @Test
  func settingsGarbageCollectResetsStaleDefaultEditorID() {
    var settings = Settings()
    settings.general.defaultEditorID = "unknownCustom"

    let mutated = settings.garbageCollectEditors(knownIDs: Self.known)
    #expect(mutated == true, "Stale ID must mutate and return true")
    #expect(settings.general.defaultEditorID == nil)
  }

  @Test
  func settingsGarbageCollectKeepsValidDefaultEditorID() {
    var settings = Settings()
    settings.general.defaultEditorID = "cursor"

    let mutated = settings.garbageCollectEditors(knownIDs: Self.known)
    #expect(mutated == false, "Valid ID must not mutate and must return false")
    #expect(settings.general.defaultEditorID == "cursor")
  }

  @Test
  func settingsGarbageCollectIsNoOpWhenDefaultIsNil() {
    var settings = Settings()
    settings.general.defaultEditorID = nil

    let mutated = settings.garbageCollectEditors(knownIDs: Self.known)
    #expect(mutated == false)
    #expect(settings.general.defaultEditorID == nil)
  }

  @Test
  func settingsGarbageCollectIsIdempotent() {
    var settings = Settings()
    settings.general.defaultEditorID = "ghost-editor"

    let first = settings.garbageCollectEditors(knownIDs: Self.known)
    let second = settings.garbageCollectEditors(knownIDs: Self.known)
    #expect(first == true)
    #expect(second == false, "Second pass must be a no-op")
    #expect(settings.general.defaultEditorID == nil)
  }

  // MARK: - Catalog.garbageCollectEditors

  @Test
  func catalogGarbageCollectResetsStaleProjectDefaultEditor() {
    var catalog = Self.makeCatalog(projectDefaults: ["unknownCustom"])
    let mutated = catalog.garbageCollectEditors(knownIDs: Self.known)
    #expect(mutated == true)
    #expect(catalog.spaces[0].projects[0].defaultEditor == nil)
  }

  @Test
  func catalogGarbageCollectKeepsValidProjectDefaultEditor() {
    var catalog = Self.makeCatalog(projectDefaults: ["vscode"])
    let mutated = catalog.garbageCollectEditors(knownIDs: Self.known)
    #expect(mutated == false)
    #expect(catalog.spaces[0].projects[0].defaultEditor == "vscode")
  }

  @Test
  func catalogGarbageCollectIsNoOpOnCleanCatalog() {
    var catalog = Catalog()
    let mutated = catalog.garbageCollectEditors(knownIDs: Self.known)
    #expect(mutated == false)
  }

  @Test
  func catalogGarbageCollectMixedStaleAndValidNormalisesOnlyStale() {
    // Space A: one project with a stale ID. Space B: one project with a valid ID.
    let staleProject = Project(
      name: "stale",
      rootPath: "/tmp/stale",
      defaultEditor: "ghost-editor"
    )
    let validProject = Project(
      name: "valid",
      rootPath: "/tmp/valid",
      defaultEditor: "cursor"
    )
    let spaceA = Space(name: "A", projects: [staleProject])
    let spaceB = Space(name: "B", projects: [validProject])
    var catalog = Catalog(spaces: [spaceA, spaceB])

    let mutated = catalog.garbageCollectEditors(knownIDs: Self.known)
    #expect(mutated == true)
    #expect(catalog.spaces[0].projects[0].defaultEditor == nil)
    #expect(catalog.spaces[1].projects[0].defaultEditor == "cursor")
  }

  @Test
  func catalogGarbageCollectIsIdempotent() {
    var catalog = Self.makeCatalog(projectDefaults: ["ghost"])
    let first = catalog.garbageCollectEditors(knownIDs: Self.known)
    let second = catalog.garbageCollectEditors(knownIDs: Self.known)
    #expect(first == true)
    #expect(second == false)
  }

  // MARK: - Legacy tolerance

  @Test
  func settingsDecodeToleratesLegacyCustomEditorsField() throws {
    // C8 shipped a `customEditors` array that C8a retired. Legacy files must still decode
    // cleanly (the field is ignored); there is no crash path even when the array is present
    // and non-empty.
    let legacyJSON = #"""
      {
        "version": 2,
        "general": {
          "appearance": "system",
          "defaultEditorID": "vscode",
          "customEditors": [
            { "id": "helix", "displayName": "Helix",
              "template": { "binary": "hx", "args": ["{dir}"] } }
          ]
        }
      }
      """#
    let data = Data(legacyJSON.utf8)
    let settings = try JSONDecoder().decode(Settings.self, from: data)
    #expect(settings.general.defaultEditorID == "vscode")
    // No assertion on the dropped field — the point is that decode did not throw.
  }

  // MARK: - Helpers

  private static func makeCatalog(projectDefaults: [EditorID?]) -> Catalog {
    let projects = projectDefaults.enumerated().map { index, editorID in
      Project(
        name: "p\(index)",
        rootPath: "/tmp/p\(index)",
        defaultEditor: editorID
      )
    }
    let space = Space(name: "Default", projects: projects)
    return Catalog(spaces: [space])
  }
}
