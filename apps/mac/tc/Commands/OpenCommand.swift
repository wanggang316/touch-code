import ArgumentParser
import Foundation
import tcKit
import TouchCodeCore
import TouchCodeIPC

/// `tc open [--in <editor>] [<worktree>]` — launch an external editor
/// against a Worktree directory, or against an arbitrary `--path`.
///
/// Resolves product-spec Q7 per C4 D14:
/// - `<worktree>` is resolved through `AliasResolver` ('current', UUID,
///   @label, or index — UUID / current ship in M6, extended forms in
///   M6.1).
/// - `--in <editor>` picks from the built-in allowlist (vscode / cursor
///   / zed / xcode / subl / finder). Omit to fall through
///   `Project.defaultEditor` → the Finder fallback.
/// - `--path <path>` bypasses the hierarchy and opens an arbitrary
///   directory; useful outside a touch-code session.
struct OpenCommand: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "open",
    abstract: "Open a worktree (or arbitrary path) in an external editor."
  )
  @OptionGroup var globals: GlobalOptions
  @Option(name: .long, help: "Editor id: vscode, cursor, zed, xcode, subl, finder.")
  var `in`: String?
  @Option(name: .long, help: "Open an arbitrary path instead of a worktree.")
  var path: String?
  @Argument(help: "Worktree id (UUID or 'current'). Defaults to 'current'.")
  var worktree: String = "current"

  func run() async throws {
    if let path, !path.isEmpty {
      try await runOpenPath(path)
    } else {
      try await runOpenWorktree(worktree)
    }
  }

  private func runOpenPath(_ path: String) async throws {
    let client = try CLISession.connect(globals: globals)
    defer { Task { await client.shutdown() } }
    do {
      struct Params: Codable { let path: String; let editor: String? }
      struct Result: Codable { let editor: String; let path: String; let exitStatus: Int32 }
      let result: Result = try await client.call(
        .systemOpenPath,
        params: Params(path: path, editor: self.in)
      )
      try Renderer.emitObject(
        ["editor": result.editor, "path": result.path, "exitStatus": Int(result.exitStatus)],
        mode: globals.renderMode
      ) { obj in
        "opened \(obj["path"] ?? "?") in \(obj["editor"] ?? "?")"
      }
    } catch {
      CLIError.from(error).exitProcess()
    }
  }

  private func runOpenWorktree(_ worktree: String) async throws {
    let client = try CLISession.connect(globals: globals)
    defer { Task { await client.shutdown() } }
    do {
      let uuid = try await AliasResolver.resolve(worktree, kind: .worktree, client: client)
      struct Params: Codable { let worktreeID: WorktreeID; let editor: String? }
      struct Result: Codable { let editor: String; let path: String; let exitStatus: Int32 }
      let result: Result = try await client.call(
        .systemOpenInEditor,
        params: Params(worktreeID: WorktreeID(raw: uuid), editor: self.in)
      )
      try Renderer.emitObject(
        ["editor": result.editor, "path": result.path, "exitStatus": Int(result.exitStatus)],
        mode: globals.renderMode
      ) { obj in
        "opened \(obj["path"] ?? "?") in \(obj["editor"] ?? "?")"
      }
    } catch {
      CLIError.from(error).exitProcess()
    }
  }
}
