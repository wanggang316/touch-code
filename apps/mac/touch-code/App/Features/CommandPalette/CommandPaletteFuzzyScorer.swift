import Foundation

/// Ranks palette items against a query. **M2 stub**: case-insensitive
/// substring match on the title, no recency blending. The full scorer
/// (contiguous-vs-subsequence, separator bonuses, recency decay, quoted
/// contiguous mode) lands in M3 and keeps this entry-point signature.
///
/// Returns `nil` when the item should be dropped from the result list.
/// Higher returned value = better rank.
enum CommandPaletteFuzzyScorer {
  static func score(
    item: CommandPaletteItem,
    query: String,
    recency: [String: TimeInterval],
    now: TimeInterval
  ) -> Int? {
    let trimmed = query.trimmingCharacters(in: .whitespaces)
    if trimmed.isEmpty {
      if item.hiddenWhenQueryEmpty { return nil }
      return 1_000 - item.priorityTier
    }
    let haystack = item.title.lowercased()
    let needle = trimmed.lowercased()
    if haystack.contains(needle) { return 10_000 - item.priorityTier }
    return nil
  }
}
