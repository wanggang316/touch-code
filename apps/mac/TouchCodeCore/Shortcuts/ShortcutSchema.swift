import Carbon.HIToolbox
import Foundation

/// Defaults table — the one place that maps `CommandID` cases to display title, category,
/// scope, and built-in chord. Reads at app launch only; never mutates. The override store
/// overlays this; resolution happens in `ShortcutResolver`.
///
/// `ShortcutSchema.app` is the production registry. Tests construct their own schemas via
/// `init(version:entries:)` for isolation.
public struct ShortcutSchema: Sendable {
  public static let currentVersion = 1

  public let version: Int
  public let entries: [Entry]

  public init(version: Int = ShortcutSchema.currentVersion, entries: [Entry]) {
    self.version = version
    self.entries = entries
  }

  public struct Entry: Sendable, Equatable {
    public let id: CommandID
    public let title: String
    public let category: Category
    public let scope: ShortcutScope
    public let defaultBinding: ShortcutBinding?

    public init(
      id: CommandID,
      title: String,
      category: Category,
      scope: ShortcutScope,
      defaultBinding: ShortcutBinding?
    ) {
      self.id = id
      self.title = title
      self.category = category
      self.scope = scope
      self.defaultBinding = defaultBinding
    }
  }

  public enum Category: String, CaseIterable, Sendable, Codable {
    case general
    case tabs
    case sidebar
    case system
  }
}

extension ShortcutSchema {
  /// Returns the entry for `id`, or `nil` if the schema is missing it. The schema audit test
  /// asserts this is never `nil` for any `CommandID.allCases` value in `ShortcutSchema.app`.
  public func entry(for id: CommandID) -> Entry? {
    entries.first { $0.id == id }
  }
}

extension ShortcutSchema {
  /// Production registry. Default chords mirror the literals previously written inline in
  /// `MainWindowCommands.swift` and `HierarchySidebarView.swift`. The schema audit test
  /// pins these against a golden table; updates require deliberate intent.
  public static let app: ShortcutSchema = .init(
    entries: [
      // System scope — display only.
      .init(
        id: .openSettings,
        title: "Open Settings",
        category: .system,
        scope: .systemFixed,
        defaultBinding: .init(keyCode: UInt16(kVK_ANSI_Comma), modifiers: .command)
      ),
      .init(
        id: .quit,
        title: "Quit touch-code",
        category: .system,
        scope: .systemFixed,
        defaultBinding: .init(keyCode: UInt16(kVK_ANSI_Q), modifiers: .command)
      ),

      // General scope.
      .init(
        id: .commandPaletteToggle,
        title: "Quick Action",
        category: .general,
        scope: .configurable,
        defaultBinding: .init(keyCode: UInt16(kVK_ANSI_P), modifiers: .command)
      ),
      .init(
        id: .openInDefaultEditor,
        title: "Open in Default Editor",
        category: .general,
        scope: .configurable,
        defaultBinding: .init(keyCode: UInt16(kVK_ANSI_O), modifiers: .command)
      ),
      .init(
        id: .toggleGitViewer,
        title: "Toggle Git Viewer",
        category: .general,
        scope: .configurable,
        defaultBinding: .init(keyCode: UInt16(kVK_ANSI_G), modifiers: [.command, .option])
      ),
      .init(
        id: .filterTags,
        title: "Filter Tags",
        category: .general,
        scope: .configurable,
        defaultBinding: .init(keyCode: UInt16(kVK_ANSI_F), modifiers: .command)
      ),
      .init(
        id: .addProject,
        title: "Add Project…",
        category: .general,
        scope: .configurable,
        defaultBinding: .init(keyCode: UInt16(kVK_ANSI_O), modifiers: [.command, .shift])
      ),
      .init(
        id: .openCurrentPR,
        title: "Open PR on GitHub",
        category: .general,
        scope: .configurable,
        defaultBinding: .init(keyCode: UInt16(kVK_ANSI_G), modifiers: [.command, .shift])
      ),

      // Tabs scope.
      .init(
        id: .newTab,
        title: "New Tab",
        category: .tabs,
        scope: .configurable,
        defaultBinding: .init(keyCode: UInt16(kVK_ANSI_T), modifiers: .command)
      ),
      .init(
        id: .closeTab,
        title: "Close Tab",
        category: .tabs,
        scope: .configurable,
        defaultBinding: .init(keyCode: UInt16(kVK_ANSI_W), modifiers: .command)
      ),
      .init(
        id: .previousTab,
        title: "Previous Tab",
        category: .tabs,
        scope: .configurable,
        defaultBinding: .init(keyCode: UInt16(kVK_ANSI_LeftBracket), modifiers: [.command, .shift])
      ),
      .init(
        id: .nextTab,
        title: "Next Tab",
        category: .tabs,
        scope: .configurable,
        defaultBinding: .init(keyCode: UInt16(kVK_ANSI_RightBracket), modifiers: [.command, .shift])
      ),
      .init(
        id: .switchToTab1,
        title: "Switch to Tab 1",
        category: .tabs,
        scope: .configurable,
        defaultBinding: .init(keyCode: UInt16(kVK_ANSI_1), modifiers: .command)
      ),
      .init(
        id: .switchToTab2,
        title: "Switch to Tab 2",
        category: .tabs,
        scope: .configurable,
        defaultBinding: .init(keyCode: UInt16(kVK_ANSI_2), modifiers: .command)
      ),
      .init(
        id: .switchToTab3,
        title: "Switch to Tab 3",
        category: .tabs,
        scope: .configurable,
        defaultBinding: .init(keyCode: UInt16(kVK_ANSI_3), modifiers: .command)
      ),
      .init(
        id: .switchToTab4,
        title: "Switch to Tab 4",
        category: .tabs,
        scope: .configurable,
        defaultBinding: .init(keyCode: UInt16(kVK_ANSI_4), modifiers: .command)
      ),
      .init(
        id: .switchToTab5,
        title: "Switch to Tab 5",
        category: .tabs,
        scope: .configurable,
        defaultBinding: .init(keyCode: UInt16(kVK_ANSI_5), modifiers: .command)
      ),
      .init(
        id: .switchToTab6,
        title: "Switch to Tab 6",
        category: .tabs,
        scope: .configurable,
        defaultBinding: .init(keyCode: UInt16(kVK_ANSI_6), modifiers: .command)
      ),
      .init(
        id: .switchToTab7,
        title: "Switch to Tab 7",
        category: .tabs,
        scope: .configurable,
        defaultBinding: .init(keyCode: UInt16(kVK_ANSI_7), modifiers: .command)
      ),
      .init(
        id: .switchToTab8,
        title: "Switch to Tab 8",
        category: .tabs,
        scope: .configurable,
        defaultBinding: .init(keyCode: UInt16(kVK_ANSI_8), modifiers: .command)
      ),
      .init(
        id: .switchToTab9,
        title: "Switch to Tab 9",
        category: .tabs,
        scope: .configurable,
        defaultBinding: .init(keyCode: UInt16(kVK_ANSI_9), modifiers: .command)
      ),
      .init(
        id: .switchToTab10,
        title: "Switch to Tab 10",
        category: .tabs,
        scope: .configurable,
        defaultBinding: .init(keyCode: UInt16(kVK_ANSI_0), modifiers: .command)
      ),

      // Sidebar scope.
      .init(
        id: .selectWorktreeAt1,
        title: "Select Worktree 1",
        category: .sidebar,
        scope: .configurable,
        defaultBinding: .init(keyCode: UInt16(kVK_ANSI_1), modifiers: [.control])
      ),
      .init(
        id: .selectWorktreeAt2,
        title: "Select Worktree 2",
        category: .sidebar,
        scope: .configurable,
        defaultBinding: .init(keyCode: UInt16(kVK_ANSI_2), modifiers: [.control])
      ),
      .init(
        id: .selectWorktreeAt3,
        title: "Select Worktree 3",
        category: .sidebar,
        scope: .configurable,
        defaultBinding: .init(keyCode: UInt16(kVK_ANSI_3), modifiers: [.control])
      ),
      .init(
        id: .selectWorktreeAt4,
        title: "Select Worktree 4",
        category: .sidebar,
        scope: .configurable,
        defaultBinding: .init(keyCode: UInt16(kVK_ANSI_4), modifiers: [.control])
      ),
      .init(
        id: .selectWorktreeAt5,
        title: "Select Worktree 5",
        category: .sidebar,
        scope: .configurable,
        defaultBinding: .init(keyCode: UInt16(kVK_ANSI_5), modifiers: [.control])
      ),
      .init(
        id: .selectWorktreeAt6,
        title: "Select Worktree 6",
        category: .sidebar,
        scope: .configurable,
        defaultBinding: .init(keyCode: UInt16(kVK_ANSI_6), modifiers: [.control])
      ),
      .init(
        id: .selectWorktreeAt7,
        title: "Select Worktree 7",
        category: .sidebar,
        scope: .configurable,
        defaultBinding: .init(keyCode: UInt16(kVK_ANSI_7), modifiers: [.control])
      ),
      .init(
        id: .selectWorktreeAt8,
        title: "Select Worktree 8",
        category: .sidebar,
        scope: .configurable,
        defaultBinding: .init(keyCode: UInt16(kVK_ANSI_8), modifiers: [.control])
      ),
      .init(
        id: .selectWorktreeAt9,
        title: "Select Worktree 9",
        category: .sidebar,
        scope: .configurable,
        defaultBinding: .init(keyCode: UInt16(kVK_ANSI_9), modifiers: [.control])
      ),
      .init(
        id: .selectWorktreeAt10,
        title: "Select Worktree 10",
        category: .sidebar,
        scope: .configurable,
        defaultBinding: .init(keyCode: UInt16(kVK_ANSI_0), modifiers: [.control])
      ),
    ]
  )
}
