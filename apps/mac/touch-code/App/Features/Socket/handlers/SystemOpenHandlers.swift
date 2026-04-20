import Foundation
import TouchCodeCore
import TouchCodeIPC

/// Handlers for `system.openInEditor` + `system.openPath`. Thin wrapper
/// around `ExternalEditor`.
@MainActor
final class SystemOpenHandlers {
  private let editor: ExternalEditor

  init(editor: ExternalEditor) {
    self.editor = editor
  }

  public struct OpenInEditorParams: Codable, Sendable {
    public let worktreeID: WorktreeID
    public let editor: String?
  }

  public struct OpenPathParams: Codable, Sendable {
    public let path: String
    public let editor: String?
  }

  public struct OpenResult: Codable, Sendable {
    public let editor: String
    public let path: String
    public let exitStatus: Int32
  }

  public func openInEditor(_ params: JSONValue) async -> RouterOutcome {
    await Task.yield()
    let req: OpenInEditorParams
    do {
      req = try params.decoded(as: OpenInEditorParams.self)
    } catch {
      return .failed(.invalidParams(message: "openInEditor requires {worktreeID, editor?}", path: nil))
    }
    do {
      let result = try await editor.open(worktreeID: req.worktreeID, editor: req.editor)
      return .unary(try JSONValue.encoded(OpenResult(
        editor: result.editor,
        path: result.path,
        exitStatus: result.exitStatus
      )))
    } catch let err as ExternalEditor.OpenError {
      return Self.mapError(err)
    } catch {
      return .failed(.internal("openInEditor: \(error)"))
    }
  }

  public func openPath(_ params: JSONValue) async -> RouterOutcome {
    await Task.yield()
    let req: OpenPathParams
    do {
      req = try params.decoded(as: OpenPathParams.self)
    } catch {
      return .failed(.invalidParams(message: "openPath requires {path, editor?}", path: nil))
    }
    do {
      let result = try await editor.openPath(req.path, editor: req.editor)
      return .unary(try JSONValue.encoded(OpenResult(
        editor: result.editor,
        path: result.path,
        exitStatus: result.exitStatus
      )))
    } catch let err as ExternalEditor.OpenError {
      return Self.mapError(err)
    } catch {
      return .failed(.internal("openPath: \(error)"))
    }
  }

  private static func mapError(_ err: ExternalEditor.OpenError) -> RouterOutcome {
    switch err {
    case .worktreeNotFound(let id):
      return .failed(.notFound(kind: "worktree", id: id.description))
    case .unknownEditor(let name):
      return .failed(.unsupported(reason: "unknown editor: \(name) (allowed: vscode/cursor/zed/xcode/subl/finder)"))
    case .binaryNotFound(let exe):
      return .failed(.notFound(kind: "executable", id: exe))
    case .spawnFailed(let status, _):
      return .failed(.internal("editor exited with status \(status)"))
    }
  }
}
