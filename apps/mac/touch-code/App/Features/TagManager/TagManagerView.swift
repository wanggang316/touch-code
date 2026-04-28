import ComposableArchitecture
import SwiftUI
import TouchCodeCore

/// CRUD sheet for catalog tags. NavigationStack-hosted List driven by
/// `hierarchyManager.catalog.tags` (single source of truth — the reducer
/// owns no tag values, only the rename / removal transients).
///
/// Replaces the deleted `SpaceManagerSheet`. See
/// `docs/design-docs/project-tags.md` §3.4 for the wire-frame.
struct TagManagerSheet: View {
  @Bindable var store: StoreOf<TagManagerFeature>
  @Environment(HierarchyManager.self) private var hierarchyManager
  @Environment(\.dismiss) private var dismissEnv

  // Inline create-row state. Lives at the View level — these drafts
  // never need to round-trip through the reducer; on Add we send a
  // single `.createTagTapped(name, color)` and reset locally.
  @State private var newTagName: String = ""
  @State private var newTagColor: TagColor = .blue
  @FocusState private var renameFocused: Bool

  /// Width budget for the inline color picker block. Sized to fit
  /// `TagColor.allCases.count` (7) discs at 22pt cells with 6pt gaps —
  /// 7×22 + 6×6 = 190. Used to align the name column across the tag
  /// rows AND the bottom new-tag row so labels start at the same x.
  private static let pickerWidth: CGFloat = 190

  var body: some View {
    NavigationStack {
      VStack(spacing: 0) {
        header
        Divider()
        tagList
        Divider()
        newTagRow
      }
      .frame(minWidth: 540, minHeight: 400)
      .navigationTitle("Tags")
      .toolbar {
        ToolbarItem(placement: .confirmationAction) {
          Button("Done") { dismissEnv() }
        }
      }
      .confirmationDialog(
        confirmationTitle,
        isPresented: Binding(
          get: { store.pendingRemoval != nil },
          set: { if !$0 { store.send(.removeCancelled) } }
        ),
        titleVisibility: .visible
      ) {
        Button("Remove Tag", role: .destructive) {
          store.send(.removeConfirmed)
        }
        Button("Cancel", role: .cancel) {
          store.send(.removeCancelled)
        }
      } message: {
        Text(confirmationMessage)
      }
    }
  }

  // MARK: - Header

  private var header: some View {
    let tags = hierarchyManager.catalog.tags
    return HStack(alignment: .center, spacing: 14) {
      ZStack {
        RoundedRectangle(cornerRadius: 9, style: .continuous)
          .fill(Color.accentColor.opacity(0.14))
          .frame(width: 36, height: 36)
        Image(systemName: "tag.fill")
          .font(.system(size: 16, weight: .semibold))
          .foregroundStyle(Color.accentColor)
      }
      .accessibilityHidden(true)

      VStack(alignment: .leading, spacing: 2) {
        Text("Manage Tags")
          .font(.title3.weight(.semibold))
        Text("Color-coded labels for grouping projects in the sidebar.")
          .font(.subheadline)
          .foregroundStyle(.secondary)
      }
      Spacer(minLength: 12)
      Text(tags.count == 1 ? "1 tag" : "\(tags.count) tags")
        .font(.caption.weight(.medium))
        .monospacedDigit()
        .foregroundStyle(.secondary)
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(Capsule().fill(Color.secondary.opacity(0.12)))
    }
    .padding(.horizontal, 18)
    .padding(.top, 14)
    .padding(.bottom, 12)
  }

  // MARK: - Tag list

  private var tagList: some View {
    let tags = hierarchyManager.catalog.tags
    return Group {
      if tags.isEmpty {
        emptyState
      } else {
        List {
          ForEach(tags) { tag in
            tagRow(tag)
              .listRowSeparator(.hidden)
              .listRowInsets(EdgeInsets(top: 3, leading: 14, bottom: 3, trailing: 14))
          }
        }
        .listStyle(.inset)
        .scrollContentBackground(.hidden)
      }
    }
  }

  private var emptyState: some View {
    VStack(spacing: 8) {
      Spacer()
      Image(systemName: "tag")
        .font(.title)
        .foregroundStyle(.secondary)
        .accessibilityHidden(true)
      Text("No tags yet.")
        .foregroundStyle(.secondary)
      Text("Use the form below to add one.")
        .font(.caption)
        .foregroundStyle(.tertiary)
      Spacer()
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
  }

  @ViewBuilder
  private func tagRow(_ tag: Tag) -> some View {
    HoverableTagRow {
      ColorRowPicker(
        selected: tag.color,
        onPick: { store.send(.recolor(tag.id, $0)) }
      )
      .frame(width: Self.pickerWidth, alignment: .leading)
      nameField(tag: tag)
      Spacer(minLength: 8)
    } trailing: {
      Button {
        store.send(.removeTapped(tag.id, name: tag.name))
      } label: {
        Image(systemName: "minus.circle.fill")
          .font(.system(size: 14))
          .foregroundStyle(.secondary)
          .symbolRenderingMode(.hierarchical)
      }
      .buttonStyle(.plain)
      .help("Remove Tag")
    }
  }

  /// Inline-editable name. Tap converts the Text to a TextField; Submit
  /// commits, Esc cancels. The reducer holds the draft so a re-render
  /// (catalog mutation from a sibling action) doesn't blow away the
  /// half-typed name.
  @ViewBuilder
  private func nameField(tag: Tag) -> some View {
    if store.renameDraft?.tagID == tag.id {
      TextField(
        "Tag name",
        text: Binding(
          get: { store.renameDraft?.text ?? tag.name },
          set: { store.send(.renameDraftChanged($0)) }
        )
      )
      .textFieldStyle(.plain)
      .focused($renameFocused)
      .onAppear { renameFocused = true }
      .onSubmit { store.send(.renameCommitted) }
      .onExitCommand { store.send(.renameCancelled) }
    } else {
      Text(tag.name)
        .contentShape(Rectangle())
        .onTapGesture {
          store.send(.renameRowTapped(tag.id, currentName: tag.name))
        }
    }
  }

  // MARK: - New tag form

  private var newTagRow: some View {
    HStack(spacing: 10) {
      ColorRowPicker(
        selected: newTagColor,
        onPick: { newTagColor = $0 }
      )
      .frame(width: Self.pickerWidth, alignment: .leading)
      TextField("New tag name", text: $newTagName)
        .textFieldStyle(.plain)
        .onSubmit(addNewTag)
      Button("Add") { addNewTag() }
        .keyboardShortcut(.defaultAction)
        .disabled(newTagName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    }
    .padding(.horizontal, 22)
    .padding(.vertical, 12)
    .background(.bar)
  }

  private func addNewTag() {
    let trimmed = newTagName.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return }
    store.send(.createTagTapped(name: trimmed, color: newTagColor))
    newTagName = ""
  }

  // MARK: - Confirmation strings

  private var confirmationTitle: String {
    let name = store.pendingRemoval?.displayName ?? ""
    return "Remove tag \"\(name)\"?"
  }

  private var confirmationMessage: String {
    let count = store.pendingRemoval?.affectedProjectCount ?? 0
    if count == 1 {
      return "1 project will lose this tag. Project data is not affected."
    }
    return "\(count) projects will lose this tag. Project data is not affected."
  }
}

// MARK: - Inline color row picker

/// Single horizontal strip showing every `TagColor` as a colored disc,
/// rendered inline (no popover hop). Tapping a disc commits the color
/// immediately. The current selection draws a 1.5pt dark ring around
/// itself so the active hue is unmistakable even when neighboring colors
/// share luminance.
///
/// Sized so seven 22×22 hit cells with 6pt gaps fit in
/// `TagManagerSheet.pickerWidth` (190pt). Disc visual is 14pt; the
/// cell carries the extra padding to keep the click target generous.
private struct ColorRowPicker: View {
  let selected: TagColor
  let onPick: (TagColor) -> Void

  var body: some View {
    HStack(spacing: 6) {
      ForEach(TagColor.allCases, id: \.self) { color in
        Button {
          if color != selected { onPick(color) }
        } label: {
          swatchCell(color: color, isSelected: color == selected)
        }
        .buttonStyle(.plain)
        .help(color.rawValue.capitalized)
        .accessibilityLabel(color.rawValue.capitalized)
        .accessibilityAddTraits(color == selected ? [.isSelected] : [])
      }
    }
  }

  @ViewBuilder
  private func swatchCell(color: TagColor, isSelected: Bool) -> some View {
    ZStack {
      Circle()
        .fill(swiftUIColor(for: color))
        .frame(width: 14, height: 14)
        .overlay(
          Circle().strokeBorder(Color.black.opacity(0.10), lineWidth: 0.5)
        )
      if isSelected {
        Circle()
          .strokeBorder(Color.primary.opacity(0.85), lineWidth: 1.5)
          .frame(width: 20, height: 20)
      }
    }
    .frame(width: 22, height: 22)
    .contentShape(Rectangle())
  }
}

// MARK: - Hover row

/// Wraps a tag list row so the trailing affordance (delete button) only
/// reveals on hover — matches Finder's Tags preferences pane and keeps
/// the steady-state list visually quiet. Hover background gives a faint
/// highlight without painting a full selection bar.
private struct HoverableTagRow<Leading: View, Trailing: View>: View {
  @ViewBuilder let leading: () -> Leading
  @ViewBuilder let trailing: () -> Trailing
  @State private var isHovering = false

  var body: some View {
    HStack(spacing: 10) {
      leading()
      trailing()
        .opacity(isHovering ? 1 : 0)
    }
    .padding(.horizontal, 8)
    .padding(.vertical, 4)
    .background(
      RoundedRectangle(cornerRadius: 6)
        .fill(isHovering ? Color.primary.opacity(0.05) : Color.clear)
    )
    .contentShape(Rectangle())
    .onHover { isHovering = $0 }
  }
}
