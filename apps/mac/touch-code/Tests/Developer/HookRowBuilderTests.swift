import Foundation
import Testing
import TouchCodeCore

@testable import touch_code

/// Covers the pure `HookSubscription` → `HookRow` derivation that T3 and T4
/// share. One assertion per branch of `HookRowBuilder.make(from:source:)`.
@Suite("HookRowBuilder")
struct HookRowBuilderTests {
  @Test
  func buildsShortCommandDisplayNameVerbatim() {
    let cmd = "notify --level warn"  // 19 chars
    let sub = HookSubscription(event: .panelOutput, command: cmd)

    let row = HookRowBuilder.make(from: sub, source: .global)

    #expect(row.displayName == cmd)
  }

  @Test
  func truncatesLongCommandWithEllipsis() {
    let cmd = String(repeating: "a", count: 100)
    let sub = HookSubscription(event: .panelOutput, command: cmd)

    let row = HookRowBuilder.make(from: sub, source: .global)

    // 60-char cap with a three-char ellipsis budget → 57 "a"s + "…".
    #expect(row.displayName.count == 58)
    #expect(row.displayName.hasSuffix("…"))
    #expect(row.displayName.hasPrefix(String(repeating: "a", count: 57)))
  }

  @Test
  func prefersMatchPatternSummary() {
    let sub = HookSubscription(
      event: .panelOutputMatch,
      command: "run",
      matchPattern: "error.*"
    )

    let row = HookRowBuilder.make(from: sub, source: .global)

    #expect(row.matchSummary == "error.*")
  }

  @Test
  func fallsBackToScopeSummary() {
    let sub = HookSubscription(
      event: .panelOutput,
      command: "run",
      scope: .panelLabel("alpha")
    )

    let row = HookRowBuilder.make(from: sub, source: .global)

    #expect(row.matchSummary == "scope: panelLabel")
  }

  @Test
  func nilSummaryWhenNoMatchAndAnyPanel() {
    let sub = HookSubscription(event: .panelOutput, command: "run")
    // Default scope is `.anyPanel` and there is no matchPattern.

    let row = HookRowBuilder.make(from: sub, source: .global)

    #expect(row.matchSummary == nil)
  }

  @Test
  func enabledInvertsDisabledFlag() {
    let off = HookSubscription(event: .panelOutput, command: "run", disabled: true)
    let on = HookSubscription(event: .panelOutput, command: "run", disabled: false)

    #expect(HookRowBuilder.make(from: off, source: .global).enabled == false)
    #expect(HookRowBuilder.make(from: on, source: .global).enabled == true)
  }

  @Test
  func sourceIsPropagated() {
    let sub = HookSubscription(event: .panelReady, command: "run")

    let global = HookRowBuilder.make(from: sub, source: .global)
    let repo = HookRowBuilder.make(from: sub, source: .repository)

    #expect(global.source == .global)
    #expect(repo.source == .repository)
  }
}
