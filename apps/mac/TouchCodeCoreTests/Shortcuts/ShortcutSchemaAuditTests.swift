import Carbon.HIToolbox
import Foundation
import Testing

@testable import TouchCodeCore

/// The audit pins every `CommandID` case to the chord literal that lived inline in
/// `MainWindowCommands.swift` and `HierarchySidebarView.swift` before the registry migration.
/// It exists to catch silent drift during the M6/M7 rewrite — if a chord changes in
/// `ShortcutSchema.app`, this test fails and the change has to be deliberate.
struct ShortcutSchemaAuditTests {
  @Test
  func everyCommandIDHasExactlyOneSchemaEntry() {
    let schema = ShortcutSchema.app
    let ids = schema.entries.map(\.id)

    for id in CommandID.allCases {
      let occurrences = ids.filter { $0 == id }.count
      #expect(occurrences == 1, "CommandID \(id) appears \(occurrences) times in schema; expected 1.")
    }

    #expect(Set(ids).count == ids.count, "Schema contains duplicate CommandID entries.")
  }

  @Test
  func defaultsMatchGoldenTable() {
    for (id, expected) in Self.golden {
      guard let entry = ShortcutSchema.app.entry(for: id) else {
        Issue.record("Missing schema entry for \(id).")
        continue
      }
      let binding = entry.defaultBinding
      #expect(binding?.keyCode == expected.keyCode, "keyCode mismatch for \(id).")
      #expect(binding?.modifiers == expected.modifiers, "modifiers mismatch for \(id).")
      #expect(binding?.isEnabled == true, "default binding for \(id) must be enabled.")
    }
  }

  @Test
  func goldenCoversEveryCommandID() {
    let coveredIDs = Set(Self.golden.map(\.0))
    for id in CommandID.allCases {
      #expect(coveredIDs.contains(id), "Golden table missing \(id); update audit when adding cases.")
    }
  }

  /// Pinned chord defaults. Order matches `ShortcutSchema.app.entries`. Updating an entry
  /// here is the deliberate signal that a default chord moved; the corresponding
  /// `ShortcutSchema.app` edit fails the audit unless this table is updated in the same
  /// commit.
  private static let golden: [(CommandID, (keyCode: UInt16, modifiers: ModifierMask))] = [
    (.openSettings, (UInt16(kVK_ANSI_Comma), [.command])),
    (.quit, (UInt16(kVK_ANSI_Q), [.command])),
    (.commandPaletteToggle, (UInt16(kVK_ANSI_P), [.command])),
    (.openInDefaultEditor, (UInt16(kVK_ANSI_E), [.command])),
    (.toggleGitViewer, (UInt16(kVK_ANSI_G), [.command, .shift])),
    (.filterTags, (UInt16(kVK_ANSI_F), [.command])),
    (.newTab, (UInt16(kVK_ANSI_T), [.command])),
    (.closeTab, (UInt16(kVK_ANSI_W), [.command])),
    (.previousTab, (UInt16(kVK_ANSI_LeftBracket), [.command, .shift])),
    (.nextTab, (UInt16(kVK_ANSI_RightBracket), [.command, .shift])),
    (.switchToTab1, (UInt16(kVK_ANSI_1), [.command, .option])),
    (.switchToTab2, (UInt16(kVK_ANSI_2), [.command, .option])),
    (.switchToTab3, (UInt16(kVK_ANSI_3), [.command, .option])),
    (.switchToTab4, (UInt16(kVK_ANSI_4), [.command, .option])),
    (.switchToTab5, (UInt16(kVK_ANSI_5), [.command, .option])),
    (.switchToTab6, (UInt16(kVK_ANSI_6), [.command, .option])),
    (.switchToTab7, (UInt16(kVK_ANSI_7), [.command, .option])),
    (.switchToTab8, (UInt16(kVK_ANSI_8), [.command, .option])),
    (.switchToTab9, (UInt16(kVK_ANSI_9), [.command, .option])),
    (.selectWorktreeAt1, (UInt16(kVK_ANSI_1), [.command, .control])),
    (.selectWorktreeAt2, (UInt16(kVK_ANSI_2), [.command, .control])),
    (.selectWorktreeAt3, (UInt16(kVK_ANSI_3), [.command, .control])),
    (.selectWorktreeAt4, (UInt16(kVK_ANSI_4), [.command, .control])),
    (.selectWorktreeAt5, (UInt16(kVK_ANSI_5), [.command, .control])),
    (.selectWorktreeAt6, (UInt16(kVK_ANSI_6), [.command, .control])),
    (.selectWorktreeAt7, (UInt16(kVK_ANSI_7), [.command, .control])),
    (.selectWorktreeAt8, (UInt16(kVK_ANSI_8), [.command, .control])),
    (.selectWorktreeAt9, (UInt16(kVK_ANSI_9), [.command, .control])),
  ]
}
