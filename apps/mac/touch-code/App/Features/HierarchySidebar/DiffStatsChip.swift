import SwiftUI

/// Compact `+N −M` line-count chip used on each Sidebar Worktree row. The
/// counts are rendered in GitHub Primer green/red (`DiffStatColor`) so the
/// chip reads like the same widget github.com shows on PRs and file lists.
///
/// When `onTap` is non-nil the chip wraps in a Button + hairline border so it
/// reads as tappable (mirrors the chord-hint chip on the right edge of the
/// row). The tap opens the project's Git Viewer for that worktree — wiring
/// lives at the call site (`HierarchySidebarView.diffStatsChip`).
struct DiffStatsChip: View {
  let additions: Int
  let deletions: Int
  let onTap: (() -> Void)?

  var body: some View {
    let counts = HStack(spacing: 4) {
      if additions > 0 {
        Text("+\(additions)").foregroundStyle(DiffStatColor.additions)
      }
      if deletions > 0 {
        Text("−\(deletions)").foregroundStyle(DiffStatColor.deletions)
      }
    }
    .font(.caption2.monospacedDigit())

    let bordered = counts
      .padding(.horizontal, 4)
      .padding(.vertical, 1)
      .overlay(
        RoundedRectangle(cornerRadius: 3)
          .stroke(Color.secondary.opacity(0.35), lineWidth: 1)
      )

    Group {
      if let onTap {
        Button(action: onTap) { bordered }
          .buttonStyle(.plain)
          .help("Open Git Viewer")
      } else {
        counts
      }
    }
    .accessibilityLabel("\(additions) additions, \(deletions) deletions")
  }
}
