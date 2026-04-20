import SwiftUI

/// Slot reserved for C6 M5 (agent-notification inbox sidebar).
///
/// DEC-2 (exec plan 0007) resolved the C6 placement as option (b):
/// leading-column mode-swap. The `SidebarMode` enum in `RootFeature.State`
/// controls whether the leading column renders `HierarchySidebarView` or
/// this inbox view. C6's plan replaces this file with the real feature.
struct InboxSidebarPlaceholder: View {
  var body: some View {
    VStack(spacing: 12) {
      Image(systemName: "bell.badge")
        .accessibilityHidden(true)
        .font(.largeTitle)
        .foregroundStyle(.secondary)
      Text("Inbox")
        .font(.headline)
      Text("Agent notifications will appear here.\nSlot reserved for C6 M5.")
        .font(.caption)
        .foregroundStyle(.secondary)
        .multilineTextAlignment(.center)
      Spacer()
    }
    .padding()
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
  }
}
