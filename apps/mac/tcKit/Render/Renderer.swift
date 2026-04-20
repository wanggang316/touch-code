import Foundation

/// Shared output rendering — every `tc` subcommand funnels through here
/// so text-mode and JSON-mode stay byte-stable across commands.
public enum Renderer {
  /// Render a value in the chosen mode and write to stdout (or an
  /// injected sink for tests).
  public static func emit<T: Encodable & CustomStringConvertible>(
    _ value: T,
    mode: RenderMode,
    sink: (String) -> Void = { print($0) }
  ) throws {
    switch mode {
    case .json:
      let encoder = JSONEncoder()
      encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
      let data = try encoder.encode(value)
      sink(String(bytes: data, encoding: .utf8) ?? "")
    case .text:
      sink(value.description)
    }
  }

  /// Render a simple object (no typed struct) by encoding via
  /// `JSONSerialization`. Convenience for quick one-off rendering — typed
  /// callers should use `emit(_:mode:sink:)` above.
  public static func emitObject(
    _ object: [String: Any],
    mode: RenderMode,
    textRender: (([String: Any]) -> String)? = nil,
    sink: (String) -> Void = { print($0) }
  ) throws {
    switch mode {
    case .json:
      let data = try JSONSerialization.data(
        withJSONObject: object,
        options: [.prettyPrinted, .sortedKeys]
      )
      sink(String(bytes: data, encoding: .utf8) ?? "")
    case .text:
      if let textRender {
        sink(textRender(object))
      } else {
        let sorted = object.sorted { $0.key < $1.key }
        sink(sorted.map { "\($0.key): \($0.value)" }.joined(separator: "\n"))
      }
    }
  }
}
