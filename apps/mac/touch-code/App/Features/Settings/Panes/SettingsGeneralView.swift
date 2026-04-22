import ComposableArchitecture
import SwiftUI
import TouchCodeCore

/// General pane placeholder for C8a Phase 3. The previous view exposed the custom-editor
/// surface (add/update/remove) retired in C8a. Phase 4a re-implements this pane against
/// the new `EditorDescriptor` shape (icons via `NSWorkspace.shared.icon(forFile:)`,
/// installed-only dropdown).
struct SettingsGeneralView: View {
  @Bindable var store: StoreOf<EditorFeature>
  let settingsStore: SettingsStore

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      Text("General")
        .font(.title2.bold())
      Text("Editor settings pending C8a Phase 4a migration.")
        .foregroundStyle(.secondary)
      Spacer()
    }
    .padding(24)
    .frame(maxWidth: .infinity, alignment: .leading)
    .task { store.send(.onAppear) }
  }
}
