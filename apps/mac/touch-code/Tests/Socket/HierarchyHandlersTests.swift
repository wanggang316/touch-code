import Foundation
import Testing

@testable import TouchCodeCore
@testable import TouchCodeIPC
@testable import touch_code

@MainActor
struct HierarchyHandlersTests {
  @Test
  func createSpaceThenListReturnsIt() async throws {
    let server = Self.makeHarness()
    defer { server.stop() }

    try InMemoryIPCServerTests.sendHello(server)
    _ = try await server.awaitResponse()

    // Create
    struct CreateParams: Codable {
      let name: String
      let activate: Bool
    }
    let createParams = try JSONValue.encoded(CreateParams(name: "work", activate: false))
    try server.send(
      IPC.Request(id: "c1", method: .hierarchyCreateSpace, params: createParams)
    )
    let created = try await server.awaitResponse()
    #expect(created.error == nil)

    // List
    try server.send(IPC.Request(id: "l1", method: .hierarchyListSpaces))
    let listed = try await server.awaitResponse()
    #expect(listed.error == nil)
    if case .object(let obj) = listed.result,
      case .array(let spaces) = obj["spaces"]
    {
      #expect(spaces.count == 1)
    } else {
      Issue.record("expected { spaces: [...] }, got \(String(describing: listed.result))")
    }
  }

  @Test
  func resolveAliasUUIDFastPath() async throws {
    let server = Self.makeHarness()
    defer { server.stop() }

    try InMemoryIPCServerTests.sendHello(server)
    _ = try await server.awaitResponse()

    let uuid = UUID()
    let params = try JSONValue.encoded(IPC.AliasResolveRequest(kind: .pane, value: uuid.uuidString))
    try server.send(
      IPC.Request(id: "r1", method: .hierarchyResolveAlias, params: params)
    )
    let response = try await server.awaitResponse()
    #expect(response.error == nil)
    let decoded = try response.result?.decoded(as: IPC.AliasResolveResult.self)
    #expect(decoded?.id == uuid)
  }

  @Test
  func activateSpaceUpdatesCatalog() async throws {
    let harness = Self.makeHarnessWithHierarchy()
    defer { harness.server.stop() }

    try InMemoryIPCServerTests.sendHello(harness.server)
    _ = try await harness.server.awaitResponse()

    let spaceID = harness.hierarchy.createSpace(name: "first")
    _ = harness.hierarchy.createSpace(name: "second")
    #expect(harness.hierarchy.catalog.selectedSpaceID != spaceID)

    struct Params: Codable { let id: UUID }
    let params = try JSONValue.encoded(Params(id: spaceID.raw))
    try harness.server.send(
      IPC.Request(id: "a1", method: .hierarchyActivateSpace, params: params)
    )
    let response = try await harness.server.awaitResponse()
    #expect(response.error == nil)
    #expect(harness.hierarchy.catalog.selectedSpaceID == spaceID)
  }

  // MARK: - Harness helpers

  /// `onPaneFocused` callback must fire after a successful focusPane —
  /// the wire `tc focus → server → InboxStore.markRead(forPane:)`
  /// (v2 D13 / B11) hangs off this hook.
  @Test
  func focusPaneInvokesOnPaneFocusedCallback() async throws {
    let catalogURL = URL(fileURLWithPath: NSTemporaryDirectory())
      .appendingPathComponent("touch-code-onfocus-\(UUID().uuidString).json")
    let catalogStore = CatalogStore(fileURL: catalogURL)
    let pane = Pane(workingDirectory: "/tmp", initialCommand: nil)
    let tab = Tab(splitTree: SplitTree(leaf: pane.id), panes: [pane])
    let worktree = Worktree(
      name: "wt", path: "/repo", branch: "main", tabs: [tab], selectedTabID: tab.id
    )
    let project = Project(
      name: "p", rootPath: "/p", gitRoot: "/p",
      worktrees: [worktree],
      selectedWorktreeID: worktree.id
    )
    let space = Space(name: "s", projects: [project], selectedProjectID: project.id)
    let catalog = Catalog(
      version: Catalog.currentVersion,
      windows: [],
      spaces: [space],
      selectedSpaceID: space.id
    )
    let hierarchy = HierarchyManager(
      catalog: catalog,
      store: catalogStore,
      runtime: FakeHierarchyRuntime()
    )
    let handlers = HierarchyHandlers(manager: hierarchy)

    final class Recorder: @unchecked Sendable {
      var focusedIDs: [PaneID] = []
    }
    let recorder = Recorder()
    handlers.onPaneFocused = { paneID in recorder.focusedIDs.append(paneID) }

    let params = JSONValue.object([
      "id": .object(["raw": .string(pane.id.raw.uuidString)]),
      "tabID": .object(["raw": .string(tab.id.raw.uuidString)]),
      "worktreeID": .object(["raw": .string(worktree.id.raw.uuidString)]),
      "projectID": .object(["raw": .string(project.id.raw.uuidString)]),
      "spaceID": .object(["raw": .string(space.id.raw.uuidString)]),
    ])
    let outcome = await handlers.focusPane(params)
    if case .failed(let err) = outcome {
      Issue.record("focusPane failed: \(err)")
    }

    #expect(recorder.focusedIDs == [pane.id])
  }

  static func makeHarness() -> InMemoryIPCServer {
    makeHarnessWithHierarchy().server
  }

  struct HarnessBundle {
    let server: InMemoryIPCServer
    let hierarchy: HierarchyManager
  }

  static func makeHarnessWithHierarchy() -> HarnessBundle {
    let (store, dispatcher) = InMemoryIPCServerTests.makeDispatcher(existing: nil)
    let hookHandlers = HookHandlers(dispatcher: dispatcher, store: store)
    let systemHandlers = SystemHandlers(
      versions: .init(server: "0.4.0", appBundle: "0.4.0+test")
    )

    let catalogURL = URL(fileURLWithPath: NSTemporaryDirectory())
      .appendingPathComponent("touch-code-hierarchy-tests-\(UUID().uuidString).json")
    let catalogStore = CatalogStore(fileURL: catalogURL)
    let catalog = (try? catalogStore.load()) ?? Catalog()
    let hierarchy = HierarchyManager(
      catalog: catalog,
      store: catalogStore,
      runtime: FakeHierarchyRuntime()
    )
    let hierarchyHandlers = HierarchyHandlers(manager: hierarchy)

    let router = MethodRouter(
      hookHandlers: hookHandlers,
      systemHandlers: systemHandlers,
      hierarchyHandlers: hierarchyHandlers
    )
    let server = InMemoryIPCServer(router: router)
    server.start()
    return HarnessBundle(server: server, hierarchy: hierarchy)
  }
}
