import Foundation

/// Validates that a filesystem path lies strictly inside `$HOME`, accounting for
/// symlinks an attacker may have planted along the path. Defends against two
/// escape paths that a naive `resolvingSymlinksInPath()` + prefix check misses:
///
/// 1. A pre-existing symlink at the destination pointing to an external target —
///    `resolvingSymlinksInPath()` on the parent URL does not always resolve the
///    final leaf the same way `copyItem` later traverses it.
/// 2. A symlink at any ancestor directory whose real target is outside `$HOME` —
///    when intermediate path components do not yet exist, `resolvingSymlinksInPath`
///    stops early and leaves the malicious ancestor unresolved, so the literal
///    prefix check against `$HOME` passes even though `FileManager.copyItem` will
///    follow the symlink and write outside `$HOME`.
///
/// The rule: only `$HOME` itself gets `resolvingSymlinksInPath()` (to collapse OS
/// firmlinks like `/Users` → `/System/Volumes/Data/Users`). The destination is
/// compared literally, and every ancestor within `$HOME` is then inspected with
/// `lstat` semantics — any symlink whose real target escapes `$HOME` is rejected.
public enum HomeScopeGuard {
  public static func isInsideHome(
    _ destination: URL,
    fileSystem: SkillFileSystem = RealSkillFileSystem(),
    homeDirectory: URL = URL(fileURLWithPath: NSHomeDirectory())
  ) -> Bool {
    let home = homeDirectory.standardizedFileURL.resolvingSymlinksInPath()
    let dest = destination.standardizedFileURL
    let homePath = home.path

    // Literal prefix check — no symlink resolution on dest.
    guard dest.path == homePath || dest.path.hasPrefix(homePath + "/") else {
      return false
    }

    // Inspect destination itself: a pre-existing symlink (including dangling ones)
    // whose real target leaves `$HOME` is an escape.
    if isSymbolicLink(atPath: dest.path, fileSystem: fileSystem),
       !targetStaysWithinHome(dest, homePath: homePath, fileSystem: fileSystem) {
      return false
    }

    // Walk ancestor chain up to `$HOME`. Any ancestor that is itself a symlink
    // pointing outside `$HOME` is an escape the literal prefix check missed.
    var current = dest.deletingLastPathComponent()
    while current.path != homePath && current.path != "/" {
      if isSymbolicLink(atPath: current.path, fileSystem: fileSystem),
         !targetStaysWithinHome(current, homePath: homePath, fileSystem: fileSystem) {
        return false
      }
      let parent = current.deletingLastPathComponent()
      if parent.path == current.path { break }
      current = parent
    }
    return true
  }

  /// Reads the raw target of a symlink (via `readlink`-equivalent) and normalizes
  /// it against `$HOME`. Prefer this over `resolvingSymlinksInPath()` because
  /// the latter silently returns the unresolved input path for *dangling* symlinks
  /// — letting a link to `/tmp/not-yet-created` read as in-home until the attacker
  /// creates the target.
  private static func targetStaysWithinHome(
    _ url: URL,
    homePath: String,
    fileSystem: SkillFileSystem
  ) -> Bool {
    guard let rawTarget = try? fileSystem.destinationOfSymbolicLink(atPath: url.path) else {
      // Cannot read the link target — treat as escape rather than silently pass.
      return false
    }
    let targetURL: URL
    if rawTarget.hasPrefix("/") {
      targetURL = URL(fileURLWithPath: rawTarget)
    } else {
      targetURL = url.deletingLastPathComponent().appendingPathComponent(rawTarget)
    }
    let targetPath = targetURL.standardizedFileURL.path
    return targetPath == homePath || targetPath.hasPrefix(homePath + "/")
  }

  private static func isSymbolicLink(
    atPath path: String,
    fileSystem: SkillFileSystem
  ) -> Bool {
    // `attributesOfItem` uses `lstat` on Darwin — it succeeds even for dangling
    // symlinks and returns `.typeSymbolicLink` without following the link.
    guard let attrs = try? fileSystem.attributesOfItem(atPath: path) else { return false }
    return (attrs[.type] as? FileAttributeType) == .typeSymbolicLink
  }
}
