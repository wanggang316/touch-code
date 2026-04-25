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
/// Editor picker contract: shared visual style with every other Open-in dropdown across
/// the app — a flat priority-ordered list of installed editors (no Automatic sentinel,
/// no grouping/dividers), each row showing `icon + displayName` via `EditorPickerRow`.
/// Priority walk when `globalDefault` is nil is still honoured downstream in
/// `EditorFeature.resolveDefault`; the picker simply does not surface the nil state as
/// a selectable choice.
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
      Section {
        LabeledContent("Appearance") {
          Picker("Appearance", selection: appearanceBinding) {
            Text("System").tag(AppearancePreference.system)
            Text("Light").tag(AppearancePreference.light)
            Text("Dark").tag(AppearancePreference.dark)
          }
          .pickerStyle(.segmented)
          .labelsHidden()
          .fixedSize()
        }
      }

      Section {
        Picker("Default editor", selection: selectionBinding) {
          pickerContent
        }
        .pickerStyle(.menu)
      } footer: {
        Text(
          "Used when opening a directory. Falls back to Finder if the chosen editor "
            + "is uninstalled later."
        )
      }
    }
    .formStyle(.grouped)
    .task { store.send(.refreshRequested) }
    .onAppear { store.send(.onAppear) }
  }

  /// Picker body — split out so `Picker(... ) { pickerContent }` stays readable. Flat
  /// priority-ordered list via `EditorPickerRow.sorted`, rendered through the shared
  /// `row(for:)` builder so every Open-in dropdown in the app reads identically.
  @ViewBuilder
  private var pickerContent: some View {
    ForEach(EditorPickerRow.sorted(store.descriptors), id: \.id) { descriptor in
      EditorPickerRow.row(for: descriptor)
        .tag(EditorID?(descriptor.id))
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
