import AppKit
import ComposableArchitecture
import SwiftUI
import TouchCodeCore

/// Rendered in place of `UnifiedDiffView` when the parser throws `GitError.diffTooLarge`.
/// Shows a brief explanation plus a "Copy command" button that places a POSIX-quoted
/// `cd '<abs-path>' && git …` string on the pasteboard. The user pastes into any terminal
/// to inspect the diff with their full toolchain.
///
/// The `copyCommandToken` binding routes the ⌘⇧C keyboard shortcut from
/// `GitViewerKeybindings`: the reducer bumps the nonce, the view observes via `.onChange`
/// and performs the pasteboard write. This keeps the NSPasteboard I/O in the view (where
/// the `AppKit` dependency naturally lives) while the binding participates in the same
/// single-source-of-truth keybinding model as every other key.
///
/// Per-file summary rows are deliberately absent: `DiffParser` throws before yielding any
/// `FileChange` values once the line cap is hit, so there is nothing to enumerate. A future
/// parser change that returns partial results would unlock a per-file preview — deferred.
struct LargeDiffPlaceholderView: View {
  let scope: DiffScope
  let worktreePath: String?
  /// Monotonic nonce from the reducer. View `onChange`s this to perform keyboard-triggered
  /// copy without duplicating the pasteboard logic.
  let copyCommandToken: Int

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
            performCopy(command)
          } label: {
            Label(copied ? "Copied" : "Copy command", systemImage: copied ? "checkmark" : "doc.on.doc")
          }
          .controlSize(.large)

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
    // Keyboard-driven copy: reducer bumped the nonce, trigger the same path as the button.
    .onChange(of: copyCommandToken) { _, _ in
      guard let command = resolvedCommand else { return }
      performCopy(command)
    }
    // Label-reset with implicit cancellation: SwiftUI cancels the prior task when `copied`
    // flips, preventing a race where an earlier sleep clobbers a fresh "Copied" after a
    // rapid second click. Same lifecycle semantics as the view (cancels on disappear).
    .task(id: copied) {
      guard copied else { return }
      try? await Task.sleep(for: .seconds(1.2))
      if !Task.isCancelled {
        copied = false
      }
    }
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

  private func performCopy(_ command: String) {
    let pb = NSPasteboard.general
    pb.clearContents()
    pb.setString(command, forType: .string)
    copied = true
    // Reset is driven by `.task(id: copied)` above, which cancels automatically on the next
    // click or on view disappearance.
  }
}
