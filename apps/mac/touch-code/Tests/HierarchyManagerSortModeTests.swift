import Foundation
import Testing
import TouchCodeCore

@testable import touch_code

/// Coverage for the sidebar bottom-bar sort-mode manager APIs:
/// - `HierarchyManager.setProjectSortMode`
/// - `HierarchyManager.applyManualProjectOrder`
/// - `HierarchyManager.bumpProjectActivity`
/// - `HierarchyManager.addProject` populates `addedAt` going forward.
@MainActor
struct HierarchyManagerSortModeTests {
  var fakeRuntime: FakeHierarchyRuntime!
  var store: CatalogStore!
  var manager: HierarchyManager!

  init() {
    let tempURL = FileManager.default.temporaryDirectory
      .appending(component: UUID().uuidString + ".json")
    fakeRuntime = FakeHierarchyRuntime()
    store = CatalogStore(fileURL: tempURL)
    manager = HierarchyManager(catalog: .default, store: store, runtime: fakeRuntime)
  }

  @Test
  func addProjectStampsAddedAt() {
    let before = Date()
    let pid = manager.addProject(name: "p", rootPath: "/p", gitRoot: nil)
    let after = Date()
    let project = manager.catalog.projects.first { $0.id == pid }!
    #expect(project.addedAt >= before)
    #expect(project.addedAt <= after)
    #expect(project.lastActiveAt == nil)
  }

  @Test
  func setProjectSortModePersists() {
    #expect(manager.catalog.projectSortMode == .joinOrder)
    manager.setProjectSortMode(.activeFirst)
    #expect(manager.catalog.projectSortMode == .activeFirst)
    manager.setProjectSortMode(.activeFirst)  // idempotent
    #expect(manager.catalog.projectSortMode == .activeFirst)
  }

  @Test
  func bumpProjectActivityMonotonic() {
    let pid = manager.addProject(name: "p", rootPath: "/p", gitRoot: nil)
    let t1 = Date(timeIntervalSince1970: 1000)
    let t2 = Date(timeIntervalSince1970: 2000)
    let stale = Date(timeIntervalSince1970: 500)

    manager.bumpProjectActivity(pid, now: t1)
    #expect(manager.catalog.projects.first { $0.id == pid }?.lastActiveAt == t1)

    manager.bumpProjectActivity(pid, now: stale)  // older — must not rewind
    #expect(manager.catalog.projects.first { $0.id == pid }?.lastActiveAt == t1)

    manager.bumpProjectActivity(pid, now: t2)
    #expect(manager.catalog.projects.first { $0.id == pid }?.lastActiveAt == t2)
  }

  @Test
  func bumpProjectActivityUnknownIDIsNoOp() {
    let bogus = ProjectID()
    manager.bumpProjectActivity(bogus)
    // No projects exist; nothing to assert beyond no crash + no panic.
    #expect(manager.catalog.projects.isEmpty)
  }

  @Test
  func applyManualProjectOrderRewritesArrayAndFlipsMode() {
    let a = manager.addProject(name: "a", rootPath: "/a", gitRoot: nil)
    let b = manager.addProject(name: "b", rootPath: "/b", gitRoot: nil)
    let c = manager.addProject(name: "c", rootPath: "/c", gitRoot: nil)
    #expect(manager.catalog.projects.map(\.id) == [a, b, c])

    manager.applyManualProjectOrder([c, a, b])
    #expect(manager.catalog.projects.map(\.id) == [c, a, b])
    #expect(manager.catalog.projectSortMode == .manual)
  }

  @Test
  func applyManualProjectOrderDropsUnknownIDsAndAppendsMissingOnes() {
    let a = manager.addProject(name: "a", rootPath: "/a", gitRoot: nil)
    let b = manager.addProject(name: "b", rootPath: "/b", gitRoot: nil)
    let c = manager.addProject(name: "c", rootPath: "/c", gitRoot: nil)
    let bogus = ProjectID()

    // Partial + bogus input → known ids land in the given order, the
    // missing project (c) is appended; bogus is dropped.
    manager.applyManualProjectOrder([b, bogus, a])
    #expect(manager.catalog.projects.map(\.id) == [b, a, c])
  }

  @Test
  func applyManualProjectOrderOnEmptyCatalogStillFlipsMode() {
    manager.applyManualProjectOrder([])
    #expect(manager.catalog.projectSortMode == .manual)
  }
}
