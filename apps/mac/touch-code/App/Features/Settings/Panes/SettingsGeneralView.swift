import ComposableArchitecture
import SwiftUI
import TouchCodeCore

/// General pane — Appearance + global "Default editor" picker.
///
/// Appearance writes directly through `SettingsStore.setAppearance(_:)` (injected via the
/// environment-held store); the value is read back by `AppAppearanceView` wrapped around
/// every scene to drive both SwiftUI's `.preferredColorScheme` and the AppKit
/// `NSApp.appearance` poke. No TCA round-trip because appearance doesn't participate in
/// any other reducer state.
///
/// Editor picker contract (C8a Phase 4a): shows only installed editors, grouped by
/// category with thin dividers between groups. Order follows `EditorRegistry.menuOrder`;
/// "installed" means the descriptor is present in the live `describe()` result (which
/// already applies the Launch Services filter and always keeps `.shellEditor`).
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

  private var appearanceBinding: Binding<AppearancePreference> {
    Binding(
      get: { settingsStore.settings.general.appearance },
      set: { settingsStore.setAppearance($0) }
    )
  }

  var body: some View {
    Form {
      Section("Appearance") {
        Picker("Appearance", selection: appearanceBinding) {
          Text("System").tag(AppearancePreference.system)
          Text("Light").tag(AppearancePreference.light)
          Text("Dark").tag(AppearancePreference.dark)
        }
        .pickerStyle(.segmented)
        .frame(maxWidth: 280, alignment: .trailing)
      }

      Section {
        Picker("Default editor", selection: selectionBinding) {
          pickerContent
        }
        .pickerStyle(.menu)
      } header: {
        Text("Default editor")
      } footer: {
        Text(
          "Used when opening a directory. \"Automatic\" picks the first installed editor "
            + "from the priority list; a specific choice falls back to Finder if the editor "
            + "is uninstalled later."
        )
      }
    }
    .formStyle(.grouped)
    .task { store.send(.refreshRequested) }
    .onAppear { store.send(.onAppear) }
  }

  /// Picker body — split out so `Picker(... ) { pickerContent }` stays readable. The
  /// "Automatic" row tagged `EditorID?(nil)` gives the user a way back to priority-walk
  /// resolution after picking any concrete editor; without it the picker has no path to
  /// clear the stored default (even though the IPC setter and the reducer both accept nil).
  /// Mirrors the "Use global default" sentinel in the Project Options picker.
  @ViewBuilder
  private var pickerContent: some View {
    HStack(spacing: 6) {
      Image(systemName: "wand.and.sparkles")
        .resizable()
        .aspectRatio(contentMode: .fit)
        .frame(width: 16, height: 16)
        .foregroundStyle(.secondary)
        .accessibilityHidden(true)
      Text("Automatic")
    }
    .tag(EditorID?(nil))

    let groups = EditorPickerRow.grouped(store.descriptors)
    ForEach(Array(groups.enumerated()), id: \.offset) { _, group in
      Divider()
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
