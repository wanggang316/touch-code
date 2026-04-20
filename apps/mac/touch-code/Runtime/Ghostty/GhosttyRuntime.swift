import AppKit
import Foundation
import GhosttyKit
import TouchCodeCore

/// Process-global libghostty façade. Owns one `ghostty_app_t` and the runtime
/// config whose callbacks route via a user-data pointer back to a weak
/// reference to `self`. Surface-scoped callbacks (`close_surface_cb`) use a
/// separate per-surface userdata (the `PanelSurface` pointer) so the
/// callback can route directly to the owning panel without a registry
/// lookup on the hot path.
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

    /// App-level: libghostty wants us to tick it soon.
    var onWakeup: (@MainActor () -> Void)?
    /// App-level: libghostty action; return true if consumed.
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

  /// Registered panel surfaces by PanelID. Referenced by engine code that
  /// needs to look up a surface from a Panel (e.g. lazy surface creation on
  /// tab activation). Surface-scoped callbacks do NOT use this table on the
  /// hot path — they cast the per-surface userdata directly to `PanelSurface`.
  private var surfacesByPanelID: [PanelID: PanelSurface] = [:]

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
    for (_, panel) in surfacesByPanelID {
      panel.close()
    }
    surfacesByPanelID.removeAll()

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

  // MARK: - Surface registry

  func register(panel: PanelSurface) {
    surfacesByPanelID[panel.panelID] = panel
  }

  func unregister(panelID: PanelID) {
    surfacesByPanelID.removeValue(forKey: panelID)
  }

  func surface(for panelID: PanelID) -> PanelSurface? {
    surfacesByPanelID[panelID]
  }

  func tick() {
    guard let app else { return }
    ghostty_app_tick(app)
  }

  // MARK: - C callback shims

  private static let wakeupCallback: (@convention(c) (UnsafeMutableRawPointer?) -> Void) = { userdata in
    guard let userdata else { return }
    let dispatcher = Unmanaged<CallbackDispatcher>.fromOpaque(userdata).takeUnretainedValue()
    DispatchQueue.main.async {
      dispatcher.onWakeup?()
    }
  }

  private static let actionCallback: (@convention(c) (ghostty_app_t?, ghostty_target_s, ghostty_action_s) -> Bool) = { _, _, _ in
    // Real routing lands with the action-dispatch seam in M5.2+; until then
    // no app-level action is consumed and ghostty gets to keep default
    // handling.
    false
  }

  /// close_surface_cb receives the SURFACE's userdata (set via
  /// ghostty_surface_config_s.userdata), which we use as an opaque pointer
  /// to the owning `PanelSurface`. Safe to unretained because PanelSurface
  /// outlives its ghostty_surface_t (panel's close() frees the surface
  /// before PanelSurface deinit runs).
  private static let closeSurfaceCallback: (@convention(c) (UnsafeMutableRawPointer?, Bool) -> Void) = { userdata, processAlive in
    guard let userdata else { return }
    let handle = UInt(bitPattern: userdata)
    DispatchQueue.main.async {
      guard let rebuilt = UnsafeMutableRawPointer(bitPattern: handle) else { return }
      let panel = Unmanaged<PanelSurface>.fromOpaque(rebuilt).takeUnretainedValue()
      panel.requestClose(processAlive: processAlive)
    }
  }
}

enum GhosttyError: Error, Equatable, Sendable {
  case configInitFailed
  case appInitFailed
}
