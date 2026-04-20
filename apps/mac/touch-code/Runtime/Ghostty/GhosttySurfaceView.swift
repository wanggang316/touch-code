import AppKit
import Carbon.HIToolbox
import Foundation
import GhosttyKit
import TouchCodeCore

/// Minimal host view for a ghostty_surface_t. Forwards key/mouse events and
/// frame/content-scale changes; leaves Metal rendering to ghostty's own
/// layer setup (it reaches through the `nsview` pointer passed in
/// `ghostty_platform_macos_s` and attaches a CAMetalLayer).
@MainActor
final class GhosttySurfaceView: NSView, NSTextInputClient {
  let panelID: PanelID
  private var surface: ghostty_surface_t?
  private var markedText = NSMutableAttributedString()
  private var trackingArea: NSTrackingArea?
  /// NSTextInputContext delivers composed text through insertText during an
  /// interpretKeyEvents pass. We accumulate what it delivers so the outer
  /// keyDown handler can attach it to the single ghostty_surface_key call —
  /// avoiding double-insertion of event.characters.
  private var keyTextAccumulator: [String]?
  /// Modifier-key state snapshot. flagsChanged events need to be diffed
  /// against the previous modifier set to emit the correct press/release;
  /// the raw NSEvent always reads .press for the event kind.
  private var lastModifierFlags: NSEvent.ModifierFlags = []

  init(panelID: PanelID) {
    self.panelID = panelID
    super.init(frame: .zero)
    self.wantsLayer = true
    self.autoresizingMask = [.width, .height]
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) not supported")
  }

  func attach(surface: ghostty_surface_t) {
    self.surface = surface
    pushGeometry()
  }

  func detachSurface() {
    self.surface = nil
  }

  func backingScaleFactor() -> Double {
    if let window { return window.backingScaleFactor }
    if let screen = NSScreen.main { return screen.backingScaleFactor }
    return 2.0
  }

  // MARK: - NSResponder

  override var acceptsFirstResponder: Bool { true }

  override func becomeFirstResponder() -> Bool {
    let accepted = super.becomeFirstResponder()
    if accepted, let surface { ghostty_surface_set_focus(surface, true) }
    return accepted
  }

  override func resignFirstResponder() -> Bool {
    let accepted = super.resignFirstResponder()
    if accepted, let surface { ghostty_surface_set_focus(surface, false) }
    return accepted
  }

  // MARK: - Geometry

  override func viewDidMoveToWindow() {
    super.viewDidMoveToWindow()
    pushGeometry()
    installTrackingArea()
  }

  override func viewDidChangeBackingProperties() {
    super.viewDidChangeBackingProperties()
    guard let surface else { return }
    let scale = backingScaleFactor()
    ghostty_surface_set_content_scale(surface, scale, scale)
  }

  override func resize(withOldSuperviewSize oldSize: NSSize) {
    super.resize(withOldSuperviewSize: oldSize)
    pushGeometry()
  }

  override func layout() {
    super.layout()
    pushGeometry()
    installTrackingArea()
  }

  private func pushGeometry() {
    guard let surface else { return }
    let scale = backingScaleFactor()
    ghostty_surface_set_content_scale(surface, scale, scale)
    // ghostty_surface_set_size takes device-pixel dimensions.
    let px = convertToBacking(bounds.size)
    if px.width > 0, px.height > 0 {
      ghostty_surface_set_size(surface, UInt32(px.width), UInt32(px.height))
    }
  }

  private func installTrackingArea() {
    if let trackingArea {
      removeTrackingArea(trackingArea)
    }
    let area = NSTrackingArea(
      rect: bounds,
      options: [.activeInActiveApp, .inVisibleRect, .mouseMoved, .mouseEnteredAndExited],
      owner: self,
      userInfo: nil
    )
    addTrackingArea(area)
    self.trackingArea = area
  }

  // MARK: - Keyboard

  override func keyDown(with event: NSEvent) {
    guard let surface else { return }

    // Accumulate composed text from the NSTextInputContext pipeline. If the
    // user is mid-IME-composition, insertText delivers the final commit
    // here; raw characters from the NSEvent are not forwarded — doing so
    // would double-insert.
    keyTextAccumulator = []
    interpretKeyEvents([event])
    let composed = keyTextAccumulator ?? []
    keyTextAccumulator = nil

    let text = composed.joined()
    sendKeyEvent(
      event: event,
      action: GHOSTTY_ACTION_PRESS,
      surface: surface,
      text: text
    )
  }

  override func keyUp(with event: NSEvent) {
    guard let surface else { return }
    sendKeyEvent(event: event, action: GHOSTTY_ACTION_RELEASE, surface: surface, text: "")
  }

  override func flagsChanged(with event: NSEvent) {
    guard let surface else { return }
    // NSEvent.flagsChanged always reads as a single event with the new mask.
    // Diff against the snapshot to know which modifier actually changed and
    // whether it's a press (newly set) or release (newly cleared).
    let newFlags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
    let oldFlags = lastModifierFlags
    lastModifierFlags = newFlags

    let added = newFlags.subtracting(oldFlags)
    let removed = oldFlags.subtracting(newFlags)

    if !added.isEmpty {
      sendKeyEvent(event: event, action: GHOSTTY_ACTION_PRESS, surface: surface, text: "")
    }
    if !removed.isEmpty {
      sendKeyEvent(event: event, action: GHOSTTY_ACTION_RELEASE, surface: surface, text: "")
    }
  }

  private func sendKeyEvent(
    event: NSEvent,
    action: ghostty_input_action_e,
    surface: ghostty_surface_t,
    text: String
  ) {
    var keyEvent = ghostty_input_key_s()
    keyEvent.action = action
    keyEvent.keycode = UInt32(event.keyCode)
    keyEvent.mods = mods(from: event.modifierFlags)
    keyEvent.consumed_mods = GHOSTTY_MODS_NONE
    keyEvent.composing = !markedText.string.isEmpty
    keyEvent.unshifted_codepoint = 0

    if text.isEmpty {
      keyEvent.text = nil
      _ = ghostty_surface_key(surface, keyEvent)
      return
    }
    // Use utf8.count for the length so strings with embedded NUL aren't
    // truncated. Pass the Data buffer so ghostty reads exactly utf8.count
    // bytes regardless of terminators.
    let bytes = Array(text.utf8)
    bytes.withUnsafeBufferPointer { buffer in
      buffer.baseAddress?.withMemoryRebound(
        to: CChar.self,
        capacity: bytes.count
      ) { ptr in
        keyEvent.text = ptr
        _ = ghostty_surface_key(surface, keyEvent)
      }
    }
  }

  private func mods(from flags: NSEvent.ModifierFlags) -> ghostty_input_mods_e {
    var raw: UInt32 = 0
    if flags.contains(.shift) { raw |= GHOSTTY_MODS_SHIFT.rawValue }
    if flags.contains(.control) { raw |= GHOSTTY_MODS_CTRL.rawValue }
    if flags.contains(.option) { raw |= GHOSTTY_MODS_ALT.rawValue }
    if flags.contains(.command) { raw |= GHOSTTY_MODS_SUPER.rawValue }
    if flags.contains(.capsLock) { raw |= GHOSTTY_MODS_CAPS.rawValue }
    return ghostty_input_mods_e(rawValue: raw)
  }

  // MARK: - Mouse

  override func mouseDown(with event: NSEvent) {
    sendMouseButton(event: event, button: GHOSTTY_MOUSE_LEFT, action: GHOSTTY_MOUSE_PRESS)
  }
  override func mouseUp(with event: NSEvent) {
    sendMouseButton(event: event, button: GHOSTTY_MOUSE_LEFT, action: GHOSTTY_MOUSE_RELEASE)
  }
  override func rightMouseDown(with event: NSEvent) {
    sendMouseButton(event: event, button: GHOSTTY_MOUSE_RIGHT, action: GHOSTTY_MOUSE_PRESS)
  }
  override func rightMouseUp(with event: NSEvent) {
    sendMouseButton(event: event, button: GHOSTTY_MOUSE_RIGHT, action: GHOSTTY_MOUSE_RELEASE)
  }
  override func otherMouseDown(with event: NSEvent) {
    sendMouseButton(event: event, button: GHOSTTY_MOUSE_MIDDLE, action: GHOSTTY_MOUSE_PRESS)
  }
  override func otherMouseUp(with event: NSEvent) {
    sendMouseButton(event: event, button: GHOSTTY_MOUSE_MIDDLE, action: GHOSTTY_MOUSE_RELEASE)
  }

  override func mouseDragged(with event: NSEvent) { sendMouseMoved(event) }
  override func rightMouseDragged(with event: NSEvent) { sendMouseMoved(event) }
  override func otherMouseDragged(with event: NSEvent) { sendMouseMoved(event) }
  override func mouseMoved(with event: NSEvent) { sendMouseMoved(event) }

  override func scrollWheel(with event: NSEvent) {
    guard let surface else { return }
    var modifier: ghostty_input_scroll_mods_t = 0
    if event.hasPreciseScrollingDeltas { modifier |= 1 }
    // Momentum scrolling: phase != .none means we are in a momentum tail.
    // NSEvent.momentumPhase returns .changed for the tail, .ended at stop.
    if !event.momentumPhase.isEmpty && event.momentumPhase != .stationary {
      modifier |= 2
    }
    ghostty_surface_mouse_scroll(surface, event.scrollingDeltaX, event.scrollingDeltaY, modifier)
  }

  private func sendMouseMoved(_ event: NSEvent) {
    guard let surface else { return }
    // ghostty_surface_mouse_pos expects point coordinates (not device-pixel)
    // — ghostty applies content_scale internally on render.
    let pos = convert(event.locationInWindow, from: nil)
    ghostty_surface_mouse_pos(surface, pos.x, pos.y, mods(from: event.modifierFlags))
  }

  private func sendMouseButton(
    event: NSEvent,
    button: ghostty_input_mouse_button_e,
    action: ghostty_input_mouse_state_e
  ) {
    guard let surface else { return }
    let pos = convert(event.locationInWindow, from: nil)
    ghostty_surface_mouse_pos(surface, pos.x, pos.y, mods(from: event.modifierFlags))
    _ = ghostty_surface_mouse_button(surface, action, button, mods(from: event.modifierFlags))
  }

  // MARK: - NSTextInputClient

  func insertText(_ string: Any, replacementRange: NSRange) {
    let text: String = (string as? String) ?? (string as? NSAttributedString)?.string ?? ""
    guard !text.isEmpty else { return }
    // Inside a keyDown's interpretKeyEvents pass, accumulate into the
    // keyTextAccumulator so keyDown attaches it to the single key event.
    // Outside that pass (e.g. drag-insert), route directly to the surface.
    if keyTextAccumulator != nil {
      keyTextAccumulator?.append(text)
    } else if let surface {
      // Clear any in-flight preedit and commit the text.
      forwardPreedit("", to: surface)
      forwardText(text, to: surface)
    }
    markedText = NSMutableAttributedString()
    if let surface {
      // Ensure preedit is cleared on the ghostty side too.
      forwardPreedit("", to: surface)
    }
  }

  func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
    let attr: NSAttributedString
    if let s = string as? NSAttributedString {
      attr = s
    } else if let s = string as? String {
      attr = NSAttributedString(string: s)
    } else {
      return
    }
    markedText = NSMutableAttributedString(attributedString: attr)
    // Forward preedit so IME composition is visible in the terminal rather
    // than appearing only after commit.
    if let surface {
      forwardPreedit(attr.string, to: surface)
    }
  }

  func unmarkText() {
    markedText = NSMutableAttributedString()
    if let surface {
      forwardPreedit("", to: surface)
    }
  }

  func selectedRange() -> NSRange { NSRange(location: NSNotFound, length: 0) }
  func markedRange() -> NSRange {
    markedText.length == 0 ? NSRange(location: NSNotFound, length: 0) : NSRange(location: 0, length: markedText.length)
  }
  func hasMarkedText() -> Bool { markedText.length > 0 }
  func attributedSubstring(forProposedRange range: NSRange, actualRange: NSRangePointer?) -> NSAttributedString? { nil }
  func validAttributesForMarkedText() -> [NSAttributedString.Key] { [] }
  func firstRect(forCharacterRange range: NSRange, actualRange: NSRangePointer?) -> NSRect {
    // Deferred for M5.4: should resolve to the cell rect under the caret
    // so the IME candidate window appears correctly. Returning view bounds
    // keeps IME functional but visually misaligned.
    guard let window else { return .zero }
    let rect = convert(bounds, to: nil)
    return window.convertToScreen(rect)
  }
  func characterIndex(for point: NSPoint) -> Int { 0 }
  override func doCommand(by selector: Selector) {
    // Let default NSResponder chain handle it; ghostty already received the
    // raw key event in keyDown.
  }

  // MARK: - Forwarding helpers

  private func forwardText(_ text: String, to surface: ghostty_surface_t) {
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

  private func forwardPreedit(_ text: String, to surface: ghostty_surface_t) {
    let bytes = Array(text.utf8)
    if bytes.isEmpty {
      ghostty_surface_preedit(surface, nil, 0)
      return
    }
    bytes.withUnsafeBufferPointer { buffer in
      buffer.baseAddress?.withMemoryRebound(
        to: CChar.self,
        capacity: bytes.count
      ) { ptr in
        ghostty_surface_preedit(surface, ptr, UInt(bytes.count))
      }
    }
  }
}
