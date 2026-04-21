import Foundation

/// `repositories[<ProjectID>]` value in `settings.json` (v2). **Reserved-empty in T1** — no
/// fields declared, no optionals added. T4 (or a future wave) may add fields without a schema
/// version bump because an empty `{}` object decodes cleanly into `RepositorySettings()` and
/// re-encodes identically.
///
/// Per-Project data that exists today (default-editor override, worktree base directory) stays
/// on `Project` in `catalog.json` and is reached via `HierarchyManager`. See
/// `docs/design-docs/settings-base.md` §Repository scope — D1.
public nonisolated struct RepositorySettings: Equatable, Codable, Sendable {
  public init() {}

  /// True when this entry carries no per-Repo preferences. `SettingsStore` GCs such entries
  /// before each save so `settings.json` does not accumulate useless `{}` objects.
  public var isEffectivelyEmpty: Bool { true }
}
