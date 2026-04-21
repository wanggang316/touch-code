import SwiftUI

/// Placeholder for the Notifications detail pane. T2 replaces this body with the real UI
/// (spec M5). Keep the `struct` name and initializer signature stable so the detail switch
/// in `SettingsWindowView` does not churn across waves.
struct NotificationsSettingsView: View {
  var body: some View {
    Text("TODO: supplied by T2")
      .foregroundStyle(.secondary)
      .frame(maxWidth: .infinity, maxHeight: .infinity)
  }
}

#Preview {
  NotificationsSettingsView()
    .frame(width: 500, height: 300)
}
