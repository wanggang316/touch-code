import Foundation

/// Shared JSON encoder/decoder configuration for hook envelopes written to
/// a user handler's stdin or a streaming RPC.
///
/// The design doc pins ISO-8601 for `timestamp`. The default `JSONEncoder`
/// strategy is `.deferredToDate` which emits Apple-epoch-seconds as a
/// floating-point number — opaque to shell handlers. `HookEnvelope.encoder`
/// pins `.iso8601`. Use these factories (instead of bare `JSONEncoder()`)
/// when (de)serialising envelopes on any wire path.
extension HookEnvelope {
  public static func encoder() -> JSONEncoder {
    let e = JSONEncoder()
    e.dateEncodingStrategy = .iso8601
    return e
  }

  public static func decoder() -> JSONDecoder {
    let d = JSONDecoder()
    d.dateDecodingStrategy = .iso8601
    return d
  }
}

/// Wire payload delivered to a user hook handler on stdin and to the
/// `hook.events` streaming RPC.
///
/// Every anchor field (`space`, `project`, `worktree`, `tab`, `pane`) is
/// optional on the wire because some events carry no pane / tab / worktree
/// by construction. `validateAnchors()` asserts the per-scope presence rule
/// (see the C3 design doc): `pane.*` must carry pane + tab + worktree +
/// project + space; `tab.*` must carry tab + ancestors; `worktree.*` must
/// carry worktree + ancestors. Debug builds call it on encode; release
/// builds trust the producer.
public nonisolated struct HookEnvelope: Equatable, Codable, Sendable, Identifiable {
  public static let currentVersion = 1

  public var id: UUID
  public var version: Int
  public var event: HookEvent
  public var timestamp: Date
  public var space: SpaceRef?
  public var project: ProjectRef?
  public var worktree: WorktreeRef?
  public var tab: TabRef?
  public var pane: PaneRef?
  public var data: HookEventData

  public init(
    id: UUID = UUID(),
    version: Int = HookEnvelope.currentVersion,
    event: HookEvent,
    timestamp: Date = Date(),
    space: SpaceRef? = nil,
    project: ProjectRef? = nil,
    worktree: WorktreeRef? = nil,
    tab: TabRef? = nil,
    pane: PaneRef? = nil,
    data: HookEventData
  ) {
    self.id = id
    self.version = version
    self.event = event
    self.timestamp = timestamp
    self.space = space
    self.project = project
    self.worktree = worktree
    self.tab = tab
    self.pane = pane
    self.data = data
  }

  public enum ValidationError: Error, Equatable {
    case missingAnchor(scope: HookScope, missing: String)
    case kindMismatch(envelope: HookEvent, data: HookEvent)
  }

  /// Assert the per-scope anchor-presence rule and that `event` agrees with
  /// `data.kind`. Intended for debug-only callers (the dispatcher's encode
  /// path); release builds may skip.
  public func validateAnchors() throws {
    if event != data.kind {
      throw ValidationError.kindMismatch(envelope: event, data: data.kind)
    }
    let required: [(name: String, present: Bool)]
    switch event.scope {
    case .pane:
      required = [
        ("pane", pane != nil),
        ("tab", tab != nil),
        ("worktree", worktree != nil),
        ("project", project != nil),
        ("space", space != nil),
      ]
    case .tab:
      required = [
        ("tab", tab != nil),
        ("worktree", worktree != nil),
        ("project", project != nil),
        ("space", space != nil),
      ]
    case .worktree:
      required = [
        ("worktree", worktree != nil),
        ("project", project != nil),
        ("space", space != nil),
      ]
    case .space:
      required = [("space", space != nil)]
    }
    for entry in required where !entry.present {
      throw ValidationError.missingAnchor(scope: event.scope, missing: entry.name)
    }
  }

  // MARK: - Anchor reference types

  public struct SpaceRef: Equatable, Codable, Sendable {
    public var id: SpaceID
    public var name: String
    public init(id: SpaceID, name: String) {
      self.id = id
      self.name = name
    }
  }

  public struct ProjectRef: Equatable, Codable, Sendable {
    public var id: ProjectID
    public var name: String
    public var rootPath: String
    public init(id: ProjectID, name: String, rootPath: String) {
      self.id = id
      self.name = name
      self.rootPath = rootPath
    }
  }

  public struct WorktreeRef: Equatable, Codable, Sendable {
    public var id: WorktreeID
    public var name: String
    public var path: String
    public var branch: String?
    public init(id: WorktreeID, name: String, path: String, branch: String? = nil) {
      self.id = id
      self.name = name
      self.path = path
      self.branch = branch
    }
  }

  public struct TabRef: Equatable, Codable, Sendable {
    public var id: TabID
    public var name: String?
    public var selectedPaneID: PaneID?
    public init(id: TabID, name: String? = nil, selectedPaneID: PaneID? = nil) {
      self.id = id
      self.name = name
      self.selectedPaneID = selectedPaneID
    }
  }

  public struct PaneRef: Equatable, Codable, Sendable {
    public var id: PaneID
    public var workingDirectory: String
    public var initialCommand: String?
    public var labels: [String]
    public init(id: PaneID, workingDirectory: String, initialCommand: String? = nil, labels: [String] = []) {
      self.id = id
      self.workingDirectory = workingDirectory
      self.initialCommand = initialCommand
      self.labels = labels
    }
  }
}
