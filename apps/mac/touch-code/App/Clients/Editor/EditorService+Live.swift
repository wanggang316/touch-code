import AppKit
import Foundation
import TouchCodeCore

/// Production `EditorService` backed by Launch Services via the `AppLauncher` seam.
///
/// State: the `describe()` result is memoised for the service's lifetime. Settings panes
/// (and the IPC `editor.describe` handler) call `clearCache()` on appear so newly-installed
/// editors surface without an app restart (R4 in the design doc).
///
/// Threading: an `actor` gives us a cheap mutex around the cache without hand-rolling a
/// lock. The `Sendable` closures for reading settings let the live factory close over
/// `@MainActor`-isolated stores without the service itself needing to hop to the main actor
/// on every resolve.
final actor LiveEditorService: EditorService {
  private let launcher: any AppLauncher
  private let globalDefault: @Sendable () -> EditorID?
  private var cachedDescriptors: [EditorDescriptor]?

  init(
    launcher: any AppLauncher = LiveAppLauncher(),
    globalDefault: @escaping @Sendable () -> EditorID? = { nil }
  ) {
    self.launcher = launcher
    self.globalDefault = globalDefault
  }

  // MARK: - describe

  func describe() async -> [EditorDescriptor] {
    if let cached = cachedDescriptors { return cached }
    var resolved: [EditorDescriptor] = []
    for template in EditorRegistry.registry {
      switch template.launchMode {
      case .shellEditor:
        // Always "installed" — the Panel primitive (Phase 4d) owns the actual launch.
        resolved.append(template)
      case .directory, .applicationWithArguments:
        if let appURL = await resolveAppURL(for: template) {
          resolved.append(
            EditorDescriptor(
              id: template.id,
              displayName: template.displayName,
              bundleIdentifier: template.bundleIdentifier,
              launchMode: template.launchMode,
              appURL: appURL,
              alternateBundleIdentifiers: template.alternateBundleIdentifiers
            )
          )
        }
      }
    }
    cachedDescriptors = resolved
    return resolved
  }

  /// Invalidates the `describe()` cache. Call on Settings-pane appear and on IPC
  /// `editor.describe` so a newly-installed editor becomes visible without restart.
  func clearCache() {
    cachedDescriptors = nil
  }

  // MARK: - resolve

  func resolve(preferred: EditorID?) async throws -> EditorDescriptor {
    let installed = await describe()

    // Tier 1 — explicit preferred (strict).
    if let preferred {
      guard let match = installed.first(where: { $0.id == preferred }) else {
        let bundleID = EditorRegistry.registry.first(where: { $0.id == preferred })?.bundleIdentifier ?? ""
        throw EditorError.notInstalled(id: preferred, bundleID: bundleID)
      }
      return match
    }

    // Tier 2 — stored global default (lenient: silently skip if uninstalled).
    if let defaultID = globalDefault(),
      let match = installed.first(where: { $0.id == defaultID })
    {
      return match
    }

    // Tier 3 — priority walk. Finder is always installed, so this always terminates.
    for id in EditorRegistry.defaultPriority {
      if let match = installed.first(where: { $0.id == id }) {
        return match
      }
    }

    // Defensive: Launch Services claims Finder is missing. Surface a launch error rather
    // than force-unwrapping — the caller can render a toast and the user can at least
    // retry.
    throw EditorError.launchFailed(reason: "No installed editor found in the priority chain.")
  }

  // MARK: - open

  @discardableResult
  func open(directory: URL, preferred: EditorID?) async throws -> EditorChoice {
    try ensureDirectoryExists(directory)
    let descriptor = try await resolve(preferred: preferred)

    switch descriptor.launchMode {
    case .directory:
      guard let appURL = descriptor.appURL else {
        throw EditorError.launchFailed(reason: "Resolved \(descriptor.id) has no app URL.")
      }
      let config = NSWorkspace.OpenConfiguration()
      try await launcher.open(urls: [directory], withApplicationAt: appURL, configuration: config)

    case .applicationWithArguments:
      guard let appURL = descriptor.appURL else {
        throw EditorError.launchFailed(reason: "Resolved \(descriptor.id) has no app URL.")
      }
      let config = NSWorkspace.OpenConfiguration()
      config.arguments = [directory.path]
      config.createsNewApplicationInstance = true
      // JetBrains IDEs ignore URL-list opens when the arguments path is used; pass an
      // empty URL list and let `configuration.arguments` carry the directory.
      try await launcher.open(urls: [], withApplicationAt: appURL, configuration: config)

    case .shellEditor:
      // TODO(C8a Phase 4d): wire `TerminalEngine.ensureSurface` to forward
      // `panel.initialCommand` ("$EDITOR\n") so the Panel primitive actually launches
      // the user's $EDITOR. Until then, fail loudly so the UI can surface a toast.
      throw EditorError.launchFailed(reason: "$EDITOR launch not yet wired — see C8a Phase 4d.")
    }

    return EditorChoice(id: descriptor.id, displayName: descriptor.displayName, binaryPath: nil)
  }

  // MARK: - Helpers

  /// Probes the launcher for the template's primary bundle ID, falling through to
  /// `alternateBundleIdentifiers` (R1 in the design doc). Returns nil if no bundle is
  /// registered for any of them.
  private func resolveAppURL(for template: EditorDescriptor) async -> URL? {
    if let url = await launcher.urlForApplication(bundleIdentifier: template.bundleIdentifier) {
      return url
    }
    for alternate in template.alternateBundleIdentifiers {
      if let url = await launcher.urlForApplication(bundleIdentifier: alternate) {
        return url
      }
    }
    return nil
  }

  private func ensureDirectoryExists(_ url: URL) throws {
    var isDir: ObjCBool = false
    let fm = FileManager.default
    guard fm.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue else {
      throw EditorError.notADirectory(path: url.path)
    }
  }
}
