import Foundation
import Testing
import TouchCodeCore

@testable import touch_code

/// Save-time validation for `HookEditorRow.Draft`. The pure helpers
/// `validate(_:)` and `makeSubscription(from:existingID:)` carry the
/// rules so unit tests can drive every branch without a SwiftUI view.
/// The view's Save button keeps the row expanded and surfaces inline
/// errors when `validate(_:)` returns a non-empty `ValidationErrors`.
struct HookEditorRowSaveValidationTests {
  private func makeDraft(
    event: HookEvent = .paneReady,
    scope: HookSubscription.Scope = .anyPane,
    command: String = "echo ready",
    timeout: Double = 5
  ) -> HookEditorRow.Draft {
    let sub = HookSubscription(
      event: event,
      command: command,
      scope: scope,
      timeoutSeconds: timeout
    )
    return HookEditorRow.Draft(from: sub)
  }

  @Test
  func emptyCommandBlocksSave() {
    let draft = makeDraft(command: "  ")
    let errors = HookEditorRow.validate(draft)
    #expect(errors.isValid == false)
    #expect(errors.command != nil)
  }

  @Test
  func validDraftPassesValidation() {
    let draft = makeDraft(scope: .anyPane, command: "echo hi", timeout: 5)
    let errors = HookEditorRow.validate(draft)
    #expect(errors.isValid)
    #expect(errors.command == nil)
    #expect(errors.scope == nil)
    #expect(errors.timeout == nil)
  }

  @Test
  func emptyPaneLabelBlocksSave() {
    let draft = makeDraft(scope: .paneLabel(""), command: "echo")
    let errors = HookEditorRow.validate(draft)
    #expect(errors.isValid == false)
    #expect(errors.scope != nil)
  }

  @Test
  func emptyWorktreePathGlobBlocksSave() {
    let draft = makeDraft(scope: .worktreePathGlob("   "), command: "echo")
    let errors = HookEditorRow.validate(draft)
    #expect(errors.isValid == false)
    #expect(errors.scope != nil)
  }

  @Test
  func emptyProjectPathGlobBlocksSave() {
    let draft = makeDraft(scope: .projectPathGlob(""), command: "echo")
    let errors = HookEditorRow.validate(draft)
    #expect(errors.isValid == false)
    #expect(errors.scope != nil)
  }

  @Test
  func timeoutOutOfRangeBlocksSave() {
    var tooBig = makeDraft()
    tooBig.timeoutSeconds = 601
    #expect(HookEditorRow.validate(tooBig).timeout != nil)

    var negative = makeDraft()
    negative.timeoutSeconds = -1
    #expect(HookEditorRow.validate(negative).timeout != nil)
  }

  @Test
  func timeoutAtBoundsPasses() {
    var lower = makeDraft()
    lower.timeoutSeconds = 0
    #expect(HookEditorRow.validate(lower).isValid)

    var upper = makeDraft()
    upper.timeoutSeconds = 600
    #expect(HookEditorRow.validate(upper).isValid)
  }

  @Test
  func makeSubscriptionPreservesFieldsAndID() {
    let id = UUID()
    var draft = makeDraft(scope: .projectID(ProjectID()), command: "  npm test  ")
    draft.matchPattern = " error.* "
    draft.matchFlags = [.caseInsensitive, .multiline]
    draft.cwd = " /tmp "
    draft.env = ["FOO": "bar"]
    draft.disabled = true
    draft.mode = .awaitActions

    let sub = HookEditorRow.makeSubscription(from: draft, existingID: id)
    #expect(sub != nil)
    guard let sub else { return }
    #expect(sub.id == id)
    #expect(sub.command == "npm test")
    #expect(sub.matchPattern == "error.*")
    #expect(sub.matchFlags == [.caseInsensitive, .multiline])
    #expect(sub.cwd == "/tmp")
    #expect(sub.env == ["FOO": "bar"])
    #expect(sub.disabled)
    #expect(sub.mode == .awaitActions)
  }

  @Test
  func makeSubscriptionReturnsNilForEmptyCommand() {
    let draft = makeDraft(command: "   \n   ")
    #expect(HookEditorRow.makeSubscription(from: draft, existingID: UUID()) == nil)
  }
}
