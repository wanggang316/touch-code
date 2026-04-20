import Darwin
import Foundation

/// Shared path convention for the touch-code Unix domain socket.
///
/// Centralises the default-path-vs-env-override precedence so both the
/// app-side `SocketServer` and the CLI-side `SocketDiscovery` (M4) agree on
/// exactly one place. No inline `getuid()` calls elsewhere.
public enum SocketPaths {
  /// `/tmp/touch-code-<uid>.sock` — the canonical default.
  public static func defaultSocketPath(uid: uid_t = getuid()) -> String {
    "/tmp/touch-code-\(uid).sock"
  }

  /// Resolve the socket path, preferring `$TOUCH_CODE_SOCKET_PATH` if set
  /// and non-empty, otherwise falling back to `defaultSocketPath()`.
  public static func resolve(
    override: String? = ProcessInfo.processInfo.environment["TOUCH_CODE_SOCKET_PATH"]
  ) -> String {
    if let override, !override.isEmpty { return override }
    return defaultSocketPath()
  }
}
