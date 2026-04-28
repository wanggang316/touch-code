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

  var body: some View {
    NavigationStack {
      VStack(spacing: 0) {
        tagList
        Divider()
        newTagRow
      }
      .frame(minWidth: 420, minHeight: 380)
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
              .listRowInsets(EdgeInsets(top: 4, leading: 12, bottom: 4, trailing: 12))
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
      ColorSwatchPicker(
        selected: tag.color,
        onPick: { store.send(.recolor(tag.id, $0)) }
      )
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
      ColorSwatchPicker(
        selected: newTagColor,
        onPick: { newTagColor = $0 }
      )
      TextField("New tag name", text: $newTagName)
        .textFieldStyle(.plain)
        .onSubmit(addNewTag)
      Button("Add") { addNewTag() }
        .keyboardShortcut(.defaultAction)
        .disabled(newTagName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    }
    .padding(.horizontal, 12)
    .padding(.vertical, 10)
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

// MARK: - Color swatch picker

/// Visual color picker — the trigger is a single colored disc; tapping
/// opens a popover with a single row of seven colored discs (one per
/// `TagColor.allCases`). The current color carries an accent-tinted ring
/// and an inner checkmark so it stands out against same-hue siblings.
/// No text labels: the colors themselves are the affordance, matching
/// macOS Reminders / Finder tag pickers.
private struct ColorSwatchPicker: View {
  let selected: TagColor
  let onPick: (TagColor) -> Void

  @State private var isPopoverPresented = false

  var body: some View {
    Button {
      isPopoverPresented.toggle()
    } label: {
      swatch(color: selected, isSelected: false, size: 16)
        .overlay(
          Circle().strokeBorder(Color.primary.opacity(0.18), lineWidth: 0.5)
        )
    }
    .buttonStyle(.plain)
    .help("Change Color")
    .popover(isPresented: $isPopoverPresented, arrowEdge: .top) {
      HStack(spacing: 10) {
        ForEach(TagColor.allCases, id: \.self) { color in
          Button {
            onPick(color)
            isPopoverPresented = false
          } label: {
            swatch(color: color, isSelected: color == selected, size: 20)
          }
          .buttonStyle(.plain)
          .help(color.rawValue.capitalized)
          .accessibilityLabel(color.rawValue.capitalized)
          .accessibilityAddTraits(color == selected ? [.isSelected] : [])
        }
      }
      .padding(.horizontal, 12)
      .padding(.vertical, 10)
    }
  }

  @ViewBuilder
  private func swatch(color: TagColor, isSelected: Bool, size: CGFloat) -> some View {
    ZStack {
      Circle()
        .fill(swiftUIColor(for: color))
        .frame(width: size, height: size)
      if isSelected {
        Circle()
          .strokeBorder(Color.accentColor, lineWidth: 2)
          .frame(width: size + 6, height: size + 6)
        Image(systemName: "checkmark")
          .font(.system(size: size * 0.55, weight: .bold))
          .foregroundStyle(.white)
          .shadow(color: .black.opacity(0.25), radius: 0.5, y: 0.5)
      }
    }
    .frame(width: size + 8, height: size + 8)
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
