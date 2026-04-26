import ComposableArchitecture
import SwiftUI
import TouchCodeCore

/// Split button: left half opens the resolved default editor; right
/// half (caret) is the picker menu. Built as two siblings inside one
/// HStack — both halves share the toolbar's glass capsule but light up
/// independently on hover via `HeaderChipHover`. Caret is a fixed 1:1
/// square the same height as the primary chip so the visual contract
/// matches the Run-Script split button.
///
/// Resolution + delegate routing flow through `WorktreeHeaderFeature`,
/// keeping the open side-effect on `RootFeature`.
struct HeaderOpenSplitButton: View {
  @Bindable var store: StoreOf<WorktreeHeaderFeature>
  @Bindable var editorStore: StoreOf<EditorFeature>
  let spaceID: SpaceID
  let projectID: ProjectID
  let worktreePath: String
  @Environment(HierarchyManager.self) private var hierarchyManager
  @Environment(SettingsStore.self) private var settingsStore

  /// Layout invariants:
  /// 1. The outer toolbar capsule has a fixed total height (computed
  ///    here as `chipSide + 2 × edgeInset` plus the toolbar's own glass
  ///    padding).
  /// 2. The outer width is dynamic — primary text varies as the user
  ///    picks a different default editor.
  /// 3. The caret is a hard 1:1 square (`chipSide × chipSide`).
  /// 4. The two inner halves (primary, caret) sit inside the outer
  ///    capsule with the same `edgeInset` on every side.
  private static let chipSide: CGFloat = 22
  private static let edgeInset: CGFloat = 4

  var body: some View {
    HStack(spacing: 4) {
      primary
      caret
    }
    // The same inset on every side gives equal breathing room between
    // the two inner halves and the outer toolbar capsule.
    .padding(Self.edgeInset)
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
      // Horizontal padding gives the icon + text breathing room inside
      // the primary hover capsule. Vertical sizing comes from the
      // shared `.frame(height: chipSide)` so this half is flush with
      // the caret square.
      .padding(.horizontal, 6)
      .frame(height: Self.chipSide)
    }
    .buttonStyle(.plain)
    .accessibilityLabel(primaryDescription)
    .help(primaryDescription)
    .modifier(HeaderChipHover())
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

  // MARK: - Caret

  private var caret: some View {
    Menu {
      openInMenu
    } label: {
      Image(systemName: "chevron.down")
        .font(.caption.bold())
        .accessibilityHidden(true)
        .frame(width: Self.chipSide, height: Self.chipSide)
    }
    .menuStyle(.button)
    .buttonStyle(.plain)
    .menuIndicator(.hidden)
    .accessibilityLabel("Choose editor")
    .help("Choose editor")
    .modifier(HeaderChipHover())
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
