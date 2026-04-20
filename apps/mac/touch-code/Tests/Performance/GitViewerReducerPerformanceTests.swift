import ComposableArchitecture
import Foundation
import Testing
@testable import touch_code
import TouchCodeCore

/// Reducer-dispatch performance for the moment `.diffSucceeded(_)` lands. This is the hot
/// path the 200 ms whole-pipeline budget measures: parse (M8 groundwork covered — P95 ≈ 10
/// ms) + reducer state update + SwiftUI diff. This test covers the middle of that
/// sandwich. The design budget is 20 ms P95 (5 % of the 200 ms pipeline) per the plan.
///
/// Same gating + sample-count + baseline-ceiling machinery as
/// `DiffParsePerformanceBaselineTests`. Ungated default runs skip cleanly.
@MainActor
struct GitViewerReducerPerformanceTests {
  nonisolated static let performanceEnabled: Bool = {
    ProcessInfo.processInfo.environment["TC_RUN_PERFORMANCE_TESTS"] == "1"
  }()

  nonisolated static let totalSamples = 50
  nonisolated static let warmupSamples = 5
  nonisolated static let driftMargin = 1.25
  nonisolated static let reducerMsDesignBudget = 20.0

  @Test(.enabled(if: GitViewerReducerPerformanceTests.performanceEnabled))
  func measureDiffSucceededDispatch() throws {
    // Parse fixture once; the parse time is covered by the sibling test. We reuse the
    // 1 000-line working-tree diff so both tests operate on the same shape.
    let fixture = try Self.loadFixture()
    let diff = try DiffParser.parse(fixture, scope: .working)
    precondition(diff.files.count == 1 && !diff.files[0].hunks.isEmpty, "fixture parsed empty")

    // Build a scoped store pinned to the working-tree selection so `.diffSucceeded`
    // lands on a loaded viewer, not a cold initial state.
    let initial: GitViewerFeature.State = {
      var state = GitViewerFeature.State()
      state.projectID = ProjectID()
      state.worktreeID = WorktreeID()
      state.worktreePathHint = "/tmp/fixture-worktree"
      state.scope = .working
      return state
    }()

    // Warm-up loop — TCA's first dispatch on a store pays an extra one-shot cost.
    for _ in 0..<Self.warmupSamples {
      let store = Store(initialState: initial) { GitViewerFeature() }
      store.send(.diffSucceeded(diff))
      _ = store.diffState
    }

    var timings: [Double] = []
    timings.reserveCapacity(Self.totalSamples - Self.warmupSamples)
    for _ in Self.warmupSamples..<Self.totalSamples {
      let store = Store(initialState: initial) { GitViewerFeature() }
      let start = ContinuousClock.now
      store.send(.diffSucceeded(diff))
      let elapsed = ContinuousClock.now - start
      timings.append(Self.millis(elapsed))
      precondition(store.diffState.asLoaded != nil, "dispatch did not land the diff")
    }

    let stats = Self.stats(timings)
    Self.logResult(metric: "reducer_ms", stats: stats)

    let captureMode = ProcessInfo.processInfo.environment["TC_PERF_BASELINE"] == "capture"
    let baselineURL = try Self.baselineURL()
    if captureMode {
      try Self.writeBaseline(reducerMs: stats, at: baselineURL)
      print("[perf] reducer baseline captured at \(baselineURL.path)")
    } else {
      let ceiling = try Self.ceiling(
        metric: "reducer_ms", at: baselineURL, designBudget: Self.reducerMsDesignBudget
      )
      let message: Comment = "reducer_ms P95 \(stats.p95) exceeded ceiling \(ceiling) — baseline P95 × \(Self.driftMargin) vs design budget \(Self.reducerMsDesignBudget) ms, whichever is greater"
      #expect(stats.p95 <= ceiling, message)
    }
  }

  // MARK: - Helpers (mirror `DiffParsePerformanceBaselineTests`)

  nonisolated struct Stats: Codable, Equatable {
    var p50: Double
    var p95: Double
    var max: Double
  }

  nonisolated static func stats(_ samples: [Double]) -> Stats {
    let sorted = samples.sorted()
    func pct(_ p: Double) -> Double {
      let idx = Swift.max(0, Swift.min(sorted.count - 1, Int((Double(sorted.count) * p).rounded(.up)) - 1))
      return sorted[idx]
    }
    return Stats(p50: pct(0.5), p95: pct(0.95), max: sorted.last ?? 0)
  }

  nonisolated static func millis(_ duration: Duration) -> Double {
    let components = duration.components
    return Double(components.seconds) * 1000.0 + Double(components.attoseconds) / 1e15
  }

  nonisolated static func logResult(metric: String, stats: Stats) {
    print("[perf] \(metric): p50=\(String(format: "%.2f", stats.p50)) ms, " +
          "p95=\(String(format: "%.2f", stats.p95)) ms, " +
          "max=\(String(format: "%.2f", stats.max)) ms")
  }

  nonisolated static func loadFixture() throws -> Data {
    let sourceURL = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .appendingPathComponent("fixtures", isDirectory: true)
      .appendingPathComponent("diff-1000-lines.txt", isDirectory: false)
    return try Data(contentsOf: sourceURL)
  }

  nonisolated static func baselineURL() throws -> URL {
    let sourceURL = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .appendingPathComponent("baseline.json", isDirectory: false)
    return sourceURL
  }

  /// Extends the existing baseline.json with a `reducer_ms` entry, preserving prior
  /// entries (in particular `parse_ms` written by the sibling test). Reads the current
  /// payload if present and merges; otherwise writes a fresh payload.
  nonisolated static func writeBaseline(reducerMs: Stats, at url: URL) throws {
    struct Payload: Codable {
      var version: Int
      var machineKey: String
      var capturedAt: String
      var samples: [String: Stats]
    }
    var existing: Payload?
    if FileManager.default.fileExists(atPath: url.path) {
      let data = try Data(contentsOf: url)
      existing = try? JSONDecoder().decode(Payload.self, from: data)
    }
    var samples = existing?.samples ?? [:]
    samples["reducer_ms"] = reducerMs
    let payload = Payload(
      version: existing?.version ?? 1,
      machineKey: machineKey(),
      capturedAt: ISO8601DateFormatter().string(from: Date()),
      samples: samples
    )
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    let data = try encoder.encode(payload)
    try data.write(to: url, options: .atomic)
  }

  nonisolated static func ceiling(metric: String, at url: URL, designBudget: Double) throws -> Double {
    struct Payload: Codable {
      var samples: [String: Stats]
    }
    guard FileManager.default.fileExists(atPath: url.path) else {
      return designBudget
    }
    let data = try Data(contentsOf: url)
    let payload = try JSONDecoder().decode(Payload.self, from: data)
    let baselineP95 = payload.samples[metric]?.p95 ?? designBudget
    return Swift.max(designBudget, baselineP95 * Self.driftMargin)
  }

  nonisolated static func machineKey() -> String {
    #if arch(arm64)
    return "arm64-apple-macos"
    #else
    return "x86_64-apple-macos"
    #endif
  }
}

extension GitViewerFeature.DiffState {
  fileprivate var asLoaded: UnifiedDiff? {
    if case .loaded(let diff) = self { return diff }
    return nil
  }
}
