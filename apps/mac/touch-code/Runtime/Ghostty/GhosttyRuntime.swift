import AppKit
import Foundation
import GhosttyKit
import SwiftUI
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

  /// Back-reference to the engine whose event stream surfaces action decoder
  /// emits (`panelInfoChanged`, `panelActionRequested`, etc.). Weak to
  /// avoid a retain cycle with `TerminalEngine.ghosttyRuntime`; the engine
  /// outlives the runtime in every supported configuration, so a dangling
  /// reference is a bug elsewhere.
  weak var terminalEngine: TerminalEngine?

  /// Last resolved color scheme applied via `setColorScheme(_:)`. Newly registered
  /// surfaces adopt this on registration so a panel opened mid-session starts in the
  /// correct palette without waiting for the next toggle.
  private var lastColorScheme: ghostty_color_scheme_e?

  /// Retained observer token for `.ghosttyRuntimeReloadRequested`. Removed in deinit so
  /// the closure can't race a freed runtime after the app shuts down.
  private var reloadObserver: NSObjectProtocol?

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

    // Subscribe to config-file writes from `GhosttyConfigFile.apply`; we re-parse from
    // disk and push the new config into libghostty. Using a weak capture avoids a
    // retain cycle through the default NotificationCenter.
    self.reloadObserver = NotificationCenter.default.addObserver(
      forName: .ghosttyRuntimeReloadRequested,
      object: nil,
      queue: .main
    ) { [weak self] _ in
      MainActor.assumeIsolated {
        self?.reloadAppConfig()
      }
    }
  }

  isolated deinit {
    if let reloadObserver {
      NotificationCenter.default.removeObserver(reloadObserver)
    }

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
    // A surface registered mid-session inherits the most recently applied scheme so
    // the palette matches the app's current appearance from its first frame.
    if let lastColorScheme {
      panel.applyColorScheme(lastColorScheme)
    }
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

  // MARK: - Appearance

  /// Applies a color scheme signal to libghostty — tells Ghostty which of its two
  /// configured palettes (light / dark) to render. Cheap, in-memory, synchronous.
  /// Invoked on every app appearance change (user picker toggle, OS dark-mode flip).
  /// Distinct from `reloadAppConfig()`: no file I/O, no config re-parse.
  func setColorScheme(_ scheme: SwiftUI.ColorScheme) {
    guard let app else { return }
    let ghosttyScheme: ghostty_color_scheme_e =
      scheme == .dark ? GHOSTTY_COLOR_SCHEME_DARK : GHOSTTY_COLOR_SCHEME_LIGHT
    lastColorScheme = ghosttyScheme
    ghostty_app_set_color_scheme(app, ghosttyScheme)
    for panel in surfacesByPanelID.values {
      panel.applyColorScheme(ghosttyScheme)
    }
  }

  /// Triggered by `.ghosttyRuntimeReloadRequested`, which `GhosttyConfigFile.apply`
  /// posts after writing the managed region of the user's Ghostty config. Delegates
  /// to `reloadConfig(soft:)`, the shared primitive used by the action-decoder path
  /// — keeping one implementation of the "rebuild from disk" behaviour.
  func reloadAppConfig() {
    reloadConfig(soft: false)
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
    _, target, action in
    // libghostty may invoke action_cb on a non-main thread. We must decode
    // the payload *here*, synchronously — several action tags
    // (SET_TITLE / PWD / MOUSE_OVER_LINK / START_SEARCH / OPEN_URL /
    // DESKTOP_NOTIFICATION / KEY_TABLE / CONFIG_CHANGE) carry C pointers
    // borrowed from libghostty for the duration of the callback; if we
    // defer the read to a later main-queue hop those pointers are dangling.
    //
    // Decode converts everything to owned Swift values (copied Strings +
    // a cloned `ghostty_config_t` for CONFIG_CHANGE) and reports the
    // "consumed" verdict synchronously, so the C return value always
    // matches what the applier will do — no more false-return-but-
    // applied races.
    if ProcessInfo.processInfo.environment["TOUCH_CODE_DISABLE_ACTION_ROUTING"] == "1" {
      return false
    }

    let targetTag = target.tag
    let surface: ghostty_surface_t? = targetTag == GHOSTTY_TARGET_SURFACE ? target.target.surface : nil
    // PanelID is only meaningful for surface-scoped actions. We need it to
    // emit panelActionRequested / windowActionRequested from the right
    // panel, and it must be resolved here while userdata is valid.
    let panelID: PanelID? = surface.flatMap { GhosttyRuntime.panelIDBytes(fromSurface: $0) }

    switch targetTag {
    case GHOSTTY_TARGET_APP:
      let decoded = GhosttyActionDecoder.decodeAppAction(action)
      let consumed = decoded.consumed
      if Thread.isMainThread {
        return MainActor.assumeIsolated {
          _ = GhosttyRuntime.shared?.applyAppAction(decoded)
          return consumed
        }
      }
      DispatchQueue.main.async {
        MainActor.assumeIsolated {
          _ = GhosttyRuntime.shared?.applyAppAction(decoded)
        }
      }
      return consumed

    case GHOSTTY_TARGET_SURFACE:
      guard let panelID else { return false }
      let decoded = GhosttyActionDecoder.decodeSurfaceAction(action, panelID: panelID)
      let consumed = decoded.consumed
      if Thread.isMainThread {
        return MainActor.assumeIsolated {
          _ = GhosttyRuntime.shared?.applySurfaceAction(decoded, panelID: panelID)
          return consumed
        }
      }
      DispatchQueue.main.async {
        MainActor.assumeIsolated {
          _ = GhosttyRuntime.shared?.applySurfaceAction(decoded, panelID: panelID)
        }
      }
      return consumed

    default:
      return false
    }
  }

  // MARK: - Action apply (MainActor — consumes decoded Swift values)

  @MainActor
  fileprivate func applyAppAction(_ decoded: DecodedAppAction) -> Bool {
    GhosttyActionDecoder.apply(decoded, runtime: self)
  }

  @MainActor
  fileprivate func applySurfaceAction(_ decoded: DecodedSurfaceAction, panelID: PanelID) -> Bool {
    guard let panel = surfacesByPanelID[panelID] else { return false }
    return GhosttyActionDecoder.apply(decoded, panelID: panelID, panel: panel, runtime: self)
  }

  /// Copy the PanelID uuid bytes out of libghostty-stored userdata. Same
  /// pattern as `closeSurfaceCallback` — UAF-safe because userdata points
  /// to a 16-byte allocation owned by `PanelSurface` for the surface's
  /// lifetime; we only read the bytes, never the owning Swift object.
  /// `nonisolated` so the C callback thunk can resolve the PanelID on
  /// whatever thread libghostty invokes us (the read is a pure byte copy).
  nonisolated static func panelIDBytes(fromSurface surface: ghostty_surface_t) -> PanelID? {
    guard let raw = ghostty_surface_userdata(surface) else { return nil }
    var bytes = uuid_t(0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)
    withUnsafeMutableBytes(of: &bytes) { dst in
      _ = dst.baseAddress.map { base in
        base.copyMemory(from: raw, byteCount: MemoryLayout<uuid_t>.size)
      }
    }
    return PanelID(raw: UUID(uuid: bytes))
  }

  // MARK: - Event emission

  /// Lift a decoded event onto the engine's `TerminalEvent` stream.
  /// No-op if the engine hasn't been wired yet (engine-less headless tests).
  @MainActor
  func emit(_ event: TerminalEvent) {
    terminalEngine?.emit(event)
  }

  /// Convenience for the info-delta family, which always travels as
  /// `panelInfoChanged(panelID, delta)`.
  @MainActor
  func emitInfoChanged(_ panelID: PanelID, _ delta: PanelInfoDelta) {
    emit(.panelInfoChanged(panelID, delta))
  }

  // MARK: - Config mutation

  /// Atomically replace the current `ghostty_config_t` with the cloned
  /// handle libghostty hands us via `CONFIG_CHANGE`. The old handle is
  /// freed after replacement; live surfaces keep rendering against their
  /// existing snapshots until ghostty re-applies.
  @MainActor
  func applyClonedConfig(_ cloned: ghostty_config_t) {
    let old = config
    config = cloned
    if let old { ghostty_config_free(old) }
  }

  /// Rebuild the config handle from disk. `soft` is forwarded for parity
  /// with libghostty's semantics; our rebuild is the same either way
  /// (load defaults → load recursive → finalize → swap).
  @MainActor
  func reloadConfig(soft: Bool) {
    _ = soft
    guard let fresh = ghostty_config_new() else { return }
    ghostty_config_load_default_files(fresh)
    ghostty_config_load_recursive_files(fresh)
    ghostty_config_finalize(fresh)
    applyClonedConfig(fresh)
  }

  /// Placeholder for `GHOSTTY_ACTION_TOGGLE_BACKGROUND_OPACITY`. Lands when
  /// the appearance layer owns an opacity override; logged for now so the
  /// keybind is observable.
  @MainActor
  func toggleBackgroundOpacity() {
    // Intentionally empty — opacity is a setting surface (DeveloperSettings
    // or appearance override) that this runtime does not yet own.
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

extension Notification.Name {
  /// Posted by `GhosttyConfigFile.apply` after writing the managed region of
  /// `~/.config/ghostty/config`. `GhosttyRuntime` listens and re-parses the config so
  /// running surfaces pick up the new theme / font without an app restart.
  static let ghosttyRuntimeReloadRequested = Notification.Name("ghosttyRuntimeReloadRequested")
}
