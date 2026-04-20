import Foundation

/// File-system layout for C6-owned configuration files under
/// `~/.config/touch-code/`. Colocated in the Notifications module (not in
/// TouchCodeCore) because `CatalogStore` already owns `Catalog.defaultURL()`
/// — keeping the path convention where its owners live keeps each capability
/// self-contained and makes test-time URL substitution trivial via the
/// `fileURL:` init parameter on every store.
enum ConfigPaths {
  static var home: URL {
    URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
  }

  static func configDirectory(home: URL = ConfigPaths.home) -> URL {
    home.appendingPathComponent(".config/touch-code", isDirectory: true)
  }

  static func notificationInbox(home: URL = ConfigPaths.home) -> URL {
    configDirectory(home: home).appendingPathComponent("notifications.json", isDirectory: false)
  }

  static func detectionRules(home: URL = ConfigPaths.home) -> URL {
    configDirectory(home: home).appendingPathComponent("detection-rules.json", isDirectory: false)
  }
}
