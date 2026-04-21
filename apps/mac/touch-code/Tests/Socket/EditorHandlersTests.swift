import ComposableArchitecture
import Foundation
import Testing
import TouchCodeCore
import TouchCodeIPC

@testable import touch_code

@MainActor
struct EditorHandlersTests {
  // MARK: - Fixtures

  private nonisolated static let sampleChoice = EditorChoice(
    id: "vscode",
    displayName: "Visual Studio Code",
    binaryPath: URL(fileURLWithPath: "/usr/local/bin/code"),
    argv: ["/usr/local/bin/code", "/w"]
  )

  private nonisolated static let sampleDescriptors: [EditorDescriptor] = [
    EditorDescriptor(
      id: "vscode",
      displayName: "Visual Studio Code",
      origin: .builtin,
      template: CommandTemplate(binary: "code", args: ["{dir}"]),
      installation: .installed(resolvedBinary: URL(fileURLWithPath: "/usr/local/bin/code"))
    ),
    EditorDescriptor(
      id: "cursor",
      displayName: "Cursor",
      origin: .builtin,
      template: CommandTemplate(binary: "cursor", args: ["{dir}"]),
      installation: .missingBinary(expected: "cursor")
    ),
  ]

  /// Builds a snapshot with one Space / Project / Worktree / Tab / Panel chain. Returns
  /// the catalog and the IDs at each level so tests can target any of them.
  private struct Fixture {
    let catalog: Catalog
    let spaceID: SpaceID
    let projectID: ProjectID
    let worktreeID: WorktreeID
    let tabID: TabID
    let panelID: PanelID
    let worktreePath: String
  }

  private static func makeFixture(
    worktreePath: String = "/tmp/touch-code-test-worktree",
    defaultEditor: EditorID? = nil
  ) -> Fixture {
    let spaceID = SpaceID()
    let projectID = ProjectID()
    let worktreeID = WorktreeID()
    let tabID = TabID()
    let panelID = PanelID()
    let panel = Panel(
      id: panelID,
      workingDirectory: worktreePath,
      initialCommand: nil
    )
    let tab = Tab(
      id: tabID, name: "t",
      splitTree: SplitTree(root: .leaf(panelID)),
      panels: [panel]
    )
    let worktree = Worktree(
      id: worktreeID, name: "w", path: worktreePath, branch: "main",
      tabs: [tab], selectedTabID: tabID
    )
    let project = Project(
      id: projectID, name: "p", rootPath: "/", gitRoot: "/",
      worktreesDirectory: nil, defaultEditor: defaultEditor,
      worktrees: [worktree], selectedWorktreeID: worktreeID
    )
    let space = Space(
      id: spaceID, name: "s", projects: [project], selectedProjectID: projectID
    )
    return Fixture(
      catalog: Catalog(windows: [], spaces: [space], selectedSpaceID: spaceID),
      spaceID: spaceID,
      projectID: projectID,
      worktreeID: worktreeID,
      tabID: tabID,
      panelID: panelID,
      worktreePath: worktreePath
    )
  }

  /// Builds a test `HierarchyClient` that answers `snapshot` + `setDefaultEditor` only.
  /// All other closures trap; tests that need more must override explicitly.
  private static func makeHierarchyClient(
    catalog: Catalog,
    setDefault: @escaping @MainActor @Sendable (ProjectID, SpaceID, EditorID?) throws -> Void = { _, _, _ in }
  ) -> HierarchyClient {
    var client = HierarchyClient.testValue
    client.snapshot = { catalog }
    client.setDefaultEditor = setDefault
    return client
  }

  // MARK: - describe

  @Test
  func describeForwardsDescriptorsAsDTOs() async {
    var editorClient = EditorClient.testValue
    editorClient.describe = { Self.sampleDescriptors }
    let handlers = EditorHandlers(
      editor: editorClient,
      hierarchy: Self.makeHierarchyClient(catalog: Self.makeFixture().catalog)
    )

    let response = await handlers.describe()

    #expect(response.descriptors.count == 2)
    #expect(response.descriptors[0].id == "vscode")
    #expect(
      response.descriptors[0].installation
        == .installed(
          resolvedBinary: URL(fileURLWithPath: "/usr/local/bin/code")
        ))
    #expect(response.descriptors[1].id == "cursor")
    #expect(response.descriptors[1].installation == .missingBinary(expected: "cursor"))
  }

  // MARK: - open (worktree resolution)

  @Test
  func openResolvesExplicitWorktreeIDAndOpensWithProjectContext() async throws {
    let fixture = Self.makeFixture()
    let captured = LockIsolated<(URL, EditorID?, ProjectID?)?>(nil)
    var editorClient = EditorClient.testValue
    editorClient.open = { dir, preferred, projectID in
      captured.setValue((dir, preferred, projectID))
      return Self.sampleChoice
    }
    let handlers = EditorHandlers(
      editor: editorClient,
      hierarchy: Self.makeHierarchyClient(catalog: fixture.catalog)
    )

    let response = try await handlers.open(
      EditorOpenRequest(
        worktreeID: fixture.worktreeID.raw,
        preferred: "vscode",
        panelID: nil
      ))

    let (dir, preferred, projectID) = try #require(captured.value)
    #expect(dir.path == fixture.worktreePath)
    #expect(preferred == "vscode")
    #expect(projectID == fixture.projectID)
    #expect(response.worktreePath == fixture.worktreePath)
    #expect(response.choice.id == "vscode")
    #expect(response.choice.argv == ["/usr/local/bin/code", "/w"])
  }

  @Test
  func openResolvesWorktreeFromPanelID() async throws {
    let fixture = Self.makeFixture()
    let captured = LockIsolated<(URL, EditorID?, ProjectID?)?>(nil)
    var editorClient = EditorClient.testValue
    editorClient.open = { dir, preferred, projectID in
      captured.setValue((dir, preferred, projectID))
      return Self.sampleChoice
    }
    let handlers = EditorHandlers(
      editor: editorClient,
      hierarchy: Self.makeHierarchyClient(catalog: fixture.catalog)
    )

    _ = try await handlers.open(
      EditorOpenRequest(
        worktreeID: nil,
        preferred: nil,
        panelID: fixture.panelID.raw
      ))

    let (dir, preferred, projectID) = try #require(captured.value)
    #expect(dir.path == fixture.worktreePath)
    #expect(preferred == nil)
    #expect(projectID == fixture.projectID)
  }

  @Test
  func openWithNeitherIDThrowsUnresolvedWorktree() async {
    let fixture = Self.makeFixture()
    let handlers = EditorHandlers(
      editor: EditorClient.testValue,
      hierarchy: Self.makeHierarchyClient(catalog: fixture.catalog)
    )
    await #expect(throws: EditorIPCError.unresolvedWorktree) {
      _ = try await handlers.open(EditorOpenRequest())
    }
  }

  @Test
  func openWithUnknownWorktreeIDThrowsUnresolvedWorktree() async {
    let fixture = Self.makeFixture()
    let handlers = EditorHandlers(
      editor: EditorClient.testValue,
      hierarchy: Self.makeHierarchyClient(catalog: fixture.catalog)
    )
    await #expect(throws: EditorIPCError.unresolvedWorktree) {
      _ = try await handlers.open(EditorOpenRequest(worktreeID: UUID()))
    }
  }

  @Test
  func openWithUnknownPanelIDThrowsUnresolvedWorktree() async {
    let fixture = Self.makeFixture()
    let handlers = EditorHandlers(
      editor: EditorClient.testValue,
      hierarchy: Self.makeHierarchyClient(catalog: fixture.catalog)
    )
    await #expect(throws: EditorIPCError.unresolvedWorktree) {
      _ = try await handlers.open(EditorOpenRequest(panelID: UUID()))
    }
  }

  // MARK: - open (error mapping)

  @Test
  func openMapsNotInstalledEditorErrorToIPCError() async {
    let fixture = Self.makeFixture()
    var editorClient = EditorClient.testValue
    editorClient.open = { _, _, _ in
      throw EditorError.notInstalled(id: "cursor", binary: "cursor")
    }
    let handlers = EditorHandlers(
      editor: editorClient,
      hierarchy: Self.makeHierarchyClient(catalog: fixture.catalog)
    )
    await #expect(throws: EditorIPCError.notInstalled) {
      _ = try await handlers.open(
        EditorOpenRequest(
          worktreeID: fixture.worktreeID.raw, preferred: "cursor"
        ))
    }
  }

  @Test
  func openMapsSpawnFailedEditorErrorToIPCError() async {
    let fixture = Self.makeFixture()
    var editorClient = EditorClient.testValue
    editorClient.open = { _, _, _ in
      throw EditorError.spawnFailed(reason: "permission denied")
    }
    let handlers = EditorHandlers(
      editor: editorClient,
      hierarchy: Self.makeHierarchyClient(catalog: fixture.catalog)
    )
    await #expect(throws: EditorIPCError.spawnFailed) {
      _ = try await handlers.open(EditorOpenRequest(worktreeID: fixture.worktreeID.raw))
    }
  }

  @Test
  func mapToIPCErrorIsExhaustiveOverEditorErrorVariants() {
    let cases: [(EditorError, EditorIPCError)] = [
      (.unresolvedWorktree, .unresolvedWorktree),
      (.notInstalled(id: "vscode", binary: "code"), .notInstalled),
      (.spawnFailed(reason: "x"), .spawnFailed),
      (.nonZeroExit(code: 1, stderr: "x"), .nonZeroExit),
      (.timedOut, .timedOut),
      (.badTemplate(id: "x", reason: "y"), .badTemplate),
      (.notADirectory(path: "/tmp/file"), .notADirectory),
    ]
    for (editorErr, expected) in cases {
      #expect(EditorHandlers.mapToIPCError(editorErr) == expected)
    }
  }

  /// Parameterized end-to-end pass through `open()` that covers the remaining `EditorError`
  /// variants the individual tests don't hit (`notInstalled` / `spawnFailed` are covered above;
  /// this harness layers on `nonZeroExit` / `timedOut` / `badTemplate` / `notADirectory`). Guards
  /// against a map-table drift where `mapToIPCErrorIsExhaustiveOverEditorErrorVariants` passes
  /// but the live call path fails to re-throw the translated error.
  @Test(arguments: [
    (EditorError.nonZeroExit(code: 1, stderr: "fatal"), EditorIPCError.nonZeroExit),
    (EditorError.timedOut, EditorIPCError.timedOut),
    (EditorError.badTemplate(id: "helix", reason: "empty binary"), EditorIPCError.badTemplate),
    (EditorError.notADirectory(path: "/tmp/not-a-dir"), EditorIPCError.notADirectory),
  ])
  func openTranslatesEditorErrorThroughLiveCallPath(
    input: EditorError, expected: EditorIPCError
  ) async {
    let fixture = Self.makeFixture()
    var editorClient = EditorClient.testValue
    editorClient.open = { _, _, _ in throw input }
    let handlers = EditorHandlers(
      editor: editorClient,
      hierarchy: Self.makeHierarchyClient(catalog: fixture.catalog)
    )
    await #expect(throws: expected) {
      _ = try await handlers.open(EditorOpenRequest(worktreeID: fixture.worktreeID.raw))
    }
  }

  // MARK: - open (path field)

  @Test
  func openWithinWorktreePathForwardsSubdirectoryToSpawner() async throws {
    let fixture = Self.makeFixture(worktreePath: "/tmp/touch-code-test-worktree")
    let captured = LockIsolated<URL?>(nil)
    var editorClient = EditorClient.testValue
    editorClient.open = { dir, _, _ in
      captured.setValue(dir)
      return Self.sampleChoice
    }
    let handlers = EditorHandlers(
      editor: editorClient,
      hierarchy: Self.makeHierarchyClient(catalog: fixture.catalog)
    )

    _ = try await handlers.open(
      EditorOpenRequest(
        worktreeID: fixture.worktreeID.raw,
        preferred: nil,
        panelID: nil,
        path: "/tmp/touch-code-test-worktree/sub"
      ))
    #expect(captured.value?.path == "/tmp/touch-code-test-worktree/sub")
  }

  @Test
  func openWithPathOutsideWorktreeThrowsNotADirectory() async {
    let fixture = Self.makeFixture(worktreePath: "/tmp/touch-code-test-worktree")
    var editorClient = EditorClient.testValue
    editorClient.open = { _, _, _ in Self.sampleChoice }
    let handlers = EditorHandlers(
      editor: editorClient,
      hierarchy: Self.makeHierarchyClient(catalog: fixture.catalog)
    )
    await #expect(throws: EditorIPCError.notADirectory) {
      _ = try await handlers.open(
        EditorOpenRequest(
          worktreeID: fixture.worktreeID.raw,
          path: "/etc"
        ))
    }
  }

  @Test
  func openWithEmptyPathFallsBackToWorktreeRoot() async throws {
    let fixture = Self.makeFixture(worktreePath: "/tmp/touch-code-test-worktree")
    let captured = LockIsolated<URL?>(nil)
    var editorClient = EditorClient.testValue
    editorClient.open = { dir, _, _ in
      captured.setValue(dir)
      return Self.sampleChoice
    }
    let handlers = EditorHandlers(
      editor: editorClient,
      hierarchy: Self.makeHierarchyClient(catalog: fixture.catalog)
    )
    _ = try await handlers.open(
      EditorOpenRequest(
        worktreeID: fixture.worktreeID.raw,
        path: ""
      ))
    #expect(captured.value?.path == fixture.worktreePath)
  }

  // MARK: - setDefault

  @Test
  func setDefaultWritesThroughHierarchyClient() throws {
    let fixture = Self.makeFixture()
    let captured = LockIsolated<(ProjectID, SpaceID, EditorID?)?>(nil)
    let hierarchy = Self.makeHierarchyClient(
      catalog: fixture.catalog,
      setDefault: { projectID, spaceID, editorID in
        captured.setValue((projectID, spaceID, editorID))
      }
    )
    let handlers = EditorHandlers(editor: EditorClient.testValue, hierarchy: hierarchy)

    _ = try handlers.setDefault(
      EditorSetDefaultRequest(
        projectID: fixture.projectID.raw,
        editorID: "zed"
      ))

    let (projectID, spaceID, editorID) = try #require(captured.value)
    #expect(projectID == fixture.projectID)
    #expect(spaceID == fixture.spaceID)
    #expect(editorID == "zed")
  }

  @Test
  func setDefaultWithNilEditorIDClearsOverride() throws {
    let fixture = Self.makeFixture(defaultEditor: "vscode")
    let captured = LockIsolated<EditorID?>("<unset>")
    let hierarchy = Self.makeHierarchyClient(
      catalog: fixture.catalog,
      setDefault: { _, _, editorID in captured.setValue(editorID) }
    )
    let handlers = EditorHandlers(editor: EditorClient.testValue, hierarchy: hierarchy)

    _ = try handlers.setDefault(
      EditorSetDefaultRequest(
        projectID: fixture.projectID.raw,
        editorID: nil
      ))

    #expect(captured.value == nil)
  }

  @Test
  func setDefaultWithUnknownProjectIDThrowsUnknownProject() {
    let fixture = Self.makeFixture()
    let handlers = EditorHandlers(
      editor: EditorClient.testValue,
      hierarchy: Self.makeHierarchyClient(catalog: fixture.catalog)
    )
    #expect(throws: EditorIPCError.unknownProject) {
      _ = try handlers.setDefault(
        EditorSetDefaultRequest(
          projectID: UUID(), editorID: "vscode"
        ))
    }
  }
}
