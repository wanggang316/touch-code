import Foundation
import Testing

@testable import TouchCodeCore

struct TemplateFieldTests {
  @Test
  func alwaysAvailableExactlyMatchesDocumentedAnchors() {
    let expected: Set<String> = [
      "agent",
      "state.from", "state.to",
      "panel.id", "panel.workingDirectory", "panel.initialCommand",
      "tab.id", "tab.name", "tab.selectedPanelID",
      "worktree.id", "worktree.name", "worktree.path", "worktree.branch",
      "project.id", "project.name", "project.rootPath",
      "space.id", "space.name",
    ]
    #expect(Set(TemplateField.alwaysAvailable.map(\.rawValue)) == expected)
  }

  @Test
  func panelOutputMatchAddsMatchAndRangeFields() {
    let paths = TemplateField.validPaths(for: .panelOutputMatch)
    #expect(paths.isSuperset(of: TemplateField.alwaysAvailable))
    let added = paths.subtracting(TemplateField.alwaysAvailable)
    #expect(added == [
      .dataMatch, .dataOutput, .dataOutputBytes,
      .dataMatchedRangeStart, .dataMatchedRangeLength,
    ])
  }

  @Test
  func panelIdleAddsIdleFields() {
    let added = TemplateField.validPaths(for: .panelIdle)
      .subtracting(TemplateField.alwaysAvailable)
    #expect(added == [.dataIdleSeconds, .dataSinceLastOutput, .dataSinceLastInput])
  }

  @Test
  func panelReadyAddsPidAndShell() {
    let added = TemplateField.validPaths(for: .panelReady)
      .subtracting(TemplateField.alwaysAvailable)
    #expect(added == [.dataPID, .dataShell])
  }

  @Test
  func panelExitedAddsExitCode() {
    let added = TemplateField.validPaths(for: .panelExited)
      .subtracting(TemplateField.alwaysAvailable)
    #expect(added == [.dataExitCode])
  }

  @Test
  func panelCrashedAddsReason() {
    let added = TemplateField.validPaths(for: .panelCrashed)
      .subtracting(TemplateField.alwaysAvailable)
    #expect(added == [.dataReason])
  }

  @Test
  func panelInputAddsTextAndInputBytes() {
    let added = TemplateField.validPaths(for: .panelInput)
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
    // The "shape-bound" guarantee: a rule scoped to .panelIdle can't use
    // {data.match} because the HookEventData case doesn't carry it.
    let idlePaths = TemplateField.validPaths(for: .panelIdle)
    #expect(idlePaths.contains(.dataMatch) == false)
    #expect(idlePaths.contains(.dataOutput) == false)
  }
}
