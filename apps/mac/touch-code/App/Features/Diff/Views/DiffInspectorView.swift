// MARK: M5
import ComposableArchitecture
import SwiftUI
import TouchCodeCore

/// Diff inspector column body. Displays the active Worktree's changed
/// files; tapping a row opens the drawer (M6) for that file. Width is
/// fixed at 280 pt by the inspector mount in `ContentView`.
struct DiffInspectorView: View {
  @Bindable var store: StoreOf<DiffFeature>

  var body: some View {
    content
      .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
      .background(Color(nsColor: .windowBackgroundColor))
      .toolbar {
        ToolbarItem(placement: .primaryAction) {
          Button {
            store.send(.refreshRequested)
          } label: {
            Image(systemName: "arrow.clockwise")
          }
          .disabled(isRefreshing)
          .help("Refresh changed files")
          .accessibilityLabel("Refresh changed files")
        }
      }
  }

  private var isRefreshing: Bool {
    if case .loading = store.changedFiles { return true }
    return false
  }

  // MARK: - Content

  @ViewBuilder
  private var content: some View {
    switch store.changedFiles {
    case .idle:
      placeholder("No worktree selected")
    case .loading:
      ProgressView()
        .controlSize(.small)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    case .loaded(let files):
      if files.isEmpty {
        placeholder("No changes")
      } else {
        fileList(files)
      }
    case .error(let error):
      errorBlock(error)
    }
  }

  @ViewBuilder
  private func fileList(_ files: [ChangedFile]) -> some View {
    ScrollView {
      LazyVStack(alignment: .leading, spacing: 0) {
        ForEach(files) { file in
          DiffFileRow(
            file: file,
            isPresented: store.presentedFilePath == file.id,
            onOpenTap: { store.send(.fileRowTapped(path: file.id)) },
            onChevronTap: {
              if store.presentedFilePath == file.id {
                store.send(.drawerCloseRequested)
              } else {
                store.send(.fileRowTapped(path: file.id))
              }
            }
          )
          Divider()
        }
      }
    }
  }

  @ViewBuilder
  private func placeholder(_ text: String) -> some View {
    VStack {
      Text(text)
        .font(.callout)
        .foregroundStyle(.secondary)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
  }

  @ViewBuilder
  private func errorBlock(_ error: GitError) -> some View {
    VStack(spacing: 10) {
      Image(systemName: "exclamationmark.triangle")
        .foregroundStyle(.orange)
        .font(.title3)
      Text(Self.errorMessage(error))
        .font(.callout)
        .foregroundStyle(.secondary)
        .multilineTextAlignment(.center)
        .padding(.horizontal, 12)
      Button("Retry") {
        store.send(.refreshRequested)
      }
      .controlSize(.small)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
  }

  /// Collapse a `GitError` to a single-line user-facing message. Mirrors
  /// the verb-prefixed format the status bar uses elsewhere in the app
  /// (e.g. `RootFeature.runScriptErrorMessage`).
  private static func errorMessage(_ error: GitError) -> String {
    switch error {
    case .notARepo: return "Not a git repository"
    case .gitMissing: return "git not found"
    case .outputTooLarge: return "Output too large"
    case .diffTooLarge: return "Diff too large"
    case .timedOut: return "git timed out"
    case .exec(_, let stderr):
      let firstLine = stderr.split(separator: "\n", maxSplits: 1).first.map(String.init) ?? ""
      let trimmed = firstLine.trimmingCharacters(in: .whitespacesAndNewlines)
      return trimmed.isEmpty ? "git failed" : trimmed
    case .invalidInput(let detail): return detail
    case .unparsable: return "Unrecognised diff format"
    case .malformedRemoteURL: return "Malformed remote URL"
    }
  }
}
