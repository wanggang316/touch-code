// MARK: M6
import ComposableArchitecture
import SwiftUI

/// Segmented picker for unified ↔ split. Reads/writes
/// `@AppStorage("diffStyle")` AND dispatches `.styleChanged` so the
/// reducer state mirrors the persisted value.
struct DiffStylePicker: View {
  @Bindable var store: StoreOf<DiffFeature>
  @AppStorage("diffStyle") private var persisted: String = DiffStyle.unified.rawValue

  var body: some View {
    Picker(selection: pickerBinding) {
      Image(systemName: "text.alignleft").tag(DiffStyle.unified)
      Image(systemName: "rectangle.split.2x1").tag(DiffStyle.split)
    } label: {
      EmptyView()
    }
    .pickerStyle(.segmented)
    .labelsHidden()
    .frame(width: 84)
    .accessibilityLabel("Diff style")
    .onAppear {
      // Sync persisted @AppStorage into reducer state on first present —
      // if the app relaunched, store.state.style starts at the default
      // and would otherwise lag the segmented control.
      if let restored = DiffStyle(rawValue: persisted), restored != store.state.style {
        store.send(.styleChanged(restored))
      }
    }
  }

  private var pickerBinding: Binding<DiffStyle> {
    Binding<DiffStyle>(
      get: { store.state.style },
      set: { newValue in
        guard newValue != store.state.style else { return }
        persisted = newValue.rawValue
        store.send(.styleChanged(newValue))
      }
    )
  }
}
