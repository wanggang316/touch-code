import Foundation

/// Byte offset + length into matched pane output. Replaces `NSRange` on the
/// wire — `NSRange`'s bridged Codable encodes as a single integer pair that
/// is platform-sensitive, while `HookMatchRange` is a transparent JSON object.
public nonisolated struct HookMatchRange: Codable, Equatable, Hashable, Sendable {
  public var start: Int
  public var length: Int

  public init(start: Int, length: Int) {
    self.start = start
    self.length = length
  }
}
