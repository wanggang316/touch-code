import AppKit
import Foundation
import GhosttyKit
import TouchCodeCore

/// Process-global libghostty façade. Owns one `ghostty_app_t` and the runtime
/// config whose callbacks route via a user-data pointer back to a weak
/// reference to `self`. Callback plumbing matches supaterm's pattern so M5's
/// `PanelSurface` can subclass the seam without rewriting init.
@MainActor
final class GhosttyRuntime {
  struct Info {
    let version: String
    let buildMode: String
  }

  /// Strong handle bridging the C callback userdata pointer back to an
  /// instance-isolated dispatcher. Lives behind an Unmanaged retain until
  /// deinit releases it on the next main-queue turn.
  final class CallbackDispatcher {
    weak var runtime: GhosttyRuntime?

    /// Called from `wakeup_cb`. libghostty asks us to tick it soon.
    var onWakeup: (@MainActor () -> Void)?
    /// Called from `close_surface_cb`. `processAlive` is true when the
    /// surface closed cleanly with a running child (user initiated).
    var onSurfaceCloseRequested: (@MainActor (UnsafeMutableRawPointer?, Bool) -> Void)?
    /// Called from `action_cb`. Return `true` if the action was consumed.
    var onAction: (@MainActor (ghostty_app_t, ghostty_target_s, ghostty_action_s) -> Bool)?
  }

  static var info: Info {
    _ = GhosttyBootstrap.initialize
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

  private(set) var app: ghostty_app_t?
  private var config: ghostty_config_t?
  let dispatcher = CallbackDispatcher()

  /// Registered panel surfaces. ghostty_surface_config_s.userdata carries a
  /// pointer to the PanelSurface's hosting view; we maintain a parallel
  /// table so callbacks reaching the dispatcher can resolve back to the
  /// owning PanelID without touching raw pointers from C.
  private var surfacesByPanelID: [PanelID: PanelSurface] = [:]

  func register(panel: PanelSurface) {
    surfacesByPanelID[panel.panelID] = panel
  }

  func unregister(panelID: PanelID) {
    surfacesByPanelID.removeValue(forKey: panelID)
  }

  func surface(for panelID: PanelID) -> PanelSurface? {
    surfacesByPanelID[panelID]
  }

  /// Returns the PanelSurface hosted by the NSView at `userdata`, if any.
  /// Used by callback paths that receive the raw nsview pointer from
  /// ghostty_platform_macos_s.nsview.
  func surface(forNSViewPointer pointer: UnsafeMutableRawPointer?) -> PanelSurface? {
    guard let pointer else { return nil }
    for panel in surfacesByPanelID.values where panel.viewPointer == pointer {
      return panel
    }
    return nil
  }

  /// Call every 16ms while there are live surfaces. Safe to over-call —
  /// ghostty_app_tick is a cheap no-op when nothing is queued.
  func tick() {
    guard let app else { return }
    ghostty_app_tick(app)
  }

  init() throws {
    _ = GhosttyBootstrap.initialize

    guard let config = ghostty_config_new() else {
      throw GhosttyError.configInitFailed
    }
    ghostty_config_load_default_files(config)
    ghostty_config_load_recursive_files(config)
    ghostty_config_finalize(config)
    self.config = config

    dispatcher.runtime = self
    let userdata = Unmanaged.passRetained(dispatcher).toOpaque()
    var runtimeConfig = ghostty_runtime_config_s(
      userdata: userdata,
      supports_selection_clipboard: false,
      wakeup_cb: Self.wakeupCallback,
      action_cb: Self.actionCallback,
      read_clipboard_cb: { _, _, _ in false },
      confirm_read_clipboard_cb: { _, _, _, _ in },
      write_clipboard_cb: { _, _, _, _, _ in },
      close_surface_cb: Self.closeSurfaceCallback
    )

    guard let app = ghostty_app_new(&runtimeConfig, config) else {
      Unmanaged<CallbackDispatcher>.fromOpaque(userdata).release()
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
    let handle = Unmanaged.passUnretained(dispatcher).toOpaque()
    DispatchQueue.main.async {
      Unmanaged<CallbackDispatcher>.fromOpaque(handle).release()
    }
  }

  // MARK: - C callback shims
  //
  // Each shim receives the userdata pointer, converts it back to the
  // strongly-held `CallbackDispatcher`, then hops to the MainActor and
  // invokes the closure set on the dispatcher. This keeps the C-convention
  // boundary pure and routes all ghostty events through a single seam.

  private static let wakeupCallback: (@convention(c) (UnsafeMutableRawPointer?) -> Void) = { userdata in
    guard let userdata else { return }
    let dispatcher = Unmanaged<CallbackDispatcher>.fromOpaque(userdata).takeUnretainedValue()
    DispatchQueue.main.async {
      dispatcher.onWakeup?()
    }
  }

  private static let actionCallback: (@convention(c) (ghostty_app_t?, ghostty_target_s, ghostty_action_s) -> Bool) = { _, _, _ in
    // Real routing lands with M5 surface integration; until then no action is consumed.
    false
  }

  private static let closeSurfaceCallback: (@convention(c) (UnsafeMutableRawPointer?, Bool) -> Void) = { userdata, processAlive in
    guard let userdata else { return }
    let dispatcher = Unmanaged<CallbackDispatcher>.fromOpaque(userdata).takeUnretainedValue()
    let surfaceHandle = UInt(bitPattern: userdata)
    DispatchQueue.main.async {
      let rebuilt = UnsafeMutableRawPointer(bitPattern: surfaceHandle)
      dispatcher.onSurfaceCloseRequested?(rebuilt, processAlive)
    }
  }
}

enum GhosttyError: Error, Equatable, Sendable {
  case configInitFailed
  case appInitFailed
}
