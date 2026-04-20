import Foundation
import Testing
@testable import touch_code

/// Gated live-process tests for `FoundationProcessSpawner`. Prove the two contracts that
/// cannot be exercised by `RecordingProcessSpawner` (which short-circuits before any real
/// `Foundation.Process` runs):
///
/// 1. Drain-past-cap: a child whose stdout exceeds `SpawnContract.maxCapturedBytes` still
///    terminates cleanly (no pipe-buffer deadlock).
/// 2. Timeout ladder: a child that ignores SIGTERM is force-killed after the grace window,
///    and wall-clock elapsed approximates the timeout + grace (never the child's duration).
///
/// Gated by `TC_RUN_EDITOR_INTEGRATION_TESTS=1` via Swift Testing's `.enabled(if:)`.
struct LiveProcessSpawnerIntegrationTests {
  static let integrationEnabled: Bool = {
    ProcessInfo.processInfo.environment["TC_RUN_EDITOR_INTEGRATION_TESTS"] == "1"
  }()

  @Test(.enabled(if: LiveProcessSpawnerIntegrationTests.integrationEnabled))
  func drainHandlesOutputFarBeyondCapWithoutBlocking() async {
    // `yes` emits lines until killed. Pipe through `head -c <N>` with N much larger than
    // the 8 KiB SpawnContract.maxCapturedBytes — the drain must tolerate the excess bytes
    // without hanging the await.
    let dir = URL(fileURLWithPath: NSTemporaryDirectory())
    let spawner = FoundationProcessSpawner()
    let big = SpawnContract.maxCapturedBytes * 4  // 32 KiB — 4× the cap

    let start = ContinuousClock.now
    let outcome = await spawner.spawnForOpen(
      argv: ["/bin/sh", "-c", "yes | head -c \(big)"],
      env: ["PATH": "/usr/bin:/bin", "HOME": NSHomeDirectory(), "LC_ALL": "C.UTF-8"],
      cwd: dir,
      timeout: .seconds(5)
    )
    let elapsed = ContinuousClock.now - start

    // yes | head -c exits 0 (or SIGPIPE=141; both acceptable).
    switch outcome {
    case .exited(let code, _):
      #expect(code == 0 || code == 141, "expected yes|head -c to exit 0 or SIGPIPE (141), got \(code)")
    case .timedOut:
      Issue.record("drain blocked — outcome came back as .timedOut at \(elapsed)")
    case .spawnFailed(let reason):
      Issue.record("unexpected spawn failure: \(reason)")
    }
    // Sanity: elapsed should be well under the timeout.
    #expect(elapsed < .seconds(5))
  }

  @Test(.enabled(if: LiveProcessSpawnerIntegrationTests.integrationEnabled))
  func timeoutKillsStuckChildAfterGrace() async {
    // `/bin/sleep 30` does not respond to SIGTERM with a fast exit in practice — it sleeps
    // until the grace elapses, then SIGKILL kicks in. Timeout set to 1 s. Combined with the
    // 1 s sigterm grace the spawner should report `.timedOut` within ~2 s, well short of
    // the 30 s sleep.
    let dir = URL(fileURLWithPath: NSTemporaryDirectory())
    let spawner = FoundationProcessSpawner()

    let start = ContinuousClock.now
    let outcome = await spawner.spawnForOpen(
      argv: ["/bin/sleep", "30"],
      env: ["PATH": "/usr/bin:/bin", "HOME": NSHomeDirectory(), "LC_ALL": "C.UTF-8"],
      cwd: dir,
      timeout: .seconds(1)
    )
    let elapsed = ContinuousClock.now - start

    #expect(outcome == .timedOut)
    // Upper bound: timeout (1 s) + sigterm grace (1 s) + a generous slack for CI jitter.
    #expect(elapsed < .seconds(5), "timeout ladder took \(elapsed); ≥ 5 s means SIGKILL didn't fire")
    // Lower bound #1: must at least wait for the timeout.
    #expect(elapsed >= .seconds(1))
    // Lower bound #2: `sleep 30` doesn't exit on SIGTERM, so the grace window must have run
    // before SIGKILL. Timeout (1 s) + sigterm grace (1 s) = 2 s minimum. If elapsed < 2 s
    // either the grace was short-circuited (regression) or macOS killed the child faster
    // than the contract claims (unexpected and worth recording).
    #expect(elapsed >= .seconds(2), "SIGKILL fired before the grace window; elapsed=\(elapsed)")
  }

  @Test(.enabled(if: LiveProcessSpawnerIntegrationTests.integrationEnabled))
  func spawnFailedOnMissingBinary() async {
    let dir = URL(fileURLWithPath: NSTemporaryDirectory())
    let spawner = FoundationProcessSpawner()
    let outcome = await spawner.spawnForOpen(
      argv: ["/usr/bin/definitely-not-a-real-binary-abcxyz"],
      env: [:],
      cwd: dir,
      timeout: .seconds(1)
    )
    switch outcome {
    case .spawnFailed(let reason):
      #expect(reason.contains("not found") || reason.contains("No such"))
    default:
      Issue.record("expected .spawnFailed, got \(outcome)")
    }
  }
}
