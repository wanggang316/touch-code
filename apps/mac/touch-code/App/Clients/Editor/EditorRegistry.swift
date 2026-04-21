import Foundation
import TouchCodeCore

/// The six-entry allowlist of built-in editors, exactly as specified in C8 design doc
/// §Built-in allowlist. The templates are binding: tests assert them byte-for-byte.
///
/// Adding an editor is a code change here; users add arbitrary entries via `CustomEditor`.
nonisolated enum EditorRegistry {
  /// Canonical ID for the Finder builtin. Always-installed; the ultimate
  /// fallback in every default-editor resolution chain. Centralizes the
  /// magic string `"finder"` that would otherwise leak into delegate
  /// handlers and tests. T2's Header split button routes through
  /// `EditorFeature.finderEditorID`, an alias of this constant.
  static let finderID: EditorID = "finder"

  static let builtins: [BuiltinEntry] = [
    BuiltinEntry(
      id: "vscode",
      displayName: "Visual Studio Code",
      template: CommandTemplate(binary: "code", args: ["{dir}"]),
      missingBinaryHelp: "Install via 'Shell Command: Install code command in PATH' in VSCode's Command Palette."
    ),
    BuiltinEntry(
      id: "cursor",
      displayName: "Cursor",
      template: CommandTemplate(binary: "cursor", args: ["{dir}"]),
      missingBinaryHelp: "Install the Cursor CLI via the app's Command Palette."
    ),
    BuiltinEntry(
      id: "zed",
      displayName: "Zed",
      template: CommandTemplate(binary: "zed", args: ["{dir}"]),
      missingBinaryHelp: "The `zed` CLI ships with Zed; ensure /Applications/Zed.app has been launched at least once."
    ),
    BuiltinEntry(
      id: "xcode",
      displayName: "Xcode",
      // `open -a Xcode <dir>` — the one case where Launch Services (via `open`) is used,
      // because Xcode has no first-party CLI wrapper. See C8 Alternatives A1.
      template: CommandTemplate(binary: "open", args: ["-a", "Xcode", "{dir}"]),
      missingBinaryHelp: "Install Xcode from the Mac App Store."
    ),
    BuiltinEntry(
      id: "sublime",
      displayName: "Sublime Text",
      template: CommandTemplate(binary: "subl", args: ["{dir}"]),
      missingBinaryHelp: "The `subl` CLI ships with Sublime Text; symlink it into a PATH directory."
    ),
    BuiltinEntry(
      id: "finder",
      displayName: "Finder",
      template: CommandTemplate(binary: "open", args: ["{dir}"]),
      missingBinaryHelp: "/usr/bin/open is always available on macOS; reporting missing is unexpected."
    ),
  ]

  /// Produces a merged list of descriptors from the built-in table + user-defined customs.
  /// On ID collision with a built-in, the custom entry is rejected with `.invalidID`.
  static func merged(with customs: [CustomEditor], prober: any PathProber) throws -> [EditorDescriptor] {
    let builtinIDs = Set(builtins.map(\.id))
    for custom in customs where builtinIDs.contains(custom.id) {
      throw EditorError.badTemplate(id: custom.id, reason: "custom editor ID collides with built-in '\(custom.id)'")
    }

    var out: [EditorDescriptor] = []
    out.reserveCapacity(builtins.count + customs.count)

    for entry in builtins {
      out.append(entry.toDescriptor(prober: prober))
    }
    for custom in customs {
      try custom.template.validate() // surfaces .badTemplate on bad user input
      let status: EditorDescriptor.InstallationStatus
      if let resolved = prober.locate(binaryName: custom.template.binary) {
        status = .installed(resolvedBinary: resolved)
      } else {
        status = .missingBinary(expected: custom.template.binary)
      }
      out.append(EditorDescriptor(
        id: custom.id,
        displayName: custom.displayName,
        origin: .custom,
        template: custom.template,
        installation: status
      ))
    }
    return out
  }

  struct BuiltinEntry: Equatable, Sendable {
    let id: EditorID
    let displayName: String
    let template: CommandTemplate
    /// Short actionable hint shown next to a missing installation status.
    let missingBinaryHelp: String

    func toDescriptor(prober: any PathProber) -> EditorDescriptor {
      let status: EditorDescriptor.InstallationStatus
      if let resolved = prober.locate(binaryName: template.binary) {
        status = .installed(resolvedBinary: resolved)
      } else {
        status = .missingBinary(expected: template.binary)
      }
      return EditorDescriptor(
        id: id,
        displayName: displayName,
        origin: .builtin,
        template: template,
        installation: status
      )
    }
  }
}
