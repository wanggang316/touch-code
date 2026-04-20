import ComposableArchitecture
import SwiftUI
import TouchCodeCore

/// Renders the hunks of the currently-selected file in the diff. `LazyVStack` over flattened
/// lines keeps SwiftUI's allocation cost proportional to the visible region, handling
/// 1 000+ lines without regression (see 0005 M8 groundwork baseline: p95 10.27 ms for parse
/// of a 1 500-line fixture; render follows the same budget).
struct UnifiedDiffView: View {
  @Bindable var store: StoreOf<GitViewerFeature>

  var body: some View {
    switch store.diffState {
    case .idle, .loading:
      placeholder
    case .error(.diffTooLarge):
      LargeDiffPlaceholderView(
        scope: store.state.scope,
        worktreePath: store.worktreePathHint,
        copyCommandToken: store.state.copyLargeDiffCommandToken
      )
    case .error:
      placeholder
    case .loaded(let diff):
      if let selected = store.selectedFilePath,
         let file = diff.files.first(where: { $0.id == selected }) {
        fileHunks(file)
      } else if let first = diff.files.first {
        fileHunks(first)
      } else {
        placeholder
      }
    }
  }

  @ViewBuilder
  private func fileHunks(_ file: FileChange) -> some View {
    if file.isBinary {
      VStack(spacing: 4) {
        Text("Binary file")
          .font(.headline)
        Text(file.id).font(.caption.monospaced()).foregroundStyle(.secondary)
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity)
    } else if file.hunks.isEmpty {
      VStack(spacing: 4) {
        Text("No changes").font(.headline)
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity)
    } else {
      ScrollView([.vertical, .horizontal]) {
        LazyVStack(alignment: .leading, spacing: 0, pinnedViews: []) {
          ForEach(Array(file.hunks.enumerated()), id: \.offset) { _, hunk in
            hunkHeader(hunk)
            ForEach(Array(hunk.lines.enumerated()), id: \.offset) { _, line in
              hunkLine(line, hunk: hunk)
            }
          }
        }
        .padding(.vertical, 4)
      }
      .background(Color(nsColor: .textBackgroundColor))
    }
  }

  private func hunkHeader(_ hunk: DiffHunk) -> some View {
    Text(hunk.header)
      .font(.system(.caption, design: .monospaced))
      .foregroundStyle(.secondary)
      .padding(.horizontal, 8)
      .padding(.vertical, 2)
      .frame(maxWidth: .infinity, alignment: .leading)
      .background(Color(nsColor: .underPageBackgroundColor))
  }

  private func hunkLine(_ line: DiffLine, hunk: DiffHunk) -> some View {
    HStack(alignment: .firstTextBaseline, spacing: 0) {
      Text(marker(for: line.kind))
        .font(.system(.body, design: .monospaced))
        .frame(width: 18, alignment: .center)
        .foregroundStyle(colorForMarker(line.kind))
      Text(line.text)
        .font(.system(.body, design: .monospaced))
        .foregroundStyle(colorForText(line.kind))
        .textSelection(.enabled)
        .padding(.leading, 2)
      Spacer(minLength: 0)
    }
    .padding(.horizontal, 6)
    .padding(.vertical, 0)
    .background(backgroundFor(line.kind))
    .accessibilityLabel(accessibilityLabel(for: line))
  }

  private func marker(for kind: DiffLine.Kind) -> String {
    switch kind {
    case .context: return " "
    case .added: return "+"
    case .removed: return "−"
    case .noNewlineMarker: return "\\"
    }
  }

  private func colorForMarker(_ kind: DiffLine.Kind) -> Color {
    switch kind {
    case .added: return ThemeGit.kindAdded
    case .removed: return ThemeGit.kindDeleted
    case .context, .noNewlineMarker: return ThemeGit.contextDim
    }
  }

  private func colorForText(_ kind: DiffLine.Kind) -> Color {
    switch kind {
    case .added: return ThemeGit.added
    case .removed: return ThemeGit.removed
    case .context: return ThemeGit.context
    case .noNewlineMarker: return ThemeGit.contextDim
    }
  }

  @ViewBuilder
  private func backgroundFor(_ kind: DiffLine.Kind) -> some View {
    switch kind {
    case .added: ThemeGit.addedBackground
    case .removed: ThemeGit.removedBackground
    case .context, .noNewlineMarker: Color.clear
    }
  }

  private func accessibilityLabel(for line: DiffLine) -> String {
    let prefix: String
    switch line.kind {
    case .context: prefix = "context line"
    case .added: prefix = "added line"
    case .removed: prefix = "removed line"
    case .noNewlineMarker: prefix = "no newline at end of file"
    }
    return "\(prefix): \(line.text)"
  }

  private var placeholder: some View {
    VStack(spacing: 6) {
      Image(systemName: "doc.text")
        .accessibilityHidden(true)
        .font(.largeTitle)
        .foregroundStyle(.tertiary)
      Text("Select a file to view its diff")
        .font(.caption)
        .foregroundStyle(.secondary)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
  }
}
