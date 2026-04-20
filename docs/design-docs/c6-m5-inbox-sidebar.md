# Design Notes: C6 M5 — InboxSidebar UI

**Status:** Draft sketch (pre-implementation)
**Author:** Gump (with Claude)
**Date:** 2026-04-20
**Blocks:** Plan 0007 TCA shell landing in the app target.

Advance notes on the M5 SwiftUI + TCA integration so the implementation
can land quickly once the TCA shell is available. No code yet — just
interface shapes, placement, and open decisions.

## Scope

M5 delivers the user-visible surface: a right-side slide-in sidebar listing
every `AgentNotification`, filter chips, swipe-dismiss, deeplink-on-click,
and the settings toggles for `MuteSettings`. All underlying services
(`InboxStore`, `SettingsStore`, `NotificationCoordinator`) are already
shipped and tested. M5 wires them into the 0007 TCA feature tree and
writes the SwiftUI views.

## What lands

Under `apps/mac/touch-code/Notifications/Views/`:

- `InboxSidebar.swift` — root view. 320pt trailing panel, slides in/out
  via `transition(.move(edge: .trailing))`. Bound to a
  `@Bindable` `InboxViewModel`.
- `InboxRow.swift` — single-row cell. Agent avatar (32pt circle with
  first letter uppercase), title, body (1 line, truncated to the cell),
  provenance (Project · Worktree · Tab · Panel), relative `createdAt`,
  state chip (Completed / Waiting / Idle / Crashed). Hover shows
  trailing actions (Focus Panel, Dismiss). `.swipeActions` exposes
  Dismiss on trailing edge with `allowsFullSwipe: true`.
- `InboxFilter.swift` — enum `{ all, unread, waiting, completed, crashed }`
  with a projection helper `filter(_:through:)` that returns the
  subset of `NotificationInbox.notifications` matching the filter.
  Pure function; unit-testable without SwiftUI.
- `NotificationsSettingsView.swift` — Settings pane section with toggle
  rows for `enabled`, `badgeEnabled`, `surfaceIdle`, `redactBodies`.
  "Open System Settings" link shown when `authStatus == .denied`,
  deeplinks to `x-apple.systempreferences:com.apple.preference.notifications?id=<bundle-id>`.
- `NotificationPermissionSheet.swift` — the Continue / Not now / Never
  pre-prompt sheet. View model conforms to `NotificationPermissionDelegate`
  (already defined in M4a) and M5's bootstrap wiring swaps it in for
  `NullPermissionDelegate`.

## TCA integration

Assumes 0007 ships a root `AppReducer` with a composition scheme for
feature reducers. C6 contributes:

```swift
@Reducer
struct InboxFeature {
  @ObservableState
  struct State: Equatable {
    var isPresented: Bool = false
    var filter: InboxFilter = .all
    var notifications: [AgentNotification] = []
    var unreadCount: Int = 0
  }

  enum Action {
    case toggleSidebar
    case filterChanged(InboxFilter)
    case rowTapped(AgentNotification.ID)
    case rowSwipedDismiss(AgentNotification.ID)
    case muteRuleTapped(ruleID: String)
    case clearAllTapped
    case inboxUpdated(NotificationInbox)        // from InboxClient stream
    case unreadCountUpdated(Int)                // from unreadPublisher
  }

  @Dependency(\.inboxClient) var inboxClient

  var body: some ReducerOf<Self> { /* … */ }
}
```

`InboxClient` is a `DependencyKey` matching the existing `TerminalClient` /
`HierarchyClient` pattern (both landing via 0007):

```swift
struct InboxClient: Sendable {
  var markRead: @Sendable ([UUID]) async -> Void
  var dismiss: @Sendable ([UUID]) async -> Void
  var clearAll: @Sendable () async -> Void
  var muteRule: @Sendable (String) async -> Void
  var observe: @Sendable () -> AsyncStream<NotificationInbox>
  var observeUnread: @Sendable () -> AsyncStream<Int>
}
```

Live impl wraps `InboxStore` + `SettingsStore`. Mock impl for tests
records every call.

## Integration with existing surfaces

- Toolbar bell icon in `MainView` with a badge reading from
  `InboxFeature.State.unreadCount`. Tapping sends `.toggleSidebar`.
- ⌘⇧N keyboard shortcut bound to the same action.
- `DeeplinkRouter` (already exists per architecture §URL scheme) —
  the OS banner's `touch-code://panel/<id>/focus` URL and the row
  double-click both go through this router. When the Panel is closed,
  router opens the inbox sidebar filtered to the source notification's
  id.

## Open design decisions

1. **Relative time formatting** — `"just now"`, `"2m ago"`, `"1h ago"`,
   `"Apr 20"`. Use `RelativeDateTimeFormatter` (auto-updating every
   minute) or hand-rolled? Leaning: `RelativeDateTimeFormatter` with
   `.abbreviated` style + a `TimelineView(.periodic(after:every:))`
   wrapper so the rendered string refreshes without state churn.
2. **Swipe gesture affordance** — AppKit's swipe is subtle on
   trackpads; confirm with a hover-activated trailing "Dismiss" button
   as a redundant affordance.
3. **Empty-state copy location** — keep "No agent pings. Nice." inline
   or promote to a reusable `EmptyStatePanel` component? Leaning:
   inline until a second empty state shows up.
4. **Row identity during filter animation** — SwiftUI's `List` with
   `id: .self` or `AgentNotification.id`? Leaning: `id: .id` for
   stable transitions.

## Tests

Unit-level (no SwiftUI harness needed):
- `InboxFilterTests` — 5 filter cases × fixed 7-entry inbox,
  assert returned subsets.
- `InboxFeatureTests` — TCA `TestStore` drives every `Action`,
  asserts state transitions and effect emission.
- `NotificationPermissionViewModelTests` — the view model conforms
  to `NotificationPermissionDelegate`; a test drives
  `presentPrompt()` and asserts each decision branch.

UI-level (deferred to a later task):
- SwiftUI snapshot tests for `InboxSidebar` with each filter chip.
- Manual dogfood checklist (written, not automated): bell icon,
  ⌘⇧N shortcut, swipe-dismiss, double-click focus, settings toggles
  persist, "Open System Settings" deeplink.

## Dependencies on 0007

- `AppReducer` root composition with a `@Presents` slot for the
  `InboxFeature`.
- `DeeplinkRouter` in `apps/mac/touch-code/App/Features/Deeplink/`
  (architecture §URL scheme pinned the path but the file doesn't
  exist yet on main).
- Toolbar host in `MainView` (today `MainView` is a single
  `PanelHostView` — 0007 replaces with the full app shell).

## Out-of-scope for M5

- In-app toast notifications (design §Alternatives A6 — deferred post-v1).
- Rich media / attachments in rows (design §Non-Goals).
- Keyboard navigation of the inbox list — accessibility enhancement, later.
- Per-row reply UI (design §Non-Goals — replying happens by focusing
  the Panel and typing).
