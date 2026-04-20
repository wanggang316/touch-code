import AppKit
import Foundation
import GhosttyKit
import TouchCodeCore

/// Owns one `ghostty_surface_t` and its hosting `GhosttySurfaceView`. One
/// PanelSurface corresponds to one `Panel` while alive; when the surface
/// closes (child exited, crash, explicit close) the engine disposes this
/// object and drops it from its registry.
@MainActor
final class PanelSurface {
  enum State: Equatable, Sendable {
    case initialising
    case ready
    case exited(code: Int32)
    case crashed(reason: String)
  }

  let panelID: PanelID
  private(set) var state: State = .initialising
  let view: GhosttySurfaceView
  private var surface: ghostty_surface_t?

  private let runtime: GhosttyRuntime
  private let workingDirectoryCString: UnsafeMutablePointer<CChar>?

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
    panelID: PanelID,
    workingDirectory: String,
    fontSize: Float32 = 13.0
  ) throws {
    guard let app = runtime.app else {
      throw GhosttyError.appInitFailed
    }
    self.runtime = runtime
    self.panelID = panelID
    self.workingDirectoryCString = strdup(workingDirectory)
    self.view = GhosttySurfaceView(panelID: panelID)

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
    config.context = GHOSTTY_SURFACE_CONTEXT_SPLIT
    // Per-surface userdata: an opaque PanelSurface pointer. close_surface_cb
    // casts this back to the owning panel. Unretained is safe because the
    // engine holds the only strong reference and calls close() before drop.
    config.userdata = Unmanaged.passUnretained(self).toOpaque()

    guard let surface = ghostty_surface_new(app, &config) else {
      throw GhosttyError.appInitFailed
    }
    self.surface = surface
    self.view.attach(surface: surface)
    self.state = .ready
  }

  isolated deinit {
    if let ptr = workingDirectoryCString {
      free(UnsafeMutableRawPointer(ptr))
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

  func sendInput(_ text: String) {
    guard let surface, !text.isEmpty else { return }
    text.withCString { ptr in
      ghostty_surface_text(surface, ptr, UInt(strlen(ptr)))
    }
  }

  func markExited(code: Int32) {
    state = .exited(code: code)
  }

  func markCrashed(reason: String) {
    state = .crashed(reason: reason)
  }

  /// Called from `GhosttyRuntime.closeSurfaceCallback` when libghostty
  /// wants to close this surface. Updates state and invokes `onClose` so
  /// the engine can emit the correct lifecycle event (panelExited vs
  /// panelCrashed) and tear down its per-panel buffers.
  func requestClose(processAlive: Bool) {
    if state == .ready {
      // processAlive=true means the user asked to close while the child was
      // still running. Treat that as a clean close-with-code-0 for now;
      // proper signal disambiguation lands when we wire up SIGCHLD handling.
      state = .exited(code: 0)
    }
    onClose?(processAlive)
    close()
  }

  /// Opaque pointer equality key for `GhosttyRuntime.surface(forNSViewPointer:)`.
  /// Matches the pointer passed as `ghostty_platform_macos_s.nsview`.
  var viewPointer: UnsafeMutableRawPointer {
    Unmanaged.passUnretained(view).toOpaque()
  }
}
