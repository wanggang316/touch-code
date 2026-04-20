import Foundation
import TouchCodeCore

/// Pure parsers for the non-diff `git` outputs this service consumes:
///
/// - `git log --pretty=format:%H%x00%an%x00%ae%x00%aI%x00%s%x00%P -z` — null-byte-separated
///   fields, `\0` record separator (trailing `\0` between records).
/// - `git status --porcelain=v1 -z` — `XY <path>\0` records, with rename/copy emitted as
///   `XY <new>\0<old>\0` (the `-z` variant uses `\0` rather than `->` separators).
///
/// `nonisolated` for the same reason as `DiffParser` — pure over its bytes.
nonisolated enum GitOutputParser {
  // MARK: - Log

  static func parseLog(_ bytes: Data) throws -> [Commit] {
    // Split on NUL. `git log -z` puts a NUL between records, not at end, so trailing empty is
    // possible. Our format uses NUL between fields *within* each record too, so every six
    // fields begin a new commit.
    guard let text = String(data: bytes, encoding: .utf8) else {
      throw GitError.unparsable(context: "log output was not UTF-8")
    }
    if text.isEmpty { return [] }

    // Split every field — commits are consecutive groups of 6 fields.
    var fields = text.components(separatedBy: "\0")
    // A trailing empty field is produced when the final record ends on NUL + empty. Drop it.
    if fields.last == "" { fields.removeLast() }
    guard fields.count % 6 == 0 else {
      throw GitError.unparsable(context: "log fields are not a multiple of 6 (got \(fields.count))")
    }

    let iso = ISO8601DateFormatter()
    iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    let isoNoFractional = ISO8601DateFormatter()
    isoNoFractional.formatOptions = [.withInternetDateTime]

    var commits: [Commit] = []
    commits.reserveCapacity(fields.count / 6)
    var idx = fields.startIndex
    while idx < fields.endIndex {
      let hash = fields[idx]
      let authorName = fields[idx + 1]
      let authorEmail = fields[idx + 2]
      let dateString = fields[idx + 3]
      let subject = fields[idx + 4]
      let parentsString = fields[idx + 5]
      idx += 6

      guard !hash.isEmpty else {
        throw GitError.unparsable(context: "empty commit hash in log output")
      }
      // Dates must parse; silently falling to epoch-0 hides real problems in the UI.
      guard let date = iso.date(from: dateString) ?? isoNoFractional.date(from: dateString) else {
        throw GitError.unparsable(context: "unparseable commit date '\(dateString)' for \(hash)")
      }
      let parents = parentsString.isEmpty ? [] : parentsString.split(separator: " ").map(String.init)

      commits.append(Commit(
        id: hash,
        authorName: authorName,
        authorEmail: authorEmail,
        date: date,
        subject: subject,
        parents: parents
      ))
    }
    return commits
  }

  // MARK: - Status

  static func parseStatus(_ bytes: Data) throws -> WorkingTreeStatus {
    guard let text = String(data: bytes, encoding: .utf8) else {
      throw GitError.unparsable(context: "status output was not UTF-8")
    }
    if text.isEmpty { return WorkingTreeStatus(entries: []) }

    var records = text.components(separatedBy: "\0")
    if records.last == "" { records.removeLast() }

    var entries: [WorkingTreeStatus.Entry] = []
    var idx = records.startIndex
    while idx < records.endIndex {
      let record = records[idx]
      idx += 1
      guard record.count >= 4 else {
        throw GitError.unparsable(context: "status record too short: '\(record)'")
      }
      let chars = Array(record)
      let indexStatus = chars[0]
      let worktreeStatus = chars[1]
      // porcelain v1 `-z` format separates XY from <path> with a literal space
      // — if it's absent we're looking at malformed output (or a future git
      // that changed the format) and continuing would truncate the path.
      guard chars[2] == " " else {
        throw GitError.unparsable(context: "status record missing XY/path separator: '\(record)'")
      }
      let path = String(chars[3...])

      // Rename/copy records emit the new path in the primary record, with the old path as the
      // *next* NUL-separated record. Both index and worktree statuses can carry `R`/`C`.
      if indexStatus == "R" || indexStatus == "C" || worktreeStatus == "R" || worktreeStatus == "C" {
        guard idx < records.endIndex else {
          throw GitError.unparsable(context: "rename/copy record missing old path: \(record)")
        }
        let renamedFrom = records[idx]
        idx += 1
        entries.append(WorkingTreeStatus.Entry(
          indexStatus: indexStatus,
          worktreeStatus: worktreeStatus,
          path: path,
          renamedFrom: renamedFrom
        ))
      } else {
        entries.append(WorkingTreeStatus.Entry(
          indexStatus: indexStatus,
          worktreeStatus: worktreeStatus,
          path: path
        ))
      }
    }
    return WorkingTreeStatus(entries: entries)
  }
}
