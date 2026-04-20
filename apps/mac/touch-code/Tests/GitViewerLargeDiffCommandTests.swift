import Foundation
import Testing
import TouchCodeCore
@testable import touch_code

/// Table-driven tests for `LargeDiffCommand.build`. Locks the exact shell-safe output per
/// scope, including POSIX-single-quote escaping for paths containing spaces, apostrophes,
/// or shell metacharacters.
struct GitViewerLargeDiffCommandTests {
  @Test
  func workingScopeProducesDiffCommand() throws {
    let result = try LargeDiffCommand.build(scope: .working, worktreePath: "/Users/gump/x")
    #expect(result == "cd '/Users/gump/x' && git diff --no-color")
  }

  @Test
  func stagedScopeProducesDashCachedCommand() throws {
    let result = try LargeDiffCommand.build(scope: .staged, worktreePath: "/Users/gump/x")
    #expect(result == "cd '/Users/gump/x' && git diff --no-color --cached")
  }

  @Test
  func commitScopeProducesShowCommandWithSHA() throws {
    let result = try LargeDiffCommand.build(
      scope: .commit(sha: "deadbee"),
      worktreePath: "/Users/gump/x"
    )
    #expect(result == "cd '/Users/gump/x' && git show --no-color deadbee")
  }

  @Test
  func logScopeThrows() {
    #expect(throws: LargeDiffCommandError.logScopeUnsupported) {
      _ = try LargeDiffCommand.build(scope: .log, worktreePath: "/Users/gump/x")
    }
  }

  @Test
  func pathWithSpaceIsPosixQuoted() throws {
    let result = try LargeDiffCommand.build(scope: .staged, worktreePath: "/tmp/with space")
    #expect(result == "cd '/tmp/with space' && git diff --no-color --cached")
  }

  @Test
  func pathWithApostropheIsPosixEscaped() throws {
    // /a/b's/c → 'a/b'\''s/c' (close quote, escape apostrophe, reopen quote).
    let result = try LargeDiffCommand.build(
      scope: .commit(sha: "deadbee"),
      worktreePath: "/a/b's/c"
    )
    #expect(result == "cd '/a/b'\\''s/c' && git show --no-color deadbee")
  }

  @Test
  func pathWithShellMetacharactersIsSafeInsideSingleQuotes() throws {
    // $, backtick, and $(…) are all inert inside POSIX single quotes.
    let result = try LargeDiffCommand.build(
      scope: .working,
      worktreePath: "/tmp/$HOME`whoami`$(ls)"
    )
    #expect(result == "cd '/tmp/$HOME`whoami`$(ls)' && git diff --no-color")
  }

  @Test
  func explicitShaOverridesScopeSha() throws {
    // Belt-and-suspenders: caller who has the SHA handy can pass it separately.
    let result = try LargeDiffCommand.build(
      scope: .commit(sha: "deadbee"),
      worktreePath: "/x",
      sha: "cafef00"
    )
    #expect(result == "cd '/x' && git show --no-color cafef00")
  }

  // MARK: - posixSingleQuote unit tests

  @Test
  func quoteEmptyString() {
    #expect(LargeDiffCommand.posixSingleQuote("") == "''")
  }

  @Test
  func quoteStringWithoutApostrophesIsPlainWrap() {
    #expect(LargeDiffCommand.posixSingleQuote("hello world") == "'hello world'")
  }

  @Test
  func quoteRepeatedApostrophes() {
    // Two apostrophes → two escape sequences.
    #expect(LargeDiffCommand.posixSingleQuote("a'b'c") == "'a'\\''b'\\''c'")
  }
}
