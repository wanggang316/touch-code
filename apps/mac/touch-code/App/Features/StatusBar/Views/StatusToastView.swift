import SwiftUI
import TouchCodeCore

/// Renders a single `StatusToast`. Leading glyph (spinner / ✓ / ▲) + secondary
/// message. Intentionally small — the toolbar center slot is a one-line summary,
/// not a banner. Priority and auto-clear live in `StatusBarFeature`; this view
/// is a pure projection of `toast`.
struct StatusToastView: View {
  let toast: StatusToast

  var body: some View {
    HStack(spacing: 6) {
      glyph
      Text(toast.message)
        .font(.footnote)
        .foregroundStyle(.secondary)
        .lineLimit(1)
    }
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(Self.accessibilityLabel(for: toast))
    .accessibilityValue(toast.message)
  }

  @ViewBuilder
  private var glyph: some View {
    switch toast {
    case .inProgress:
      ProgressView()
        .controlSize(.small)
        .accessibilityHidden(true)
    case .success:
      Image(systemName: "checkmark.circle.fill")
        .foregroundStyle(.green)
        .accessibilityHidden(true)
    case .warning:
      Image(systemName: "exclamationmark.triangle.fill")
        .foregroundStyle(.orange)
        .accessibilityHidden(true)
    }
  }

  static func accessibilityLabel(for toast: StatusToast) -> String {
    switch toast {
    case .inProgress: return "In progress"
    case .success: return "Success"
    case .warning: return "Warning"
    }
  }
}
