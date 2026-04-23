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
  private var appFocusObservers: [NSObjectProtocol] = []

  /// Back-reference to the engine whose event stream surfaces action decoder
  /// emits (`panelInfoChanged`, `panelActionRequested`, etc.). Weak to
  /// avoid a retain cycle with `TerminalEngine.ghosttyRuntime`; the engine
  /// outlives the runtime in every supported configuration, so a dangling
  /// reference is a bug elsewhere.
  weak var terminalEngine: TerminalEngine?

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
    // libghostty signals "I have work pending; please call ghostty_app_tick
    // soon" via wakeup_cb. Without a real handler the action queue, new-
    // surface shell fork, keybind dispatch, and mouse state all stall.
    // The wakeup shim hops to main; tick on the MainActor here.
    dispatcher.onWakeup = { [weak self] in
      self?.tick()
    }
    let userdata = Unmanaged.passRetained(dispatcher).toOpaque()
    var runtimeConfig = ghostty_runtime_config_s(
      userdata: userdata,
      supports_selection_clipboard: true,
      wakeup_cb: Self.wakeupCallback,
      action_cb: Self.actionCallback,
      read_clipboard_cb: Self.readClipboardCallback,
      confirm_read_clipboard_cb: Self.confirmReadClipboardCallback,
      write_clipboard_cb: Self.writeClipboardCallback,
      close_surface_cb: Self.closeSurfaceCallback
    )

    guard let app = ghostty_app_new(&runtimeConfig, config) else {
      Unmanaged<CallbackDispatcher>.fromOpaque(userdata).release()
      throw GhosttyError.appInitFailed
    }
    self.app = app
    Self.shared = self

    // App-level focus notifications. libghostty gates some global behavior
    // (e.g. bell, bracketed-paste toasts) on app focus; without these the
    // runtime thinks the app is always backgrounded.
    let center = NotificationCenter.default
    appFocusObservers.append(
      center.addObserver(
        forName: NSApplication.didBecomeActiveNotification,
        object: nil,
        queue: .main
      ) { [weak self] _ in
        MainActor.assumeIsolated {
          guard let app = self?.app else { return }
          ghostty_app_set_focus(app, true)
        }
      }
    )
    appFocusObservers.append(
      center.addObserver(
        forName: NSApplication.didResignActiveNotification,
        object: nil,
        queue: .main
      ) { [weak self] _ in
        MainActor.assumeIsolated {
          guard let app = self?.app else { return }
          ghostty_app_set_focus(app, false)
        }
      }
    )
    // Initialise to the current state so a runtime created after the app has
    // already activated doesn't start out "unfocused".
    ghostty_app_set_focus(app, NSApp.isActive)
  }

  isolated deinit {
    let center = NotificationCenter.default
    for observer in appFocusObservers {
      center.removeObserver(observer)
    }
    appFocusObservers.removeAll()

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

    GhosttyActionDecoder.logger.debug(
      "action_cb fired: targetTag=\(targetTag.rawValue, privacy: .public) tag=\(action.tag.rawValue, privacy: .public)"
    )

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
    return panelID(fromRawUserdata: raw)
  }

  /// Read 16 uuid_t bytes from a raw userdata pointer. Used by clipboard
  /// and close callbacks that receive surface-userdata directly.
  nonisolated static func panelID(fromRawUserdata raw: UnsafeMutableRawPointer) -> PanelID {
    var bytes = uuid_t(0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)
    withUnsafeMutableBytes(of: &bytes) { dst in
      _ = dst.baseAddress.map { base in
        base.copyMemory(from: raw, byteCount: MemoryLayout<uuid_t>.size)
      }
    }
    return PanelID(raw: UUID(uuid: bytes))
  }

  // MARK: - Clipboard callbacks

  /// Map ghostty's clipboard enum to the AppKit pasteboard. We route
  /// SELECTION to a dedicated named pasteboard the way mitchellh/ghostty
  /// does so OSC52 "selection" writes don't clobber the user's general
  /// clipboard.
  @MainActor static func pasteboard(for clipboard: ghostty_clipboard_e) -> NSPasteboard? {
    switch clipboard {
    case GHOSTTY_CLIPBOARD_STANDARD:
      return NSPasteboard.general
    case GHOSTTY_CLIPBOARD_SELECTION:
      return ghosttySelectionPasteboard
    default:
      return nil
    }
  }

  // Named selection pasteboard so SELECTION writes don't clobber the
  // user's general clipboard. `@MainActor` keeps concurrency happy — all
  // our clipboard code hops through MainActor before touching it.
  @MainActor private static let ghosttySelectionPasteboard: NSPasteboard = {
    NSPasteboard(name: .init("com.mitchellh.ghostty.selection"))
  }()

  /// Read clipboard on libghostty's behalf. Must return synchronously;
  /// if not on the main thread we hop via `DispatchQueue.main.sync`.
  /// The reported `state` pointer is opaque — must be handed back to
  /// `ghostty_surface_complete_clipboard_request` unchanged.
  private static let readClipboardCallback:
    (@convention(c) (UnsafeMutableRawPointer?, ghostty_clipboard_e, UnsafeMutableRawPointer?) -> Bool) = {
      userdata, location, state in
      guard let userdata else { return false }
      let panelID = panelID(fromRawUserdata: userdata)
      let stateBits = state.map { UInt(bitPattern: $0) }
      let complete: @MainActor () -> Bool = {
        guard let panel = GhosttyRuntime.shared?.surface(for: panelID) else { return false }
        guard let pb = pasteboard(for: location),
          let text = pb.string(forType: .string)
        else { return false }
        let stateBack = stateBits.flatMap { UnsafeMutableRawPointer(bitPattern: $0) }
        panel.completeClipboardRequest(text: text, state: stateBack, confirmed: false)
        return true
      }
      if Thread.isMainThread {
        return MainActor.assumeIsolated { complete() }
      }
      return DispatchQueue.main.sync {
        MainActor.assumeIsolated { complete() }
      }
    }

  /// Follow-up for the OSC52 paste-confirmation flow. Ghostty calls this
  /// once the user (via our UI, eventually) has approved an inbound paste;
  /// today we simply forward the provided string to the surface. The
  /// confirmation dialog itself is deferred — we trust the OSC52 sender,
  /// same as supacode's defaults.
  private static let confirmReadClipboardCallback:
    (@convention(c) (UnsafeMutableRawPointer?, UnsafePointer<CChar>?, UnsafeMutableRawPointer?, ghostty_clipboard_request_e) -> Void) = {
      userdata, cString, state, _ in
      guard let userdata, let cString else { return }
      let value = String(cString: cString)
      let panelID = panelID(fromRawUserdata: userdata)
      let stateBits = state.map { UInt(bitPattern: $0) }
      let complete: @MainActor () -> Void = {
        guard let panel = GhosttyRuntime.shared?.surface(for: panelID) else { return }
        let stateBack = stateBits.flatMap { UnsafeMutableRawPointer(bitPattern: $0) }
        panel.completeClipboardRequest(text: value, state: stateBack, confirmed: true)
      }
      if Thread.isMainThread {
        MainActor.assumeIsolated { complete() }
      } else {
        DispatchQueue.main.async {
          MainActor.assumeIsolated { complete() }
        }
      }
    }

  /// Write `content` (array of {mime, data}) to the requested pasteboard.
  /// Called when the user invokes `copy_to_clipboard` via keybind or menu.
  private static let writeClipboardCallback:
    (@convention(c) (UnsafeMutableRawPointer?, ghostty_clipboard_e, UnsafePointer<ghostty_clipboard_content_s>?, Int, Bool) -> Void) = {
      _, location, content, len, _ in
      guard let content, len > 0 else { return }
      // Copy items out of borrowed pointers into Swift strings before the
      // main-queue hop — the pointers are valid only for the callback.
      let items: [(mime: String, data: String)] = (0..<len).compactMap { i in
        let entry = content.advanced(by: i).pointee
        guard let mimePtr = entry.mime, let dataPtr = entry.data else { return nil }
        return (String(cString: mimePtr), String(cString: dataPtr))
      }
      guard !items.isEmpty else { return }
      let write: @MainActor () -> Void = {
        guard let pb = pasteboard(for: location) else { return }
        let types: [NSPasteboard.PasteboardType] = items.map { item in
          item.mime == "text/plain" ? .string : NSPasteboard.PasteboardType(item.mime)
        }
        pb.declareTypes(types, owner: nil)
        for (item, type) in zip(items, types) {
          pb.setString(item.data, forType: type)
        }
      }
      if Thread.isMainThread {
        MainActor.assumeIsolated { write() }
      } else {
        DispatchQueue.main.async {
          MainActor.assumeIsolated { write() }
        }
      }
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
