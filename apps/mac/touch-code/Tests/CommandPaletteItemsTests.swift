import Foundation
import Testing
import TouchCodeCore

@testable import touch_code

/// `CommandPaletteItems.build` produces different items depending on
/// selection state and catalog shape. Tests cover each context band.
@MainActor
struct CommandPaletteItemsTests {
  private static let emptyCatalog = Catalog()
  private static let emptySelection = HierarchySelection.empty

  // MARK: - App-scope only

  @Test
  func emptyCatalogEmitsOnlyAppAndEmptySpaceSlots() {
    let items = CommandPaletteItems.build(
      selection: Self.emptySelection, catalog: Self.emptyCatalog
    )
    let ids = Set(items.map(\.id))
    #expect(ids.contains("app.open-settings"))
    #expect(ids.contains("app.check-for-updates"))
    #expect(ids.contains("app.quit"))
    #expect(ids.contains("space.manage"))
    #expect(!ids.contains("git.toggle-viewer"))
    #expect(!ids.contains("editor.open-default"))
    #expect(!ids.contains { $0.hasPrefix("pane.") })
    #expect(!ids.contains { $0.hasPrefix("window.") })
  }

  // MARK: - Space switching

  @Test
  func spaceSwitchItemsAppearPerSpace() {
    var catalog = Catalog()
    let spaceA = Space(name: "Personal")
    let spaceB = Space(name: "Work")
    catalog.spaces = [spaceA, spaceB]
    catalog.selectedSpaceID = spaceA.id
    let items = CommandPaletteItems.build(
      selection: Self.emptySelection, catalog: catalog
    )
    let spaceIDs = items.map(\.id).filter { $0.hasPrefix("space.select.") }
    #expect(spaceIDs.count == 2)
    #expect(items.contains { $0.title == "Switch to Space: Personal" })
    #expect(items.contains { $0.title == "Switch to Space: Work" })
    // Active space's subtitle reads "Currently active".
    let active = items.first { $0.id == "space.select.\(spaceA.id.raw.uuidString)" }
    #expect(active?.subtitle == "Currently active")
  }

  // MARK: - Worktree context

  @Test
  func worktreeSelectedEmitsWorktreeCommands() {
    var catalog = Catalog()
    var space = Space(name: "S")
    var project = Project(name: "P", rootPath: "/tmp/p", gitRoot: "/tmp/p")
    let worktree = Worktree(name: "wt", path: "/tmp/p/wt", branch: "main")
    project.worktrees = [worktree]
    space.projects = [project]
    catalog.spaces = [space]
    let selection = HierarchySelection(
      spaceID: space.id, projectID: project.id, worktreeID: worktree.id
    )
    let items = CommandPaletteItems.build(selection: selection, catalog: catalog)
    let ids = Set(items.map(\.id))
    #expect(ids.contains("git.toggle-viewer"))
    #expect(ids.contains("editor.open-default"))
    #expect(ids.contains("editor.reveal-in-finder"))
    #expect(ids.contains("worktree.refresh"))
    #expect(ids.contains("worktree.close"))
    // worktree.close is hidden when query is empty.
    let closeItem = items.first { $0.id == "worktree.close" }
    #expect(closeItem?.hiddenWhenQueryEmpty == true)
  }

  @Test
  func editorDescriptorsBecomeOpenInItems() {
    var catalog = Catalog()
    var space = Space(name: "S")
    var project = Project(name: "P", rootPath: "/tmp/p", gitRoot: "/tmp/p")
    let worktree = Worktree(name: "wt", path: "/tmp/p/wt", branch: "main")
    project.worktrees = [worktree]
    space.projects = [project]
    catalog.spaces = [space]
    let selection = HierarchySelection(
      spaceID: space.id, projectID: project.id, worktreeID: worktree.id
    )
    let descriptors = [
      EditorDescriptor(
        id: "vscode",
        displayName: "Visual Studio Code",
        bundleIdentifier: "com.microsoft.VSCode",
        launchMode: .directory,
        appURL: nil,
        alternateBundleIdentifiers: []
      ),
      EditorDescriptor(
        id: "zed",
        displayName: "Zed",
        bundleIdentifier: "dev.zed.Zed",
        launchMode: .directory,
        appURL: nil,
        alternateBundleIdentifiers: []
      ),
    ]
    let items = CommandPaletteItems.build(
      selection: selection, catalog: catalog, editorDescriptors: descriptors
    )
    let ids = Set(items.map(\.id))
    #expect(ids.contains("editor.open.vscode"))
    #expect(ids.contains("editor.open.zed"))
  }

  // MARK: - Focused pane resolution

  @Test
  func resolveFocusedPaneIDReturnsNilWhenNoSelection() {
    let id = CommandPaletteItems.resolveFocusedPaneID(
      selection: Self.emptySelection, catalog: Self.emptyCatalog
    )
    #expect(id == nil)
  }
}
