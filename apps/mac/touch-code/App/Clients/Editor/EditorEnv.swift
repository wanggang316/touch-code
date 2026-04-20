import Foundation

/// Environment construction for every editor subprocess. Symmetric with
/// `touch-code/Git/GitProcessEnv.swift`: allowlist of three keys (`PATH`, `HOME`, forced
/// `LC_ALL=C.UTF-8`) and a forbidden set for keys that could influence a GUI editor or
/// leak unrelated context.
///
/// `SHELL` is explicitly in `forbidden`, not in `allowlist` — aligned with C8 design v2.
nonisolated enum EditorEnv {
  static let allowlist: [String] = ["PATH", "HOME"]
  static let forced: [String: String] = ["LC_ALL": "C.UTF-8"]
  static let forbidden: Set<String> = [
    "SHELL",
    "EDITOR",
    "VISUAL",
    "GIT_DIR",
    "GIT_CONFIG",
    "GIT_CONFIG_SYSTEM",
    "GIT_CONFIG_GLOBAL",
    "GIT_ASKPASS",
    "JAVA_TOOL_OPTIONS",
  ]

  static func build(from parent: [String: String] = ProcessInfo.processInfo.environment) -> [String: String] {
    var env: [String: String] = [:]
    for key in allowlist {
      if let value = parent[key] { env[key] = value }
    }
    for (key, value) in forced { env[key] = value }
    #if DEBUG
    for key in forbidden {
      precondition(env[key] == nil, "EditorEnv: forbidden key '\(key)' leaked into child env")
    }
    #endif
    return env
  }
}
