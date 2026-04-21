import ArgumentParser
import Foundation
import tcKit
import TouchCodeCore
import TouchCodeIPC

/// `tc open [--in <editor>] [--path <path>] [<worktree>]` — launch an
/// external editor against a Worktree directory (or arbitrary `--path`)
/// by calling the app-side `editor.open` RPC.
///
/// The app-side `EditorService` + `editor.*` RPC surface is owned by
/// exec-plan 0005 (C8); this plan ships only the CLI wrapper. Until C8
/// merges, `editor.open` returns `.unsupported` from the router and
/// `tc open` exits with `CLIExitCode.unsupported (4)`.
///
/// Worktree resolution: `<worktree>` goes through `AliasResolver` (UUID,
/// `current`, or — post-M6.1 — `@label` / index / glob). Defaults to
/// `current`; the server's `hierarchy.resolveAlias` interprets `current`
/// as "the Worktree of the selected Project in the selected Space"
/// (see 0003 M6 `HierarchyHandlers.resolveAlias`). Callers running
/// inside a Panel that is *not* currently selected should pass an
/// explicit UUID instead — the CLI has no local binding to its host
/// Panel's Worktree.
///
/// Editor precedence (handled server-side by C8's EditorService):
///  1. `--in` explicit flag on this command.
///  2. `Project.defaultEditor`.
///  3. `Settings.defaultEditorID`.
///  4. Finder fallback (always available).
struct OpenCommand: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "open",
    abstract: "Open a worktree (or arbitrary path) in an external editor."
  )
  @OptionGroup var globals: GlobalOptions
  @Option(
    name: .long,
    help: "Editor id (built-in allowlist: vscode, cursor, zed, xcode, sublime, finder). Omit to use Project/Settings defaults."
  )
  var `in`: String?
  @Option(name: .long, help: "Open an arbitrary path instead of a worktree.")
  var path: String?
  @Argument(help: "Worktree id (UUID or 'current'). Ignored when --path is set.")
  var worktree: String = "current"

  func run() async throws {
    let client = try CLISession.connect(globals: globals)
    defer { Task { await client.shutdown() } }
    do {
      let request = try await Self.buildRequest(
        path: self.path,
        worktree: self.worktree,
        editor: self.in,
        client: client
      )
      let response: EditorOpenResponse = try await client.call(.editorOpen, params: request)
      let rendered = self.path ?? response.worktreePath
      try Renderer.emitObject(
        ["editor": response.choice.displayName, "path": rendered],
        mode: globals.renderMode
      ) { obj in
        "opened \(obj["path"] ?? "?") in \(obj["editor"] ?? "?")"
      }
    } catch {
      CLIError.from(error).exitProcess()
    }
  }

  /// Build the canonical `EditorOpenRequest`. `--path` is threaded through on the optional
  /// `path` field; the server-side `EditorHandlers` validates it lies within the resolved
  /// Worktree. The `<worktree>` alias (default `current`) is always resolved to an UUID so
  /// the server has a base directory for that prefix check even when `--path` is set.
  static func buildRequest(
    path: String?,
    worktree: String,
    editor: String?,
    client: RPCClient
  ) async throws -> EditorOpenRequest {
    let uuid = try await AliasResolver.resolve(worktree, kind: .worktree, client: client)
    return EditorOpenRequest(
      worktreeID: uuid,
      preferred: editor,
      panelID: nil,
      path: (path?.isEmpty == false) ? path : nil
    )
  }
}
