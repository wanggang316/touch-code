import ComposableArchitecture
import SwiftUI
import TouchCodeCore

/// Split button: left half opens the resolved default editor; right half
/// (caret) is the picker menu. Resolution, picker content, and the
/// "Set default for this Project" sub-menu all flow through the
/// `WorktreeHeaderFeature` delegate so `RootFeature` owns the editor-open
/// side effect and descriptors stay TCA-observable.
struct HeaderOpenSplitButton: View {
  @Bindable var store: StoreOf<WorktreeHeaderFeature>
  @Bindable var editorStore: StoreOf<EditorFeature>
  let spaceID: SpaceID
  let projectID: ProjectID
  let worktreePath: String
  @Environment(HierarchyManager.self) private var hierarchyManager
  @Environment(SettingsStore.self) private var settingsStore

  var body: some View {
    HStack(spacing: 0) {
      primary
      caret
    }
    .task { editorStore.send(.onAppear) }
  }

  // MARK: - Primary

  private var primary: some View {
    Button {
      store.send(
        .openDefaultEditorTapped(
          worktreePath: worktreePath,
          projectID: projectID
        ))
    } label: {
      HStack(spacing: 4) {
        primaryIcon
          .frame(width: 16, height: 16)
          .accessibilityHidden(true)
        Text(primaryLabel)
          .lineLimit(1)
      }
      .padding(.horizontal, 6)
      .padding(.vertical, 3)
    }
    .buttonStyle(.borderless)
    .accessibilityLabel(primaryDescription)
    .help(primaryDescription)
  }

  @ViewBuilder
  private var primaryIcon: some View {
    switch resolvedDefault {
    case .editor(let descriptor):
      AppIconImage(
        bundleIdentifier: descriptor.bundleIdentifier,
        fallbackSystemName: "arrow.up.right.square"
      )
    case .finder:
      AppIconImage(
        bundleIdentifier: "com.apple.finder",
        fallbackSystemName: "folder"
      )
    }
  }

  /// Visible button label. Drops the "Open in " prefix so the trailing
  /// toolbar capsules stay compact; the icon already conveys intent.
  private var primaryLabel: String {
    switch resolvedDefault {
    case .editor(let descriptor): return descriptor.displayName
    case .finder: return "Finder"
    }
  }

  /// Verbose form used for accessibility + help tooltip — VoiceOver and
  /// the hover tooltip still benefit from the explicit verb.
  private var primaryDescription: String {
    switch resolvedDefault {
    case .editor(let descriptor): return "Open in \(descriptor.displayName)"
    case .finder: return "Open in Finder"
    }
  }

  private var resolvedDefault: EditorFeature.ResolvedDefault {
    EditorFeature.resolveDefault(
      projectOverride: projectOverrideID,
      globalDefault: editorStore.state.globalDefault,
      descriptors: editorStore.state.descriptors
    )
  }

  private var projectOverrideID: EditorID? {
    // v3 reads per-Project editor override from settings.json.projects[pid].
    settingsStore.settings.projects[projectID]?.defaultEditor
  }

  // MARK: - Caret menu

  private var caret: some View {
    Menu {
      openInMenu
    } label: {
      Image(systemName: "chevron.down")
        .font(.caption.bold())
        .accessibilityHidden(true)
        .padding(.horizontal, 4)
        .padding(.vertical, 3)
    }
    .menuStyle(.borderlessButton)
    .menuIndicator(.hidden)
    .accessibilityLabel("Choose editor")
    .help("Choose editor")
  }

  @ViewBuilder
  private var openInMenu: some View {
    // `EditorService.describe()` already filters to installed entries, so every
    // descriptor is launch-ready. `EditorPickerRow.sorted` gives the same priority
    // order used by every other Open-in dropdown; `row(for:)` renders the shared
    // `icon + displayName` row (including the terminal glyph for the shell editor).
    ForEach(EditorPickerRow.sorted(editorStore.state.descriptors), id: \.id) { descriptor in
      Button {
        store.send(
          .openEditorTapped(
            editorID: descriptor.id,
            worktreePath: worktreePath,
            projectID: projectID
          ))
      } label: {
        EditorPickerRow.row(for: descriptor)
      }
      .help(descriptor.displayName)
    }
  }

}
