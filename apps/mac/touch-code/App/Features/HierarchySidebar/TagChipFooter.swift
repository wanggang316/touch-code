import SwiftUI
import TouchCodeCore

/// Footer view mounted at the sidebar's `.safeAreaInset(edge: .bottom)`
/// (formerly the Space footer slot — see docs/design-docs/project-tags.md
/// §3.4). One pill per Tag plus implicit `[All]` and conditional
/// `[Untagged]` chips. Multi-select on `[Tag]` chips is OR-semantics.
/// `[All]` clears the filter; `[Untagged]` is mutually exclusive with
/// `[Tag]` selection.
struct TagChipFooter: View {
  let tags: [Tag]
  let activeFilter: TagFilter
  let showUntaggedChip: Bool
  let onAllTapped: () -> Void
  let onTagTapped: (TagID) -> Void
  let onUntaggedTapped: () -> Void
  /// Bound to ⌘F via the parent's `tagFilterFocusRequested` action — the
  /// chip footer takes keyboard focus when the user invokes the binding.
  @FocusState private var focused: Bool

  var body: some View {
    ScrollView(.horizontal, showsIndicators: false) {
      HStack(spacing: 6) {
        chip(
          label: "All",
          color: nil,
          isSelected: isAllSelected,
          action: onAllTapped
        )
        ForEach(tags) { tag in
          chip(
            label: tag.name,
            color: tag.color,
            isSelected: isTagSelected(tag.id),
            action: { onTagTapped(tag.id) }
          )
        }
        if showUntaggedChip {
          chip(
            label: "Untagged",
            color: nil,
            isSelected: isUntaggedSelected,
            action: onUntaggedTapped
          )
        }
      }
      .padding(.horizontal, 10)
      .padding(.vertical, 6)
    }
    .background(.bar)
    .focusable()
    .focused($focused)
  }

  private var isAllSelected: Bool {
    if case .all = activeFilter { return true }
    if case .tags(let set) = activeFilter, set.isEmpty { return true }
    return false
  }

  private var isUntaggedSelected: Bool {
    if case .untagged = activeFilter { return true }
    return false
  }

  private func isTagSelected(_ id: TagID) -> Bool {
    if case .tags(let set) = activeFilter { return set.contains(id) }
    return false
  }

  @ViewBuilder
  private func chip(
    label: String,
    color: TagColor?,
    isSelected: Bool,
    action: @escaping () -> Void
  ) -> some View {
    Button(action: action) {
      HStack(spacing: 5) {
        if let color {
          Circle()
            .fill(swiftUIColor(for: color))
            .frame(width: 8, height: 8)
        }
        Text(label)
          .font(.caption)
          .lineLimit(1)
      }
      .padding(.horizontal, 9)
      .padding(.vertical, 4)
      .background(
        Capsule()
          .fill(isSelected ? Color.accentColor.opacity(0.20) : Color.secondary.opacity(0.10))
      )
      .overlay(
        Capsule()
          .strokeBorder(isSelected ? Color.accentColor : Color.clear, lineWidth: 1)
      )
      .contentShape(Capsule())
    }
    .buttonStyle(.plain)
  }
}

/// Maps the fixed Finder palette onto `SwiftUI.Color`. Kept inside the
/// view (not on `TagColor` itself) so the core type stays UI-framework
/// neutral.
func swiftUIColor(for color: TagColor) -> Color {
  switch color {
  case .red: return .red
  case .orange: return .orange
  case .yellow: return .yellow
  case .green: return .green
  case .blue: return .blue
  case .purple: return .purple
  case .grey: return .gray
  }
}
