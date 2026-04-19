import AppKit
import Foundation
import GhosttyKit

@MainActor
final class GhosttyRuntime {
  struct Info {
    let version: String
    let buildMode: String
  }

  final class CallbackState {
    weak var runtime: GhosttyRuntime?
  }

  private static let globalInit: Int32 = {
    ghostty_init(UInt(CommandLine.argc), CommandLine.unsafeArgv)
  }()

  private(set) var app: ghostty_app_t?
  private var config: ghostty_config_t?
  private let callbackState = CallbackState()

  static var info: Info {
    _ = Self.globalInit
    let raw = ghostty_info()
    let version = (NSString(
      bytes: raw.version,
      length: Int(raw.version_len),
      encoding: NSUTF8StringEncoding
    ) as String?) ?? "unknown"

    let mode: String = switch raw.build_mode {
    case GHOSTTY_BUILD_MODE_DEBUG: "Debug"
    case GHOSTTY_BUILD_MODE_RELEASE_SAFE: "ReleaseSafe"
    case GHOSTTY_BUILD_MODE_RELEASE_FAST: "ReleaseFast"
    case GHOSTTY_BUILD_MODE_RELEASE_SMALL: "ReleaseSmall"
    default: "Unknown"
    }
    return Info(version: version, buildMode: mode)
  }

  init() throws {
    _ = Self.globalInit
    guard let config = ghostty_config_new() else {
      throw GhosttyError.configInitFailed
    }
    ghostty_config_load_default_files(config)
    ghostty_config_load_recursive_files(config)
    ghostty_config_finalize(config)
    self.config = config

    callbackState.runtime = self
    var runtimeConfig = ghostty_runtime_config_s(
      userdata: Unmanaged.passRetained(callbackState).toOpaque(),
      supports_selection_clipboard: false,
      wakeup_cb: { _ in },
      action_cb: { _, _, _ in false },
      read_clipboard_cb: { _, _, _ in false },
      confirm_read_clipboard_cb: { _, _, _, _ in },
      write_clipboard_cb: { _, _, _, _, _ in },
      close_surface_cb: { _, _ in }
    )

    guard let app = ghostty_app_new(&runtimeConfig, config) else {
      throw GhosttyError.appInitFailed
    }
    self.app = app
  }

  isolated deinit {
    if let app {
      ghostty_app_free(app)
    }
    if let config {
      ghostty_config_free(config)
    }
    let handle = Unmanaged.passUnretained(callbackState).toOpaque()
    DispatchQueue.main.async {
      Unmanaged<CallbackState>.fromOpaque(handle).release()
    }
  }
}

enum GhosttyError: Error, Equatable, Sendable {
  case configInitFailed
  case appInitFailed
}
