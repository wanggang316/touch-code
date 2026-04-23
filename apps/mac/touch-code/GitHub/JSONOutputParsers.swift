import Foundation
import TouchCodeCore

/// Decoders that translate raw `gh` stdout bytes into TouchCodeCore DTOs. Each function is
/// a pure mapping from `Data` → (DTO | `nil` | throw `GitHubError.other`).
///
/// Why a dedicated translation layer rather than relying on the DTOs' built-in Codable:
///
/// - `gh pr view` returns `author` as a nested object (`{login, name, is_bot}`) — the DTO
///   carries a flat `author: String` login.
/// - `gh pr view` returns `commits` as an array of commit objects — the DTO carries a flat
///   `commitCount: Int`.
/// - `gh pr checks` returns a single `state` field that conflates status + conclusion
///   (`SUCCESS` / `FAILURE` / `PENDING` / `SKIPPING`) — the DTO carries a split
///   `status: CheckStatus` + `conclusion: CheckConclusion?` pair.
/// - `gh run list` emits lowercase status + conclusion strings (`completed`, `success`) —
///   the DTO enums use uppercase GraphQL raw values.
///
/// Keeping the translation here lets the DTOs stay wire-shape-independent so a future v2
/// IPC surface can evolve the server-side JSON independently.
nonisolated enum JSONOutputParsers {
  // MARK: - gh auth status

  struct AuthStatusResult: Equatable, Sendable {
    var host: String
    var user: String
  }

  /// Parses `gh auth status --json hosts`. Returns nil when no host is logged in. The
  /// first host with a non-empty user field wins; multi-host configurations fall back to
  /// the first entry (matches exec-plan 0012 single-host-in-UI scope cut).
  static func parseAuthStatus(_ data: Data) throws -> AuthStatusResult? {
    struct Wire: Decodable {
      var hosts: [String: HostEntry]?
    }
    struct HostEntry: Decodable {
      var user: String?
      var active_user: String?
    }
    do {
      let wire = try JSONDecoder().decode(Wire.self, from: data)
      guard let hosts = wire.hosts else { return nil }
      for (host, entry) in hosts {
        let user = entry.user ?? entry.active_user
        if let user, !user.isEmpty {
          return AuthStatusResult(host: host, user: user)
        }
      }
      return nil
    } catch {
      throw GitHubError.other("auth status decode: \(error)")
    }
  }

  // MARK: - gh pr view

  /// Parses `gh pr view --json ...`. Returns `nil` when the payload signals "no PR"
  /// (empty object, `{}`) — `gh` itself exits 1 in that case but stderr-carrying
  /// handling is the caller's job; this function only deals with well-formed JSON.
  static func parsePullRequest(_ data: Data) throws -> PullRequestSnapshot? {
    struct Wire: Decodable {
      var number: Int?
      var title: String?
      var state: PullRequestState?
      var isDraft: Bool?
      var headRefName: String?
      var author: Author?
      var additions: Int?
      var deletions: Int?
      var commits: [CommitStub]?
      var mergeable: MergeableState?
      var url: URL?
      var updatedAt: Date?
    }
    struct Author: Decodable {
      var login: String?
      var name: String?
    }
    struct CommitStub: Decodable {
      var oid: String?
    }
    do {
      let decoder = JSONDecoder()
      // gh pr view's `updatedAt` includes fractional seconds; plain `.iso8601` rejects
      // them. Use the same tolerant strategy the checks + run-list parsers use.
      decoder.dateDecodingStrategy = .iso8601WithFractionalSeconds
      let wire = try decoder.decode(Wire.self, from: data)
      guard let number = wire.number, let title = wire.title, let state = wire.state,
        let headRefName = wire.headRefName, let mergeable = wire.mergeable,
        let url = wire.url, let updatedAt = wire.updatedAt
      else {
        return nil
      }
      return PullRequestSnapshot(
        number: number,
        title: title,
        state: state,
        isDraft: wire.isDraft ?? false,
        headRefName: headRefName,
        author: wire.author?.login ?? "",
        additions: wire.additions ?? 0,
        deletions: wire.deletions ?? 0,
        commitCount: wire.commits?.count ?? 0,
        mergeable: mergeable,
        url: url,
        updatedAt: updatedAt
      )
    } catch {
      throw GitHubError.other("pr view decode: \(error)")
    }
  }

  // MARK: - gh pr checks

  /// Parses `gh pr checks --json ...`. Each element's single `state` field is split into
  /// the DTO's (`CheckStatus`, `CheckConclusion?`) pair. `durationSeconds` is computed
  /// from `startedAt` + `completedAt` when both are present.
  static func parseChecks(_ data: Data) throws -> [CheckResult] {
    struct WireCheck: Decodable {
      var name: String?
      var state: String?
      var startedAt: Date?
      var completedAt: Date?
      var link: URL?
    }
    do {
      let decoder = JSONDecoder()
      decoder.dateDecodingStrategy = .iso8601WithFractionalSeconds
      let wires = try decoder.decode([WireCheck].self, from: data)
      return wires.compactMap { wire -> CheckResult? in
        guard let name = wire.name, let stateString = wire.state else { return nil }
        let (status, conclusion) = splitCheckState(stateString)
        let duration: Int? = {
          guard let s = wire.startedAt, let c = wire.completedAt else { return nil }
          let seconds = Int(c.timeIntervalSince(s))
          return seconds >= 0 ? seconds : nil
        }()
        return CheckResult(
          name: name,
          status: status,
          conclusion: conclusion,
          detailsURL: wire.link,
          startedAt: wire.startedAt,
          completedAt: wire.completedAt,
          durationSeconds: duration
        )
      }
    } catch {
      throw GitHubError.other("pr checks decode: \(error)")
    }
  }

  /// Maps `gh pr checks`' collapsed `state` to the split status + conclusion pair. Unknown
  /// tokens fall through to `.inProgress` with no conclusion so the UI shows "pending" —
  /// better than failing the whole check list on a single unrecognised value.
  static func splitCheckState(_ state: String) -> (CheckStatus, CheckConclusion?) {
    switch state.uppercased() {
    case "SUCCESS": return (.completed, .success)
    case "FAILURE", "FAILED": return (.completed, .failure)
    case "CANCELLED", "CANCELED": return (.completed, .cancelled)
    case "SKIPPED", "SKIPPING": return (.completed, .skipped)
    case "NEUTRAL": return (.completed, .neutral)
    case "TIMED_OUT", "TIMEOUT": return (.completed, .timedOut)
    case "ACTION_REQUIRED": return (.completed, .actionRequired)
    case "PENDING", "QUEUED": return (.queued, nil)
    case "IN_PROGRESS": return (.inProgress, nil)
    case "WAITING": return (.waiting, nil)
    default: return (.inProgress, nil)
    }
  }

  // MARK: - gh run list

  /// Parses `gh run list --limit 1 --json ...`. Returns the first (and only) element,
  /// or `nil` when the branch has never run a workflow. Normalizes gh's lowercase
  /// status / conclusion strings to the DTO's uppercase raw values.
  static func parseLatestWorkflowRun(_ data: Data) throws -> WorkflowRun? {
    struct Wire: Decodable {
      var databaseId: Int64?
      var name: String?
      var status: String?
      var conclusion: String?
      var headBranch: String?
      var headSha: String?
      var number: Int?
      var updatedAt: Date?
      var url: URL?
    }
    do {
      let decoder = JSONDecoder()
      decoder.dateDecodingStrategy = .iso8601WithFractionalSeconds
      let wires = try decoder.decode([Wire].self, from: data)
      guard let wire = wires.first,
        let dbid = wire.databaseId, let name = wire.name, let statusRaw = wire.status,
        let headBranch = wire.headBranch, let headSha = wire.headSha,
        let number = wire.number, let updatedAt = wire.updatedAt, let url = wire.url
      else {
        return nil
      }
      guard let status = CheckStatus(rawValue: statusRaw.uppercased()) else {
        throw GitHubError.other("run list: unknown status '\(statusRaw)'")
      }
      let conclusion: CheckConclusion? = wire.conclusion.flatMap { raw -> CheckConclusion? in
        guard !raw.isEmpty else { return nil }
        return CheckConclusion(rawValue: raw.uppercased())
      }
      return WorkflowRun(
        databaseID: dbid,
        name: name,
        status: status,
        conclusion: conclusion,
        headBranch: headBranch,
        headSHA: headSha,
        runNumber: number,
        updatedAt: updatedAt,
        url: url
      )
    } catch let error as GitHubError {
      throw error
    } catch {
      throw GitHubError.other("run list decode: \(error)")
    }
  }
}

extension JSONDecoder.DateDecodingStrategy {
  /// `gh` timestamps are ISO-8601 with a trailing `Z`; some commands return fractional
  /// seconds (`...123Z`), some don't. `.iso8601` alone rejects the fractional form.
  nonisolated static var iso8601WithFractionalSeconds: JSONDecoder.DateDecodingStrategy {
    .custom { decoder in
      let container = try decoder.singleValueContainer()
      let string = try container.decode(String.self)
      let formatters: [ISO8601DateFormatter] = [
        {
          let f = ISO8601DateFormatter()
          f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
          return f
        }(),
        {
          let f = ISO8601DateFormatter()
          f.formatOptions = [.withInternetDateTime]
          return f
        }(),
      ]
      for formatter in formatters {
        if let date = formatter.date(from: string) {
          return date
        }
      }
      throw DecodingError.dataCorruptedError(
        in: container,
        debugDescription: "Invalid ISO-8601 date: \(string)"
      )
    }
  }
}
