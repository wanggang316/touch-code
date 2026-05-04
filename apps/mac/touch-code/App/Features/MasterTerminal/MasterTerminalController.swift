import AppKit
import TouchCodeCore

/// Owns the single Master Terminal panel — the slide-in NSPanel that hosts
/// a `claude remote-control` session running in
/// `~/.config/touch-code/master-terminal/`. The Ghostty surface is built
/// lazily on first summon and lives for the rest of the app lifetime so
/// successive summons resume the same Claude session.
@MainActor
final class MasterTerminalController: NSObject, NSWindowDelegate {
  private(set) var isVisible: Bool = false

  /// The app the user was in when the panel was last summoned. Restored on
  /// dismiss so the user lands back where they were instead of touch-code.
  private var previousApp: NSRunningApplication?

  /// Bound at init; surface allocation requires the live libghostty
  /// `ghostty_app_t` exposed via `runtime.app`.
  private let runtime: GhosttyRuntime

  /// Lazy — the surface is not built until the user first opens the panel.
  /// Once built it survives the controller's lifetime so hide/show cycles
  /// preserve the Claude session and scrollback.
  private var paneSurface: PaneSurface?
  /// Becomes true after we've sent `claude remote-control\n` so the input is
  /// not re-typed on every summon.
  private var initialCommandSent: Bool = false

  init(runtime: GhosttyRuntime) {
    self.runtime = runtime
    super.init()
  }

  /// Built lazily so a touch-code launch that never opens the Master
  /// Terminal pays no NSPanel construction cost.
  private lazy var panel: MasterTerminalWindow = {
    let panel = MasterTerminalWindow(
      contentRect: NSRect(x: 0, y: 0, width: 800, height: 400),
      styleMask: [.borderless, .nonactivatingPanel, .fullSizeContentView],
      backing: .buffered,
      defer: true
    )
    panel.isOpaque = false
    panel.backgroundColor = .clear
    panel.hasShadow = true
    panel.level = .floating
    panel.collectionBehavior = [
      .canJoinAllSpaces,
      .stationary,
      .fullScreenAuxiliary,
    ]
    panel.isReleasedWhenClosed = false
    panel.hidesOnDeactivate = false
    panel.delegate = self

    let visualEffect = NSVisualEffectView(frame: panel.contentLayoutRect)
    visualEffect.material = .hudWindow
    visualEffect.state = .active
    visualEffect.blendingMode = .behindWindow
    visualEffect.autoresizingMask = [.width, .height]
    panel.contentView = visualEffect
    return panel
  }()

  // MARK: - Public

  func toggle() {
    if isVisible {
      animateOut()
    } else {
      animateIn()
    }
  }

  // MARK: - Surface

  /// Build the Ghostty surface once and embed it. Returns the surface
  /// regardless of whether it was newly built or already existed.
  /// Returns nil only if surface allocation failed; callers should
  /// gracefully degrade (panel still slides in, just without content).
  private func ensureSurface() -> PaneSurface? {
    if let existing = paneSurface { return existing }
    do {
      let surface = try PaneSurface(
        runtime: runtime,
        // Synthetic PaneID — Master Terminal lives outside the Catalog,
        // so this UUID is never persisted, looked up, or routed. It exists
        // only because PaneSurface's libghostty userdata wiring is
        // PaneID-shaped.
        paneID: PaneID(raw: UUID()),
        workingDirectory: MasterTerminalBootstrap.userDirectory.path
      )
      paneSurface = surface

      guard let contentView = panel.contentView else { return surface }
      surface.view.translatesAutoresizingMaskIntoConstraints = false
      contentView.addSubview(surface.view)
      NSLayoutConstraint.activate([
        surface.view.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
        surface.view.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
        surface.view.topAnchor.constraint(equalTo: contentView.topAnchor),
        surface.view.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
      ])
      return surface
    } catch {
      print("MasterTerminal: surface allocation failed: \(error)")
      return nil
    }
  }

  // MARK: - Animation

  private func animateIn() {
    let screen = screenForCursor() ?? NSScreen.main ?? NSScreen.screens.first
    guard let screen else { return }

    let visibleFrame = screen.visibleFrame
    // Top 40% of the screen, full width.
    let targetHeight = visibleFrame.height * 0.40
    let targetFrame = NSRect(
      x: visibleFrame.minX,
      y: visibleFrame.maxY - targetHeight,
      width: visibleFrame.width,
      height: targetHeight
    )
    let offscreenFrame = NSRect(
      x: targetFrame.origin.x,
      y: visibleFrame.maxY,  // Above the screen — slides DOWN into place.
      width: targetFrame.width,
      height: targetFrame.height
    )

    // Capture frontmost app so we can return focus to it on dismiss. Skip
    // self — touching the panel after summon should not flip "previousApp"
    // to touch-code.
    if let frontmost = NSWorkspace.shared.frontmostApplication,
      frontmost.bundleIdentifier != Bundle.main.bundleIdentifier
    {
      previousApp = frontmost
    }

    let surface = ensureSurface()

    panel.setFrame(offscreenFrame, display: false)
    panel.alphaValue = 0
    panel.orderFrontRegardless()
    panel.makeKey()

    if let surface {
      panel.makeFirstResponder(surface.view)
      surface.setFocus(true)
    }

    NSAnimationContext.runAnimationGroup { ctx in
      ctx.duration = 0.18
      ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
      panel.animator().setFrame(targetFrame, display: true)
      panel.animator().alphaValue = 1
    }
    isVisible = true

    // Send the initial `claude remote-control` command after the surface is
    // ready and the animation kicks off. Defer one main-queue turn so
    // libghostty has finished booting the shell and is ready to consume
    // input. Single-shot — preserved across hide/show cycles.
    if let surface, !initialCommandSent {
      initialCommandSent = true
      Task { @MainActor in
        try? await Task.sleep(nanoseconds: 200_000_000)
        surface.sendInput("claude remote-control\n")
      }
    }
  }

  private func animateOut() {
    guard isVisible else { return }
    isVisible = false  // Set first so windowDidResignKey re-entry is a no-op.

    paneSurface?.setFocus(false)

    var offscreenFrame = panel.frame
    if let screen = panel.screen ?? NSScreen.main {
      offscreenFrame.origin.y = screen.visibleFrame.maxY
    } else {
      offscreenFrame.origin.y += offscreenFrame.height
    }

    let appToRestore = previousApp
    previousApp = nil

    NSAnimationContext.runAnimationGroup(
      { ctx in
        ctx.duration = 0.16
        ctx.timingFunction = CAMediaTimingFunction(name: .easeIn)
        panel.animator().setFrame(offscreenFrame, display: true)
        panel.animator().alphaValue = 0
      },
      completionHandler: { [weak self] in
        guard let self else { return }
        self.panel.orderOut(nil)
        appToRestore?.activate()
      }
    )
  }

  private func screenForCursor() -> NSScreen? {
    let cursor = NSEvent.mouseLocation
    return NSScreen.screens.first { $0.frame.contains(cursor) }
  }

  // MARK: - NSWindowDelegate

  func windowDidResignKey(_ notification: Notification) {
    // Click-away dismissal — matches upstream quick terminal behavior.
    guard isVisible else { return }
    animateOut()
  }
}
