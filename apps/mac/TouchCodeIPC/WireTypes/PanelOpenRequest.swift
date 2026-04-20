import Foundation
import TouchCodeCore

public extension IPC {
  /// Params for `hierarchy.openPanel`. `labels` seed the new Panel's label
  /// set; `activate` requests focus after creation.
  struct PanelOpenRequest: Codable, Equatable, Sendable {
    public let tabID: TabID?
    public let workingDirectory: String?
    public let initialCommand: String?
    public let labels: [String]
    public let activate: Bool

    public init(
      tabID: TabID? = nil,
      workingDirectory: String? = nil,
      initialCommand: String? = nil,
      labels: [String] = [],
      activate: Bool = true
    ) {
      self.tabID = tabID
      self.workingDirectory = workingDirectory
      self.initialCommand = initialCommand
      self.labels = labels
      self.activate = activate
    }
  }
}
