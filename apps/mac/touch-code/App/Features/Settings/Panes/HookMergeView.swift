import SwiftUI
import TouchCodeCore

/// Where a hook row originated. `.global` is the user's `hooks.json`; `.project`
/// is a subscription whose scope binds it to the current Project (via `.projectID`,
/// `.projectPathGlob`, or any worktree-level scope pointing at this Project's
/// worktrees). Used by the Project Hooks pane to source-tag each row.
public nonisolated enum HookSource: String, Hashable, Sendable {
  case global
  case project

  var tagLabel: String {
    switch self {
    case .global: return "Global"
    case .project: return "Project"
    }
  }
}

/// One row in the Hooks list. Immutable. Pane owners build these from
/// `HookSubscription` via `HookRowBuilder.make(from:source:)` (or by any other
/// rule; the view does not care). Frozen contract — T3 and T4 share this shape.
public nonisolated struct HookRow: Identifiable, Hashable, Sendable {
  public let id: UUID
  public let displayName: String
  public let eventLabel: String
  public let matchSummary: String?
  public let enabled: Bool
  public let source: HookSource

  public init(
    id: UUID,
    displayName: String,
    eventLabel: String,
    matchSummary: String?,
    enabled: Bool,
    source: HookSource
  ) {
    self.id = id
    self.displayName = displayName
    self.eventLabel = eventLabel
    self.matchSummary = matchSummary
    self.enabled = enabled
    self.source = source
  }
}

/// A button rendered underneath the list. `handler` runs on `@MainActor`. Two
/// `TrailingAction` values compare equal if they share title + systemImage;
/// closures are intentionally excluded from equality.
public nonisolated struct TrailingAction {
  public let title: String
  public let systemImage: String?
  public let handler: @MainActor () -> Void

  public init(
    title: String,
    systemImage: String? = nil,
    handler: @escaping @MainActor () -> Void
  ) {
    self.title = title
    self.systemImage = systemImage
    self.handler = handler
  }
}

extension TrailingAction: Equatable {
  public static func == (lhs: TrailingAction, rhs: TrailingAction) -> Bool {
    lhs.title == rhs.title && lhs.systemImage == rhs.systemImage
  }
}

/// Read-only renderer for a list of `HookRow`. Shared between the Developer pane
/// (Global-only) and the Project Hooks pane (Global + Project merged — flips
/// `showsSourceTag` on). Empty-state and trailing-action affordances are
/// configurable; the core rendering rules are fixed so hooks look identical in
/// both surfaces.
public struct HookMergeView: View {
  private let rows: [HookRow]
  private let emptyStateTitle: String
  private let emptyStateMessage: String?
  private let showsSourceTag: Bool
  private let trailingAction: TrailingAction?

  public init(
    rows: [HookRow],
    emptyStateTitle: String = "No hooks configured.",
    emptyStateMessage: String? = nil,
    showsSourceTag: Bool = false,
    trailingAction: TrailingAction? = nil
  ) {
    self.rows = rows
    self.emptyStateTitle = emptyStateTitle
    self.emptyStateMessage = emptyStateMessage
    self.showsSourceTag = showsSourceTag
    self.trailingAction = trailingAction
  }

  public var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      if rows.isEmpty {
        emptyState
      } else {
        list
      }
      if let action = trailingAction {
        Button {
          action.handler()
        } label: {
          if let symbol = action.systemImage {
            Label(action.title, systemImage: symbol)
          } else {
            Text(action.title)
          }
        }
        .buttonStyle(.borderless)
      }
    }
  }

  private var list: some View {
    VStack(alignment: .leading, spacing: 0) {
      ForEach(rows) { row in
        HookRowView(row: row, showsSourceTag: showsSourceTag)
        if row.id != rows.last?.id { Divider() }
      }
    }
    .padding(8)
    .background(Color(nsColor: .textBackgroundColor), in: .rect(cornerRadius: 6))
  }

  private var emptyState: some View {
    VStack(alignment: .leading, spacing: 4) {
      Text(emptyStateTitle)
        .font(.callout)
        .foregroundStyle(.secondary)
      if let message = emptyStateMessage {
        Text(message)
          .font(.caption)
          .foregroundStyle(.tertiary)
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .padding(12)
    .background(Color(nsColor: .textBackgroundColor), in: .rect(cornerRadius: 6))
  }
}

private struct HookRowView: View {
  let row: HookRow
  let showsSourceTag: Bool

  var body: some View {
    HStack(alignment: .top, spacing: 10) {
      Circle()
        .fill(row.enabled ? Color.green : Color.secondary)
        .frame(width: 8, height: 8)
        .padding(.top, 6)
        .accessibilityLabel(row.enabled ? "enabled" : "disabled")
      VStack(alignment: .leading, spacing: 2) {
        Text(row.displayName)
          .font(.system(.body, design: .monospaced))
          .lineLimit(1)
          .truncationMode(.tail)
        Text(caption)
          .font(.caption)
          .foregroundStyle(.secondary)
      }
      Spacer(minLength: 0)
      if showsSourceTag {
        Text(row.source.tagLabel)
          .font(.caption)
          .foregroundStyle(.tertiary)
      }
    }
    .padding(.vertical, 4)
  }

  private var caption: String {
    if let summary = row.matchSummary, !summary.isEmpty {
      return "\(row.eventLabel) — \(summary)"
    }
    return row.eventLabel
  }
}

/// Shared mapping rule `HookSubscription` → `HookRow`. Keeps the display
/// derivation in one place so T3 and T4 render identical looking rows for the
/// same underlying subscription.
///
/// **Truncation contract (frozen).** Both `maxDisplayNameLength` and
/// `matchSummaryLimit` are expressed as the *final rendered length including
/// the ellipsis character*. When a source string exceeds the limit, the row
/// ends with `"…"` (one glyph) and the total character count is exactly
/// `limit`, not `limit + 1`. Callers — especially T4's Repository Hooks pane —
/// can rely on this when reserving visual width.
public nonisolated enum HookRowBuilder {
  /// Maximum final visual width of `HookRow.displayName`, **including** the
  /// trailing ellipsis when truncation occurs.
  static let maxDisplayNameLength = 60
  /// Maximum final visual width of `HookRow.matchSummary`, **including** the
  /// trailing ellipsis when truncation occurs.
  static let matchSummaryLimit = 80

  public static func make(
    from subscription: HookSubscription,
    source: HookSource
  ) -> HookRow {
    HookRow(
      id: subscription.id,
      displayName: displayName(for: subscription.command),
      eventLabel: subscription.event.rawValue,
      matchSummary: matchSummary(for: subscription),
      enabled: !subscription.disabled,
      source: source
    )
  }

  static func displayName(for command: String) -> String {
    truncated(command, limit: maxDisplayNameLength)
  }

  static func matchSummary(for subscription: HookSubscription) -> String? {
    if let pattern = subscription.matchPattern, !pattern.isEmpty {
      return truncated(pattern, limit: matchSummaryLimit)
    }
    if subscription.scope != .anyPane {
      return "scope: \(scopeLabel(subscription.scope))"
    }
    return nil
  }

  /// Returns `value` unchanged when its character count is `<= limit`,
  /// otherwise `<prefix><ellipsis>` whose final total character count is
  /// exactly `limit`. `limit` is interpreted as the final visual width
  /// including the ellipsis — see the truncation contract on
  /// `HookRowBuilder`.
  static func truncated(_ value: String, limit: Int) -> String {
    guard value.count > limit else { return value }
    return String(value.prefix(limit - 1)) + "…"
  }

  private static func scopeLabel(_ scope: HookSubscription.Scope) -> String {
    switch scope {
    case .anyPane: return "anyPane"
    case .paneID: return "paneID"
    case .paneLabel: return "paneLabel"
    case .tabID: return "tabID"
    case .tabLabel: return "tabLabel"
    case .worktreeID: return "worktreeID"
    case .worktreePathGlob: return "worktreePathGlob"
    case .projectID: return "projectID"
    case .projectPathGlob: return "projectPathGlob"
    }
  }
}

#Preview("Populated, Global only") {
  HookMergeView(
    rows: [
      HookRow(
        id: UUID(),
        displayName: "notify-on-error",
        eventLabel: "pane.output",
        matchSummary: "error.*",
        enabled: true,
        source: .global
      ),
      HookRow(
        id: UUID(),
        displayName: "short",
        eventLabel: "worktree.activated",
        matchSummary: nil,
        enabled: false,
        source: .global
      ),
    ],
    trailingAction: TrailingAction(title: "Reveal hooks.json", systemImage: "folder") {}
  )
  .padding()
  .frame(width: 500)
}

#Preview("Merged sources, tag visible") {
  HookMergeView(
    rows: [
      HookRow(
        id: UUID(), displayName: "global hook", eventLabel: "pane.ready",
        matchSummary: nil, enabled: true, source: .global
      ),
      HookRow(
        id: UUID(), displayName: "repo hook", eventLabel: "pane.output",
        matchSummary: "scope: paneLabel", enabled: true, source: .project
      ),
    ],
    showsSourceTag: true
  )
  .padding()
  .frame(width: 520)
}

#Preview("Empty") {
  HookMergeView(rows: [], emptyStateMessage: "Edit hooks.json to add one.")
    .padding()
    .frame(width: 500)
}
