import Foundation

/// Errors surfaced by editor-storage validators. Encoded once here so both the settings UI
/// (inline validation) and the IPC layer (wire-safe codes) can map consistently.
public nonisolated enum EditorTemplateError: Error, Equatable, Sendable {
  case emptyBinary
  case missingDirPlaceholder
  case duplicateDirPlaceholder
  case invalidID(String)
}

extension CommandTemplate {
  /// Enforces the template invariants.
  ///
  /// - `binary` must be non-empty.
  /// - `args` must contain exactly one element that equals `"{dir}"`.
  public func validate() throws {
    if binary.isEmpty { throw EditorTemplateError.emptyBinary }
    let placeholderCount = args.filter { $0 == CommandTemplate.dirPlaceholder }.count
    switch placeholderCount {
    case 0: throw EditorTemplateError.missingDirPlaceholder
    case 1: return
    default: throw EditorTemplateError.duplicateDirPlaceholder
    }
  }
}

extension CustomEditor {
  /// Accepts IDs that match `^[a-z][a-z0-9_-]{1,31}$`. Returns the validated ID (unchanged on
  /// success). Call from the Settings UI before persisting a new custom editor.
  public static func validatedID(_ raw: String) throws -> EditorID {
    let count = raw.count
    guard count >= 2, count <= 32 else {
      throw EditorTemplateError.invalidID(raw)
    }
    var iterator = raw.unicodeScalars.makeIterator()
    guard let first = iterator.next(), Self.isLowerAlpha(first) else {
      throw EditorTemplateError.invalidID(raw)
    }
    while let next = iterator.next() {
      guard Self.isIDContinuation(next) else {
        throw EditorTemplateError.invalidID(raw)
      }
    }
    return raw
  }

  private static func isLowerAlpha(_ scalar: Unicode.Scalar) -> Bool {
    ("a"..."z").contains(scalar)
  }

  private static func isIDContinuation(_ scalar: Unicode.Scalar) -> Bool {
    if ("a"..."z").contains(scalar) { return true }
    if ("0"..."9").contains(scalar) { return true }
    return scalar == "-" || scalar == "_"
  }
}
