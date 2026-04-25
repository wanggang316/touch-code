import AppKit
import Foundation
import GhosttyKit
import TouchCodeCore

/// Owns one `ghostty_surface_t` and its hosting `GhosttySurfaceView`. One
/// PaneSurface corresponds to one `Pane` while alive; when the surface
/// closes (child exited, crash, explicit close) the engine disposes this
/// object and drops it from its registry.
@MainActor
final class PaneSurface {
  enum State: Equatable, Sendable {
    case initialising
    case ready
    case exited(code: Int32)
    case crashed(reason: String)
  }

  let paneID: PaneID
  /// Observable informational state populated from the `PaneInfoDelta`
  /// stream via `apply(_:)`. Reference type — `let` is intentional; the
  /// instance lives for the full PaneSurface lifetime and its fields
  /// are mutated in place so observers keep the same identity.
  let info: SurfaceInfo = SurfaceInfo()
  private(set) var state: State = .initialising
  let view: GhosttySurfaceView
  private var surface: ghostty_surface_t?

  private let runtime: GhosttyRuntime
  private let workingDirectoryCString: UnsafeMutablePointer<CChar>?
  /// Heap-allocated key/value C strings backing the env_vars array passed
  /// to libghostty. `strdup`'d in init, every entry `free`'d in deinit.
  /// Held on the instance because libghostty does NOT documented-copy the
  /// `env_vars` buffer; keeping the strings alive matches the
  /// `working_directory` lifecycle.
  private let envCStrings: [(key: UnsafeMutablePointer<CChar>, value: UnsafeMutablePointer<CChar>)]
  /// Backing storage for the `ghostty_env_var_s` array. Allocated only
  /// when the env map is non-empty; a `nil` buffer means the surface
  /// config receives `env_vars = nil, env_var_count = 0`.
  private let envVarsBuffer: UnsafeMutableBufferPointer<ghostty_env_var_s>?
  /// Heap-allocated uuid_t bytes passed to libghostty as the surface
  /// userdata. close_surface_cb reads these bytes to recover the owning
  /// PaneID without casting to a Swift object pointer (UAF-safe across
  /// the C→main-queue hop).
  private let paneIDUserdata: UnsafeMutablePointer<UInt8>

  /// Engine-provided close callback. Runs when the libghostty surface
  /// reports close (child exited or crashed). `processAlive` is true for
  /// user-initiated close with a live child, false for child-exit triggered
  /// close.
  var onClose: (@MainActor (_ processAlive: Bool) -> Void)?

  /// Engine-provided output callback. Currently unused — surface output
  /// reaches the engine via ghostty's own rendering layer; the engine hooks
  /// this in M4 integration (deferred).
  var onOutput: (@MainActor (Data) -> Void)?

  init(
    runtime: GhosttyRuntime,
    paneID: PaneID,
    workingDirectory: String,
    env: [String: String] = [:],
    fontSize: Float32 = 13.0
  ) throws {
    guard let app = runtime.app else {
      throw GhosttyError.appInitFailed
    }
    self.runtime = runtime
    self.paneID = paneID
    self.workingDirectoryCString = strdup(workingDirectory)
    self.view = GhosttySurfaceView(paneID: paneID)

    // Stable C-string ownership for env: each (key, value) is `strdup`'d,
    // referenced from a `ghostty_env_var_s` in `envVarsBuffer`, and freed
    // in `deinit`. Empty map → nil buffer → config.env_vars stays nil.
    let strdupped = Self.makeEnvCStrings(env)
    self.envCStrings = strdupped
    if strdupped.isEmpty {
      self.envVarsBuffer = nil
    } else {
      let buffer = UnsafeMutableBufferPointer<ghostty_env_var_s>.allocate(
        capacity: strdupped.count
      )
      for (index, pair) in strdupped.enumerated() {
        buffer[index] = ghostty_env_var_s(
          key: UnsafePointer(pair.key),
          value: UnsafePointer(pair.value)
        )
      }
      self.envVarsBuffer = buffer
    }

    // Allocate 16 bytes to hold the PaneID's uuid bytes as surface userdata.
    self.paneIDUserdata = UnsafeMutablePointer<UInt8>.allocate(capacity: 16)
    withUnsafeBytes(of: paneID.raw.uuid) { src in
      paneIDUserdata.update(
        from: src.bindMemory(to: UInt8.self).baseAddress!,
        count: 16
      )
    }

    var config = ghostty_surface_config_new()
    config.platform_tag = GHOSTTY_PLATFORM_MACOS
    config.platform = ghostty_platform_u(
      macos: ghostty_platform_macos_s(
        nsview: Unmanaged.passUnretained(view).toOpaque()
      )
    )
    config.scale_factor = view.backingScaleFactor()
    config.font_size = fontSize
    config.working_directory = workingDirectoryCString.map { UnsafePointer($0) }
    if let envBuffer = envVarsBuffer {
      config.env_vars = envBuffer.baseAddress
      config.env_var_count = envBuffer.count
    }
    config.context = GHOSTTY_SURFACE_CONTEXT_SPLIT
    // Per-surface userdata: opaque pointer to the 16 uuid-bytes of the
    // owning PaneID. The close_surface_cb copies these bytes into a local
    // UUID so the callback survives the C→main-queue hop even if the
    // PaneSurface object is freed in-between.
    config.userdata = UnsafeMutableRawPointer(paneIDUserdata)

    guard let surface = ghostty_surface_new(app, &config) else {
      throw GhosttyError.surfaceInitFailed
    }
    self.surface = surface
    self.view.attach(surface: surface)
    // libghostty defaults new surfaces to focused; in a multi-pane layout
    // that makes every fresh surface draw the filled blinking cursor until
    // something explicitly resigns it. Force-false here — the one pane that
    // wins first-responder will flip it back to true via becomeFirstResponder.
    ghostty_surface_set_focus(surface, false)
    self.state = .ready
  }

  isolated deinit {
    // Safety net: callers should invoke close() explicitly, but if the
    // engine drops a PaneSurface without doing so, release the surface
    // here to avoid leaking a ghostty_surface_t + the child PTY.
    if let surface {
      ghostty_surface_free(surface)
    }
    if let ptr = workingDirectoryCString {
      free(UnsafeMutableRawPointer(ptr))
    }
    for pair in envCStrings {
      free(UnsafeMutableRawPointer(pair.key))
      free(UnsafeMutableRawPointer(pair.value))
    }
    if let buffer = envVarsBuffer {
      buffer.deallocate()
    }
    paneIDUserdata.deallocate()
  }

  // MARK: - Env helpers

  /// Allocate a stable `(key, value)` C-string pair for each entry in
  /// `env`. Returned pointers must be freed with `free`. Pure / nonisolated
  /// so unit tests can exercise the conversion without spinning a real
  /// `GhosttyRuntime`.
  static func makeEnvCStrings(
    _ env: [String: String]
  ) -> [(key: UnsafeMutablePointer<CChar>, value: UnsafeMutablePointer<CChar>)] {
    guard !env.isEmpty else { return [] }
    // Sort for deterministic ordering — libghostty does not require any
    // particular order, but stable iteration makes the test surface
    // predictable and avoids spurious flakiness on dictionary reorderings.
    return env.sorted(by: { $0.key < $1.key }).map { entry in
      (key: strdup(entry.key)!, value: strdup(entry.value)!)
    }
  }

  /// Explicit teardown. Idempotent. After `close()`, the surface handle is
  /// nil and all subsequent operations no-op.
  func close() {
    guard let surface else { return }
    ghostty_surface_free(surface)
    self.surface = nil
    view.detachSurface()
  }

  func setFocus(_ focused: Bool) {
    guard let surface else { return }
    ghostty_surface_set_focus(surface, focused)
  }

  /// Apply a color scheme to this surface and request a redraw. No-op after `close()`.
  /// Called by `GhosttyRuntime.setColorScheme(_:)` when the app's resolved
  /// color scheme changes (either user picker toggle or OS-level appearance flip).
  func applyColorScheme(_ scheme: ghostty_color_scheme_e) {
    guard let surface else { return }
    ghostty_surface_set_color_scheme(surface, scheme)
    ghostty_surface_refresh(surface)
  }

  /// Push a config to this specific surface. Called from the action decoder
  /// when libghostty fires a surface-target `reload_config` action (per-surface
  /// light/dark flip raised by `ghostty_surface_set_color_scheme`). libghostty
  /// copies what it needs synchronously from `ghostty_surface_update_config`
  /// — caller owns and frees the handle it passes in. The surface's own
  /// `config_conditional_state` has already been mutated before this call, so
  /// `Surface.updateConfig` will pick up the new scheme while applying the
  /// config we push here.
  func reloadConfig(soft: Bool, appConfig: ghostty_config_t?) {
    guard let surface else { return }
    let pushed: ghostty_config_t?
    if soft, let current = appConfig {
      pushed = ghostty_config_clone(current)
    } else {
      guard let fresh = ghostty_config_new() else { return }
      ghostty_config_load_default_files(fresh)
      ghostty_config_load_recursive_files(fresh)
      ghostty_config_finalize(fresh)
      pushed = fresh
    }
    guard let handle = pushed else { return }
    ghostty_surface_update_config(surface, handle)
    ghostty_config_free(handle)
  }

  /// Fulfils a `read_clipboard_cb` request by forwarding the string back to
  /// libghostty. Called from `GhosttyRuntime`'s clipboard bridge on
  /// MainActor after the pasteboard is read.
  func completeClipboardRequest(
    text: String, state: UnsafeMutableRawPointer?, confirmed: Bool
  ) {
    guard let surface else { return }
    text.withCString { ptr in
      ghostty_surface_complete_clipboard_request(surface, ptr, state, confirmed)
    }
  }

  func sendInput(_ text: String) {
    guard let surface, !text.isEmpty else { return }
    // Use utf8.count, not strlen — embedded NUL in composed glyphs would
    // truncate the forwarded bytes on strlen.
    let bytes = Array(text.utf8)
    bytes.withUnsafeBufferPointer { buffer in
      buffer.baseAddress?.withMemoryRebound(
        to: CChar.self,
        capacity: bytes.count
      ) { ptr in
        ghostty_surface_text(surface, ptr, UInt(bytes.count))
      }
    }
  }

  func markExited(code: Int32) {
    state = .exited(code: code)
    info.lastChildExitCode = code
  }

  func markCrashed(reason: String) {
    state = .crashed(reason: reason)
  }

  /// Called from `GhosttyRuntime.closeSurfaceCallback` when libghostty
  /// wants to close this surface. Invokes `onClose` with the processAlive
  /// flag so the engine decides how to emit the lifecycle event — the
  /// engine distinguishes user-initiated close (`processAlive == true`)
  /// from child-exit-driven close (`processAlive == false`) and uses
  /// state transitions that were already set via markExited / markCrashed
  /// if any.
  func requestClose(processAlive: Bool) {
    onClose?(processAlive)
    close()
  }

  // MARK: - Info delta application

  /// Fold a single `PaneInfoDelta` into `info`. Exhaustive over every
  /// delta case — the compiler enforces coverage when new cases land in
  /// TouchCodeCore, which is the whole point of keeping the enum Core-side.
  ///
  /// This only mutates per-surface observable state; it does NOT emit
  /// `TerminalEvent.paneInfoChanged`. The decoder is responsible for
  /// fan-out so listeners that don't need per-field tracking can stay on
  /// the event stream.
  func apply(_ delta: PaneInfoDelta) {
    switch delta {
    case .title(let t):
      info.title = t
    case .tabTitle(let t):
      info.tabTitle = t
    case .promptTitle(let tag):
      info.promptTitle = tag
    case .pwd(let p):
      info.pwd = p

    case .mouseShape(let shape):
      info.mouseShape = shape
    case .mouseVisible(let visible):
      info.mouseVisible = visible
    case .mouseOverLink(let url):
      info.mouseOverLink = url

    case .colorChange(let kind, let r, let g, let b):
      info.colorChange = ColorChange(kind: kind, r: r, g: g, b: b)
    case .rendererHealthy(let healthy):
      info.rendererHealthy = healthy

    case .cellSize(let width, let height):
      info.cellWidth = width
      info.cellHeight = height
    case .sizeLimit(let minWidth, let minHeight, let maxWidth, let maxHeight):
      info.sizeLimitMinWidth = minWidth
      info.sizeLimitMinHeight = minHeight
      info.sizeLimitMaxWidth = maxWidth
      info.sizeLimitMaxHeight = maxHeight
    case .initialSize(let width, let height):
      info.initialWidth = width
      info.initialHeight = height
    case .resetWindowSize:
      // Transient intent — libghostty asks the host to restore its default
      // window size. No persistent field to update here; the decoder
      // forwards this on the event stream for the window layer to service.
      break

    case .scrollbar(let total, let offset, let length):
      info.scrollbarTotal = total
      info.scrollbarOffset = offset
      info.scrollbarLength = length

    case .secureInput(let mode):
      info.secureInput = mode
    case .keySequence(let active, let trigger):
      info.keySequenceActive = active
      info.keySequenceTrigger = trigger
    case .keyTable(let name, let depth):
      info.keyTableName = name
      info.keyTableDepth = depth
    case .readonly(let ro):
      info.readonly = ro
    case .quitTimer(let phase):
      info.quitTimer = phase
    case .floatWindow(let floating):
      info.floatWindow = floating

    case .searchStarted(let needle):
      info.searchNeedle = needle
      info.searchTotal = nil
      info.searchSelected = nil
    case .searchEnded:
      info.searchNeedle = nil
      info.searchTotal = nil
      info.searchSelected = nil
    case .searchTotal(let total):
      info.searchTotal = total
    case .searchSelected(let index):
      info.searchSelected = index

    case .progress(let state, let value):
      info.progressState = state
      info.progressValue = value

    case .bellRang:
      info.bellCount &+= 1
    case .desktopNotification(let title, let body):
      info.lastNotificationTitle = title
      info.lastNotificationBody = body
    case .commandFinished(let exitCode, let duration):
      info.lastCommandExitCode = exitCode
      info.lastCommandDuration = duration
    case .childExited(let code):
      info.lastChildExitCode = code
    }
  }
}
