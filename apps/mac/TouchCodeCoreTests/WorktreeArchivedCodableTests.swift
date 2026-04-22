import Foundation
import Testing

@testable import TouchCodeCore

/// Covers the backward-compatible `archived: Bool` flag added for the
/// Worktree Management spec. The three cases assert the key is *not*
/// emitted for default values (pre-archive catalogs round-trip
/// identically), that a pre-archive JSON object (no `archived` key)
/// decodes to `false`, and that `true` round-trips with the key present.
struct WorktreeArchivedCodableTests {
  @Test
  func preArchiveFixtureDecodesToFalse() throws {
    let json = #"""
      {
        "id": { "raw": "00000000-0000-0000-0000-000000000001" },
        "name": "main",
        "path": "/tmp/repo",
        "tabs": []
      }
      """#
    let data = Data(json.utf8)
    let worktree = try JSONDecoder().decode(Worktree.self, from: data)
    #expect(worktree.archived == false)
  }

  @Test
  func defaultWorktreeOmitsArchivedKey() throws {
    let worktree = Worktree(name: "main", path: "/tmp/repo")
    let data = try JSONEncoder().encode(worktree)
    let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
    #expect(object?["archived"] == nil)
  }

  @Test
  func archivedTrueRoundTrips() throws {
    let worktree = Worktree(name: "feature", path: "/tmp/feat", archived: true)
    let data = try JSONEncoder().encode(worktree)
    let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
    #expect(object?["archived"] as? Bool == true)

    let decoded = try JSONDecoder().decode(Worktree.self, from: data)
    #expect(decoded == worktree)
    #expect(decoded.archived == true)
  }
}
