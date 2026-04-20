import ComposableArchitecture
import SwiftUI
import TouchCodeCore

/// Root view for the Settings sheet. Ships with the Editors pane; future panes slot in as
/// additional sections. Dismissed via the top-right Done button or sheet chrome.
struct SettingsSheetView: View {
  @Bindable var store: StoreOf<SettingsSheetFeature>
  let onDismiss: () -> Void

  var body: some View {
    VStack(spacing: 0) {
      header
      Divider()
      ScrollView {
        VStack(alignment: .leading, spacing: 24) {
          SettingsEditorSection(
            store: store.scope(state: \.editor, action: \.editor)
          )
        }
        .padding(24)
      }
    }
    .frame(minWidth: 560, idealWidth: 640, minHeight: 420, idealHeight: 560)
  }

  private var header: some View {
    HStack {
      Text("Settings")
        .font(.title2.bold())
      Spacer(minLength: 0)
      Button("Done") {
        store.send(.dismissTapped)
        onDismiss()
      }
      .keyboardShortcut(.return, modifiers: [.command])
      .controlSize(.large)
    }
    .padding(.horizontal, 20)
    .padding(.vertical, 12)
  }
}
