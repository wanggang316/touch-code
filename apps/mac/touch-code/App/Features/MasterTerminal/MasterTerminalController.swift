import AppKit

/// Owns the single Master Terminal panel — the slide-in NSPanel that hosts
/// the Claude session. M2 ships a placeholder content view; M3 swaps it
/// for a real Ghostty surface.
@MainActor
final class MasterTerminalController: NSObject, NSWindowDelegate {
  private(set) var isVisible: Bool = false

  /// The app the user was in when the panel was last summoned. Restored on
  /// dismiss so the user lands back where they were instead of touch-code.
  private var previousApp: NSRunningApplication?

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

    let placeholder = NSTextField(labelWithString: "Master Terminal — surface pending")
    placeholder.font = .systemFont(ofSize: 18, weight: .semibold)
    placeholder.textColor = .labelColor
    placeholder.translatesAutoresizingMaskIntoConstraints = false
    visualEffect.addSubview(placeholder)
    NSLayoutConstraint.activate([
      placeholder.centerXAnchor.constraint(equalTo: visualEffect.centerXAnchor),
      placeholder.centerYAnchor.constraint(equalTo: visualEffect.centerYAnchor),
    ])

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

    panel.setFrame(offscreenFrame, display: false)
    panel.alphaValue = 0
    panel.orderFrontRegardless()
    panel.makeKey()

    NSAnimationContext.runAnimationGroup { ctx in
      ctx.duration = 0.18
      ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
      panel.animator().setFrame(targetFrame, display: true)
      panel.animator().alphaValue = 1
    }
    isVisible = true
  }

  private func animateOut() {
    guard isVisible else { return }
    isVisible = false  // Set first so windowDidResignKey re-entry is a no-op.

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
