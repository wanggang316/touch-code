import ComposableArchitecture
import SwiftUI
import TouchCodeCore

/// Per-file changes list for the current diff. Rendered in the `.working` / `.staged` /
/// `.commit(...)` scopes; hidden in `.log` until a commit is selected.
struct FileChangeListView: View {
  @Bindable var store: StoreOf<GitViewerFeature>

  var body: some View {
    switch store.diffState {
    case .idle:
      emptyState(title: "No changes", subtitle: "Nothing to display for this scope.")
    case .loading:
      ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
    case .error(let error):
      errorState(error: error)
    case .loaded(let diff):
      if diff.files.isEmpty {
        emptyState(title: emptyTitle(for: diff.scope), subtitle: "")
      } else {
        fileList(diff: diff)
      }
    }
  }

  @ViewBuilder
  private func fileList(diff: UnifiedDiff) -> some View {
    let selection = Binding<String?>(
      get: { store.selectedFilePath },
      set: { newValue in store.send(.fileSelected(newValue)) }
    )
    List(selection: selection) {
      ForEach(diff.files) { file in
        fileRow(file)
          .tag(file.id as String?)
      }
    }
    .listStyle(.inset)
  }

  private func fileRow(_ file: FileChange) -> some View {
    HStack(spacing: 6) {
      kindGlyph(file.kind)
        .font(.system(.caption, design: .monospaced).weight(.semibold))
        .frame(width: 18, alignment: .leading)
      Text(displayPath(file))
        .font(.system(.body, design: .monospaced))
        .lineLimit(1)
        .truncationMode(.middle)
      Spacer(minLength: 0)
      if !file.isBinary {
        Text("+\(file.linesAdded)")
          .font(.caption.monospacedDigit())
          .foregroundStyle(ThemeGit.kindAdded)
        Text("−\(file.linesRemoved)")
          .font(.caption.monospacedDigit())
          .foregroundStyle(ThemeGit.kindDeleted)
      } else {
        Text("bin").font(.caption).foregroundStyle(.secondary)
      }
    }
    .padding(.vertical, 1)
    .contentShape(.rect)
  }

  @ViewBuilder
  private func kindGlyph(_ kind: FileChange.Kind) -> some View {
    switch kind {
    case .added: Text("A").foregroundStyle(ThemeGit.kindAdded)
    case .modified: Text("M").foregroundStyle(ThemeGit.kindModified)
    case .deleted: Text("D").foregroundStyle(ThemeGit.kindDeleted)
    case .renamed: Text("R→").foregroundStyle(ThemeGit.kindRenamed)
    case .copied: Text("C→").foregroundStyle(ThemeGit.kindCopied)
    case .typeChanged: Text("T").foregroundStyle(ThemeGit.kindTypeChanged)
    }
  }

  private func displayPath(_ file: FileChange) -> String {
    switch file.kind {
    case .renamed(let from), .copied(let from):
      return "\(from) → \(file.id)"
    default:
      return file.id
    }
  }

  private func emptyTitle(for scope: DiffScope) -> String {
    switch scope {
    case .working: return "Working tree is clean"
    case .staged: return "No staged changes"
    case .log: return "No changes in this commit"
    case .commit: return "No changes in this commit"
    }
  }

  private func emptyState(title: String, subtitle: String) -> some View {
    VStack(spacing: 6) {
      Text(title).font(.headline)
      if !subtitle.isEmpty {
        Text(subtitle).font(.caption).foregroundStyle(.secondary)
      }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .padding()
  }

  private func errorState(error: GitError) -> some View {
    VStack(alignment: .leading, spacing: 6) {
      Text("Could not load diff").font(.headline)
      Text(errorDescription(error)).font(.caption).foregroundStyle(.secondary)
      Button("Retry") { store.send(.refreshRequested) }.buttonStyle(.borderless)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    .padding()
  }

  private func errorDescription(_ error: GitError) -> String {
    switch error {
    case .notARepo: return "Not a git repository."
    case .gitMissing: return "The `git` binary was not found."
    case .outputTooLarge: return "Diff exceeded the 16 MiB cap."
    case .diffTooLarge: return "Diff exceeded the line cap — use Copy command (M4b)."
    case .timedOut: return "`git diff` took too long."
    case .exec(_, let stderr): return stderr.components(separatedBy: "\n").first ?? ""
    case .invalidInput(let msg), .unparsable(let msg): return msg
    }
  }
}
