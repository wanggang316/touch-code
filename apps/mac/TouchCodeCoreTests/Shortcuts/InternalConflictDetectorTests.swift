import Foundation
import Testing

@testable import TouchCodeCore

struct InternalConflictDetectorTests {
  // MARK: - Fixtures

  /// Stand-in chord for tests that need a binding guaranteed not to collide with anything in
  /// `ShortcutSchema.app` (keyCode `0xFFFF` is a sentinel never produced by AppKit).
  private static let unusedBinding = ShortcutBinding(keyCode: 0xFFFF, modifiers: .command)

  /// `⌘G` — the `toggleDiffInspector` schema default uses `⌘⇧G`, so plain `⌘G` is also a free
  /// chord to plant on a synthetic command.
  private static let cmdG = ShortcutBinding(keyCode: 5, modifiers: .command)

  // MARK: - Tests

  @Test
  func emptyMapReturnsNil() {
    let result = InternalConflictDetector.conflicts(
      in: [:],
      candidate: Self.cmdG,
      excluding: .commandPaletteToggle
    )
    #expect(result == nil)
  }

  @Test
  func detectsClashWithAnotherConfigurableCommand() {
    // Candidate matches the schema default for `.toggleDiffInspector` (⌘⇧G).
    let toggleDiffInspectorDefault = ShortcutSchema.app.entry(for: .toggleDiffInspector)?.defaultBinding
    let candidate = try! #require(toggleDiffInspectorDefault)

    let map = ShortcutResolver.resolve(overrides: .empty)
    let result = InternalConflictDetector.conflicts(
      in: map,
      candidate: candidate,
      excluding: .commandPaletteToggle
    )
    #expect(result == .toggleDiffInspector)
  }

  @Test
  func systemFixedCommandsDoNotReportAsInternalConflicts() {
    // `.openSettings` is `.systemFixed` with default `⌘,`. Internal detector must not surface
    // it; AppKitReservedDetector handles that tier.
    let openSettingsDefault = ShortcutSchema.app.entry(for: .openSettings)?.defaultBinding
    let candidate = try! #require(openSettingsDefault)

    let map = ShortcutResolver.resolve(overrides: .empty)
    let result = InternalConflictDetector.conflicts(
      in: map,
      candidate: candidate,
      excluding: .commandPaletteToggle
    )
    #expect(result == nil)
  }

  @Test
  func excludingCommandIsSkippedEvenWhenChordsMatch() {
    // The candidate exactly equals `.toggleDiffInspector`'s own default; passing it as `excluding`
    // means we are asking "would this chord clash with anyone *other than* myself?".
    let toggleDiffInspectorDefault = ShortcutSchema.app.entry(for: .toggleDiffInspector)?.defaultBinding
    let candidate = try! #require(toggleDiffInspectorDefault)

    let map = ShortcutResolver.resolve(overrides: .empty)
    let result = InternalConflictDetector.conflicts(
      in: map,
      candidate: candidate,
      excluding: .toggleDiffInspector
    )
    #expect(result == nil)
  }

  @Test
  func disabledOverrideCedesItsSlot() {
    // Disable `.toggleDiffInspector` but keep its chord. The candidate using that same chord must
    // no longer be reported as conflicting with it (disabled rows cede their slot).
    let toggleDiffInspectorDefault = ShortcutSchema.app.entry(for: .toggleDiffInspector)?.defaultBinding
    let chord = try! #require(toggleDiffInspectorDefault)
    let disabled = ShortcutBinding(
      keyCode: chord.keyCode,
      modifiers: chord.modifiers,
      isEnabled: false
    )
    let store = ShortcutOverrideStore(overrides: [.toggleDiffInspector: disabled])
    let map = ShortcutResolver.resolve(overrides: store)

    let result = InternalConflictDetector.conflicts(
      in: map,
      candidate: chord,
      excluding: .commandPaletteToggle
    )
    #expect(result == nil)
  }

  @Test
  func nilBindingDoesNotMatch() {
    // A row whose `binding == nil` (no chord assigned) cannot conflict with anything.
    // Construct a synthetic map that pins one such row.
    var map: ResolvedShortcutMap = [:]
    map[.commandPaletteToggle] = ResolvedShortcut(
      id: .commandPaletteToggle,
      binding: nil,
      isEnabled: false,
      source: .userOverride
    )

    let result = InternalConflictDetector.conflicts(
      in: map,
      candidate: Self.unusedBinding,
      excluding: .toggleDiffInspector
    )
    #expect(result == nil)
  }

  @Test
  func deterministicWinnerWhenTwoEntriesShareCandidateChord() {
    // Defensive: a well-formed resolved map should never have two entries on the same chord,
    // but if it does (e.g. a hand-built test fixture), the detector must return a stable
    // result. Iteration follows `CommandID.allCases`, so the case declared earlier wins.
    let chord = ShortcutBinding(keyCode: 200, modifiers: [.command, .control])

    var map: ResolvedShortcutMap = [:]
    map[.previousTab] = ResolvedShortcut(
      id: .previousTab,
      binding: chord,
      isEnabled: true,
      source: .userOverride
    )
    map[.nextTab] = ResolvedShortcut(
      id: .nextTab,
      binding: chord,
      isEnabled: true,
      source: .userOverride
    )

    let result = InternalConflictDetector.conflicts(
      in: map,
      candidate: chord,
      excluding: .commandPaletteToggle
    )
    // `.previousTab` precedes `.nextTab` in the `CommandID` declaration order.
    let allCases = CommandID.allCases
    let prevIndex = allCases.firstIndex(of: .previousTab) ?? -1
    let nextIndex = allCases.firstIndex(of: .nextTab) ?? -1
    #expect(prevIndex < nextIndex)
    #expect(result == .previousTab)
  }
}
