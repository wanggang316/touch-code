import SwiftUI

/// Placeholder for the Developer detail pane. T3 replaces this body with the real UI
/// (spec M6 — `tc` CLI install, Hooks list, Diagnostics). Signature is frozen so the detail
/// switch in `SettingsWindowView` does not churn across waves.
struct DeveloperSettingsView: View {
  var body: some View {
    Text("TODO: supplied by T3")
      .foregroundStyle(.secondary)
      .frame(maxWidth: .infinity, maxHeight: .infinity)
  }
}

#Preview {
  DeveloperSettingsView()
    .frame(width: 500, height: 300)
}
