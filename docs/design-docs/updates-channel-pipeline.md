# Design Doc: Update channel — release pipeline

**Status:** Draft
**Author:** Gump
**Date:** 2026-05-08

## Context and Scope

The macOS app now persists `GeneralSettings.updateChannel` (`stable` / `tip`) and a
`ChannelUpdaterDelegate` already returns the right `allowedChannels(for:)` set so Sparkle
will filter appcast items by channel. The matching server-side pieces are not in place —
`apps/mac/.github/workflows/release.yml` (lives at the repo root as
`.github/workflows/release.yml`) generates a per-release `appcast.xml` that contains the
single newly-published DMG and never carries a `<sparkle:channel>` element. This doc
records the plan to wire the pipeline so the in-app channel picker actually flips between
two streams of releases.

`SUFeedURL` in `Configurations/mac-Info.plist` currently points at
`https://github.com/wanggang316/touch-code/releases/latest/download/appcast.xml`. The
`/releases/latest/...` redirect skips prereleases, so any release marked `--prerelease`
becomes invisible to that URL.

## Goals and Non-Goals

**Goals**
- A user who selects Tip in Settings or in the menu's Update Channel submenu starts
  receiving pre-release builds within one Sparkle check cycle (≤ 1 h on tip).
- A user who stays on Stable never receives a tip build, even if a tip release is more
  recent than the current stable.
- Single feed URL per channel — Sparkle's `feedURLString(for:)` is wired in the
  `ChannelUpdaterDelegate` (or two distinct URLs are baked into a per-channel branch of
  the delegate).
- The appcast for each channel includes a rolling window of recent releases (≥ 3) so a
  user upgrading from an older build still sees a delta path, not just the latest item.

**Non-Goals**
- Per-architecture appcasts. touch-code is universal-binary today; Sparkle handles the
  arch matching internally.
- Delta updates (`.delta` patches). One-shot full-DMG updates are fine for v1.
- Beta-of-beta channels (alpha, nightly). Two channels is plenty.
- An automated workflow that produces a tip release on every `main` push. Tip releases
  are still tag-triggered and human-sanctioned, just like stable.

## Design

### Overview

Pick **Option A: two appcasts hosted on a fixed-tag GitHub Release**. The release pipeline
maintains a long-lived release tagged `appcast` that holds two files: `appcast.xml`
(stable items) and `appcast-tip.xml` (tip items, plus any stable items newer than the
current tip). Each `vX.Y.Z` or `vX.Y.Z-tip.N` release pipeline run regenerates both files
by scanning the most recent N releases' DMG enclosures and re-attaches them to the
`appcast` release.

Why this over the alternatives:

- **GitHub Pages** would also work and is more conventional for static hosting, but it
  requires (a) opting in Pages on the repo, (b) a `gh-pages` branch or `/docs` directory
  workflow step, and (c) a permissions bump. The fixed-tag release approach reuses the
  release pipeline's existing GitHub-Releases auth path with no new infrastructure.
- **`releases/latest/download/...`** can't carry tip artifacts without polluting the
  `latest` redirect for stable users (or hiding tip from its own users via `--prerelease`).
  Using a fixed `appcast` release tag sidesteps both halves of that bind.
- **`raw.githubusercontent.com` + a `feeds` branch** works but has a lower published rate
  limit and is documented by GitHub as not for high-traffic distribution.

### Tag conventions

| Pattern | Channel | GitHub release flag |
|---|---|---|
| `vX.Y.Z` | `stable` | `--latest` (default) |
| `vX.Y.Z-tip.N` | `tip` | `--prerelease` |

Anything else is rejected by the workflow.

### Pipeline changes (`.github/workflows/release.yml`)

1. **Tag parser** — extend the existing regex check to accept either pattern and emit a
   `channel=stable|tip` output and a `prerelease=true|false` output.
2. **Release marking** — pass `--prerelease` to `gh release create` when `channel == tip`.
   Stable continues to take `--latest` (the default).
3. **`generate_appcast` invocation** — pass `--channel tip` for tip builds. Sparkle's
   tooling stamps `<sparkle:channel>tip</sparkle:channel>` on the generated item;
   `allowedChannels(for:)` already filters on this string client-side.
4. **Aggregate step (new)** — after the per-release appcast is generated:
   - Download the existing `appcast.xml` and `appcast-tip.xml` artifacts from the
     `appcast` release if they exist (`gh release download appcast --pattern 'appcast*.xml'`).
     Treat absence as the bootstrap case.
   - Merge: prepend the new item to whichever file matches the channel; trim each file
     to a 5-item window. For tip, also include any stable item newer than the most
     recent tip so tip users transparently follow stable when no fresh tip exists.
   - Re-sign the merged files with `sign_update` (Sparkle CLI) — `generate_appcast`'s
     EdDSA stamping is per-item, so re-stitching preserves signatures.
5. **Re-attach to fixed release** — `gh release upload appcast appcast.xml appcast-tip.xml --clobber`.
   If the `appcast` release does not exist yet, create it once with
   `gh release create appcast --title 'Sparkle appcasts' --notes 'Do not delete.' --draft=false`.
6. **Old per-release appcast attachment** stays for now — it costs nothing and is useful
   for offline archeology.

### Client changes (`Configurations/mac-Info.plist` + delegate)

1. **Update `SUFeedURL`** to the fixed-release URL:
   ```
   https://github.com/wanggang316/touch-code/releases/download/appcast/appcast.xml
   ```
2. **Wire `feedURLString(for:)` on `ChannelUpdaterDelegate`** so the tip branch swaps in
   `appcast-tip.xml`:
   ```swift
   nonisolated func feedURLString(for updater: SPUUpdater) -> String? {
     MainActor.assumeIsolated {
       switch channel {
       case .stable: return nil   // use Info.plist's SUFeedURL
       case .tip:    return "https://github.com/wanggang316/touch-code/releases/download/appcast/appcast-tip.xml"
       }
     }
   }
   ```
   `nil` for stable preserves the Info.plist URL — keeps the canonical default discoverable
   in plist viewers and avoids a hardcode-twice trap.

### Bootstrap

First run after this lands:

1. Manually create the `appcast` release (one-off): `gh release create appcast --title 'Sparkle appcasts' --notes 'Do not delete.'`.
2. Cut a stable release with the new pipeline (will populate `appcast.xml`).
3. Cut a tip release with the new pipeline (will populate `appcast-tip.xml`).
4. Verify the two URLs return well-formed appcast XML and that the channel filter routes
   builds correctly to a debug client with `defaults delete com.gumpw.touch-agent-mac`
   between channel flips.

## Open questions

- **Maximum-versions window** — `generate_appcast --maximum-versions 5` is the current
  setting. Tip might warrant a tighter window (3) to avoid offering stale tip builds. Worth
  revisiting once we have ≥ 5 tip releases of data.
- **Release-notes URL** — Sparkle supports `<sparkle:releaseNotesLink>` per item. Optional
  v1, but eventually each `vX.Y.Z(-tip.N)?` should link to its GitHub Release notes URL so
  the in-app update prompt shows real changelog text.
- **Demoting from tip to stable** — Sparkle's default behavior re-prompts every check;
  there's no "downgrade" path. Documented as a manual step (delete `~/Library/Caches/Sparkle*`
  + reinstall) for users who switch to stable while running a newer tip build.
