import SwiftUI
import TouchCodeCore

/// Default titlebar-center view when no toast is active and the current
/// Worktree has no live PR. Renders the current time + a time-of-day
/// glyph + a Command Palette hint so the slot always carries *something*
/// useful without demanding attention.
///
/// `TimelineView(.everyMinute)` re-evaluates the body once per minute;
/// the 4-way time-of-day split (sunrise / noon / sunset / night) shifts
/// across hour boundaries, not on every second.
struct StatusMotivationalView: View {
  var body: some View {
    TimelineView(.everyMinute) { context in
      row(for: context.date)
    }
  }

  @ViewBuilder
  private func row(for date: Date) -> some View {
    let style = Self.timeStyle(for: Calendar.current.component(.hour, from: date))
    let displayTime = date.formatted(date: .omitted, time: .shortened)
    let text = "\(displayTime) – Open Command Palette \(CommandPaletteShortcut.displayString)"
    HStack(spacing: 8) {
      Image(systemName: style.icon)
        .foregroundStyle(style.color)
        .font(.callout)
        .accessibilityHidden(true)
      Text(text)
        .font(.footnote)
        .monospaced()
        .foregroundStyle(.secondary)
        .lineLimit(1)
    }
    .accessibilityElement(children: .ignore)
    .accessibilityLabel("Status idle")
    .accessibilityValue(text)
    .accessibilityIdentifier("status.motivational")
  }

  /// Pure `hour → (icon, color)` mapping. Break-points are inclusive on
  /// the lower bound and exclusive on the upper, so 5:59 is still night,
  /// 6:00 is sunrise, 11:59 is sunrise, 12:00 is noon, etc.
  static func timeStyle(for hour: Int) -> (icon: String, color: Color) {
    switch hour {
    case 6..<12: return ("sunrise.fill", .orange)
    case 12..<17: return ("sun.max.fill", .yellow)
    case 17..<21: return ("sunset.fill", .pink)
    default: return ("moon.stars.fill", .indigo)
    }
  }
}
