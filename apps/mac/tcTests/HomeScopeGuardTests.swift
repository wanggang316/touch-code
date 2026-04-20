import Foundation
import Testing

@testable import tcKit

struct HomeScopeGuardTests {
  @Test
  func acceptsDestinationDirectlyInsideHome() throws {
    let home = Self.tempHome()
    defer { try? FileManager.default.removeItem(at: home) }
    let dest = home.appendingPathComponent("skills/touch-code")
    #expect(HomeScopeGuard.isInsideHome(dest, homeDirectory: home))
  }

  @Test
  func rejectsDestinationOutsideHome() throws {
    let home = Self.tempHome()
    defer { try? FileManager.default.removeItem(at: home) }
    let dest = URL(fileURLWithPath: "/tmp/tc-outside-\(UUID().uuidString)")
    #expect(!HomeScopeGuard.isInsideHome(dest, homeDirectory: home))
  }

  @Test
  func rejectsWhenAncestorSymlinkEscapesHome() throws {
    // Mirror the real attack: an attacker plants `$HOME/.claude/skills` as a
    // symlink to `/tmp/attacker`, then the installer is asked to write
    // `$HOME/.claude/skills/touch-code`. The literal prefix check passes because
    // the destination string starts with `$HOME`, but the symlink redirects the
    // actual write to `/tmp/attacker/touch-code`.
    let home = Self.tempHome()
    defer { try? FileManager.default.removeItem(at: home) }
    let external = Self.tempExternalDir()
    defer { try? FileManager.default.removeItem(at: external) }

    let parent = home.appendingPathComponent(".claude")
    try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
    let malicious = parent.appendingPathComponent("skills")
    try FileManager.default.createSymbolicLink(at: malicious, withDestinationURL: external)

    let dest = malicious.appendingPathComponent("touch-code")
    #expect(!HomeScopeGuard.isInsideHome(dest, homeDirectory: home))
  }

  @Test
  func rejectsWhenDestinationItselfIsSymlinkToOutside() throws {
    let home = Self.tempHome()
    defer { try? FileManager.default.removeItem(at: home) }
    let external = Self.tempExternalDir()
    defer { try? FileManager.default.removeItem(at: external) }

    let dest = home.appendingPathComponent("touch-code")
    try FileManager.default.createSymbolicLink(at: dest, withDestinationURL: external)
    #expect(!HomeScopeGuard.isInsideHome(dest, homeDirectory: home))
  }

  @Test
  func rejectsDanglingSymlinkAtDestinationPointingOutsideHome() throws {
    // `fileExists` returns false for a dangling symlink so a naive check that
    // only triggered when the destination "exists" would miss this case and
    // then blindly overwrite the symlink target once the attacker creates it.
    let home = Self.tempHome()
    defer { try? FileManager.default.removeItem(at: home) }

    let dest = home.appendingPathComponent("touch-code-dangling")
    let danglingTarget = URL(fileURLWithPath: "/tmp/tc-missing-\(UUID().uuidString)")
    try FileManager.default.createSymbolicLink(at: dest, withDestinationURL: danglingTarget)
    #expect(!HomeScopeGuard.isInsideHome(dest, homeDirectory: home))
  }

  @Test
  func acceptsSymlinkInsideHomePointingWithinHome() throws {
    let home = Self.tempHome()
    defer { try? FileManager.default.removeItem(at: home) }
    let target = home.appendingPathComponent("real-skills")
    try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)

    let link = home.appendingPathComponent("skills")
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)

    let dest = link.appendingPathComponent("touch-code")
    #expect(HomeScopeGuard.isInsideHome(dest, homeDirectory: home))
  }

  // MARK: - Helpers

  static func tempHome() -> URL {
    let base = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
      .appendingPathComponent(".touch-code-homescope-\(UUID().uuidString)", isDirectory: true)
    try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
    return base
  }

  static func tempExternalDir() -> URL {
    let base = URL(fileURLWithPath: "/tmp", isDirectory: true)
      .appendingPathComponent("touch-code-ext-\(UUID().uuidString)", isDirectory: true)
    try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
    return base
  }
}
