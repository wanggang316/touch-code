import SwiftUI
import TouchCodeCore

/// Compact footer mounted at the sidebar's `.safeAreaInset(edge: .bottom)`.
/// Shows a single trailing filter glyph; tapping the glyph opens a popover
/// (anchored above the button via `arrowEdge: .bottom`) that lists the
/// available tag filters: implicit `[All]`, one row per Tag, optional
/// `[Untagged]` when any project carries no tag, and an `Edit Tags…`
/// shortcut to the catalog manager.
///
/// The icon flips to its `.fill` variant tinted with `Color.accentColor`
/// whenever the active filter is anything other than `.all`, so the user
/// can tell at a glance that the project list is being filtered without
/// opening the popover.
struct TagFilterPopoverFooter: View {
  let tags: [Tag]
  let activeFilter: TagFilter
  let showUntaggedChip: Bool
  let onAllTapped: () -> Void
  let onTagTapped: (TagID) -> Void
  let onUntaggedTapped: () -> Void
  /// Trailing "Edit Tags…" entry — opens the TagManager sheet.
  /// Optional so previews / tests without manager wiring can omit it.
  var onEditTagsTapped: (() -> Void)?

  @State private var isPopoverPresented = false

  var body: some View {
    HStack(spacing: 0) {
      Button {
        isPopoverPresented.toggle()
      } label: {
        Image(
          systemName: hasActiveFilter
            ? "line.3.horizontal.decrease.circle.fill"
            : "line.3.horizontal.decrease.circle"
        )
        .font(.system(size: 15, weight: .regular))
        .foregroundStyle(hasActiveFilter ? Color.accentColor : .secondary)
        .frame(width: 22, height: 22)
        .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      .help(hasActiveFilter ? "Filtered by tag — click to change" : "Filter by tag")
      .accessibilityLabel("Filter by tag")
      .popover(isPresented: $isPopoverPresented, arrowEdge: .bottom) {
        TagFilterList(
          tags: tags,
          activeFilter: activeFilter,
          showUntaggedChip: showUntaggedChip,
          onAllTapped: { onAllTapped() },
          onTagTapped: { onTagTapped($0) },
          onUntaggedTapped: { onUntaggedTapped() },
          onEditTagsTapped: onEditTagsTapped.map { handler in
            { handler() }
          }
        )
      }
      Spacer()
    }
    .padding(.horizontal, 8)
    .padding(.vertical, 4)
    .background(.bar)
  }

  private var hasActiveFilter: Bool {
    switch activeFilter {
    case .all: return false
    case .tags(let set): return !set.isEmpty
    case .untagged: return true
    }
  }
}

/// Vertical list of filter rows shown inside the footer's popover. Each
/// row is a tappable `Button` styled with a leading colored dot (when the
/// row corresponds to a Tag), the row label, and a trailing checkmark when
/// the row is part of the active filter. `[All]` and `[Untagged]` rows
/// have no dot. The popover does NOT auto-dismiss on tap so the user can
/// toggle multiple tags in one pass; `[All]` still clears the filter
/// because the reducer treats it as a hard reset.
private struct TagFilterList: View {
  let tags: [Tag]
  let activeFilter: TagFilter
  let showUntaggedChip: Bool
  let onAllTapped: () -> Void
  let onTagTapped: (TagID) -> Void
  let onUntaggedTapped: () -> Void
  var onEditTagsTapped: (() -> Void)?

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      filterRow(
        label: "All",
        color: nil,
        isSelected: isAllSelected,
        action: onAllTapped
      )
      if !tags.isEmpty {
        Divider().padding(.vertical, 2)
        ForEach(tags) { tag in
          filterRow(
            label: tag.name,
            color: tag.color,
            isSelected: isTagSelected(tag.id),
            action: { onTagTapped(tag.id) }
          )
        }
      }
      if showUntaggedChip {
        Divider().padding(.vertical, 2)
        filterRow(
          label: "Untagged",
          color: nil,
          isSelected: isUntaggedSelected,
          action: onUntaggedTapped
        )
      }
      if let onEditTagsTapped {
        Divider().padding(.vertical, 2)
        Button(action: onEditTagsTapped) {
          HStack(spacing: 8) {
            Image(systemName: "pencil")
              .font(.system(size: 11))
              .frame(width: 12)
              .foregroundStyle(.secondary)
            Text("Edit Tags…")
              .font(.callout)
              .foregroundStyle(.primary)
            Spacer(minLength: 0)
          }
          .padding(.horizontal, 8)
          .padding(.vertical, 5)
          .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
      }
    }
    .padding(6)
    .frame(minWidth: 200)
  }

  @ViewBuilder
  private func filterRow(
    label: String,
    color: TagColor?,
    isSelected: Bool,
    action: @escaping () -> Void
  ) -> some View {
    Button(action: action) {
      HStack(spacing: 8) {
        if let color {
          Circle()
            .fill(swiftUIColor(for: color))
            .frame(width: 10, height: 10)
        } else {
          Color.clear.frame(width: 10, height: 10)
        }
        Text(label)
          .font(.callout)
          .foregroundStyle(.primary)
          .lineLimit(1)
        Spacer(minLength: 8)
        if isSelected {
          Image(systemName: "checkmark")
            .font(.caption.weight(.semibold))
            .foregroundStyle(Color.accentColor)
        }
      }
      .padding(.horizontal, 8)
      .padding(.vertical, 5)
      .background(
        RoundedRectangle(cornerRadius: 5)
          .fill(isSelected ? Color.accentColor.opacity(0.12) : Color.clear)
      )
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
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
