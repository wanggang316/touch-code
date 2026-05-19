import SwiftUI
import TouchCodeCore

/// Leading-edge icon for a Sidebar Worktree row. Replaces the old `circle.fill`/`circle`
/// selection dot with a GitHub-style glyph that doubles as the row's PR-state signal:
///
/// - Dir-kind synthetic worktree → `folder` SF Symbol. The synthetic worktree under a
///   dir-kind Project reads as a filesystem directory rather than a git anchor.
/// - Worktrees with no PR snapshot (including main) → the `git-branch` octicon tinted by
///   `roleTint` (orange for user-pinned rows, secondary otherwise). Desaturates to the
///   selection text color when the row is selected — `listRowBackground` already shows
///   selection, so a loud icon would fight the highlight. The main checkout no longer
///   gets a separate glyph; the "this is default" signal is rendered next to the name
///   via a yellow star at the call site (HierarchySidebarView / WorktreeHeaderInfoLabel).
/// - PR snapshot     → `git-pull-request`, `git-merge`, `git-pull-request-closed`, or
///   `git-pull-request-draft`, tinted by PR state (green / purple / red / grey). PR
///   state is the dominant signal when a PR exists; the role tint is suppressed.
///
/// A 10×10 circle overlays the bottom-right corner when the aggregated check rollup is
/// non-empty, so the row can surface CI health at a glance without expanding the popover.
struct WorktreeRowIcon: View {
  let snapshot: PullRequestSnapshot?
  let rollup: PullRequestBadge.CheckRollup
  let isSelected: Bool
  /// Fallback tint applied when no PR snapshot is available. Encodes the Worktree's
  /// "role" in the Project — orange for pinned rows, secondary for everything else
  /// (including the main checkout, which shares the regular-worktree palette).
  var roleTint: Color = .secondary
  /// `true` for the placeholder worktree auto-injected under a dir-kind
  /// Project (`Project.gitRoot == nil` + `worktree.path == project.rootPath`).
  /// Swaps the leading glyph to `folder` so the row reads as a filesystem
  /// directory rather than a git anchor — git semantics (branch, PR state)
  /// don't apply.
  var isSynthetic: Bool = false
  /// L3 unread override. When `true`, the row icon swaps to a bell glyph
  /// regardless of PR / branch state, and the role tint is replaced by
  /// the accent colour. PR check rollup overlay still renders unchanged.
  var hasUnreadNotification: Bool = false

  /// Native `List(selection:)` paints the selection chrome via NSTableView's
  /// `.sourceList` mode and sets `\.backgroundProminence = .increased` on
  /// the row content only while the selection is *emphasized* (sidebar
  /// holds first-responder, blue fill, white text). The instant focus
  /// moves to a terminal pane the fill becomes unemphasized grey, the
  /// system text color flips to dark, and `backgroundProminence` returns
  /// to `.standard`. Reading this env (rather than `\.controlActiveState`,
  /// which only tracks window-key state) keeps the icon tint in lockstep
  /// with the text color through both transitions.
  @Environment(\.backgroundProminence) private var backgroundProminence

  var body: some View {
    Group {
      if hasUnreadNotification {
        Image(systemName: "bell.fill")
          .resizable()
          .aspectRatio(contentMode: .fit)
          .frame(width: 12, height: 12)
          .foregroundStyle(Color.orange)
      } else if isSynthetic {
        // Dir-kind Project's synthetic worktree: render a folder rather
        // than the `circlebadge` git-anchor glyph. 12pt inside a 14pt
        // slot mirrors the `circlebadge` sizing so the label column stays
        // aligned with sibling git rows.
        Image(systemName: "folder")
          .resizable()
          .aspectRatio(contentMode: .fit)
          .frame(width: 12, height: 12)
          .foregroundStyle(tint)
          .frame(width: 14, height: 14)
      } else {
        Image(assetName)
          .renderingMode(.template)
          .resizable()
          .aspectRatio(contentMode: .fit)
          .frame(width: 14, height: 14)
          .foregroundStyle(tint)
      }
    }
    .overlay(alignment: .bottomTrailing) {
      // Bell outranks the CI rollup: unread notifications are a higher-priority
      // signal than check state, so suppress the rollup overlay entirely while
      // the bell glyph is showing rather than letting a green/red disc smear
      // over it.
      if !hasUnreadNotification { rollupBadge }
    }
    .accessibilityLabel(accessibilityLabel)
  }

  private var assetName: String {
    guard let snapshot else { return "git-branch" }
    return snapshot.state.rowIconName(isDraft: snapshot.isDraft)
  }

  private var tint: Color {
    if let snapshot {
      return snapshot.state.rowTint(isDraft: snapshot.isDraft)
    }
    if isSelected {
      // Emphasized: white on blue. Unemphasized: the same dark token the
      // system uses for the row label, so icon and text move together
      // when focus shifts to a terminal pane within the same window.
      return backgroundProminence == .increased
        ? Color(nsColor: .alternateSelectedControlTextColor)
        : Color(nsColor: .unemphasizedSelectedTextColor)
    }
    return roleTint
  }

  @ViewBuilder
  private var rollupBadge: some View {
    switch rollup {
    case .allPassing:
      rollupGlyph(symbol: "checkmark.circle.fill", color: CheckRollupColor.passing)
    case .anyFailing:
      rollupGlyph(symbol: "xmark.circle.fill", color: CheckRollupColor.failing)
    case .anyPending:
      rollupGlyph(symbol: "clock.circle.fill", color: CheckRollupColor.pending)
    case .noChecks:
      EmptyView()
    }
  }

  private func rollupGlyph(symbol: String, color: Color) -> some View {
    // Inverted palette: the state colour fills the disc and the inner check /
    // x / clock glyph is painted in `windowBackgroundColor` so it reads as a
    // hole punched through the disc revealing whatever sits behind. Light
    // mode → near-white inner glyph; dark mode → near-black. Using the
    // window-bg token (rather than hard-coded `.white`) keeps the contrast
    // direction sensible across both schemes instead of looking blown out in
    // dark mode. Disc shrunk 11 → 10pt; `.fontWeight(.bold)` thickens the
    // inner stroke so it stays legible at sidebar density.
    Image(systemName: symbol)
      .resizable()
      .fontWeight(.bold)
      .frame(width: 10, height: 10)
      .symbolRenderingMode(.palette)
      .foregroundStyle(Color(nsColor: .windowBackgroundColor), color)
      .offset(x: 4, y: 4)
      .accessibilityHidden(true)
  }

  private var accessibilityLabel: Text {
    if isSynthetic {
      return Text(isSelected ? "Active project folder" : "Project folder")
    }
    guard let snapshot else {
      return Text(isSelected ? "Active worktree branch" : "Worktree branch")
    }
    let stateWord: String = {
      if snapshot.isDraft { return "draft" }
      switch snapshot.state {
      case .open: return "open"
      case .merged: return "merged"
      case .closed: return "closed"
      }
    }()
    return Text("\(stateWord) pull request #\(snapshot.number)")
  }
}
