import ComposableArchitecture
import SwiftUI

struct NewSpaceSheet: View {
  @Bindable var store: StoreOf<NewSpaceFeature>

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      Text("New Space")
        .font(.headline)
      TextField("Space name", text: $store.draftName)
        .textFieldStyle(.roundedBorder)
      HStack {
        Spacer()
        Button("Cancel") { store.send(.cancelButtonTapped) }
          .keyboardShortcut(.cancelAction)
        Button("Create") { store.send(.submitButtonTapped) }
          .keyboardShortcut(.defaultAction)
          .disabled(store.draftName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
      }
    }
    .padding(20)
    .frame(minWidth: 320)
  }
}

struct NewTabSheet: View {
  @Bindable var store: StoreOf<NewTabFeature>

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      Text("New Tab")
        .font(.headline)
      TextField("Tab name (optional)", text: $store.draftName)
        .textFieldStyle(.roundedBorder)
      HStack {
        Spacer()
        Button("Cancel") { store.send(.cancelButtonTapped) }
          .keyboardShortcut(.cancelAction)
        Button("Create") { store.send(.submitButtonTapped) }
          .keyboardShortcut(.defaultAction)
      }
    }
    .padding(20)
    .frame(minWidth: 320)
  }
}
