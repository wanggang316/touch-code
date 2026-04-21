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
    let version =
      (NSString(
        bytes: raw.version,
        length: Int(raw.version_len),
        encoding: NSUTF8StringEncoding
      ) as String?) ?? "unknown"

    let mode: String =
      switch raw.build_mode {
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

  /// Process-global weak reference used by C callback shims that hop through
  /// DispatchQueue.main.async — the original dispatcher userdata may point
  /// to freed memory by the time the async block runs, so we go through the
  /// MainActor-isolated static instead. Only one GhosttyRuntime exists per
  /// process; init/deinit set and clear this.
  nonisolated(unsafe) static weak var shared: GhosttyRuntime?

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
    Self.shared = self
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

  private static let actionCallback: (@convention(c) (ghostty_app_t?, ghostty_target_s, ghostty_action_s) -> Bool) = {
    _, _, _ in
    // Real routing lands with the action-dispatch seam in M5.2+; until then
    // no app-level action is consumed and ghostty gets to keep default
    // handling.
    false
  }

  /// close_surface_cb receives the SURFACE's userdata, which we set at
  /// creation to the raw bytes of the owning `PanelID.raw.uuid`. We avoid
  /// casting to a `PanelSurface` pointer because the callback hops through
  /// `DispatchQueue.main.async`: if the engine drops the PanelSurface on
  /// the main thread between the C call and the async block, the opaque
  /// pointer would reference freed memory.
  ///
  /// PanelID lookup via the runtime registry is UAF-safe — the registry
  /// maps a PanelID (value type) to a live PanelSurface, and if the panel
  /// was already unregistered the lookup returns nil and we no-op.
  private static let closeSurfaceCallback: (@convention(c) (UnsafeMutableRawPointer?, Bool) -> Void) = {
    userdata, processAlive in
    guard let userdata else { return }
    // Copy the UUID bytes out of the userdata payload now, before hopping
    // to main — the memory may be freed if the PanelSurface is dropped.
    var uuidBytes = uuid_t(0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)
    withUnsafeMutableBytes(of: &uuidBytes) { dst in
      _ = dst.baseAddress.map { base in
        base.copyMemory(from: userdata, byteCount: MemoryLayout<uuid_t>.size)
      }
    }
    let panelID = PanelID(raw: UUID(uuid: uuidBytes))
    DispatchQueue.main.async {
      MainActor.assumeIsolated {
        guard let panel = GhosttyRuntime.shared?.surface(for: panelID) else { return }
        panel.requestClose(processAlive: processAlive)
      }
    }
  }
}

enum GhosttyError: Error, Equatable, Sendable {
  case configInitFailed
  case appInitFailed
  case surfaceInitFailed
}
