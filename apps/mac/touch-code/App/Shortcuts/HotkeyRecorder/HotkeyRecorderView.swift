import AppKit
import SwiftUI
import TouchCodeCore

/// SwiftUI wrapper around `HotkeyRecorderNSView`. The host owns recording state and presents
/// the captured chord; this view focuses on event capture and rejection feedback.
///
/// Conflict detection is *not* run inside the recorder — that responsibility belongs to the
/// settings pane (`ShortcutsSettingsView`), which has the resolved map plus the schema
/// scope rules and surfaces a confirmation popover when needed. The recorder simply hands
/// up the validated `ShortcutBinding`.
struct HotkeyRecorderView: NSViewRepresentable {
  /// True when this field is the active recorder. Driven by the parent view.
  @Binding var isRecording: Bool
  /// Called with a validated chord on successful capture. The parent ends recording and
  /// applies the binding through `ShortcutsStore`.
  let onCapture: (ShortcutBinding) -> Void
  /// Called when validation rejects the chord (no primary modifier / modifier-only key).
  let onReject: (HotkeyRecorderNSView.RejectionReason) -> Void
  /// Called when the user dismisses recording without committing (Esc, click-out).
  let onCancel: () -> Void

  func makeNSView(context: Context) -> HotkeyRecorderNSView {
    let view = HotkeyRecorderNSView(frame: .zero)
    view.onCapture = { binding in
      onCapture(binding)
      isRecording = false
    }
    view.onReject = onReject
    view.onCancel = {
      onCancel()
      isRecording = false
    }
    return view
  }

  func updateNSView(_ nsView: HotkeyRecorderNSView, context: Context) {
    if isRecording, !nsView.isRecording {
      nsView.beginRecording()
    } else if !isRecording, nsView.isRecording {
      nsView.endRecording()
    }
  }
}
