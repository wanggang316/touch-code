import AppKit
import Foundation

/// Runs a shell command under macOS administrator privileges via in-process
/// `NSAppleScript`. Used by `CLIInstallerClient` to install / uninstall
/// `tc` and `tcode` symlinks under `/usr/local/bin`. In-process AppleScript
/// makes the auth dialog show the touch-code app icon and bundle name
/// instead of a generic `osascript` prompt.
public protocol PrivilegedShell: Sendable {
  /// Runs `command` (a `/bin/sh`-compatible script) with administrator
  /// privileges, surfacing the system auth dialog with `prompt`.
  /// Throws `.userCancelled` when the dialog is dismissed (NSAppleScript
  /// errno `-128`). Throws `.scriptFailed(stderr:)` on any other failure.
  func run(_ command: String, prompt: String) throws
}

public enum PrivilegedShellError: Error, Equatable {
  case userCancelled
  case scriptFailed(stderr: String)
}

public struct AppleScriptPrivilegedShell: PrivilegedShell {
  public init() {}

  public func run(_ command: String, prompt: String) throws {
    let escapedCommand = command.replacingOccurrences(of: "\\", with: "\\\\")
      .replacingOccurrences(of: "\"", with: "\\\"")
    let escapedPrompt = prompt.replacingOccurrences(of: "\\", with: "\\\\")
      .replacingOccurrences(of: "\"", with: "\\\"")
    let source =
      "do shell script \"\(escapedCommand)\" with prompt \"\(escapedPrompt)\" with administrator privileges"
    guard let script = NSAppleScript(source: source) else {
      throw PrivilegedShellError.scriptFailed(stderr: "Failed to prepare authorization script.")
    }
    var errorInfo: NSDictionary?
    script.executeAndReturnError(&errorInfo)
    guard let errorInfo else { return }
    let errorNumber = errorInfo[NSAppleScript.errorNumber] as? Int
    if errorNumber == -128 {
      throw PrivilegedShellError.userCancelled
    }
    let message = errorInfo[NSAppleScript.errorMessage] as? String ?? ""
    throw PrivilegedShellError.scriptFailed(stderr: message)
  }
}

/// Wraps a value in single quotes for safe embedding in a `/bin/sh` script.
/// Escapes embedded single quotes via the `'\''` idiom so the result remains
/// a single shell token even if `value` contains apostrophes.
public func shellEscape(_ value: String) -> String {
  "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
}
