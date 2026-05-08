---
name: release
description: Cut a touch-code release. Bump MARKETING_VERSION in Project.xcconfig, promote CHANGELOG [Unreleased] to a dated version section, commit, tag vX.Y.Z, and push to trigger the GitHub Actions Developer-ID release pipeline. Also covers tip-channel cuts via release-tip.yml. Use when shipping a new build.
---

# release: Cut a touch-code release

## Channels at a glance

touch-code ships on two Sparkle channels. They share one canonical feed
(`releases/latest/download/appcast.xml`) and are filtered client-side via
`ChannelUpdaterDelegate.allowedChannels(for:)`:

| Channel | Triggered by | Tag | GitHub Release | Updates the canonical feed? |
|---|---|---|---|---|
| Stable | This skill (human-driven) | `vX.Y.Z` annotated | `--latest` (default) | Yes — overwrites with stable items |
| Tip | `gh workflow run release-tip.yml` (manual) | `tip` (floating, force-moved) | `--prerelease` | Yes — merges tip item into the latest stable's appcast |

The rest of this document is the **stable cut** flow. The shorter
**tip cut** flow lives at the bottom under "Cutting a tip release".

## Overview

A stable touch-code release is **a tag push**. The
`.github/workflows/release.yml` pipeline keys off `v*` tags: it builds,
signs (Developer ID), notarizes, generates a Sparkle-signed
`appcast.xml`, and drafts a GitHub Release with the DMG attached. CI
**fails loud** when the tag does not match `MARKETING_VERSION` in
`apps/mac/Configurations/Project.xcconfig`, so the release contract is:

> tag `vX.Y.Z` ⇔ `MARKETING_VERSION = X.Y.Z` ⇔ `CHANGELOG.md` has a
> `## [X.Y.Z] - YYYY-MM-DD` section.

This skill walks those three artifacts into alignment, commits, tags,
pushes, and verifies CI started.

## When to use

- Ready to ship a new developer build to GitHub Releases / Sparkle clients.
- `[Unreleased]` in `CHANGELOG.md` has user-visible entries that warrant a release.

**Don't use** for:
- Hot-fixing CI or the release pipeline itself (no version bump).
- Local-only experiments — never tag without intent to publish.

## Project facts (load before acting)

| Concern | Where it lives |
|---|---|
| Marketing version (semver) | `apps/mac/Configurations/Project.xcconfig` → `MARKETING_VERSION` |
| Build number (date-based, stable) | same file → `CURRENT_PROJECT_VERSION` (`YYYYMMDD` for the first release of the day; same-day re-releases append a sequence digit, e.g. `202605062`, `202605063`, ...) |
| Build number (tip) | computed by `release-tip.yml` as `STABLE_BUILD * 1000 + run_number`; never written to xcconfig |
| Bump tool | `apps/mac/scripts/bump-version.sh` (called by `make mac-bump-version`) |
| User-visible changelog | `CHANGELOG.md` (project root) — stable only; tip cuts do not touch CHANGELOG |
| Stable release CI | `.github/workflows/release.yml` (tag-triggered on `v*`) |
| Tip release CI | `.github/workflows/release-tip.yml` (`workflow_dispatch` only) |
| Tag format (stable) | `vX.Y.Z` annotated |
| Tag (tip) | floating `tip` ref, force-moved by `release-tip.yml` |
| Distribution unit | DMG (notarized + stapled). Sparkle clients update from the same DMG. |
| Canonical Sparkle feed | `https://github.com/wanggang316/touch-code/releases/latest/download/appcast.xml` — always served from the most recent non-prerelease release |
| Past bump style | `chore(release): bump to X.Y.Z` (xcconfig only) |

`MARKETING_VERSION` is **not** strict SemVer pre-1.0 — every release is a
developer build (per `CHANGELOG.md` preamble). Default cadence is patch;
bump minor when behavior is materially different.

## Process

### 0. Pre-flight — refuse to proceed if any check fails

Run all checks in parallel via `Bash`:

```bash
git rev-parse --abbrev-ref HEAD          # must be 'main' (or confirm with user)
git status --porcelain                    # must be empty
git fetch origin --tags                   # quiet; just refresh
git rev-list --left-right --count HEAD...origin/main   # must be 0 0 (or 0 N if local-ahead is intentional)
git tag --sort=-creatordate | head -3     # show most recent tags
./apps/mac/scripts/bump-version.sh --print  # current MARKETING_VERSION + CURRENT_PROJECT_VERSION + suggested next patch
```

Bail with a clear message if any of these are wrong:
- Not on `main` and user hasn't approved an off-`main` release.
- Working tree dirty.
- Local diverged from `origin/main` in a way the user didn't intend.
- A tag for the proposed version already exists.

### 1. Decide the version — ask the user

1. Read current `MARKETING_VERSION` and the `## [Unreleased]` section of
   `CHANGELOG.md`.
2. Propose: **patch** by default (`0.1.3 → 0.1.4`).
3. Show the user a summary table:

   ```
   Current: 0.1.3 (build 4)
   Next:    0.1.4 (build 20260506)     ← patch (default; build = today's date)
   Or:      0.2.0 (build 20260506)     ← minor (user-visible scope changed)
   Same-day re-release: build = 202605062, 202605063, ... (auto)

   Unreleased highlights:
     Added — Add Project picker can create new folders inline
     Added — Folder → git auto-promotion
     Changed — Worktree executing indicator on icon
     Fixed — ⌘⌫ guard for main worktree + sidebar focus
     Removed — Inline loading spinner
   ```

4. Wait for explicit confirmation of `X.Y.Z` and the new build number
   before proceeding. **Never invent a version silently.**

### 2. Verify the changelog has shippable content

If `[Unreleased]` is empty (or only contains category headers with no
entries), **stop**. Tell the user to run `/hs-changelog` first to
extract recent commits, then resume.

### 3. Cut the changelog version section

Edit `CHANGELOG.md`:

1. Replace `## [Unreleased]` with two sections:
   - A fresh empty `## [Unreleased]` at top with all six standard
     headers (`Added / Changed / Deprecated / Removed / Fixed /
     Security`) but **leave them empty** — the next cycle fills them.
   - The previous `[Unreleased]` body promoted under
     `## [X.Y.Z] - YYYY-MM-DD` (today's date in the user's local TZ).
2. Show the diff to the user before writing.

### 4. Bump the version files

```bash
make mac-bump-version VERSION=X.Y.Z
# or, with an explicit build number override (rarely needed):
make mac-bump-version VERSION=X.Y.Z BUILD=N
```

The Makefile target wraps `apps/mac/scripts/bump-version.sh`, which:
- validates `X.Y.Z` semver format,
- refuses if the new marketing version isn't strictly greater than the current,
- defaults `CURRENT_PROJECT_VERSION` to today's date in `YYYYMMDD`
  form, or `YYYYMMDDN` (sequence digit) on a same-day re-release,
- refuses if the computed build is not numerically greater than the
  current build (rollover guard for the rare ">9 builds in one day"
  edge case),
- writes via tmpfile + post-write verification (atomic),
- and the Makefile guard refuses to run if `apps/mac/Configurations`
  has uncommitted changes.

Do **not** hand-edit `Project.xcconfig` — the script is the rule.

CI rejects a tag whose version doesn't match `MARKETING_VERSION` —
this is the gate that prevents accidental tag pushes.

### 5. Optional build verification

Default: **skip** the build (CI will catch real problems and the
pipeline takes ~10–20 minutes locally). Run `make mac-check` (fast,
~10s) only if the user has unrelated lint debt and wants to be sure
the bump commit is clean.

Run a full local `make mac-build` only if explicitly requested.

### 6. Commit — only the two bumped files

Show the user the staged diff before committing.

```bash
git add CHANGELOG.md apps/mac/Configurations/Project.xcconfig
git status                  # confirm only those two files are staged
git diff --cached            # final eyeball
```

Commit message format (matches `c65abde`, `9e6e5a0`, `2748a1f`):

```
chore(release): bump to X.Y.Z
```

No body unless the release has unusual notes (e.g., schema break worth
flagging in `git log` independently of the changelog). **No
Co-Authored-By trailer** — see `~/.claude/.../memory/feedback_no_coauthor_in_commits.md`.

Use a HEREDOC for the message:

```bash
git commit -m "$(cat <<'EOF'
chore(release): bump to X.Y.Z
EOF
)"
```

### 7. Tag — annotated, with release highlights

```bash
git tag -a vX.Y.Z -m "$(cat <<'EOF'
vX.Y.Z

<one short paragraph naming the headline change(s); pull from CHANGELOG>
EOF
)"
```

The annotated message ends up on the GitHub Release page next to
`gh release create --generate-notes` output, so keep it scannable.

**Do not push yet.** Confirm with the user that the tag looks right
(`git show vX.Y.Z --stat`).

### 8. Push — commit first, tag second

```bash
git push origin main
git push origin vX.Y.Z       # triggers .github/workflows/release.yml
```

Push order matters: pushing the tag first races CI against a
not-yet-visible commit. The CI checks out by ref name (`tag ==
commit`), so the commit must be on the remote before the tag.

If the user wants to pre-flight without triggering CI, use
`workflow_dispatch` with an existing tag instead of pushing a new one
— but that's an escape hatch, not the default.

### 9. Verify CI started

```bash
gh run list --workflow=release.yml --limit 1
gh run watch                          # follow the active run, optional
# When green:
gh release view vX.Y.Z                # the draft release
```

Tell the user:
- CI status (queued / running / passed / failed).
- The release is **draft** — they need to publish it manually via the
  GitHub UI or `gh release edit vX.Y.Z --draft=false` once they've
  reviewed the auto-generated notes and the DMG download.
- **Tip-channel implication**: publishing this stable release will
  overwrite `releases/latest/download/appcast.xml` with stable-only
  items. Any tip item that was merged into the previous stable's
  appcast disappears from the canonical feed for the brief window
  between this stable going live and the next `release-tip.yml` run.
  Tip clients (`allowedChannels = ["tip"]`) silently fall back to the
  stable item during that window — Sparkle treats untagged stable
  items as "default channel, always allowed". Mention this only if the
  user is actively coordinating with tip subscribers; usually it's
  noise.

If CI fails, **do not** delete the tag or force-push without explicit
user approval — diagnose first (`gh run view --log-failed`).

## Failure modes & recovery

| Symptom | Cause | Fix |
|---|---|---|
| CI step "Verify tag matches MARKETING_VERSION" red | xcconfig wasn't bumped, or tag was created before bump landed | Bump xcconfig in a new commit, delete & recreate tag (`git tag -d vX.Y.Z; git push origin :refs/tags/vX.Y.Z`) — confirm with user before deleting remote tag |
| Tag pushed without CHANGELOG section | Skipped step 3 | Add the section in a follow-up `docs(changelog): record vX.Y.Z` commit on `main`; do not retag |
| Notarization fails | Apple-side; secrets correct but build flagged | Check `gh run view --log-failed`, often transient — re-run via `workflow_dispatch` against the existing tag |
| Wrong version pushed | Bumped to e.g. 0.2.0 when user wanted 0.1.4 | Roll forward only — pull next version, supersede with a new tag. Do not rewrite history on `main`. |
| Tip workflow's "Merge tip item into latest stable's appcast.xml" step fails with "Stable release ... has no appcast.xml asset" | The latest stable was cut before the appcast pipeline existed (or its appcast.xml was manually deleted) | Run `release.yml` (cut a fresh stable, even a no-op patch bump) so the canonical feed exists. The tip workflow will then merge correctly on its next run. |
| `release-tip.yml` errors out with "run_number ... exceeds 999" | Too many tip cuts piled up against one stable base | Cut a stable release (any patch bump) — that resets the BASE component of the tip build number formula. |

## Verification checklist

Before reporting "done":

- [ ] `git tag --sort=-creatordate | head -1` shows the new tag.
- [ ] `git log -1 --oneline origin/main` shows `chore(release): bump to X.Y.Z`.
- [ ] `awk -F'=' '/^MARKETING_VERSION/ ...' apps/mac/Configurations/Project.xcconfig` matches the tag.
- [ ] `CHANGELOG.md` has `## [X.Y.Z] - YYYY-MM-DD` with non-empty body and a fresh empty `## [Unreleased]` above.
- [ ] `gh run list --workflow=release.yml --limit 1` shows a queued or running job.
- [ ] User informed the GitHub Release will land as **draft** and needs manual publish.

## Anti-patterns

- ❌ Bumping `MARKETING_VERSION` and `CHANGELOG.md` in separate commits — pre-1.0 we keep the bump atomic.
- ❌ `git add -A` / `git add -u` — only stage the two release files.
- ❌ Co-Authored-By trailer on the bump commit.
- ❌ Lightweight tag (`git tag vX.Y.Z`) — always annotated.
- ❌ Pushing tag before commit.
- ❌ Auto-publishing the GitHub Release — leave it draft for human review.
- ❌ Force-pushing `main` to "fix" a bad bump — roll forward instead.
- ❌ Manually creating a `vX.Y.Z-tip.N` tag or editing `MARKETING_VERSION` for a tip cut — tip is `release-tip.yml`'s territory; the floating `tip` ref + `BASE*1000+run_number` build is the entire interface.
- ❌ Hand-editing `appcast.xml` on a release — the merge step in `release-tip.yml` is the only writer. Manual edits get clobbered on the next tip cut.
- ❌ Running `release-tip.yml` while a stable cut's `release.yml` is still in flight — the workflows share `concurrency: release`, but doing this manually defeats that gate. Wait for stable to finish + verify the canonical feed first.

## Cutting a tip release

A tip release is **a single workflow_dispatch invocation**. It does NOT
require a `MARKETING_VERSION` bump, a `CHANGELOG.md` edit, a new
annotated tag, or any commit on `main`. It builds against the current
HEAD of `main`, force-moves the floating `tip` git tag to that commit,
publishes (or updates) a GitHub Release tagged `tip` marked
`--prerelease`, then merges the tip-channel item into the latest
stable's `appcast.xml` so the canonical feed
(`releases/latest/download/appcast.xml`) starts advertising it to
clients with `allowedChannels = ["tip"]`.

### Pre-flight

```bash
git rev-parse --abbrev-ref HEAD                                # main
git status --porcelain                                          # empty
gh release list --exclude-drafts --exclude-pre-releases --limit 1  # latest stable exists
gh release view <latest_stable_tag> --json assets --jq '.assets[].name' | grep '^appcast.xml$'
                                                                 # canonical feed asset present
```

Bail if no stable release exists yet — there's nothing to merge tip
items into. Cut a stable first.

### Trigger

```bash
gh workflow run release-tip.yml
```

No arguments. The workflow reads `MARKETING_VERSION` and
`CURRENT_PROJECT_VERSION` from `apps/mac/Configurations/Project.xcconfig`
on its own and computes the tip build number as
`CURRENT_PROJECT_VERSION * 1000 + github.run_number`.

### Verify

```bash
gh run list --workflow=release-tip.yml --limit 1
gh run watch                                  # optional

# When green, smoke-check that the canonical feed picked up the tip item:
curl -fsSL "https://github.com/wanggang316/touch-code/releases/latest/download/appcast.xml" \
  | grep -c '<sparkle:channel>tip</sparkle:channel>'
# expected: 1
```

The workflow does this same `curl` check internally as its final
step — if CI is green, the feed is good. The local `curl` exists for
human reassurance only.

### Tip-cut verification checklist

- [ ] `gh run list --workflow=release-tip.yml --limit 1` green.
- [ ] `git tag --sort=-creatordate | grep '^tip$'` shows `tip` was force-moved (compare its short SHA with `git rev-parse --short main`).
- [ ] `gh release view tip --json isPrerelease --jq .isPrerelease` returns `true`.
- [ ] `gh release view tip` shows the new DMG, its `.sha256`, and `appcast-tip.xml`.
- [ ] `curl ... releases/latest/download/appcast.xml | grep '<sparkle:channel>tip'` finds the freshly tagged item.
- [ ] On a debug client switched to Tip channel: Sparkle prompts to update.

### When NOT to use the tip workflow

- The change is tiny, low-risk, and you'd rather just ship to stable. Tip is for
  pre-release validation, not a substitute for normal patches.
- Stable cut is queued or in flight. Wait for it to finish to avoid the
  merge step racing against an evolving stable appcast.
- HEAD has uncommitted local changes you wanted in the tip — push them first.
  The workflow checks out `main` from the remote.
