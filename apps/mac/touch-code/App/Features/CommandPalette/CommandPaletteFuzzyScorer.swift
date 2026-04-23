import Foundation

/// Ranks palette items against a query. Higher score = better rank;
/// returns `nil` when the item should be dropped from the filtered list.
///
/// Score bands (integer arithmetic throughout — deterministic on identical
/// input, cheap to compute):
///
///   0x2_0000 base: contiguous substring match on the item title
///   0x1_0000 base: subsequence match on the item title
///   0x0_8000 base: subsequence match on the item subtitle
///
/// Recency adds a bonus within a band but cannot flip a band — a never-
/// used contiguous match always outranks a recent subsequence match.
///
/// When the query is wrapped in double quotes (`"git view"`) the scorer
/// enters **contiguous mode**: subsequence fallback is skipped so the user
/// can force exact-substring intent when the fuzzy ranking picks the
/// wrong row.
enum CommandPaletteFuzzyScorer {
  static let contiguousBase = 0x2_0000
  static let subsequenceTitleBase = 0x1_0000
  static let subsequenceSubtitleBase = 0x0_8000
  /// Band width reserved for the recency bonus. Chosen so the largest
  /// possible recency contribution (~`maxRecencyBonus`) stays below half
  /// the gap between subsequence-title and contiguous bases.
  static let maxRecencyBonus = 0x4_000

  static func score(
    item: CommandPaletteItem,
    query: String,
    recency: [String: TimeInterval],
    now: TimeInterval
  ) -> Int? {
    let trimmed = query.trimmingCharacters(in: .whitespaces)

    if trimmed.isEmpty {
      if item.hiddenWhenQueryEmpty { return nil }
      let base = 1_000 - item.priorityTier
      return base + recencyBonus(id: item.id, recency: recency, now: now)
    }

    let (pattern, forceContiguous) = stripQuotes(trimmed)
    let needle = pattern.lowercased()
    guard !needle.isEmpty else { return nil }

    let title = item.title.lowercased()
    let titleChars = Array(title)
    let needleChars = Array(needle)

    if let (position, length) = contiguousMatch(title: titleChars, needle: needleChars) {
      let lengthRatio = (needle.count * 1_000) / max(title.count, 1)
      let positionBonus = max(0, 200 - position * 10)
      let priorityBonus = 100 - item.priorityTier
      return contiguousBase + lengthRatio + positionBonus + priorityBonus
        + recencyBonus(id: item.id, recency: recency, now: now)
    }

    if forceContiguous { return nil }

    if let score = subsequenceScore(haystack: titleChars, needle: needleChars) {
      let priorityBonus = 100 - item.priorityTier
      return subsequenceTitleBase + score + priorityBonus
        + recencyBonus(id: item.id, recency: recency, now: now)
    }

    if let subtitle = item.subtitle?.lowercased() {
      let subtitleChars = Array(subtitle)
      if let score = subsequenceScore(haystack: subtitleChars, needle: needleChars) {
        let priorityBonus = 100 - item.priorityTier
        return subsequenceSubtitleBase + score + priorityBonus
          + recencyBonus(id: item.id, recency: recency, now: now)
      }
    }

    return nil
  }

  // MARK: - Helpers

  private static func stripQuotes(_ s: String) -> (String, Bool) {
    guard s.count >= 2, s.first == "\"", s.last == "\"" else { return (s, false) }
    let inner = String(s.dropFirst().dropLast()).trimmingCharacters(in: .whitespaces)
    return (inner, true)
  }

  private static func contiguousMatch(
    title: [Character],
    needle: [Character]
  ) -> (position: Int, length: Int)? {
    guard !needle.isEmpty, needle.count <= title.count else { return nil }
    let upper = title.count - needle.count
    for start in 0...upper {
      var matched = true
      for offset in 0..<needle.count where title[start + offset] != needle[offset] {
        matched = false
        break
      }
      if matched { return (start, needle.count) }
    }
    return nil
  }

  /// Subsequence scorer with dynamic-programming match selection. For
  /// each position where a needle character could land, tracks the best
  /// cumulative bonus over all previous matches; the final score is the
  /// best path's bonus minus a span penalty. This lets `"nt"` prefer
  /// `"Open [N]ew [T]ab"` over `"Open" + "Tab"` or `"Neurotic"` without
  /// needing heuristic backtracking.
  ///
  /// Returns `nil` when the subsequence cannot be placed in order.
  private static func subsequenceScore(
    haystack: [Character],
    needle: [Character]
  ) -> Int? {
    guard !needle.isEmpty, needle.count <= haystack.count else { return nil }
    let m = needle.count
    let n = haystack.count
    // dp[k][j] = best bonus sum for placing needle[0..=k] where the k-th
    // match lands at haystack[j]; Int.min = unreachable. start[k][j] =
    // the starting position (first match) on that best path.
    var dp: [[Int]] = Array(repeating: Array(repeating: Int.min, count: n), count: m)
    var start: [[Int]] = Array(repeating: Array(repeating: -1, count: n), count: m)
    for j in 0..<n where haystack[j] == needle[0] {
      dp[0][j] = charBonus(at: j, in: haystack)
      start[0][j] = j
    }
    for k in 1..<m {
      for j in 0..<n where haystack[j] == needle[k] {
        var best = Int.min
        var bestStart = -1
        // Small optimization: iterate backwards so the first hit is also
        // the minimum gap, which is the likeliest maximum in practice.
        for jp in 0..<j where dp[k - 1][jp] != Int.min {
          let gap = j - jp - 1
          let candidate = dp[k - 1][jp] + charBonus(at: j, in: haystack) - gap
          if candidate > best {
            best = candidate
            bestStart = start[k - 1][jp]
          }
        }
        if best != Int.min {
          dp[k][j] = best
          start[k][j] = bestStart
        }
      }
    }
    // Pick the best endpoint of the final row.
    var finalScore = Int.min
    var finalStart = -1
    var finalEnd = -1
    for j in 0..<n where dp[m - 1][j] != Int.min {
      if dp[m - 1][j] > finalScore {
        finalScore = dp[m - 1][j]
        finalStart = start[m - 1][j]
        finalEnd = j
      }
    }
    guard finalScore != Int.min else { return nil }
    let span = finalEnd - finalStart + 1
    let spanPenalty = span * 2
    let positionBonus = max(0, 150 - finalStart * 5)
    return 1_000 + finalScore + positionBonus - spanPenalty
  }

  private static func charBonus(at i: Int, in haystack: [Character]) -> Int {
    guard i > 0 else { return 10 }  // first char of title
    let prev = haystack[i - 1]
    let char = haystack[i]
    switch prev {
    case "/": return 20
    case "-", "_", ".", " ": return 20
    default:
      if prev.isLowercase && char.isUppercase { return 10 }
      return 0
    }
  }

  private static func recencyBonus(
    id: String,
    recency: [String: TimeInterval],
    now: TimeInterval
  ) -> Int {
    guard let last = recency[id] else { return 0 }
    let ageSeconds = max(0, now - last)
    let ageDays = ageSeconds / 86_400
    if ageDays > 30 { return 0 }
    // 2^(-ageDays/7): half-life 7 days, fully cut at ~30 days.
    let decay = pow(0.5, ageDays / 7.0)
    return Int(Double(maxRecencyBonus) * decay)
  }
}
