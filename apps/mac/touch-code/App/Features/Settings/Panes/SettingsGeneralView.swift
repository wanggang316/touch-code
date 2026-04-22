import ComposableArchitecture
import SwiftUI
import TouchCodeCore

/// General pane — global "Default editor" picker (C8a Phase 4a).
///
/// Contract: shows only installed editors, grouped by category with thin dividers between
/// groups. The list order follows `EditorRegistry.menuOrder`; "installed" means the
/// descriptor is present in the live `describe()` result (which already applies the
/// Launch Services filter and always keeps `.shellEditor`).
///
/// Refresh model: the view dispatches `.refreshRequested` on appear so the service's
/// `describe()` cache is flushed before re-fetch. Editors installed while touch-code was
/// running therefore surface the first time Settings is opened (design R4).
struct SettingsGeneralView: View {
  @Bindable var store: StoreOf<EditorFeature>
  let settingsStore: SettingsStore

  private var selectionBinding: Binding<EditorID?> {
    Binding(
      get: { store.globalDefault },
      set: { store.send(.setGlobalDefault($0)) }
    )
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      Text("General")
        .font(.title2.bold())

      VStack(alignment: .leading, spacing: 6) {
        Text("Default editor")
          .font(.subheadline.weight(.medium))

        Picker("Default editor", selection: selectionBinding) {
          pickerContent
        }
        .pickerStyle(.menu)
        .labelsHidden()

        Text(
          "Used when opening a directory. Falls back to Finder if the chosen editor is uninstalled later."
        )
        .font(.caption)
        .foregroundStyle(.secondary)
      }

      Spacer()
    }
    .padding(24)
    .frame(maxWidth: .infinity, alignment: .leading)
    .task { store.send(.refreshRequested) }
    .onAppear { store.send(.onAppear) }
  }

  /// Picker body — split out so `Picker(... ) { pickerContent }` stays readable. Emits an
  /// empty option when no descriptors are loaded yet so the menu never renders an empty
  /// ghost selection.
  @ViewBuilder
  private var pickerContent: some View {
    let groups = EditorPickerRow.grouped(store.descriptors)
    if groups.isEmpty {
      // First frame before `describe()` returns; no sentinel row — the menu just shows
      // the stored default ID (or nothing) until the refresh effect lands.
      EmptyView()
    } else {
      ForEach(Array(groups.enumerated()), id: \.offset) { index, group in
        if index > 0 { Divider() }
        ForEach(group, id: \.id) { descriptor in
          HStack(spacing: 6) {
            EditorPickerRow.icon(for: descriptor)
            Text(descriptor.displayName)
          }
          .tag(EditorID?(descriptor.id))
        }
      }
    }
  }
}

#if DEBUG
#Preview("SettingsGeneralView") {
  SettingsGeneralView(
    store: Store(initialState: EditorFeature.State()) { EditorFeature() },
    settingsStore: SettingsStore(
      fileURL: FileManager.default.temporaryDirectory.appending(component: "\(UUID()).json"),
      debounceWindow: .seconds(3600)
    )
  )
  .frame(width: 520, height: 320)
}
#endif
