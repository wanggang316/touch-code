import Foundation
import Testing
import TouchCodeCore

@testable import touch_code

struct EditorServiceSpawnTests {
  private static func allInstalledProber() -> FakePathProber {
    FakePathProber(resolution: [
      "code": URL(fileURLWithPath: "/usr/local/bin/code"),
      "cursor": URL(fileURLWithPath: "/usr/local/bin/cursor"),
      "zed": URL(fileURLWithPath: "/usr/local/bin/zed"),
      "subl": URL(fileURLWithPath: "/usr/local/bin/subl"),
      "open": URL(fileURLWithPath: "/usr/bin/open"),
    ])
  }

  private static func existingDirectory() throws -> URL {
    let url = URL(fileURLWithPath: NSTemporaryDirectory())
      .appendingPathComponent("touch-code-editor-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
  }

  private static func cleanup(_ url: URL) {
    _ = try? FileManager.default.removeItem(at: url)
  }

  @Test
  func vscodeArgvMatchesTemplate() async throws {
    let dir = try Self.existingDirectory()
    defer { Self.cleanup(dir) }
    let spawner = RecordingProcessSpawner()
    let service = LiveEditorService(spawner: spawner, prober: Self.allInstalledProber())

    let choice = try await service.open(directory: dir, preferred: "vscode", projectID: nil)
    #expect(choice.id == "vscode")
    #expect(choice.binaryPath.path == "/usr/local/bin/code")
    #expect(choice.argv == ["/usr/local/bin/code", dir.path])

    let calls = await spawner.calls
    #expect(calls.count == 1)
    #expect(calls[0].argv == ["/usr/local/bin/code", dir.path])
  }

  @Test
  func xcodeArgvUsesOpenDashA() async throws {
    let dir = try Self.existingDirectory()
    defer { Self.cleanup(dir) }
    let spawner = RecordingProcessSpawner()
    let service = LiveEditorService(spawner: spawner, prober: Self.allInstalledProber())

    _ = try await service.open(directory: dir, preferred: "xcode", projectID: nil)
    let calls = await spawner.calls
    #expect(calls[0].argv == ["/usr/bin/open", "-a", "Xcode", dir.path])
  }

  @Test
  func finderArgvIsPlainOpen() async throws {
    let dir = try Self.existingDirectory()
    defer { Self.cleanup(dir) }
    let spawner = RecordingProcessSpawner()
    let service = LiveEditorService(spawner: spawner, prober: Self.allInstalledProber())

    _ = try await service.open(directory: dir, preferred: "finder", projectID: nil)
    let calls = await spawner.calls
    #expect(calls[0].argv == ["/usr/bin/open", dir.path])
  }

  @Test
  func dirPlaceholderSubstitutionIsLiteralNotShellExpanded() async throws {
    let baseTmp = URL(fileURLWithPath: NSTemporaryDirectory())
    let dir = baseTmp.appendingPathComponent("touch-code-weird dir-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { Self.cleanup(dir) }

    let spawner = RecordingProcessSpawner()
    let service = LiveEditorService(spawner: spawner, prober: Self.allInstalledProber())

    _ = try await service.open(directory: dir, preferred: "finder", projectID: nil)
    let calls = await spawner.calls
    // The dir slot is a single argv element, unquoted. A shell would split on the space;
    // Process does not.
    #expect(calls[0].argv.count == 2)
    #expect(calls[0].argv[1] == dir.path)
    #expect(calls[0].argv[1].contains(" "))
  }

  @Test
  func spawnReceivesAllowlistEnvOnly() async throws {
    let dir = try Self.existingDirectory()
    defer { Self.cleanup(dir) }
    let spawner = RecordingProcessSpawner()
    let service = LiveEditorService(spawner: spawner, prober: Self.allInstalledProber())

    _ = try await service.open(directory: dir, preferred: "finder", projectID: nil)
    let calls = await spawner.calls
    let keys = Set(calls[0].env.keys)
    // PATH and HOME optionally present (depending on parent), LC_ALL always present.
    #expect(keys.isSubset(of: ["PATH", "HOME", "LC_ALL"]))
    #expect(calls[0].env["LC_ALL"] == "C.UTF-8")
    #expect(calls[0].env["SHELL"] == nil)
    #expect(calls[0].env["EDITOR"] == nil)
  }

  @Test
  func cwdIsTheWorktreeDirectory() async throws {
    let dir = try Self.existingDirectory()
    defer { Self.cleanup(dir) }
    let spawner = RecordingProcessSpawner()
    let service = LiveEditorService(spawner: spawner, prober: Self.allInstalledProber())

    _ = try await service.open(directory: dir, preferred: "finder", projectID: nil)
    let calls = await spawner.calls
    #expect(calls[0].cwd.path == dir.path)
  }

  @Test
  func timeoutReportsEditorErrorTimedOut() async throws {
    let dir = try Self.existingDirectory()
    defer { Self.cleanup(dir) }
    let spawner = RecordingProcessSpawner()
    await spawner.setOutcomes([.timedOut])
    let service = LiveEditorService(spawner: spawner, prober: Self.allInstalledProber())

    await #expect(throws: EditorError.timedOut) {
      _ = try await service.open(directory: dir, preferred: "finder", projectID: nil)
    }
  }

  @Test
  func nonZeroExitReportsCodeAndStderr() async throws {
    let dir = try Self.existingDirectory()
    defer { Self.cleanup(dir) }
    let spawner = RecordingProcessSpawner()
    await spawner.setOutcomes([.exited(code: 2, stderr: "boom")])
    let service = LiveEditorService(spawner: spawner, prober: Self.allInstalledProber())

    await #expect(throws: EditorError.nonZeroExit(code: 2, stderr: "boom")) {
      _ = try await service.open(directory: dir, preferred: "finder", projectID: nil)
    }
  }

  @Test
  func spawnFailedPropagatesSpawnerReason() async throws {
    let dir = try Self.existingDirectory()
    defer { Self.cleanup(dir) }
    let spawner = RecordingProcessSpawner()
    await spawner.setOutcomes([.spawnFailed(reason: "ENOENT")])
    let service = LiveEditorService(spawner: spawner, prober: Self.allInstalledProber())

    await #expect(throws: EditorError.spawnFailed(reason: "ENOENT")) {
      _ = try await service.open(directory: dir, preferred: "finder", projectID: nil)
    }
  }

  @Test
  func notADirectoryIsSurfacedBeforeSpawning() async {
    let bogus = URL(fileURLWithPath: "/this/does/not/exist-\(UUID().uuidString)")
    let spawner = RecordingProcessSpawner()
    let service = LiveEditorService(spawner: spawner, prober: Self.allInstalledProber())

    await #expect(throws: EditorError.notADirectory(path: bogus.path)) {
      _ = try await service.open(directory: bogus, preferred: "finder", projectID: nil)
    }
    let calls = await spawner.calls
    #expect(calls.isEmpty)
  }
}
