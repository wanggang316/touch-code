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
      .frame(minWidth: 380, minHeight: 360)
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
          }
        }
        .listStyle(.inset)
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
    HStack(spacing: 10) {
      colorSwatchMenu(tag: tag)
      nameField(tag: tag)
      Spacer()
      Button {
        store.send(.removeTapped(tag.id, name: tag.name))
      } label: {
        Image(systemName: "trash")
          .foregroundStyle(.secondary)
      }
      .buttonStyle(.borderless)
      .help("Remove Tag")
    }
    .padding(.vertical, 2)
  }

  /// Color swatch as a Menu over a 14×14 circle. Each palette case is a
  /// Button that fires `.recolor`.
  @ViewBuilder
  private func colorSwatchMenu(tag: Tag) -> some View {
    Menu {
      ForEach(TagColor.allCases, id: \.self) { color in
        Button {
          store.send(.recolor(tag.id, color))
        } label: {
          Label(color.rawValue.capitalized, systemImage: tag.color == color ? "checkmark" : "")
        }
      }
    } label: {
      Circle()
        .fill(swiftUIColor(for: tag.color))
        .frame(width: 14, height: 14)
        .overlay(Circle().strokeBorder(Color.primary.opacity(0.15), lineWidth: 0.5))
    }
    .menuStyle(.button)
    .menuIndicator(.hidden)
    .buttonStyle(.plain)
    .fixedSize()
    .help("Change Color")
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
      .textFieldStyle(.roundedBorder)
      .focused($renameFocused)
      .onAppear { renameFocused = true }
      .onSubmit { store.send(.renameCommitted) }
      .onExitCommand { store.send(.renameCancelled) }
    } else {
      Text(tag.name)
        .onTapGesture {
          store.send(.renameRowTapped(tag.id, currentName: tag.name))
        }
    }
  }

  // MARK: - New tag form

  private var newTagRow: some View {
    HStack(spacing: 8) {
      Menu {
        ForEach(TagColor.allCases, id: \.self) { color in
          Button {
            newTagColor = color
          } label: {
            Label(
              color.rawValue.capitalized,
              systemImage: newTagColor == color ? "checkmark" : ""
            )
          }
        }
      } label: {
        Circle()
          .fill(swiftUIColor(for: newTagColor))
          .frame(width: 14, height: 14)
          .overlay(Circle().strokeBorder(Color.primary.opacity(0.15), lineWidth: 0.5))
      }
      .menuStyle(.button)
      .menuIndicator(.hidden)
      .buttonStyle(.plain)
      .fixedSize()
      .help("New Tag Color")

      TextField("New tag name", text: $newTagName)
        .textFieldStyle(.roundedBorder)
        .onSubmit(addNewTag)

      Button("Add") { addNewTag() }
        .keyboardShortcut(.defaultAction)
        .disabled(newTagName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    }
    .padding(10)
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
