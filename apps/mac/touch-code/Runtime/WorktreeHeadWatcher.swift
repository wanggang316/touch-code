import ComposableArchitecture
import Darwin
import Dispatch
import Foundation
import TouchCodeCore

/// Per-Worktree file-system observer on `<worktree>/.git[/...]/HEAD`.
/// Fires `events()` whenever HEAD's contents change so the rest of the
/// app can refresh the catalog row's `branch`, the WorktreeHeader, and
/// any per-branch derived state (PR badge, GitHub fetch). Closes the
/// canonical HAN-62 gap: terminal-driven `git checkout` inside a pane
/// doesn't fire NSApplication's `didBecomeActive`, so the focus-driven
/// reconcile path alone wouldn't pick up the new branch.
///
/// Design notes:
/// - One `DispatchSource.makeFileSystemObjectSource(O_EVTONLY)` per
///   watched HEAD file. Branch flips land within tens of milliseconds.
/// - Branch events are debounced (~200ms) so a single `git checkout`
///   (which usually triggers a flurry of writes and an atomic rename)
///   surfaces as one event, not three.
/// - HEAD writes are typically atomic renames (`HEAD.lock` → `HEAD`),
///   which fire `.delete` / `.rename` on the original file descriptor.
///   The watcher schedules a short restart after a delete so it
///   re-attaches to the freshly-renamed HEAD without leaking the
///   stale source.
/// - `setWorktrees` is the single mutation entry point — diff against
///   the current set and create / drop watchers accordingly. Idempotent
///   on no-op calls.
@MainActor
final class WorktreeHeadWatcher {
  private struct Watcher {
    let headURL: URL
    let source: DispatchSourceFileSystemObject
  }

  private var watchers: [WorktreeID: Watcher] = [:]
  private var pendingWorktrees: [WorktreeID: URL] = [:]
  private var debounceTasks: [WorktreeID: Task<Void, Never>] = [:]
  private var restartTasks: [WorktreeID: Task<Void, Never>] = [:]
  private var eventContinuation: AsyncStream<WorktreeID>.Continuation?

  private let debounceInterval: Duration
  private let restartDelay: Duration

  init(
    debounceInterval: Duration = .milliseconds(200),
    restartDelay: Duration = .milliseconds(500)
  ) {
    self.debounceInterval = debounceInterval
    self.restartDelay = restartDelay
  }

  /// Single subscriber. Each call replaces the prior stream; the
  /// previous one finishes so the consuming `for await` loop exits.
  /// RootFeature's `onLaunch` is the only caller.
  func events() -> AsyncStream<WorktreeID> {
    eventContinuation?.finish()
    let (stream, continuation) = AsyncStream.makeStream(of: WorktreeID.self)
    eventContinuation = continuation
    return stream
  }

  /// Sync the set of watched worktrees against the catalog. Watchers
  /// for ids no longer present are torn down; newly-present ids get a
  /// watcher attached when their HEAD file can be resolved (folders
  /// that aren't git repos yet are remembered in `pendingWorktrees`
  /// and re-tried on the next `setWorktrees` call once the path
  /// becomes a repo).
  func setWorktrees(_ worktrees: [(id: WorktreeID, path: String)]) {
    let desired = Dictionary(uniqueKeysWithValues: worktrees.map { ($0.id, URL(fileURLWithPath: $0.path)) })
    let desiredIDs = Set(desired.keys)
    let currentIDs = Set(watchers.keys).union(pendingWorktrees.keys)
    for staleID in currentIDs.subtracting(desiredIDs) {
      stopWatcher(for: staleID)
    }
    for (id, url) in desired {
      configureWatcher(worktreeID: id, worktreeURL: url)
    }
  }

  /// Tear everything down. Called from the host app's `onQuit` path.
  func stopAll() {
    for id in Array(watchers.keys) { stopWatcher(for: id) }
    pendingWorktrees.removeAll()
    eventContinuation?.finish()
    eventContinuation = nil
  }

  private func configureWatcher(worktreeID: WorktreeID, worktreeURL: URL) {
    guard let headURL = WorktreeHeadResolver.headURL(for: worktreeURL) else {
      // Not a git repo yet (e.g. `addProject(gitRoot: nil)` placeholder).
      // Remember it so the next `setWorktrees` retry picks it up after
      // `git init` lands.
      pendingWorktrees[worktreeID] = worktreeURL
      stopHeadSource(for: worktreeID)
      return
    }
    if let existing = watchers[worktreeID], existing.headURL == headURL {
      return
    }
    stopHeadSource(for: worktreeID)
    pendingWorktrees.removeValue(forKey: worktreeID)
    startWatcher(worktreeID: worktreeID, worktreeURL: worktreeURL, headURL: headURL)
  }

  private func startWatcher(worktreeID: WorktreeID, worktreeURL: URL, headURL: URL) {
    let path = headURL.path(percentEncoded: false)
    let fd = open(path, O_EVTONLY)
    guard fd >= 0 else {
      // HEAD vanished between `headURL(for:)` and `open()`. Queue a
      // restart so the next ~500ms re-resolve catches the new path.
      pendingWorktrees[worktreeID] = worktreeURL
      scheduleRestart(worktreeID: worktreeID)
      return
    }
    let queue = DispatchQueue(label: "touch-code.head-watcher.\(worktreeID.raw.uuidString)")
    let source = DispatchSource.makeFileSystemObjectSource(
      fileDescriptor: fd,
      eventMask: [.write, .rename, .delete, .attrib],
      queue: queue
    )
    source.setEventHandler { @Sendable [weak self, weak source] in
      guard let source else { return }
      let event = source.data
      Task { @MainActor in
        self?.handleEvent(worktreeID: worktreeID, worktreeURL: worktreeURL, event: event)
      }
    }
    source.setCancelHandler { @Sendable in
      close(fd)
    }
    source.resume()
    watchers[worktreeID] = Watcher(headURL: headURL, source: source)
  }

  private func handleEvent(
    worktreeID: WorktreeID,
    worktreeURL: URL,
    event: DispatchSource.FileSystemEvent
  ) {
    if event.contains(.delete) || event.contains(.rename) {
      // Atomic `HEAD.lock` → `HEAD` rename invalidates our fd. Drop the
      // current source, remember the worktree for the next reattach,
      // and still emit a debounced branch-changed event — the new HEAD
      // already holds the post-checkout ref.
      stopHeadSource(for: worktreeID)
      pendingWorktrees[worktreeID] = worktreeURL
      scheduleRestart(worktreeID: worktreeID)
      scheduleBranchChanged(worktreeID: worktreeID)
      return
    }
    scheduleBranchChanged(worktreeID: worktreeID)
  }

  private func scheduleBranchChanged(worktreeID: WorktreeID) {
    debounceTasks[worktreeID]?.cancel()
    let interval = debounceInterval
    debounceTasks[worktreeID] = Task { [weak self] in
      try? await Task.sleep(for: interval)
      guard !Task.isCancelled else { return }
      await MainActor.run {
        guard let self else { return }
        self.debounceTasks.removeValue(forKey: worktreeID)
        self.eventContinuation?.yield(worktreeID)
      }
    }
  }

  private func scheduleRestart(worktreeID: WorktreeID) {
    restartTasks[worktreeID]?.cancel()
    let delay = restartDelay
    restartTasks[worktreeID] = Task { [weak self] in
      try? await Task.sleep(for: delay)
      guard !Task.isCancelled else { return }
      await MainActor.run {
        guard let self else { return }
        self.restartTasks.removeValue(forKey: worktreeID)
        guard let worktreeURL = self.pendingWorktrees[worktreeID] else { return }
        self.configureWatcher(worktreeID: worktreeID, worktreeURL: worktreeURL)
      }
    }
  }

  private func stopHeadSource(for worktreeID: WorktreeID) {
    if let watcher = watchers.removeValue(forKey: worktreeID) {
      watcher.source.cancel()
    }
  }

  private func stopWatcher(for worktreeID: WorktreeID) {
    stopHeadSource(for: worktreeID)
    pendingWorktrees.removeValue(forKey: worktreeID)
    debounceTasks.removeValue(forKey: worktreeID)?.cancel()
    restartTasks.removeValue(forKey: worktreeID)?.cancel()
  }
}

extension WorktreeHeadWatcher: DependencyKey {
  /// Unconfigured fallback used until `TouchCodeApp.bringUp` overrides it
  /// with the live instance. Mirrors `ProjectReconciler.liveValue`: a real
  /// instance, but `setWorktrees` is never called so no watchers are
  /// attached and `events()` finishes immediately. Lets reducer wiring
  /// resolve `@Dependency(WorktreeHeadWatcher.self)` in tests without an
  /// explicit override.
  static var liveValue: WorktreeHeadWatcher {
    MainActor.assumeIsolated { WorktreeHeadWatcher() }
  }

  static var testValue: WorktreeHeadWatcher { liveValue }
}

extension DependencyValues {
  var worktreeHeadWatcher: WorktreeHeadWatcher {
    get { self[WorktreeHeadWatcher.self] }
    set { self[WorktreeHeadWatcher.self] = newValue }
  }
}
