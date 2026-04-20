import ComposableArchitecture
import SwiftUI
import TouchCodeCore

/// Commit-log list for the `.log` scope. Each row shows short SHA, author, subject, and a
/// relative timestamp. `.onAppear` of the last row triggers pagination via
/// `.logScrolledToBottom`.
struct CommitLogView: View {
  @Bindable var store: StoreOf<GitViewerFeature>

  var body: some View {
    switch store.logState {
    case .idle:
      emptyState(title: "No commits loaded", subtitle: "Switch to the log scope to load history.")
    case .loading:
      ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
    case .error(let error):
      errorState(error: error)
    case .loaded(let page):
      if page.commits.isEmpty {
        emptyState(title: "No commits yet", subtitle: "This worktree has no history.")
      } else {
        commitList(page: page)
      }
    }
  }

  @ViewBuilder
  private func commitList(page: LogPage) -> some View {
    List {
      ForEach(page.commits) { commit in
        Button {
          store.send(.commitSelected(sha: commit.id))
        } label: {
          commitRow(commit)
        }
        .buttonStyle(.plain)
        .onAppear {
          if commit.id == page.commits.last?.id, page.hasMore {
            store.send(.logScrolledToBottom)
          }
        }
      }
    }
    .listStyle(.inset)
  }

  private func commitRow(_ commit: Commit) -> some View {
    HStack(alignment: .firstTextBaseline, spacing: 8) {
      Text(commit.shortID)
        .font(.system(.caption, design: .monospaced))
        .foregroundStyle(.secondary)
      VStack(alignment: .leading, spacing: 2) {
        Text(commit.subject)
          .font(.system(.body))
          .lineLimit(1)
        HStack(spacing: 6) {
          Text(commit.authorName)
            .font(.caption)
            .foregroundStyle(.secondary)
          Text(commit.date, style: .relative)
            .font(.caption)
            .foregroundStyle(.tertiary)
        }
      }
      Spacer(minLength: 0)
    }
    .padding(.vertical, 2)
    .contentShape(.rect)
  }

  private func emptyState(title: String, subtitle: String) -> some View {
    VStack(spacing: 6) {
      Text(title).font(.headline)
      Text(subtitle).font(.caption).foregroundStyle(.secondary)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .padding()
  }

  private func errorState(error: GitError) -> some View {
    VStack(alignment: .leading, spacing: 6) {
      Text("Could not load log")
        .font(.headline)
      Text(errorDescription(error))
        .font(.caption)
        .foregroundStyle(.secondary)
      Button("Retry") { store.send(.refreshRequested) }
        .buttonStyle(.borderless)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    .padding()
  }

  private func errorDescription(_ error: GitError) -> String {
    switch error {
    case .notARepo: return "Not a git repository."
    case .gitMissing: return "The `git` binary was not found."
    case .outputTooLarge: return "Log output exceeded the 16 MiB cap."
    case .diffTooLarge: return "Log output exceeded the line cap."
    case .timedOut: return "`git log` took too long."
    case .exec(_, let stderr): return stderr.components(separatedBy: "\n").first ?? ""
    case .invalidInput(let msg), .unparsable(let msg): return msg
    }
  }
}
