import Foundation

/// Namespaced method constants for the `editor.*` IPC surface. Kept as string constants (not an
/// enum) so the `tc` CLI and the app can compare wire methods without coupling to a Swift enum's
/// rawValue indirection. Request/response envelopes for each method land in M7a.
public nonisolated enum EditorIPCMethod {
  public static let describe = "editor.describe"
  public static let open = "editor.open"
  public static let setDefault = "editor.setDefault"
}
