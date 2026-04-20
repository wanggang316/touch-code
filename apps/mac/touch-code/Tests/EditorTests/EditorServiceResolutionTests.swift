import Foundation
import Testing
import TouchCodeCore
@testable import touch_code

struct EditorServiceResolutionTests {
  /// A prober that marks every built-in as installed.
  private static func allInstalledProber() -> FakePathProber {
    FakePathProber(resolution: [
      "code": URL(fileURLWithPath: "/usr/local/bin/code"),
      "cursor": URL(fileURLWithPath: "/usr/local/bin/cursor"),
      "zed": URL(fileURLWithPath: "/usr/local/bin/zed"),
      "subl": URL(fileURLWithPath: "/usr/local/bin/subl"),
      "open": URL(fileURLWithPath: "/usr/bin/open"),
    ])
  }

  @Test
  func explicitPreferredWins() async {
    let service = LiveEditorService(
      spawner: RecordingProcessSpawner(),
      prober: Self.allInstalledProber()
    )
    let descriptor = await service.resolve(preferred: "cursor", projectID: nil)
    #expect(descriptor.id == "cursor")
  }

  @Test
  func projectOverrideWinsWhenPreferredIsNil() async {
    let pid = ProjectID()
    let service = LiveEditorService(
      spawner: RecordingProcessSpawner(),
      prober: Self.allInstalledProber(),
      projectOverride: { _ in "zed" }
    )
    let descriptor = await service.resolve(preferred: nil, projectID: pid)
    #expect(descriptor.id == "zed")
  }

  @Test
  func globalDefaultWinsWhenProjectOverrideIsNil() async {
    let service = LiveEditorService(
      spawner: RecordingProcessSpawner(),
      prober: Self.allInstalledProber(),
      globalDefault: { "vscode" }
    )
    let descriptor = await service.resolve(preferred: nil, projectID: nil)
    #expect(descriptor.id == "vscode")
  }

  @Test
  func finderFallbackWhenNothingIsSet() async {
    let service = LiveEditorService(
      spawner: RecordingProcessSpawner(),
      prober: Self.allInstalledProber()
    )
    let descriptor = await service.resolve(preferred: nil, projectID: nil)
    #expect(descriptor.id == "finder")
  }

  @Test
  func missingPreferredSurfacesMissingBinaryDescriptor() async {
    // VSCode not on PATH.
    let prober = FakePathProber(resolution: ["open": URL(fileURLWithPath: "/usr/bin/open")])
    let service = LiveEditorService(spawner: RecordingProcessSpawner(), prober: prober)
    let descriptor = await service.resolve(preferred: "vscode", projectID: nil)
    #expect(descriptor.id == "vscode")
    #expect(!descriptor.isInstalled)
  }

  @Test
  func finderFallbackPrefersInstalledOverMissing() async {
    // Nothing in registry is installed — including `open`. Resolve still returns the Finder
    // descriptor (last-resort clause), but its .installation is .missingBinary so the UI
    // can render "not installed" accurately and `open()` can throw a clear .notInstalled.
    let prober = FakePathProber(resolution: [:])
    let service = LiveEditorService(spawner: RecordingProcessSpawner(), prober: prober)
    let descriptor = await service.resolve(preferred: nil, projectID: nil)
    #expect(descriptor.id == "finder")
    #expect(!descriptor.isInstalled)
  }

  @Test
  func openOnMissingFinderSurfacesNotInstalled() async throws {
    let dir = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
    let prober = FakePathProber(resolution: [:])
    let service = LiveEditorService(spawner: RecordingProcessSpawner(), prober: prober)
    await #expect(throws: EditorError.notInstalled(id: "finder", binary: "open")) {
      _ = try await service.open(directory: dir, preferred: nil, projectID: nil)
    }
  }

  @Test
  func openThrowsNotInstalledOnMissingPreferredNoSilentFallthrough() async throws {
    // Only Finder installed. Preferring vscode → `.notInstalled` (no fallthrough to Finder).
    let prober = FakePathProber(resolution: ["open": URL(fileURLWithPath: "/usr/bin/open")])
    let spawner = RecordingProcessSpawner()
    let service = LiveEditorService(spawner: spawner, prober: prober)
    let directory = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)

    await #expect(throws: EditorError.notInstalled(id: "vscode", binary: "code")) {
      _ = try await service.open(directory: directory, preferred: "vscode", projectID: nil)
    }
    let calls = await spawner.calls
    #expect(calls.isEmpty, "spawner must not be invoked when preferred editor is missing")
  }
}
