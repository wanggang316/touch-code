import Foundation
import Testing
import TouchCodeCore

@testable import touch_code

/// Unit tests for the pure `ScopePickerView.applyKindSwitch(...)` helper.
/// The helper carries the kind-switch logic out of SwiftUI so we can
/// drive the buffer through every interesting transition without
/// instantiating a view. ID-based kinds skip the buffer; the four
/// text-valued kinds (`paneLabel` / `tabLabel` / `worktreePathGlob` /
/// `projectPathGlob`) snapshot their value into the buffer on the way
/// out and restore it on the way back in.
struct ScopePickerKindSwitchTests {
  @Test
  func togglingPaneLabelToTabLabelPreservesPaneLabelInBuffer() {
    let projectID = ProjectID()
    let initial = HookSubscription.Scope.paneLabel("ssh-pane")

    let result = ScopePickerView.applyKindSwitch(
      from: initial,
      to: .tabLabel,
      buffer: [:],
      currentProjectID: projectID
    )

    #expect(result.buffer[.paneLabel] == "ssh-pane")
    #expect(result.scope == .tabLabel(""))
  }

  @Test
  func togglingTabLabelBackToPaneLabelRestoresOriginalText() {
    let projectID = ProjectID()
    let step1 = ScopePickerView.applyKindSwitch(
      from: .paneLabel("ssh-pane"),
      to: .tabLabel,
      buffer: [:],
      currentProjectID: projectID
    )
    // User types in the tab-label field; subsequent toggle reads from buffer.
    var buffer = step1.buffer
    buffer[.tabLabel] = "main-tab"

    let step2 = ScopePickerView.applyKindSwitch(
      from: .tabLabel("main-tab"),
      to: .paneLabel,
      buffer: buffer,
      currentProjectID: projectID
    )

    #expect(step2.scope == .paneLabel("ssh-pane"))
    #expect(step2.buffer[.tabLabel] == "main-tab")
    #expect(step2.buffer[.paneLabel] == "ssh-pane")
  }

  @Test
  func togglingPaneLabelToPaneIDAndBackKeepsBufferIntact() {
    let projectID = ProjectID()
    let buffer: [ScopeKindTag: String] = [.paneLabel: "ssh-pane"]

    let step1 = ScopePickerView.applyKindSwitch(
      from: .paneLabel("ssh-pane"),
      to: .paneID,
      buffer: buffer,
      currentProjectID: projectID
    )

    // ID-based scopes do not share the buffer.
    #expect(step1.buffer[.paneLabel] == "ssh-pane")
    if case .paneID = step1.scope {} else {
      Issue.record("Expected .paneID scope, got \(step1.scope)")
    }

    let step2 = ScopePickerView.applyKindSwitch(
      from: step1.scope,
      to: .paneLabel,
      buffer: step1.buffer,
      currentProjectID: projectID
    )

    #expect(step2.scope == .paneLabel("ssh-pane"))
  }

  @Test
  func togglingToProjectIDDefaultsToCurrentProject() {
    let projectID = ProjectID()
    let result = ScopePickerView.applyKindSwitch(
      from: .anyPane,
      to: .projectID,
      buffer: [:],
      currentProjectID: projectID
    )
    #expect(result.scope == .projectID(projectID))
  }

  @Test
  func togglingBetweenWorktreePathGlobAndProjectPathGlobPreservesEachField() {
    let projectID = ProjectID()
    var buffer: [ScopeKindTag: String] = [:]

    // Set worktree glob.
    let step1 = ScopePickerView.applyKindSwitch(
      from: .worktreePathGlob("**/feature/*"),
      to: .projectPathGlob,
      buffer: buffer,
      currentProjectID: projectID
    )
    buffer = step1.buffer
    buffer[.projectPathGlob] = "**/repos/*"

    // Toggle back; worktree glob restored, project glob retained in buffer.
    let step2 = ScopePickerView.applyKindSwitch(
      from: .projectPathGlob("**/repos/*"),
      to: .worktreePathGlob,
      buffer: buffer,
      currentProjectID: projectID
    )

    #expect(step2.scope == .worktreePathGlob("**/feature/*"))
    #expect(step2.buffer[.projectPathGlob] == "**/repos/*")
  }
}
