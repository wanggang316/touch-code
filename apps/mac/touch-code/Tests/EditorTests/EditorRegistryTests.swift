import Foundation
import Testing
import TouchCodeCore
@testable import touch_code

struct EditorRegistryTests {
  @Test
  func builtinListHasSixEntriesInExpectedOrder() {
    let ids = EditorRegistry.builtins.map(\.id)
    #expect(ids == ["vscode", "cursor", "zed", "xcode", "sublime", "finder"])
  }

  @Test
  func vscodeTemplateMatchesDesign() {
    let entry = EditorRegistry.builtins[0]
    #expect(entry.id == "vscode")
    #expect(entry.displayName == "Visual Studio Code")
    #expect(entry.template.binary == "code")
    #expect(entry.template.args == ["{dir}"])
  }

  @Test
  func xcodeTemplateUsesOpenDashA() {
    let entry = EditorRegistry.builtins.first(where: { $0.id == "xcode" })!
    #expect(entry.template.binary == "open")
    #expect(entry.template.args == ["-a", "Xcode", "{dir}"])
  }

  @Test
  func finderTemplateIsPlainOpen() {
    let entry = EditorRegistry.builtins.first(where: { $0.id == "finder" })!
    #expect(entry.template.binary == "open")
    #expect(entry.template.args == ["{dir}"])
  }

  @Test
  func sublimeCursorZedUseBareBinaries() {
    for id in ["cursor", "zed", "sublime"] {
      let entry = EditorRegistry.builtins.first(where: { $0.id == id })!
      #expect(entry.template.args == ["{dir}"])
      #expect(!entry.template.binary.contains("/"))
    }
  }

  @Test
  func everyBuiltinTemplateValidatesSuccessfully() throws {
    for entry in EditorRegistry.builtins {
      try entry.template.validate()
    }
  }

  @Test
  func mergeIncludesBuiltinsAndCustomsWithResolvedStatus() throws {
    let prober = FakePathProber(resolution: [
      "code": URL(fileURLWithPath: "/usr/local/bin/code"),
      "open": URL(fileURLWithPath: "/usr/bin/open"),
      "helix": URL(fileURLWithPath: "/opt/homebrew/bin/helix"),
    ])
    let custom = CustomEditor(
      id: "helix",
      displayName: "Helix",
      template: CommandTemplate(binary: "helix", args: ["{dir}"])
    )
    let merged = try EditorRegistry.merged(with: [custom], prober: prober)
    #expect(merged.count == EditorRegistry.builtins.count + 1)
    let helix = merged.last!
    #expect(helix.id == "helix")
    #expect(helix.origin == .custom)
    #expect(helix.isInstalled)
    // VSCode installed; Cursor/Zed/Sublime/Xcode marked missing.
    #expect(merged.first(where: { $0.id == "vscode" })?.isInstalled == true)
    #expect(merged.first(where: { $0.id == "zed" })?.isInstalled == false)
    #expect(merged.first(where: { $0.id == "finder" })?.isInstalled == true)
  }

  @Test
  func mergeRejectsCustomIDCollidingWithBuiltin() {
    let prober = FakePathProber(resolution: [:])
    let colliding = CustomEditor(
      id: "vscode",
      displayName: "My VSCode",
      template: CommandTemplate(binary: "code-insiders", args: ["{dir}"])
    )
    #expect(throws: EditorError.badTemplate(id: "vscode", reason: "custom editor ID collides with built-in 'vscode'")) {
      _ = try EditorRegistry.merged(with: [colliding], prober: prober)
    }
  }

  @Test
  func mergeSurfacesBadTemplateForInvalidCustom() {
    let prober = FakePathProber(resolution: [:])
    let invalid = CustomEditor(
      id: "bad",
      displayName: "Bad",
      template: CommandTemplate(binary: "", args: ["{dir}"])
    )
    // validate() throws EditorTemplateError.emptyBinary which the registry rethrows.
    #expect(throws: (any Error).self) {
      _ = try EditorRegistry.merged(with: [invalid], prober: prober)
    }
  }
}
