import AppKit
import ComposableArchitecture
import Foundation

/// Thin TCA dependency over `NSOpenPanel` for picking a single local folder.
/// Exists so `AddProjectFeature` can trigger the macOS folder picker without
/// importing AppKit into the reducer and so `TestStore` can drive the flow
/// with scripted URLs.
///
/// Distinct from `FinderClient` (which is reveal-only and returns `Void`):
/// the picker needs an async `URL?` return and a different dialog shape, so
/// keeping them separate avoids mixing two unrelated affordances.
nonisolated struct FolderPickerClient: Sendable {
  /// Shows a directory-only open panel with the given prompt. Returns the
  /// user's selection, or `nil` if they cancelled.
  var pick: @MainActor @Sendable (_ prompt: String) async -> URL?
}

extension FolderPickerClient: DependencyKey {
  static let liveValue = FolderPickerClient(
    pick: { prompt in
      await MainActor.run {
        let panel = NSOpenPanel()
        panel.prompt = prompt
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = false
        guard panel.runModal() == .OK else { return Optional<URL>.none }
        return panel.url
      }
    }
  )

  static let testValue = FolderPickerClient(
    pick: unimplemented("FolderPickerClient.pick", placeholder: nil)
  )
}

extension DependencyValues {
  var folderPickerClient: FolderPickerClient {
    get { self[FolderPickerClient.self] }
    set { self[FolderPickerClient.self] = newValue }
  }
}
