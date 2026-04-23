import Foundation
import Testing

@testable import TouchCodeCore

/// Pure-parser tests for `RemoteInfo.parse(_:)`. Covers every URL shape `git remote get-url`
/// is known to emit (SSH SCP-style, HTTPS, explicit `ssh://`) plus malformed inputs the
/// service layer must reject before dispatching GraphQL.
struct RemoteInfoParseTests {
  // MARK: - SSH / SCP-style

  @Test
  func parsesSCPStyleWithDotGitSuffix() throws {
    let info = try RemoteInfo.parse("git@github.com:wanggang316/touch-code.git")
    #expect(info.host == "github.com")
    #expect(info.owner == "wanggang316")
    #expect(info.repo == "touch-code")
  }

  @Test
  func parsesSCPStyleWithoutDotGitSuffix() throws {
    let info = try RemoteInfo.parse("git@github.com:wanggang316/touch-code")
    #expect(info.host == "github.com")
    #expect(info.owner == "wanggang316")
    #expect(info.repo == "touch-code")
  }

  // MARK: - HTTPS

  @Test
  func parsesHTTPSWithDotGitSuffix() throws {
    let info = try RemoteInfo.parse("https://github.com/wanggang316/touch-code.git")
    #expect(info.host == "github.com")
    #expect(info.owner == "wanggang316")
    #expect(info.repo == "touch-code")
  }

  @Test
  func parsesHTTPSWithoutDotGitSuffix() throws {
    let info = try RemoteInfo.parse("https://github.com/wanggang316/touch-code")
    #expect(info.host == "github.com")
    #expect(info.owner == "wanggang316")
    #expect(info.repo == "touch-code")
  }

  @Test
  func parsesHTTPSWithUserAuthority() throws {
    // Some environments stash a username into the https URL — `user@host/...` should be
    // tolerated and the user token stripped before host parsing.
    let info = try RemoteInfo.parse("https://gump@github.com/wanggang316/touch-code.git")
    #expect(info.host == "github.com")
    #expect(info.owner == "wanggang316")
    #expect(info.repo == "touch-code")
  }

  // MARK: - ssh://

  @Test
  func parsesSSHSchemeStyle() throws {
    let info = try RemoteInfo.parse("ssh://git@github.com/wanggang316/touch-code.git")
    #expect(info.host == "github.com")
    #expect(info.owner == "wanggang316")
    #expect(info.repo == "touch-code")
  }

  // MARK: - GitHub Enterprise host

  @Test
  func parsesEnterpriseHost() throws {
    // Non-github.com hosts are accepted — GHES installs vary. The caller decides whether
    // the host is one it supports.
    let info = try RemoteInfo.parse("git@github.example.corp:platform/monorepo.git")
    #expect(info.host == "github.example.corp")
    #expect(info.owner == "platform")
    #expect(info.repo == "monorepo")
  }

  // MARK: - Malformed

  @Test
  func rejectsEmptyString() {
    #expect(throws: RemoteInfo.ParseError.self) {
      _ = try RemoteInfo.parse("")
    }
  }

  @Test
  func rejectsWhitespaceOnlyString() {
    #expect(throws: RemoteInfo.ParseError.self) {
      _ = try RemoteInfo.parse("   \n\t ")
    }
  }

  @Test
  func rejectsSCPStyleMissingOwner() {
    // "git@host:/repo" — colon-then-slash with no owner segment.
    #expect(throws: RemoteInfo.ParseError.self) {
      _ = try RemoteInfo.parse("git@github.com:/touch-code.git")
    }
  }

  @Test
  func rejectsSCPStyleMissingRepo() {
    // "git@host:owner" — no slash, no repo segment.
    #expect(throws: RemoteInfo.ParseError.self) {
      _ = try RemoteInfo.parse("git@github.com:wanggang316")
    }
  }

  @Test
  func rejectsHTTPSMissingRepo() {
    #expect(throws: RemoteInfo.ParseError.self) {
      _ = try RemoteInfo.parse("https://github.com/wanggang316")
    }
  }

  @Test
  func rejectsUnknownScheme() {
    #expect(throws: RemoteInfo.ParseError.self) {
      _ = try RemoteInfo.parse("ftp://github.com/o/r.git")
    }
  }

  @Test
  func trimsLeadingAndTrailingWhitespace() throws {
    // `git remote get-url` emits a trailing newline — the parser must strip it.
    let info = try RemoteInfo.parse("  git@github.com:wanggang316/touch-code.git\n")
    #expect(info.host == "github.com")
    #expect(info.owner == "wanggang316")
    #expect(info.repo == "touch-code")
  }
}
