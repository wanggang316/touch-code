import AppKit
import SwiftUI
import TouchCodeCore

/// Shared building blocks for every "Open in / Default editor" dropdown across the app
/// (Settings → General + Repository, Project Options sheet, and the Worktree header's
/// Open-in split button). All surfaces share one visual contract — a flat priority-
/// ordered list where each row is `icon + displayName`; no groupings, no auto-resolve
/// sentinel. Callers decide whether to prepend a semantic sentinel row (e.g. "Use
/// global default" for per-project overrides).
///
/// Scope: this file is intentionally bound to the editor-picker UI. It lives under the
/// Settings Panes directory because it is used by sibling views; extracting further
/// would pull editor-specific assumptions into a generic UI module.
enum EditorPickerRow {
  /// 16×16 glyph for an editor row. Uses Launch Services' bundled icon for bundle-backed
  /// entries and a terminal SF Symbol for the `.shellEditor` pseudo-entry. The catch-all
  /// `app.dashed` glyph handles a defensive "bundle-backed but unresolved" case that
  /// `describe()` filters out in practice.
  @ViewBuilder
  static func icon(for descriptor: EditorDescriptor) -> some View {
    switch descriptor.launchMode {
    case .shellEditor:
      Image(systemName: "terminal")
        .resizable()
        .aspectRatio(contentMode: .fit)
        .frame(width: 16, height: 16)
        .foregroundStyle(.secondary)
        .accessibilityHidden(true)
    case .directory, .applicationWithArguments:
      if let appURL = descriptor.appURL {
        Image(nsImage: NSWorkspace.shared.icon(forFile: appURL.path))
          .resizable()
          .frame(width: 16, height: 16)
          .accessibilityHidden(true)
      } else {
        Image(systemName: "app.dashed")
          .resizable()
          .aspectRatio(contentMode: .fit)
          .frame(width: 16, height: 16)
          .foregroundStyle(.secondary)
          .accessibilityHidden(true)
      }
    }
  }

  /// Standard row content for every editor dropdown — a compact `icon + displayName`
  /// HStack. Used as the tag-bearing body inside `Picker` items and as the Button
  /// label inside `Menu` items, so all surfaces render editors identically.
  @ViewBuilder
  static func row(for descriptor: EditorDescriptor) -> some View {
    HStack(spacing: 6) {
      icon(for: descriptor)
      Text(descriptor.displayName)
    }
  }

  /// Flat priority-ordered list of installed descriptors, following
  /// `EditorRegistry.menuOrder`. Replaces the previous grouped/divided layout; callers
  /// render the result as a single flat list with no dividers.
  static func sorted(_ installed: [EditorDescriptor]) -> [EditorDescriptor] {
    let byID = Dictionary(uniqueKeysWithValues: installed.map { ($0.id, $0) })
    return EditorRegistry.menuOrder.compactMap { byID[$0] }
  }
}
