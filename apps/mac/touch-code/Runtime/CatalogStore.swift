import Foundation
import TouchCodeCore
import os.log

@MainActor
final class CatalogStore {
  private let fileURL: URL
  private let logger = Logger(subsystem: "com.touch-code.persistence", category: "catalog")

  private var pendingSaveTask: Task<Void, Never>?
  private var latestCatalog: Catalog?

  init(fileURL: URL = Catalog.defaultURL()) {
    self.fileURL = fileURL
  }

  func load() throws -> Catalog {
    if let existing = try AtomicFileStore.read(Catalog.self, at: fileURL) {
      return existing
    }
    return .default
  }

  func scheduleSave(_ catalog: Catalog) {
    latestCatalog = catalog

    pendingSaveTask?.cancel()
    pendingSaveTask = Task {
      try? await Task.sleep(nanoseconds: 500_000_000)

      guard !Task.isCancelled else { return }

      if let toSave = latestCatalog {
        do {
          try saveNow(toSave)
        } catch {
          logger.error("Failed to save catalog: \(error)")
          backupBrokenFile()
        }
      }
    }
  }

  func saveNow(_ catalog: Catalog) throws {
    try AtomicFileStore.write(catalog, to: fileURL)
  }

  private func backupBrokenFile() {
    let timestamp = ISO8601DateFormatter().string(from: Date())
    let backupURL = fileURL.deletingLastPathComponent()
      .appendingPathComponent("catalog.json.broken-\(timestamp)")
    try? FileManager.default.moveItem(at: fileURL, to: backupURL)
  }
}

extension Catalog {
  static let `default` = Catalog(windows: [], spaces: [], selectedSpaceID: nil)
}
