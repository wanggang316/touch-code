import Foundation
import Testing

@testable import TouchCodeCore

struct TemplateFieldTests {
  @Test
  func alwaysAvailableExactlyMatchesDocumentedAnchors() {
    let expected: Set<String> = [
      "agent",
      "state.from", "state.to",
      "pane.id", "pane.workingDirectory", "pane.initialCommand",
      "tab.id", "tab.name", "tab.selectedPaneID",
      "worktree.id", "worktree.name", "worktree.path", "worktree.branch",
      "project.id", "project.name", "project.rootPath",
      "space.id", "space.name",
    ]
    #expect(Set(TemplateField.alwaysAvailable.map(\.rawValue)) == expected)
  }

  @Test
  func paneOutputMatchAddsMatchAndRangeFields() {
    let paths = TemplateField.validPaths(for: .paneOutputMatch)
    #expect(paths.isSuperset(of: TemplateField.alwaysAvailable))
    let added = paths.subtracting(TemplateField.alwaysAvailable)
    #expect(added == [
      .dataMatch, .dataOutput, .dataOutputBytes,
      .dataMatchedRangeStart, .dataMatchedRangeLength,
    ])
  }

  @Test
  func paneIdleAddsIdleFields() {
    let added = TemplateField.validPaths(for: .paneIdle)
      .subtracting(TemplateField.alwaysAvailable)
    #expect(added == [.dataIdleSeconds, .dataSinceLastOutput, .dataSinceLastInput])
  }

  @Test
  func paneReadyAddsPidAndShell() {
    let added = TemplateField.validPaths(for: .paneReady)
      .subtracting(TemplateField.alwaysAvailable)
    #expect(added == [.dataPID, .dataShell])
  }

  @Test
  func paneExitedAddsExitCode() {
    let added = TemplateField.validPaths(for: .paneExited)
      .subtracting(TemplateField.alwaysAvailable)
    #expect(added == [.dataExitCode])
  }

  @Test
  func paneCrashedAddsReason() {
    let added = TemplateField.validPaths(for: .paneCrashed)
      .subtracting(TemplateField.alwaysAvailable)
    #expect(added == [.dataReason])
  }

  @Test
  func paneInputAddsTextAndInputBytes() {
    let added = TemplateField.validPaths(for: .paneInput)
      .subtracting(TemplateField.alwaysAvailable)
    #expect(added == [.dataText, .dataInputBytes])
  }

  @Test
  func everyHookEventCaseIsHandledInSwitch() {
    // If a new HookEvent case lands and validPaths(for:) isn't updated,
    // the compiler catches it inside the switch. This test asserts runtime
    // coverage too: every case returns at least the anchors set.
    for event in HookEvent.allCases {
      let paths = TemplateField.validPaths(for: event)
      #expect(paths.isSuperset(of: TemplateField.alwaysAvailable),
              "Event \(event) missing alwaysAvailable anchors")
    }
  }

  @Test
  func dataMatchIsNotValidForNonOutputMatchEvents() {
    // The "shape-bound" guarantee: a rule scoped to .paneIdle can't use
    // {data.match} because the HookEventData case doesn't carry it.
    let idlePaths = TemplateField.validPaths(for: .paneIdle)
    #expect(idlePaths.contains(.dataMatch) == false)
    #expect(idlePaths.contains(.dataOutput) == false)
  }
}
