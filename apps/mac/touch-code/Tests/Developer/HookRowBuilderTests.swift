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
    let sub = HookSubscription(event: .paneOutput, command: cmd)

    let row = HookRowBuilder.make(from: sub, source: .global)

    #expect(row.displayName == cmd)
  }

  @Test
  func truncatesLongCommandWithEllipsis() {
    // Truncation contract: 60 is the *final rendered width including the
    // ellipsis*. Long command → 59 "a"s + "…" = 60 glyphs total.
    let cmd = String(repeating: "a", count: 100)
    let sub = HookSubscription(event: .paneOutput, command: cmd)

    let row = HookRowBuilder.make(from: sub, source: .global)

    #expect(row.displayName.count == 60)
    #expect(row.displayName.hasSuffix("…"))
    #expect(row.displayName.hasPrefix(String(repeating: "a", count: 59)))
  }

  @Test
  func displayNameAtLimitIsReturnedVerbatim() {
    // Boundary check: 60 glyphs exactly should not be truncated (no ellipsis
    // appended). Proves the contract excludes an off-by-one truncation of
    // a legitimately 60-wide command.
    let cmd = String(repeating: "a", count: 60)
    let sub = HookSubscription(event: .paneOutput, command: cmd)

    let row = HookRowBuilder.make(from: sub, source: .global)

    #expect(row.displayName == cmd)
    #expect(!row.displayName.hasSuffix("…"))
  }

  @Test
  func truncatesLongMatchPatternWithEllipsis() {
    // Same contract for matchSummary: 80 is the *final rendered width
    // including the ellipsis*. A 100-char pattern → 79 glyphs + "…" = 80.
    let pattern = String(repeating: "b", count: 100)
    let sub = HookSubscription(
      event: .paneOutputMatch, command: "run", matchPattern: pattern)

    let row = HookRowBuilder.make(from: sub, source: .global)

    let summary = row.matchSummary ?? ""
    #expect(summary.count == 80)
    #expect(summary.hasSuffix("…"))
    #expect(summary.hasPrefix(String(repeating: "b", count: 79)))
  }

  @Test
  func prefersMatchPatternSummary() {
    let sub = HookSubscription(
      event: .paneOutputMatch,
      command: "run",
      matchPattern: "error.*"
    )

    let row = HookRowBuilder.make(from: sub, source: .global)

    #expect(row.matchSummary == "error.*")
  }

  @Test
  func fallsBackToScopeSummary() {
    let sub = HookSubscription(
      event: .paneOutput,
      command: "run",
      scope: .paneLabel("alpha")
    )

    let row = HookRowBuilder.make(from: sub, source: .global)

    #expect(row.matchSummary == "scope: paneLabel")
  }

  @Test
  func nilSummaryWhenNoMatchAndAnyPane() {
    let sub = HookSubscription(event: .paneOutput, command: "run")
    // Default scope is `.anyPane` and there is no matchPattern.

    let row = HookRowBuilder.make(from: sub, source: .global)

    #expect(row.matchSummary == nil)
  }

  @Test
  func enabledInvertsDisabledFlag() {
    let off = HookSubscription(event: .paneOutput, command: "run", disabled: true)
    let on = HookSubscription(event: .paneOutput, command: "run", disabled: false)

    #expect(HookRowBuilder.make(from: off, source: .global).enabled == false)
    #expect(HookRowBuilder.make(from: on, source: .global).enabled == true)
  }

  @Test
  func sourceIsPropagated() {
    let sub = HookSubscription(event: .paneReady, command: "run")

    let global = HookRowBuilder.make(from: sub, source: .global)
    let repo = HookRowBuilder.make(from: sub, source: .project)

    #expect(global.source == .global)
    #expect(repo.source == .project)
  }
}
