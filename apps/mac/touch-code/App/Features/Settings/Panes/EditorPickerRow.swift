import AppKit
import SwiftUI
import TouchCodeCore

/// Shared building blocks for the C8a editor pickers (Settings "Default editor" and
/// Project Options "Editor" override). Both surfaces render the same row content
/// (icon + display name) and group installed descriptors into the same five buckets
/// (editors / xcode+finder / terminals / git clients / `.editor`).
///
/// Scope: this file is intentionally bound to the editor-picker UI. It lives under the
/// Settings Panes directory because it is used by two sibling views; extracting further
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

  /// Re-orders `installed` into `EditorRegistry.menuOrder` sequence and partitions it into
  /// the five display categories. Empty groups are dropped so the caller can interleave
  /// dividers without producing leading/double separators.
  static func grouped(_ installed: [EditorDescriptor]) -> [[EditorDescriptor]] {
    let byID = Dictionary(uniqueKeysWithValues: installed.map { ($0.id, $0) })
    func lookup(_ ids: [EditorID]) -> [EditorDescriptor] {
      ids.compactMap { byID[$0] }
    }
    let groups: [[EditorDescriptor]] = [
      lookup(EditorRegistry.editorPriority),
      lookup(["xcode", EditorRegistry.finderID]),
      lookup(EditorRegistry.terminalPriority),
      lookup(EditorRegistry.gitClientPriority),
      lookup([EditorRegistry.shellEditorID]),
    ]
    return groups.filter { !$0.isEmpty }
  }
}
