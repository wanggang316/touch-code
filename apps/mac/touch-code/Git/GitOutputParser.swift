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

      commits.append(
        Commit(
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
        entries.append(
          WorkingTreeStatus.Entry(
            indexStatus: indexStatus,
            worktreeStatus: worktreeStatus,
            path: path,
            renamedFrom: renamedFrom
          ))
      } else {
        entries.append(
          WorkingTreeStatus.Entry(
            indexStatus: indexStatus,
            worktreeStatus: worktreeStatus,
            path: path
          ))
      }
    }
    return WorkingTreeStatus(entries: entries)
  }

  // MARK: - Diff numstat / name-status

  /// Intermediate row from `git diff --numstat -z`. Binary files emit `-\t-\tpath`
  /// (`addedLines = -1`, `removedLines = -1`).
  struct NumstatRow: Equatable, Sendable {
    var oldPath: String?
    var newPath: String
    var addedLines: Int
    var removedLines: Int
    var isBinary: Bool { addedLines < 0 && removedLines < 0 }
  }

  /// Intermediate row from `git diff --name-status -z`. Status letter is the first
  /// character of the record (`M`, `A`, `D`, `R`, `C`, …). Renames and copies emit
  /// `R<score>` / `C<score>` followed by old + new paths as separate NUL records.
  struct NameStatusRow: Equatable, Sendable {
    var status: Character
    var oldPath: String?
    var newPath: String
  }

  /// Parse `git diff --numstat -z` output. Records are NUL-separated. Rename / copy
  /// records emit `<adds>\t<dels>\t\0<old>\0<new>\0` (the path field is empty before the
  /// first NUL); the rename detection here matches that shape.
  static func parseDiffNumstatZ(_ bytes: Data) throws -> [NumstatRow] {
    guard let text = String(data: bytes, encoding: .utf8) else {
      throw GitError.unparsable(context: "numstat output was not UTF-8")
    }
    if text.isEmpty { return [] }
    var fields = text.components(separatedBy: "\0")
    if fields.last == "" { fields.removeLast() }
    var rows: [NumstatRow] = []
    var idx = fields.startIndex
    while idx < fields.endIndex {
      let head = fields[idx]
      idx += 1
      // Each numstat row begins with `<adds>\t<dels>\t<path-or-empty>`. Tabs survive
      // the `-z` split because `-z` only changes the inter-record separator.
      let parts = head.split(separator: "\t", maxSplits: 2, omittingEmptySubsequences: false)
      guard parts.count == 3 else {
        throw GitError.unparsable(context: "numstat record too short: '\(head)'")
      }
      let addsRaw = String(parts[0])
      let delsRaw = String(parts[1])
      let pathField = String(parts[2])
      let adds = addsRaw == "-" ? -1 : (Int(addsRaw) ?? 0)
      let dels = delsRaw == "-" ? -1 : (Int(delsRaw) ?? 0)
      if pathField.isEmpty {
        // Rename/copy: next two NUL records are old + new path.
        guard idx + 1 < fields.endIndex else {
          throw GitError.unparsable(context: "numstat rename missing old/new path")
        }
        let oldPath = fields[idx]
        let newPath = fields[idx + 1]
        idx += 2
        rows.append(
          NumstatRow(oldPath: oldPath, newPath: newPath, addedLines: adds, removedLines: dels)
        )
      } else {
        rows.append(
          NumstatRow(oldPath: nil, newPath: pathField, addedLines: adds, removedLines: dels)
        )
      }
    }
    return rows
  }

  /// Parse `git diff --name-status -z` output. Each record is `<STATUS>\0<path>\0` for
  /// `M` / `A` / `D` / `T`; rename / copy records are `<STATUS><score>\0<old>\0<new>\0`.
  static func parseDiffNameStatusZ(_ bytes: Data) throws -> [NameStatusRow] {
    guard let text = String(data: bytes, encoding: .utf8) else {
      throw GitError.unparsable(context: "name-status output was not UTF-8")
    }
    if text.isEmpty { return [] }
    var fields = text.components(separatedBy: "\0")
    if fields.last == "" { fields.removeLast() }
    var rows: [NameStatusRow] = []
    var idx = fields.startIndex
    while idx < fields.endIndex {
      let raw = fields[idx]
      idx += 1
      guard let status = raw.first else {
        throw GitError.unparsable(context: "empty name-status record")
      }
      if status == "R" || status == "C" {
        guard idx + 1 < fields.endIndex else {
          throw GitError.unparsable(context: "name-status rename missing old/new path")
        }
        let oldPath = fields[idx]
        let newPath = fields[idx + 1]
        idx += 2
        rows.append(NameStatusRow(status: status, oldPath: oldPath, newPath: newPath))
      } else {
        guard idx < fields.endIndex else {
          throw GitError.unparsable(context: "name-status missing path for status '\(status)'")
        }
        let path = fields[idx]
        idx += 1
        rows.append(NameStatusRow(status: status, oldPath: nil, newPath: path))
      }
    }
    return rows
  }

  /// Inner-join numstat and name-status rows on `newPath`. Status letters map to
  /// `ChangeStatus`: `A → .added`, `D → .deleted`, `R → .renamed`, anything else
  /// (`M`, `T`, `C`) → `.modified`.
  static func joinDiffNumstatNameStatus(
    numstat: [NumstatRow],
    nameStatus: [NameStatusRow]
  ) -> [ChangedFile] {
    let byPath = Dictionary(uniqueKeysWithValues: nameStatus.map { ($0.newPath, $0) })
    return numstat.map { row in
      let nameStatus = byPath[row.newPath]
      let mappedStatus: ChangeStatus = {
        guard let s = nameStatus?.status else { return .modified }
        switch s {
        case "A": return .added
        case "D": return .deleted
        case "R": return .renamed
        default: return .modified
        }
      }()
      let oldPath = row.oldPath ?? nameStatus?.oldPath
      return ChangedFile(
        oldPath: oldPath,
        newPath: row.newPath,
        status: mappedStatus,
        addedLines: max(0, row.addedLines),
        removedLines: max(0, row.removedLines),
        isBinary: row.isBinary
      )
    }
  }
}
