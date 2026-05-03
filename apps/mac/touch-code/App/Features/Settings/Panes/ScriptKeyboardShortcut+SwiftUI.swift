import SwiftUI
import TouchCodeCore

/// View-side bridge from the model-layer `ScriptKeyboardShortcut` to
/// SwiftUI's `KeyEquivalent` + `EventModifiers` pair. Lives in the
/// app target so `TouchCodeCore` stays SwiftUI-free.
extension ScriptKeyboardShortcut {
  /// `KeyEquivalent` derived from `key`'s first Character. Returns nil
  /// when `key` is empty — the caller is expected to gate on
  /// `isValid` before binding.
  var keyEquivalent: KeyEquivalent? {
    guard let first = key.first else { return nil }
    return KeyEquivalent(first)
  }

  var eventModifiers: EventModifiers {
    var m: EventModifiers = []
    if modifiers.contains(.command) { m.insert(.command) }
    if modifiers.contains(.option) { m.insert(.option) }
    if modifiers.contains(.control) { m.insert(.control) }
    if modifiers.contains(.shift) { m.insert(.shift) }
    return m
  }
}
