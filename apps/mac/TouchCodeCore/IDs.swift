import Foundation

public protocol HierarchyID: Codable, Hashable, Sendable, CustomStringConvertible {
  var raw: UUID { get }
  init(raw: UUID)
}

nonisolated extension HierarchyID {
  public init() { self.init(raw: UUID()) }
  public var description: String { raw.uuidString }
}

public nonisolated struct SpaceID: HierarchyID {
  public let raw: UUID
  public init(raw: UUID) { self.raw = raw }
}

public nonisolated struct ProjectID: HierarchyID {
  public let raw: UUID
  public init(raw: UUID) { self.raw = raw }
}

public nonisolated struct WorktreeID: HierarchyID {
  public let raw: UUID
  public init(raw: UUID) { self.raw = raw }
}

public nonisolated struct TabID: HierarchyID {
  public let raw: UUID
  public init(raw: UUID) { self.raw = raw }
}

public nonisolated struct PaneID: HierarchyID {
  public let raw: UUID
  public init(raw: UUID) { self.raw = raw }
}
