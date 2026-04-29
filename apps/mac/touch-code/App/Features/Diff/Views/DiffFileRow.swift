// MARK: M5
import SwiftUI

/// One file row inside the inspector. Status badge, head-truncated path,
/// `+adds -dels`, and an open/closed chevron. Tap on the row body opens
/// the drawer; tap on the chevron — when this row is currently presented —
/// closes it (chevron-as-toggle when open).
struct DiffFileRow: View {
  let file: ChangedFile
  let isPresented: Bool
  let onOpenTap: () -> Void
  let onChevronTap: () -> Void

  private var displayPath: String { file.newPath ?? file.oldPath ?? "" }

  var body: some View {
    HStack(spacing: 8) {
      statusBadge
      Text(displayPath)
        .font(.system(.callout, design: .monospaced))
        .lineLimit(1)
        .truncationMode(.head)
        .frame(maxWidth: .infinity, alignment: .leading)
        .help(displayPath)
      addRemoveColumn
      chevron
    }
    .padding(.horizontal, 12)
    .padding(.vertical, 6)
    .contentShape(Rectangle())
    .background(isPresented ? Color.accentColor.opacity(0.18) : Color.clear)
    .onTapGesture { onOpenTap() }
    .accessibilityElement(children: .combine)
    .accessibilityLabel(accessibilityLabel)
    .accessibilityAddTraits(isPresented ? [.isSelected] : [])
  }

  private var statusBadge: some View {
    Image(systemName: badgeSymbol)
      .font(.system(size: 11, weight: .semibold))
      .foregroundStyle(badgeColor)
      .frame(width: 14, height: 14)
      .accessibilityHidden(true)
  }

  private var badgeSymbol: String {
    switch file.status {
    case .added: return "plus"
    case .modified: return "circle.fill"
    case .deleted: return "minus"
    case .renamed: return "arrow.right"
    }
  }

  private var badgeColor: Color {
    switch file.status {
    case .added: return .green
    case .modified: return .orange
    case .deleted: return .red
    case .renamed: return .blue
    }
  }

  @ViewBuilder
  private var addRemoveColumn: some View {
    if file.isBinary {
      Text("bin")
        .font(.caption2)
        .foregroundStyle(.secondary)
    } else {
      HStack(spacing: 4) {
        if file.addedLines > 0 {
          Text("+\(file.addedLines)")
            .foregroundStyle(.green)
        }
        if file.removedLines > 0 {
          Text("-\(file.removedLines)")
            .foregroundStyle(.red)
        }
      }
      .font(.caption.monospacedDigit())
    }
  }

  /// Tap area is just the chevron glyph — the row body owns the open tap.
  /// `Button(.plain)` avoids the chevron appearing as a focus ring inside
  /// the highlighted row.
  private var chevron: some View {
    Button(action: onChevronTap) {
      Image(systemName: isPresented ? "chevron.down" : "chevron.right")
        .font(.system(size: 10, weight: .semibold))
        .foregroundStyle(.secondary)
        .frame(width: 14, height: 14)
        .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .accessibilityLabel(isPresented ? "Close diff" : "Open diff")
  }

  private var accessibilityLabel: String {
    let statusWord: String = {
      switch file.status {
      case .added: return "Added"
      case .modified: return "Modified"
      case .deleted: return "Deleted"
      case .renamed: return "Renamed"
      }
    }()
    if file.isBinary {
      return "\(statusWord) \(displayPath), binary"
    }
    return "\(statusWord) \(displayPath), +\(file.addedLines) -\(file.removedLines)"
  }
}
