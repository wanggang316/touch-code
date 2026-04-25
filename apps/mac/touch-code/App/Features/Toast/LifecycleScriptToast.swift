import ComposableArchitecture
import SwiftUI
import TouchCodeCore

/// Sheet view for `LifecycleScriptToastFeature`. Renders the phase
/// + worktree name as a status line, the captured output in a
/// scrollable monospace box, and a context-aware action button
/// (Cancel while running, Dismiss on terminal exit). Mounted on the
/// main window via `.sheet(item:)` from `RootFeature`.
struct LifecycleScriptToast: View {
  @Bindable var store: StoreOf<LifecycleScriptToastFeature>
  @Environment(\.dismiss) private var dismiss

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      HStack(spacing: 8) {
        statusIcon
        VStack(alignment: .leading, spacing: 2) {
          Text(titleText)
            .font(.headline)
            .foregroundStyle(titleColor)
          Text(store.worktreeName)
            .font(.subheadline)
            .foregroundStyle(.secondary)
        }
        Spacer()
      }

      ScrollView {
        Text(store.output.isEmpty ? "(no output)" : store.output)
          .font(.system(.caption, design: .monospaced))
          .textSelection(.enabled)
          .frame(maxWidth: .infinity, alignment: .leading)
          .padding(8)
      }
      .frame(minHeight: 140, maxHeight: 280)
      .background(Color(NSColor.textBackgroundColor))
      .cornerRadius(6)
      .overlay(
        RoundedRectangle(cornerRadius: 6)
          .strokeBorder(Color.secondary.opacity(0.25))
      )

      HStack {
        Spacer()
        actionButton
      }
    }
    .padding(20)
    .frame(minWidth: 420, minHeight: 260)
  }

  @ViewBuilder
  private var statusIcon: some View {
    switch store.exitState {
    case .running:
      ProgressView().controlSize(.small)
    case .succeeded:
      Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
    case .failed:
      Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.red)
    }
  }

  private var titleText: String {
    let phaseLabel: String
    switch store.phase {
    case .setup: phaseLabel = "Setup"
    case .archive: phaseLabel = "Archive"
    case .delete: phaseLabel = "Delete"
    }
    switch store.exitState {
    case .running: return "\(phaseLabel) script running…"
    case .succeeded: return "\(phaseLabel) script succeeded"
    case .failed(let code): return "\(phaseLabel) script failed (exit \(code))"
    }
  }

  private var titleColor: Color {
    switch store.exitState {
    case .running: return .primary
    case .succeeded: return .green
    case .failed: return .red
    }
  }

  @ViewBuilder
  private var actionButton: some View {
    switch store.exitState {
    case .running:
      Button("Cancel") { store.send(.cancelTapped) }
    case .succeeded, .failed:
      Button("Dismiss") { store.send(.dismissTapped) }
        .keyboardShortcut(.defaultAction)
    }
  }
}
