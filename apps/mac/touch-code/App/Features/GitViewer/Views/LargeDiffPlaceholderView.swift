import ComposableArchitecture
import SwiftUI
import TouchCodeCore

/// Rendered in place of `UnifiedDiffView` when the parser throws `GitError.diffTooLarge`.
/// Shows a brief explanation plus a "Copy command" button that places a POSIX-quoted
/// `cd '<abs-path>' && git …` string on the pasteboard. The user pastes into any terminal
/// to inspect the diff with their full toolchain.
///
/// Per-file summary rows are deliberately absent: `DiffParser` throws before yielding any
/// `FileChange` values once the line cap is hit, so there is nothing to enumerate. A future
/// parser change that returns partial results (0005 plan review "suggestion: partial
/// UnifiedDiff with truncated: true") would unlock the per-file preview — deferred.
struct LargeDiffPlaceholderView: View {
  let scope: DiffScope
  let worktreePath: String?

  @State private var copied = false

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      HStack(spacing: 8) {
        Image(systemName: "exclamationmark.triangle.fill")
          .accessibilityHidden(true)
          .foregroundStyle(.orange)
        Text("Diff too large")
          .font(.headline)
      }
      Text("This diff exceeds the 50 000-line cap. Copy the command below and run it in a terminal to inspect it with your full git toolchain.")
        .font(.callout)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)

      if let command = resolvedCommand {
        Text(command)
          .font(.system(.callout, design: .monospaced))
          .textSelection(.enabled)
          .padding(.horizontal, 10)
          .padding(.vertical, 6)
          .frame(maxWidth: .infinity, alignment: .leading)
          .background(Color(nsColor: .textBackgroundColor), in: .rect(cornerRadius: 6))

        HStack(spacing: 8) {
          Button {
            copy(command)
          } label: {
            Label(copied ? "Copied" : "Copy command", systemImage: copied ? "checkmark" : "doc.on.doc")
          }
          .controlSize(.large)
          .keyboardShortcut("c", modifiers: [.command, .shift])

          Text("⌘⇧C")
            .font(.caption.monospaced())
            .foregroundStyle(.tertiary)

          Spacer(minLength: 0)
        }
      } else {
        Text(unavailableReason)
          .font(.callout)
          .foregroundStyle(.secondary)
      }

      Spacer(minLength: 0)
    }
    .padding(16)
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
  }

  // MARK: - Helpers

  /// The rendered command, or nil if the scope/worktree combination can't produce one.
  private var resolvedCommand: String? {
    guard let path = worktreePath else { return nil }
    return try? LargeDiffCommand.build(scope: scope, worktreePath: path)
  }

  private var unavailableReason: String {
    if worktreePath == nil { return "No worktree selected." }
    if case .log = scope { return "Log scope paginates and cannot hit the cap." }
    return "Unavailable for this scope."
  }

  private func copy(_ command: String) {
    let pb = NSPasteboard.general
    pb.clearContents()
    pb.setString(command, forType: .string)
    copied = true
    // Reset the label after a short delay so the user gets the success feedback without
    // the label sticking forever.
    Task {
      try? await Task.sleep(for: .seconds(1.2))
      await MainActor.run { copied = false }
    }
  }
}
