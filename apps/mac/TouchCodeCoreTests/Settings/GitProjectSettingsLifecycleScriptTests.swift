import Foundation
import Testing

@testable import TouchCodeCore

struct GitProjectSettingsLifecycleScriptTests {
  private let encoder: JSONEncoder = {
    let e = JSONEncoder()
    e.outputFormatting = [.sortedKeys]
    return e
  }()
  private let decoder = JSONDecoder()

  @Test
  func payloadWithoutLifecycleScriptsDecodesWithEmptyDefaults() throws {
    // Phase 1 settings.json shape — no setupScript / archiveScript / deleteScript keys.
    let payload = Data("""
      { "githubDisabled": true }
      """.utf8)
    let git = try decoder.decode(GitProjectSettings.self, from: payload)
    #expect(git.setupScript == "")
    #expect(git.archiveScript == "")
    #expect(git.deleteScript == "")
  }

  @Test
  func roundTripsWithEveryLifecycleScriptPopulated() throws {
    let git = GitProjectSettings(
      setupScript: "npm install",
      archiveScript: "git lfs prune",
      deleteScript: "./scripts/save-state.sh"
    )
    let data = try encoder.encode(git)
    let decoded = try decoder.decode(GitProjectSettings.self, from: data)
    #expect(decoded == git)
  }

  @Test
  func encoderOmitsEmptyLifecycleScripts() throws {
    let git = GitProjectSettings(
      setupScript: "npm install",
      archiveScript: "",
      deleteScript: ""
    )
    let data = try encoder.encode(git)
    let text = try #require(String(bytes: data, encoding: .utf8))
    #expect(text.contains("\"setupScript\":\"npm install\""))
    #expect(text.contains("archiveScript") == false)
    #expect(text.contains("deleteScript") == false)
  }

  @Test
  func emptyLifecycleScriptsDoNotBreakIsEffectivelyEmpty() {
    var git = GitProjectSettings()
    #expect(git.isEffectivelyEmpty == true)

    git.setupScript = "echo hi"
    #expect(git.isEffectivelyEmpty == false)

    git.setupScript = ""
    git.archiveScript = "echo bye"
    #expect(git.isEffectivelyEmpty == false)

    git.archiveScript = ""
    #expect(git.isEffectivelyEmpty == true)
  }

  @Test
  func projectSettingsCollapsesGitWithOnlyLifecycleScriptsToNonEmpty() {
    // A `git` subtree with a lifecycle script set is NOT effectively empty.
    var settings = ProjectSettings(
      git: GitProjectSettings(setupScript: "npm install")
    )
    settings.collapseEmptyGit()
    #expect(settings.git != nil)
    #expect(settings.isEffectivelyEmpty == false)
  }
}
