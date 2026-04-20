import Foundation

/// Captures the outcome of running an external binary: exit code + captured output.
public struct ProcessOutcome: Sendable, Equatable {
  public let exitCode: Int32
  public let stdout: String
  public let stderr: String

  public init(exitCode: Int32, stdout: String, stderr: String) {
    self.exitCode = exitCode
    self.stdout = stdout
    self.stderr = stderr
  }
}

public enum ProcessSpawnerError: Error, Equatable, Sendable {
  /// The requested executable was not found on the user's `$PATH`.
  case executableNotFound(String)
  /// `Process.run()` itself failed (e.g. permission denied on the launchd path).
  case launchFailed(String, underlying: String)
}

/// Narrow protocol over `Process` for the parts `tc skill install --pi` exercises.
/// `RealProcessSpawner` is the production implementation; tests inject a stub that
/// returns a canned `ProcessOutcome` and records the call for assertions.
public protocol ProcessSpawner: Sendable {
  /// Resolves `name` on `$PATH` (typically via `/usr/bin/which`). Returns `nil` when the
  /// binary is not installed rather than throwing, so callers can emit a targeted error.
  func locateBinary(named name: String) throws -> String?

  /// Runs `executable` with `arguments` and returns the captured outcome. Inherits
  /// current-process env unless `environment` is passed explicitly.
  func run(
    executable: String,
    arguments: [String],
    environment: [String: String]?
  ) throws -> ProcessOutcome
}

public struct RealProcessSpawner: ProcessSpawner {
  public init() {}

  public func locateBinary(named name: String) throws -> String? {
    let outcome = try run(
      executable: "/usr/bin/which",
      arguments: [name],
      environment: nil
    )
    guard outcome.exitCode == 0 else { return nil }
    let path = outcome.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
    return path.isEmpty ? nil : path
  }

  public func run(
    executable: String,
    arguments: [String],
    environment: [String: String]?
  ) throws -> ProcessOutcome {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: executable)
    process.arguments = arguments
    if let env = environment { process.environment = env }

    let outPipe = Pipe()
    let errPipe = Pipe()
    process.standardOutput = outPipe
    process.standardError = errPipe

    do {
      try process.run()
    } catch {
      throw ProcessSpawnerError.launchFailed(executable, underlying: "\(error)")
    }
    process.waitUntilExit()

    let stdout = String(
      bytes: outPipe.fileHandleForReading.readDataToEndOfFile(),
      encoding: .utf8
    ) ?? ""
    let stderr = String(
      bytes: errPipe.fileHandleForReading.readDataToEndOfFile(),
      encoding: .utf8
    ) ?? ""
    return ProcessOutcome(
      exitCode: process.terminationStatus,
      stdout: stdout,
      stderr: stderr
    )
  }
}
