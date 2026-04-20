import Foundation
import Testing

@testable import tcKit

struct ProcessSpawnerTests {
  /// Regression: the original implementation read stdout to EOF and then stderr to
  /// EOF *after* `waitUntilExit` returned, so a child that filled both pipes past
  /// the OS pipe buffer (~64 KiB) would block on its own write and never exit. The
  /// concurrent drain resolves this; 1 MiB on each stream is well past the buffer.
  @Test(.timeLimit(.minutes(1)))
  func drainsLargeStdoutAndStderrConcurrentlyWithoutDeadlock() throws {
    let spawner = RealProcessSpawner()
    // `head -c N < /dev/zero | tr` produces exactly N bytes of a single printable
    // character. Doing stdout and stderr sequentially from the shell is fine —
    // the point is that both accumulate > pipe buffer before the child exits.
    let script = """
      head -c 1048576 < /dev/zero | tr '\\0' 'a'
      head -c 1048576 < /dev/zero | tr '\\0' 'b' 1>&2
      """
    let outcome = try spawner.run(
      executable: "/bin/sh",
      arguments: ["-c", script],
      environment: nil
    )
    #expect(outcome.exitCode == 0)
    #expect(outcome.stdout.utf8.count == 1_048_576)
    #expect(outcome.stderr.utf8.count == 1_048_576)
    #expect(outcome.stdout.hasPrefix("aaaa"))
    #expect(outcome.stderr.hasPrefix("bbbb"))
  }

  @Test
  func capturesExitCodeAndStreamsForSmallChild() throws {
    let spawner = RealProcessSpawner()
    let outcome = try spawner.run(
      executable: "/bin/sh",
      arguments: ["-c", "printf out; printf err 1>&2; exit 3"],
      environment: nil
    )
    #expect(outcome.exitCode == 3)
    #expect(outcome.stdout == "out")
    #expect(outcome.stderr == "err")
  }

  @Test
  func locateBinaryReturnsNilForUnknownExecutable() throws {
    let spawner = RealProcessSpawner()
    let result = try spawner.locateBinary(named: "definitely-no-such-binary-\(UUID().uuidString)")
    #expect(result == nil)
  }
}
