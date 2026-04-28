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

  /// Pinned chord defaults. Numeric `keyCode` literals are deliberate — using `kVK_ANSI_*`
  /// would make the audit a tautology against the production schema. The values are taken
  /// from `Carbon.HIToolbox.Events.h` and from the call sites that lived inline before the
  /// migration (see commits before `feature/shotcuts`). Updating an entry here is the
  /// deliberate signal that a default chord moved; the corresponding `ShortcutSchema.app`
  /// edit fails the audit unless this table is updated in the same commit.
  private static let golden: [(CommandID, (keyCode: UInt16, modifiers: ModifierMask))] = [
    (.openSettings, (0x2B, [.command])),                    // ,
    (.quit, (0x0C, [.command])),                            // q
    (.commandPaletteToggle, (0x23, [.command])),            // p
    (.openInDefaultEditor, (0x1F, [.command])),             // o
    (.toggleGitViewer, (0x05, [.command, .shift])),         // g
    (.filterTags, (0x03, [.command])),                      // f
    (.newTab, (0x11, [.command])),                          // t
    (.closeTab, (0x0D, [.command])),                        // w
    (.previousTab, (0x21, [.command, .shift])),             // [
    (.nextTab, (0x1E, [.command, .shift])),                 // ]
    (.switchToTab1, (0x12, [.command, .option])),
    (.switchToTab2, (0x13, [.command, .option])),
    (.switchToTab3, (0x14, [.command, .option])),
    (.switchToTab4, (0x15, [.command, .option])),
    (.switchToTab5, (0x17, [.command, .option])),           // kVK_ANSI_5 == 0x17 (not 0x16!)
    (.switchToTab6, (0x16, [.command, .option])),           // kVK_ANSI_6 == 0x16
    (.switchToTab7, (0x1A, [.command, .option])),
    (.switchToTab8, (0x1C, [.command, .option])),
    (.switchToTab9, (0x19, [.command, .option])),
    (.selectWorktreeAt1, (0x12, [.command, .control])),
    (.selectWorktreeAt2, (0x13, [.command, .control])),
    (.selectWorktreeAt3, (0x14, [.command, .control])),
    (.selectWorktreeAt4, (0x15, [.command, .control])),
    (.selectWorktreeAt5, (0x17, [.command, .control])),
    (.selectWorktreeAt6, (0x16, [.command, .control])),
    (.selectWorktreeAt7, (0x1A, [.command, .control])),
    (.selectWorktreeAt8, (0x1C, [.command, .control])),
    (.selectWorktreeAt9, (0x19, [.command, .control])),
  ]
}
