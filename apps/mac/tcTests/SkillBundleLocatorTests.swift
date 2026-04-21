import Foundation
import Testing

@testable import tcKit

struct SkillBundleLocatorTests {
  @Test
  func locatesAgentsJSONFromWorktreeExecutable() throws {
    // Feed a synthetic executable URL that sits at `<repo>/apps/mac/.build/tc-release/tc`.
    // The walk should find `apps/mac/Resources/agents.json` and return it.
    let repoRoot = Self.repoRoot()
    let synthetic = repoRoot
      .appendingPathComponent("apps/mac/.build/tc-release/tc")
    let url = try SkillBundleLocator.locateAgentsJSON(executableURL: synthetic)
    #expect(url.lastPathComponent == "agents.json")
    #expect(url.path.hasPrefix(repoRoot.path))
  }

  @Test
  func locatesSkillBundleFromWorktreeExecutable() throws {
    let repoRoot = Self.repoRoot()
    let synthetic = repoRoot
      .appendingPathComponent("apps/mac/.build/tc-release/tc")
    let url = try SkillBundleLocator.locateSkillBundle(executableURL: synthetic)
    #expect(url.lastPathComponent == "touch-code-cli")
    #expect(url.path.hasPrefix(repoRoot.path))
  }

  @Test
  func locateAgentsJSONThrowsWhenNotReachable() throws {
    // An executable URL under /tmp has no `apps/mac/Resources/agents.json` anywhere up
    // the tree. Expect agentsJSONNotFound.
    let synthetic = URL(fileURLWithPath: "/tmp/\(UUID().uuidString)/tc")
    var threw = false
    do { _ = try SkillBundleLocator.locateAgentsJSON(executableURL: synthetic) } catch SkillBundleLocator.LocatorError.agentsJSONNotFound {
      threw = true
    }
    #expect(threw)
  }

  @Test
  func locateSkillBundleThrowsWhenNotReachable() throws {
    let synthetic = URL(fileURLWithPath: "/tmp/\(UUID().uuidString)/tc")
    var threw = false
    do { _ = try SkillBundleLocator.locateSkillBundle(executableURL: synthetic) } catch SkillBundleLocator.LocatorError.bundleNotFound {
      threw = true
    }
    #expect(threw)
  }

  // MARK: - Helpers

  /// Repo root, computed from this file's path at compile time.
  static func repoRoot() -> URL {
    // .../apps/mac/tcTests/SkillBundleLocatorTests.swift
    URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent() // tcTests
      .deletingLastPathComponent() // mac
      .deletingLastPathComponent() // apps
      .deletingLastPathComponent() // repo root
  }
}
