import SwiftUI

/// Terminal-region placeholder shown when a Worktree is selected but the
/// active Tab is nil — i.e. the user closed the last Tab, or restored a
/// snapshot whose tabs were pruned. Mirrors supacode's
/// `EmptyTerminalPaneView`: terminal glyph + title + a `+` hint that
/// points at the tab-bar plus button rendered immediately above this
/// view, so the user's eye lands on the same affordance the message
/// describes.
struct EmptyTerminalPaneView: View {
  let message: String

  var body: some View {
    VStack(spacing: 12) {
      Image(systemName: "apple.terminal.on.rectangle")
        .font(.title)
        .imageScale(.large)
        .accessibilityHidden(true)
        .foregroundStyle(.secondary)
      VStack(spacing: 4) {
        Text(message)
          .font(.title3)
        Text("Use the \(Text("+").bold()) button to open a terminal.")
          .font(.subheadline)
          .foregroundStyle(.secondary)
      }
    }
    .multilineTextAlignment(.center)
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .background(Color(nsColor: .windowBackgroundColor))
  }
}

#Preview {
  EmptyTerminalPaneView(message: "No terminals open")
    .frame(width: 600, height: 400)
}
