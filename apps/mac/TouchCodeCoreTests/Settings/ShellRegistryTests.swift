import Foundation
import Testing

@testable import TouchCodeCore

/// `ShellRegistry` reads `/etc/shells` and filters by file existence. The
/// real-filesystem path is not a useful test surface (the result depends on
/// the host machine); these tests exercise the parser directly through a
/// temp file so behaviour is deterministic.
struct ShellRegistryTests {
  @Test
  func parserDropsCommentsBlankLinesAndMissingBinaries() throws {
    let tmp = FileManager.default.temporaryDirectory
      .appending(component: "etc-shells-\(UUID().uuidString)")
    let content = """
      # macOS default shells

      /bin/zsh
      /bin/bash
      /opt/homebrew/bin/fish
      """
    try content.write(to: tmp, atomically: true, encoding: .utf8)
    defer { try? FileManager.default.removeItem(at: tmp) }

    let result = ShellRegistry.readEtcShells(at: tmp.path, fileManager: FileManager.default)
    // /bin/zsh is always present on a macOS host. /opt/homebrew/bin/fish may
    // or may not exist; the test asserts only that the parser keeps real
    // entries and never returns the comment / blank lines.
    #expect(result.contains("/bin/zsh"))
    #expect(!result.contains(""))
    #expect(!result.contains { $0.hasPrefix("#") })
  }

  @Test
  func parserReturnsEmptyForMissingFile() {
    let missing = "/tmp/does-not-exist-\(UUID().uuidString)"
    let result = ShellRegistry.readEtcShells(at: missing, fileManager: FileManager.default)
    #expect(result.isEmpty)
  }

  @Test
  func fixedProviderReturnsListVerbatim() {
    let provider = ShellRegistry.Provider.fixed(["/bin/zsh", "/bin/bash"])
    #expect(ShellRegistry.installed(via: provider) == ["/bin/zsh", "/bin/bash"])
  }
}
