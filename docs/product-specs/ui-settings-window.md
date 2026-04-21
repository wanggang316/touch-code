# Product Spec: Settings Window

**Status:** Draft
**Author:** Gump (with Claude)
**Date:** 2026-04-21
**Branch:** `feature/settings-base`

## Summary

Replace the current modal Settings *sheet* (one pane: Editors) with a dedicated,
always-available **Settings Window** modeled on supacode. The window uses a
`NavigationSplitView` — left sidebar lists global sections plus a Repositories
section; right detail pane renders the selected section. Along the way, unify the
now-clashing `settings.json` schemas (`SettingsStore` vs `NotificationSettingsStore`
both write the same file and silently strip each other's keys) into a single
versioned `settings.json` v2 under one owner, and introduce per-Repository
overrides as first-class state.

Scope for this "settings-base" branch is the **framework plus the panes that map
to already-shipped capabilities (C4, C6, C7, C8) and minimal plumbing for C3**.
Functionally new surfaces (Shortcuts recorder, Updates channel, Appearance
theme engine) ship as placeholder sections with a shared "Coming soon" pane so
the navigation shape and schema slots are in place without requiring their
engines to exist yet.

## Vocabulary

- **Project** is touch-code's internal term for a git repo bound to a Space
  (see C2 in `docs/product-spec.md`). In the Settings Window the sidebar
  *labels* them as **Repositories** to match supacode; the underlying entity
  type remains `Project`. No renaming of `Project*` types.
- **Section** refers to a sidebar row. The user picks one section at a time.
- **Global section** = not scoped to a single Repository (General, Notifications,
  Developer, Shortcuts, Updates, About).
- **Repository section** = scoped to one Project (repository-level General,
  repository-level Hooks).

## Layout Overview

```
┌──────────────────────┬───────────────────────────────────────────────┐
│  Settings window (independent Window, ⌘,)                            │
├──────────────────────┼───────────────────────────────────────────────┤
│ ⚙  General           │  Detail pane for the selected section         │
│ 🔔 Notifications     │                                               │
│ 🔨 Developer         │                                               │
│ ⌨  Shortcuts         │                                               │
│ ⬇  Updates           │                                               │
│ ℹ  About             │                                               │
│                      │                                               │
│ ── Repositories ──   │                                               │
│ ▶ touch-code         │                                               │
│ ▼ supacode           │                                               │
│    General           │                                               │
│    Hooks             │                                               │
│ ▶ ghostty            │                                               │
└──────────────────────┴───────────────────────────────────────────────┘
  sidebar (≥220pt)        detail (≥530pt)              total ≥750 × ≥500
```

## User Stories

- As a user, I want ⌘, to open a dedicated Settings window (not a sheet blocking
  my terminal) so that I can tweak a preference and see its effect in the main
  window without closing Settings.
- As a user with several open repositories, I want a per-Repository section in
  the sidebar so that I can override the default editor or hooks for just one
  project.
- As a user who already uses the Editors pane, I want the Editors UI preserved
  inside General so that nothing I configured before is lost or moved out from
  under me.
- As a user who relies on agent notifications (C6), I want the Notifications
  pane to surface mute rules, system-notification permission state, and a
  one-click "Open System Settings" escape hatch when permission is denied.
- As a user of the `tc` CLI (C4), I want an inline "Install / Uninstall `tc`"
  control so that I do not have to hunt for a shell one-liner.
- As a user whose `~/.config/touch-code/settings.json` is today silently
  clobbered by two competing writers, I want a single owner and a versioned
  v1 → v2 migration so that my notification preferences and editor defaults
  stop overwriting each other.

## Requirements

### Must have

- [ ] **M1 — Independent window.** A SwiftUI `Window(id: "settings")` scene,
  opened by ⌘, (menu item `CommandGroup(replacing: .appSettings)`) and
  reopenable via the menu while open. Sheet-based `SettingsSheetFeature`
  plumbing is deleted.
- [ ] **M2 — NavigationSplitView chrome.** Sidebar + detail, both visible
  (`columnVisibility: .constant(.all)`), minimum size `750 × 500`, sidebar
  min width 220 pt. Selection is a `SettingsSection` enum (see Design).
- [ ] **M3 — Six global sections.** General, Notifications, Developer,
  Shortcuts, Updates, About — all reachable, all render without crashing.
  Panes backed by shipped capabilities render real UI; panes without engine
  (Shortcuts, Updates) render a shared `ComingSoonPane` placeholder.
- [ ] **M4 — General pane.** Hosts the existing Editors feature (default
  editor picker + built-in list + custom editors list + add/remove) plus an
  Appearance placeholder row (system / light / dark picker that writes to
  settings but has no global renderer yet — deliberately non-functional UI
  stub; clearly marked "Preview" in a label).
- [ ] **M5 — Notifications pane.** Binds to the existing
  `NotificationSettingsStore` surface: in-app toggle, system toggle (+permission
  check and "Open System Settings" alert when denied), sound toggle,
  Dock-badge toggle, mute-rules summary (read-only link into mute editor
  if one exists; otherwise shows a stub). No behavior changes to the
  C6 coordinator.
- [ ] **M6 — Developer pane.** Three grouped controls:
  1. **`tc` CLI** — install / uninstall button bound to a new
     `CLIInstallerClient` (shells out to the bundled installer script;
     detects install state by `which tc` or symlink presence).
  2. **Hooks** — read-only list of user hooks from `HookConfigStore` with
     a "Reveal in Finder" button that opens `~/.config/touch-code/hooks.json`.
     No in-window editor in v1; users continue to edit via the existing flow.
  3. **Diagnostics** — "Reveal settings.json", "Reveal hooks.json",
     "Copy app version" — cheap affordances that aid support.
- [ ] **M7 — Shortcuts, Updates panes.** Shared `ComingSoonPane` with the
  section's title and a single line: "Coming in a later release."
  Selection still highlights; no empty-state flicker.
- [ ] **M8 — About pane.** App name, version (short + build), copyright,
  link to website placeholder, "Check for updates" button is absent (kept
  out — belongs in Updates pane when it lands).
- [ ] **M9 — Repositories section (sidebar).** Header "Repositories".
  `ForEach(projects)` — one `DisclosureGroup` per open Project. Disclosure
  expands to two rows: **General** and **Hooks**. Sidebar row label is the
  Project name; no avatar fetch in v1 (supacode's GitHub avatar loader is
  explicitly skipped — out of scope for settings-base).
- [ ] **M10 — Repository General pane.** Per-Project overrides: default
  editor (dropdown with "Use global default" + every installed editor),
  and a "Worktree base directory" override (file picker + clear button).
  Writes to `settings.json` under `repositories[projectID]`.
- [ ] **M11 — Repository Hooks pane.** Read-only list of the Project's
  effective hooks (global + project-scope merged). "Reveal in Finder" to
  edit on disk. Same shape as global Developer > Hooks; no in-window
  editor in v1.
- [ ] **M12 — Unified `settings.json` v2.** Single owner (`SettingsStore`
  lifted out of `TouchCodeCore/Editor/` into a new `TouchCodeCore/Settings/`
  module). New top-level shape:
  ```jsonc
  {
    "version": 2,
    "general": {
      "appearanceMode": "system",        // system | light | dark
      "defaultEditorID": "vscode",       // or null
      "customEditors": [ ... ]           // migrated verbatim from v1
    },
    "notifications": {
      "inAppEnabled": true,
      "systemEnabled": true,
      "soundEnabled": true,
      "dockBadgeEnabled": true,
      "mute": { ... },                   // MuteSettings
      "authStatus": "authorized",
      "neverPrompt": false,
      "notNowUntil": null
    },
    "developer": {
      "cliInstalled": null               // cache; null = unknown
    },
    "repositories": {
      "<projectID>": {
        "defaultEditorID": null,         // nil = inherit global
        "worktreeBaseDirectoryPath": null,
        "hookOverrides": {}              // reserved; empty in v1
      }
    }
  }
  ```
  v1 → v2 migration: read v1 shape, fold `{defaultEditorID, customEditors}`
  into `general.*`, fold existing `{notifications}` into `notifications.*`,
  write v2, rename old file to `settings.json.v1-<timestamp>` as a backup.
- [ ] **M13 — Single writer.** `NotificationSettingsStore` is deleted.
  C6 coordinator consumes notification settings from the unified
  `SettingsStore` via a narrow read-only protocol (`NotificationSettingsReader`)
  so its own test harness does not need to know about the window.
- [ ] **M14 — TCA reducer shape.** New `SettingsFeature` reducer
  (`@Reducer`, `@ObservableState`) with:
  - `selection: SettingsSection?`
  - Embedded `EditorFeature.State` for the General/Editors sub-pane
  - Embedded `RepositorySettingsFeature.State?` for the currently selected
    Repository (mirrors supacode's `@Presents` pattern)
  - Per-pane actions: `binding`, `setSelection`, `setSystemNotificationsEnabled`,
    `cliInstallTapped`, `cliUninstallTapped`, `cliInstallCompleted`,
    `repositorySettings(RepositorySettingsFeature.Action)`
- [ ] **M15 — Dismiss behavior.** Closing the window sets
  `settings.selection = nil` (matches supacode) but does not tear down
  `SettingsFeature.State` — reopening returns to last selection.
- [ ] **M16 — Menu + keyboard.** `⌘,` opens or focuses the Settings window.
  `Escape` does **not** close it (macOS convention for non-modal windows).
  Window title: "Settings".

### Nice to have

- [ ] **N1** — Sidebar search field (top of sidebar) that fuzzy-filters
  section labels and Repository names.
- [ ] **N2** — Sparkle "Check for updates now" button in Updates pane
  (still leaves Updates as `ComingSoonPane` otherwise).
- [ ] **N3** — Settings export / import (JSON round-trip) in Developer >
  Diagnostics.
- [ ] **N4** — Repository Hooks pane shows the *source* of each hook
  (global vs. project override) when `hookOverrides` becomes editable.

### Explicitly out of scope (v1)

- Shortcuts recorder / custom key-binding storage (placeholder pane only).
- Appearance engine (picker stores the value but has no renderer).
- GitHub integration / repo avatars (no GitHub client in touch-code yet).
- Analytics / crash-reports toggles (no such pipeline yet).
- Skill installer UI (`tc skill install --claude-code`) — CLAUDE.md's
  "Skill is pure text, no engineering coupling" rule: the app must not
  drive skill installation through a settings reducer. Skill install stays
  a CLI-only action.
- Updates channel picker, auto-download, auto-check.
- Worktree-creation policy toggles beyond `worktreeBaseDirectoryPath`
  (supacode has `promptForWorktreeCreation`, `fetchOriginBefore…`, etc. —
  all deferred).
- Automatic `settings.json` schema upgrade past v2; unknown versions still
  abort per the architecture invariant.

## Acceptance Criteria

### Window lifecycle

- Given the app is running, when the user presses ⌘,, then a window titled
  "Settings" opens sized at least 750 × 500.
- Given the Settings window is already visible, when the user presses ⌘,,
  then the same window is focused (no second window appears).
- Given the Settings window is open, when the user closes the main window,
  then Settings stays open and its state is unchanged.
- Given the Settings window was open with a Repository > Hooks section
  selected and was closed, when the user reopens it, then the previously
  selected section is restored.

### Sidebar & navigation

- Given no Project is open, when the user opens Settings, then the
  "Repositories" section header renders with no rows beneath it.
- Given two Projects `A` and `B` are open, when the user opens Settings,
  then two DisclosureGroups render in alphabetical order, both collapsed.
- Given a Project's disclosure is collapsed, when the user clicks its
  label, then it expands and selects its General sub-row.
- Given Project `A` > General is selected, when the user adds Project `C`
  in the main window, then the sidebar updates to include `C` without
  losing the `A > General` selection.

### General pane

- Given the v1 settings file had `defaultEditorID: "vscode"`, when v2
  migration runs, then General's picker shows "VS Code" selected and
  `~/.config/touch-code/settings.json.v1-<ts>` exists as a backup.
- Given a custom editor is added via the Add sheet, when the user reopens
  Settings, then the custom editor still appears in the list (debounced
  write landed).
- Given the Appearance picker is set to "Dark", when the user closes and
  reopens Settings, then the picker still shows "Dark" (value persists
  even though no visual theme applies yet).

### Notifications pane

- Given system notification permission is denied, when the user flips the
  "System notifications" toggle on, then an alert appears with an "Open
  System Settings" button that routes to the system preferences pane.
- Given `inAppEnabled` is toggled off, when an agent completes in a
  Panel, then no in-app banner appears (coordinator reads from the
  unified store).

### Developer pane

- Given `tc` is not on PATH, when the user opens Developer, then the CLI
  row shows "Not installed" and an "Install" button.
- Given the user clicks "Install", when the installer succeeds, then the
  row shows "Installed" and the button becomes "Uninstall". On failure,
  the row shows "Failed: <error>" with a retry button.
- Given the user clicks "Reveal hooks.json" with no file present, then a
  default empty hooks file is created and revealed.

### Repository General pane

- Given Project `A` has no default-editor override, when the user picks
  "Zed" from `A`'s General pane, then `settings.json` gains
  `repositories.<id>.defaultEditorID = "zed"` within the 500 ms debounce
  window.
- Given Project `A` has a default-editor override of "Zed", when the user
  selects "Use global default", then the override is removed from the
  JSON (not set to `null`) on the next write.

### Schema migration

- Given a v1 `settings.json` with both `defaultEditorID` and a `notifications`
  block (the pre-fix corrupt-but-readable state), when the app launches,
  then both values survive into v2 and the old file is backed up under
  `settings.json.v1-<ts>`.
- Given a `settings.json` with `version: 3` (unknown), when the app
  launches, then `SettingsStore` aborts load, backs up the file, and
  starts from defaults (matches existing invariant).

### Non-regression

- Given the current `SettingsSheetFeature` tests are deleted / retargeted,
  when the test suite runs, then no residual `SettingsSheetFeature`
  references remain in the source tree (grep == 0).
- Given the root command palette had a `Settings…` entry, when the user
  selects it, then the new window opens (same wiring, new target).

## Design

### Module layout

- `TouchCodeCore/Settings/` — **new** module home for all settings types.
  - `Settings.swift` (renamed/moved from `Editor/Settings.swift`) —
    top-level `Settings` Codable struct, v2 shape, `defaultURL()`,
    migration entry point.
  - `GeneralSettings.swift`, `NotificationsSettings.swift`,
    `DeveloperSettings.swift`, `RepositorySettings.swift` — sub-shapes.
  - `SettingsMigration.swift` — v1→v2 migrator, pure function, unit-tested.
- `TouchCodeCore/Editor/` — keeps `CustomEditor`, `CommandTemplate`,
  `EditorRegistry` etc. Drops `Settings.swift` (moved).
- `apps/mac/touch-code/App/Features/Settings/` — renamed contents:
  - `SettingsFeature.swift` (new; supersedes `SettingsSheetFeature.swift`)
  - `SettingsSection.swift` (new enum)
  - `Views/SettingsWindowView.swift` (new; supersedes `SettingsSheetView`)
  - `Views/GeneralSettingsView.swift` (wraps existing `SettingsEditorSection`)
  - `Views/NotificationsSettingsView.swift`
  - `Views/DeveloperSettingsView.swift`
  - `Views/ComingSoonPane.swift`
  - `Views/AboutSettingsView.swift`
  - `Views/RepositorySettingsView.swift`
  - `RepositorySettingsFeature.swift`
  - `CLIInstallerClient.swift` (wraps existing installer script)

### SettingsSection

```swift
public enum SettingsSection: Hashable {
  case general
  case notifications
  case developer
  case shortcuts            // ComingSoonPane
  case updates              // ComingSoonPane
  case about
  case repository(ProjectID)
  case repositoryHooks(ProjectID)

  public var projectID: ProjectID? {
    switch self {
    case .repository(let id), .repositoryHooks(let id): return id
    default: return nil
    }
  }
}
```

### TCA state outline

```swift
@Reducer
struct SettingsFeature {
  @ObservableState
  struct State: Equatable {
    var selection: SettingsSection?          // nil when window closed
    var general: GeneralFeature.State        // wraps existing EditorFeature
    var notifications: NotificationsFeature.State
    var developer: DeveloperFeature.State
    var projectSummaries: [ProjectSummary] = []
    @Presents var repository: RepositorySettingsFeature.State?
    @Presents var alert: AlertState<Alert>?
  }
  // Actions mirror supacode's SettingsFeature shape but without the
  // un-shipped capabilities (updates, github, skill, shortcuts).
}
```

### Persistence / writer

- `SettingsStore` stays an `@MainActor @Observable` class, same
  `AtomicFileStore` + 500 ms debounce contract (matches `CatalogStore`).
- All settings mutations funnel through typed methods on `SettingsStore`;
  views never mutate properties directly.
- `NotificationSettingsReader` protocol (in `TouchCodeCore`) exposes only
  the subset C6 needs (`mute`, `authStatus`, `neverPrompt`, `notNowUntil`)
  so coordinator tests don't have to stub the whole `Settings` struct.

### Open vs existing split

- **Kept as-is:** `HookConfigStore` (hooks have their own richer shape —
  `hooks.json` is not merged into `settings.json`).
- **Kept as-is:** `InboxStore` (notifications *data*, not settings).
- **Deleted:** `NotificationSettingsStore` (merged into `SettingsStore`).
- **Moved:** `TouchCodeCore/Editor/Settings.swift` → `TouchCodeCore/Settings/Settings.swift`.

### Link to follow-up docs

- Design doc: `docs/design-docs/settings-base.md` (to be written in Phase 3
  if design decisions surface beyond what this spec states).
- Execution plan: `docs/exec-plans/settings-base.md` (via `/hs-planner`).

## Open Questions

1. **CLI installer UX** — `tc` install today likely requires admin rights
   to symlink into `/usr/local/bin` (supacode uses `CLIInstallerClient`
   with an AppleScript `osascript -e "do shell script ... with administrator
   privileges"`). For touch-code, is that the intended install path, or do
   we prefer a user-scope target (`~/.local/bin` / `~/bin`) to avoid the
   prompt? Affects M6.1 copy and error handling.
2. **Appearance engine placeholder** — ship the picker **disabled** with a
   "Themes coming soon" caption, or ship it **enabled** and write to
   `general.appearanceMode` without any consumer? Current spec assumes the
   latter (picker enabled, value persists, no renderer), but a disabled
   picker is less misleading.
3. **Repository list source** — should the Repositories sidebar list
   reflect `CatalogStore`'s open Projects only, or all Projects that have
   ever had per-repo overrides saved (even if currently closed)? Supacode
   lists only open repos; current spec matches. Edge: if a user removes a
   Project, the settings entry under `repositories.<id>` orphans — do we
   GC it on removal or keep it for re-add? Proposed: keep (GC is hard to
   reason about and cheap to ignore).
4. **Hooks read-only vs editable** — Developer > Hooks pane is read-only
   + "Reveal in Finder" today. Do we have appetite for a minimal editable
   view (enable/disable per hook) in this same branch, or is that a
   follow-up? Current spec says follow-up.
