import Foundation
import Testing

@testable import touch_code
@testable import TouchCodeCore

@MainActor
struct ExternalEditorTests {
  @Test
  func openPathResolvesVSCodeArgv() async throws {
    let runner = FakeRunner()
    let editor = ExternalEditor(catalog: { Catalog() }, runner: runner)
    let result = try await editor.openPath("/tmp/dir", editor: "vscode")
    #expect(runner.calls.count == 1)
    #expect(runner.calls[0].executable == "code")
    #expect(runner.calls[0].arguments == ["/tmp/dir"])
    #expect(result.editor == "vscode")
    #expect(result.path == "/tmp/dir")
    #expect(result.exitStatus == 0)
  }

  @Test
  func openPathXcodeUsesOpenDashA() async throws {
    let runner = FakeRunner()
    let editor = ExternalEditor(catalog: { Catalog() }, runner: runner)
    _ = try await editor.openPath("/tmp/dir", editor: "xcode")
    #expect(runner.calls[0].executable == "open")
    #expect(runner.calls[0].arguments == ["-a", "Xcode", "/tmp/dir"])
  }

  @Test
  func openPathNilEditorFallsBackToFinder() async throws {
    let runner = FakeRunner()
    let editor = ExternalEditor(catalog: { Catalog() }, runner: runner)
    let result = try await editor.openPath("/tmp/dir", editor: nil)
    #expect(result.editor == "finder")
    #expect(runner.calls[0].executable == "open")
    #expect(runner.calls[0].arguments == ["/tmp/dir"])
  }

  @Test
  func openPathUnknownEditorThrows() async throws {
    let runner = FakeRunner()
    let editor = ExternalEditor(catalog: { Catalog() }, runner: runner)
    await #expect(throws: ExternalEditor.OpenError.unknownEditor("nvim")) {
      try await editor.openPath("/tmp/dir", editor: "nvim")
    }
    #expect(runner.calls.isEmpty)
  }

  @Test
  func openPathBinaryMissingThrowsBinaryNotFound() async throws {
    let runner = FakeRunner(error: NSError(domain: "test", code: 1))
    let editor = ExternalEditor(catalog: { Catalog() }, runner: runner)
    await #expect(throws: ExternalEditor.OpenError.binaryNotFound("code")) {
      try await editor.openPath("/tmp/dir", editor: "vscode")
    }
  }

  @Test
  func openPathNonZeroExitThrowsSpawnFailed() async throws {
    let runner = FakeRunner(exitStatus: 42)
    let editor = ExternalEditor(catalog: { Catalog() }, runner: runner)
    do {
      _ = try await editor.openPath("/tmp/dir", editor: "vscode")
      Issue.record("expected throw")
    } catch ExternalEditor.OpenError.spawnFailed(let status, _) {
      #expect(status == 42)
    } catch {
      Issue.record("unexpected error: \(error)")
    }
  }

  @Test
  func openWorktreeUsesWorktreePath() async throws {
    let (catalog, worktreeID) = Self.singleWorktreeCatalog(path: "/tmp/wt", projectEditor: nil)
    let runner = FakeRunner()
    let editor = ExternalEditor(catalog: { catalog }, runner: runner)
    let result = try await editor.open(worktreeID: worktreeID, editor: "cursor")
    #expect(result.path == "/tmp/wt")
    #expect(result.editor == "cursor")
    #expect(runner.calls[0].executable == "cursor")
    #expect(runner.calls[0].arguments == ["/tmp/wt"])
  }

  @Test
  func openWorktreeFallsThroughProjectDefault() async throws {
    let (catalog, worktreeID) = Self.singleWorktreeCatalog(path: "/tmp/wt", projectEditor: "zed")
    let runner = FakeRunner()
    let editor = ExternalEditor(catalog: { catalog }, runner: runner)
    let result = try await editor.open(worktreeID: worktreeID, editor: nil)
    #expect(result.editor == "zed")
    #expect(runner.calls[0].executable == "zed")
  }

  @Test
  func openWorktreeExplicitEditorBeatsProjectDefault() async throws {
    let (catalog, worktreeID) = Self.singleWorktreeCatalog(path: "/tmp/wt", projectEditor: "zed")
    let runner = FakeRunner()
    let editor = ExternalEditor(catalog: { catalog }, runner: runner)
    let result = try await editor.open(worktreeID: worktreeID, editor: "vscode")
    #expect(result.editor == "vscode")
  }

  @Test
  func openWorktreeMissingWorktreeThrows() async throws {
    let runner = FakeRunner()
    let editor = ExternalEditor(catalog: { Catalog() }, runner: runner)
    let stranger = WorktreeID(raw: UUID())
    await #expect(throws: ExternalEditor.OpenError.worktreeNotFound(stranger)) {
      try await editor.open(worktreeID: stranger, editor: "vscode")
    }
  }

  // MARK: - Helpers

  final class FakeRunner: ExternalEditor.ProcessRunner, @unchecked Sendable {
    struct Call: Sendable, Equatable {
      let executable: String
      let arguments: [String]
    }
    private let lock = NSLock()
    private var _calls: [Call] = []
    var calls: [Call] {
      lock.lock(); defer { lock.unlock() }
      return _calls
    }
    let exitStatus: Int32
    let error: Error?

    init(exitStatus: Int32 = 0, error: Error? = nil) {
      self.exitStatus = exitStatus
      self.error = error
    }

    nonisolated func launch(executable: String, arguments: [String]) throws -> Int32 {
      if let error { throw error }
      lock.lock()
      _calls.append(Call(executable: executable, arguments: arguments))
      lock.unlock()
      return exitStatus
    }
  }

  static func singleWorktreeCatalog(
    path: String,
    projectEditor: String?
  ) -> (Catalog, WorktreeID) {
    let worktreeID = WorktreeID(raw: UUID())
    let worktree = Worktree(
      id: worktreeID,
      name: "wt",
      path: path,
      branch: nil,
      tabs: [],
      selectedTabID: nil
    )
    let project = Project(
      id: ProjectID(raw: UUID()),
      name: "proj",
      rootPath: "/tmp",
      gitRoot: nil,
      defaultEditor: projectEditor,
      worktrees: [worktree],
      selectedWorktreeID: worktreeID
    )
    let space = Space(
      id: SpaceID(raw: UUID()),
      name: "s",
      projects: [project],
      selectedProjectID: project.id
    )
    let catalog = Catalog(
      version: 1,
      spaces: [space],
      selectedSpaceID: space.id
    )
    return (catalog, worktreeID)
  }
}
