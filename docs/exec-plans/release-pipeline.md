# ExecPlan: Mac app packaging, signing, and release pipeline

**Status:** Draft
**Author:** Gump (with Claude)
**Date:** 2026-04-28

This is a living document. The Progress, Surprises & Discoveries, Decision Log, and Outcomes & Retrospective sections must be kept up to date as work proceeds.

## Purpose

Today the repository can only produce a Debug build that runs on the developer's own Mac. There is no archive flow, no Developer ID signing, no notarization, no DMG, no published release. After this plan, a maintainer can:

1. Run `make mac-release VERSION=0.2.0` on their Mac and get a notarized, stapled `Touch Code.dmg` plus a checksums file in `apps/mac/.build/release/`.
2. Push a `v0.2.0` git tag and have GitHub Actions produce the same artifacts in CI and attach them to a draft GitHub Release.
3. Hand a user the resulting DMG and have it open on a stock macOS 14+ machine without Gatekeeper warnings.

The pipeline must also embed the `tc` CLI inside the app bundle so [c4-cli.md §Surface](../design-docs/c4-cli.md) — which already specifies `tc` ships inside `<app>/Contents/Resources/` and is installed to `~/.local/bin/tc` on first launch — has a binary to point at.

## Progress

- [x] M1 — Identity, productName, entitlements, embedded `tc` — 2026-04-28
- [ ] M2 — Local archive + Developer ID signing script
- [ ] M3 — Notarization + stapling
- [ ] M4 — DMG packaging (signed + notarized)
- [ ] M5 — Single-source version bump + Makefile front door
- [ ] M6 — (Deferred) GitHub Actions release workflow on tag — no GitHub-hosted release channel in v1; revisit when a distribution repo exists
- [ ] M7 — (Deferred) Sparkle auto-update — captured as ADR only, no code

## Surprises & Discoveries

- **2026-04-28 (M1): Tuist warns on spaces in `productName` but the build works.** `mise exec -- tuist generate` prints `Invalid product name 'Touch Code'. This string must contain only alphanumeric (A-Z,a-z,0-9), period (.), hyphen (-), and underscore (_) characters.` and proceeds anyway. xcodebuild resolves `PRODUCT_NAME=Touch Code`, `WRAPPER_NAME=Touch Code.app`, `EXECUTABLE_NAME=Touch Code` correctly; `Touch Code.app` builds, signs ad-hoc, and launches. The Tuist warning is a Tuist-only style check, not an xcodebuild-level constraint — left as-is. If a future Tuist version upgrades it to an error, fall back to `productName: "TouchCode"` and rely on `CFBundleDisplayName` alone.
- **2026-04-28 (M1): `xcodebuild` first run after pbxproj regeneration printed `** BUILD FAILED ** (3 failures)` but a second invocation a moment later (piped through xcbeautify) succeeded.** No source change between the two runs. Likely a transient stale-derived-data effect from Tuist regenerating the pbxproj while a previous build's incremental graph was still indexed. Re-running was sufficient; not adding a `xcodebuild clean` step in the Makefile because the cost (full rebuild on every generate) outweighs the rare flake.

## Decision Log

- **DEC-1: DMG, not zip, as the primary artifact.** A signed+notarized DMG is the convention macOS users expect from a Developer ID app, and the `/Applications` drop-target inside the DMG removes the most common "users run the app from Downloads" support issue. Cost is one extra `hdiutil` step over a flat zip.
- **DEC-2: Embed `tc` inside `Touch Code.app/Contents/Resources/bin/tc`, not `Contents/MacOS/`.** Apple convention reserves `Contents/MacOS/` for binaries Launch Services can run; helper CLIs commonly live in `Resources/`. The first-launch installer in [c4-cli.md §D3](../design-docs/c4-cli.md) symlinks to `~/.local/bin/tc`, so the canonical inside-bundle path is what the symlink target needs to be stable. Putting it under `Resources/bin/` keeps it grouped with `Resources/git-wt/wt`.
- **DEC-3: Set `productName: "Touch Code"` so the bundle is `Touch Code.app`, not `touch-code.app`.** `CFBundleDisplayName=Touch Code` already makes Finder show the right name, but the on-disk filename inside the DMG and in `/Applications` is what users actually see when dragging. The Mach-O executable inside `Contents/MacOS/` will then also be `Touch Code` — that is harmless but noted.
- **DEC-4: One Release.xcconfig holding `DEVELOPMENT_TEAM` + `CODE_SIGN_IDENTITY`, gitignored.** The Tuist-generated pbxproj must not bake a team ID into version-controlled files because (a) a different contributor with a different Apple ID could not regenerate, and (b) the team ID is mildly sensitive. Local devs override locally; CI provides the values via env vars consumed by the release script.
- **DEC-5: Notarize via App Store Connect API key (not app-specific password).** API keys are revocable, scoped, and the only credential type that works cleanly in headless CI without 2FA prompts. The local maintainer flow uses `xcrun notarytool store-credentials` to cache the same key in the login keychain, so `release.sh` reads from `--keychain-profile touch-code-notary` locally and from env vars (`AC_API_KEY_ID`, `AC_API_ISSUER_ID`, `AC_API_KEY_P8`) in CI.
- **DEC-6: Sparkle deferred to a separate plan.** Sparkle adds an appcast, a public EdDSA key in Info.plist, hosted XML, and a UI surface for "Check for updates." None of that is needed to produce a v0.x DMG that users can download manually. Recording this as DEC-6 so the omission is explicit, not accidental.
- **DEC-7: GitHub Actions release workflow deferred.** There is no GitHub-hosted release channel for touch-code in v1 (confirmed with Gump on 2026-04-28). The local `make mac-release` flow (M1–M5) covers the maintainer's actual distribution path. A workflow file is value-add only when a distribution repo exists; writing it now risks bit-rot before first use. M6 stays in the plan as a stub so the future maintainer doesn't have to re-derive the secret list and the keychain-import dance.

## Outcomes & Retrospective

### M1 — Identity, productName, entitlements, embedded `tc` (2026-04-28)

**What landed:** `apps/mac/Project.swift` now sets `productName: "Touch Code"` and `entitlements: .file(path: "Configurations/touch-code.entitlements")` on the app target; `tc`'s blanket `CODE_SIGNING_ALLOWED=NO` was scoped to `[config=Debug]` so Release will sign the CLI for embedding. New files: `apps/mac/Configurations/touch-code.entitlements` (empty `<dict/>`) and `apps/mac/scripts/embed-tc.sh` (modeled on `embed-git-wt.sh`). `docs/architecture.md` Codemap row for `touch-code` records the embedding.

**Verification:**
- `mise exec -- tuist generate --no-open` succeeds (with a Tuist style warning about the space in productName — see Surprises).
- `xcodebuild ... build` produces `Touch Code.app` at `~/Library/Developer/Xcode/DerivedData/touch-code-*/Build/Products/Debug/Touch Code.app`.
- `/usr/libexec/PlistBuddy -c "Print CFBundleIdentifier"` returns `com.gumpw.touch-agent-mac`; `CFBundleDisplayName` and `CFBundleName` both `Touch Code`.
- `codesign -d --entitlements -` shows the (Debug-injected) `get-task-allow=true` only — the empty Release entitlements file is intact.
- `Touch Code.app/Contents/Resources/bin/tc --version` runs from the embedded location.

**Carry-forward to M2:** Release configuration is now structurally ready for Developer ID signing — the entitlements file exists, tc will sign in Release, and the bundle filename is final. M2 needs `Release.xcconfig` (gitignored) + `ExportOptions.plist` + `release.sh archive`.

## Context and Orientation

Related documents:
- Product spec: [docs/product-spec.md](../product-spec.md)
- Architecture: [docs/architecture.md](../architecture.md) — Codemap, Dependency Direction, Architectural Invariants
- CLI design (governs `tc` install model): [docs/design-docs/c4-cli.md](../design-docs/c4-cli.md) — §Surface, §D3
- Bootstrap plan (current build pipeline): [docs/exec-plans/0001-bootstrap-monorepo.md](0001-bootstrap-monorepo.md)
- Golden rules: [docs/golden-rules.md](../golden-rules.md) — especially §7 "Enforce architecture mechanically"

Key source files (all paths relative to repo root):
- `apps/mac/Project.swift` — Tuist target graph. The `touch-code` app target at line 188 already enables Hardened Runtime; `tc` at line 164 sets `CODE_SIGNING_ALLOWED=NO` and will need that lifted for Release config.
- `apps/mac/Configurations/Project.xcconfig` — `MARKETING_VERSION`, `CURRENT_PROJECT_VERSION`. Single source of version truth after M5.
- `apps/mac/Configurations/mac-Info.plist` — `CFBundleShortVersionString`, `CFBundleVersion`. Currently hard-coded `0.1.0`/`1`; M5 changes them to `$(MARKETING_VERSION)` / `$(CURRENT_PROJECT_VERSION)` so a single edit in the xcconfig propagates.
- `apps/mac/Makefile` — Top-level mac targets. `mac-archive` / `mac-release` / `mac-bump-version` get added in M2 / M5.
- `apps/mac/scripts/build-ghostty.sh` — Existing fingerprint-cached static-XCFramework build. Release pipeline reuses it unchanged; the XCFramework links statically into the app binary so it does not require its own signature.
- `apps/mac/scripts/embed-git-wt.sh` — Existing post-action that copies `wt` into `Contents/Resources/git-wt/wt`. The new `tc` embedding script (M1) follows the same shape.

New files this plan creates:
- `apps/mac/Configurations/touch-code.entitlements` — Hardened Runtime entitlements for the app.
- `apps/mac/Configurations/Release.xcconfig` — Local `DEVELOPMENT_TEAM` + `CODE_SIGN_IDENTITY` (gitignored). A `Release.xcconfig.example` is checked in.
- `apps/mac/Configurations/ExportOptions.plist` — `xcodebuild -exportArchive` options for `developer-id` method.
- `apps/mac/scripts/embed-tc.sh` — Post-action: copy `tc` into `Touch Code.app/Contents/Resources/bin/tc`.
- `apps/mac/scripts/release.sh` — Orchestrator: archive → export → sign → notarize → staple → DMG.
- `apps/mac/scripts/make-dmg.sh` — Pure `hdiutil`-based DMG builder, no `brew install create-dmg` dep.
- `apps/mac/scripts/notarize.sh` — Wraps `xcrun notarytool submit --wait` + `stapler`.
- `.github/workflows/release.yml` — GitHub Actions workflow, tag-triggered.

Terms:
- **Hardened Runtime.** A macOS code-signing flag that opts the binary into stricter runtime protections (no unsigned dylib loads, no unsigned executable memory, etc.) and is mandatory for notarization. Already on for the `touch-code` target in `Project.swift:241`.
- **Notarization.** Apple's automated malware scan of a signed binary. Returns a "ticket" that gets *stapled* to the artifact so Gatekeeper accepts it offline.
- **Stapling.** Embedding the notarization ticket into the artifact (`.app`, `.dmg`) so users on first launch don't need network access to verify.
- **Developer ID Application.** The certificate type used to distribute apps outside the Mac App Store. Distinct from "Apple Development" (used for local debug) and "Mac App Store" (MAS-only).

## Plan of Work

The work splits into seven milestones. M1–M5 are local-only — a maintainer can run the full release on their own Mac after M5. M6 lifts that into CI. M7 is intentionally deferred.

### Milestone 1: Identity, productName, entitlements, embedded `tc`

By the end of this milestone, `make mac-build` produces `apps/mac/.build/Build/Products/Debug/Touch Code.app` (note the renamed bundle) with `tc` already inside `Contents/Resources/bin/tc`. Hardened Runtime entitlements live in version-controlled XML.

Work:

1. In `apps/mac/Project.swift` at the `touch-code` app target (line 190-247), add `productName: "Touch Code"` so the build product is `Touch Code.app`. Update the `OTHER_LDFLAGS` line if needed; nothing else changes.
2. Create `apps/mac/Configurations/touch-code.entitlements` with the minimum Hardened Runtime entitlements: empty `<dict/>` is the starting point. If notarization in M3 reveals libghostty needs `com.apple.security.cs.allow-unsigned-executable-memory` or `com.apple.security.cs.allow-jit`, add them then with a comment recording the symptom that prompted the addition.
3. In `Project.swift` settings for the app target, add `"CODE_SIGN_ENTITLEMENTS": "Configurations/touch-code.entitlements"`.
4. Lift `tc`'s blanket `CODE_SIGNING_ALLOWED=NO` (`Project.swift:178`) — switch to `CODE_SIGNING_ALLOWED[config=Debug]=NO`-style scoping so Release builds sign `tc` with the same identity as the app. Concretely: drop the unconditional override and let xcconfig handle it (Release will pick up the Developer ID identity once M2 wires it in; Debug builds still produce an ad-hoc-signed `tc` because `CODE_SIGN_STYLE=Automatic` falls back to `-` when no team is set).
5. Add `apps/mac/scripts/embed-tc.sh` modeled on `embed-git-wt.sh`: assert `SRCROOT` / `TARGET_BUILD_DIR` / `UNLOCALIZED_RESOURCES_FOLDER_PATH` / `CONFIGURATION_BUILD_DIR` are set, copy `${CONFIGURATION_BUILD_DIR}/tc` to `${TARGET_BUILD_DIR}/${UNLOCALIZED_RESOURCES_FOLDER_PATH}/bin/tc`, chmod +x. Idempotent.
6. In `Project.swift`, add a `.post` script entry to the `touch-code` target's `scripts:` array (next to `Embed git-wt`) that runs `scripts/embed-tc.sh`, with input `$(CONFIGURATION_BUILD_DIR)/tc` and output `$(TARGET_BUILD_DIR)/$(UNLOCALIZED_RESOURCES_FOLDER_PATH)/bin/tc`. `basedOnDependencyAnalysis: true` here — unlike git-wt, the input is a build product so dependency analysis works.
7. Update [docs/architecture.md](../architecture.md) Codemap to record that `tc` is now embedded inside the app bundle, not just side-by-side in DerivedData.

Acceptance: `make mac-generate && make mac-build` succeeds. `find apps/mac/.build -name "Touch Code.app" -prune` finds the bundle. `ls "<found-path>/Contents/Resources/bin/tc"` shows the embedded CLI. `codesign -dv "<found-path>"` shows ad-hoc signature in Debug. The app still launches.

### Milestone 2: Local archive + Developer ID signing

By the end of this milestone, a maintainer with a Developer ID Application certificate in their login keychain can run a one-command archive that produces a signed `.app` ready for notarization.

Work:

1. Create `apps/mac/Configurations/Release.xcconfig.example` containing `DEVELOPMENT_TEAM = XXXXXXXXXX` and `CODE_SIGN_IDENTITY = Developer ID Application`. Add `Release.xcconfig` to `.gitignore`.
2. In `Project.swift`, add the Release configuration mapping at the project's top-level `configurations:` array (line 19) so the release config additionally reads `Configurations/Release.xcconfig`. Tuist's `.release(name: .release, xcconfig: ...)` only takes one path, so the mechanism is: keep `Project.xcconfig` as the base for both Debug and Release, and have Release.xcconfig included via `#include? "Release.xcconfig"` inside `Project.xcconfig` (the optional include — `?` — is silently skipped when the file is absent, so Debug builds and CI checkouts without Release.xcconfig still work).
3. Create `apps/mac/Configurations/ExportOptions.plist`:

       <plist version="1.0"><dict>
         <key>method</key><string>developer-id</string>
         <key>teamID</key><string>$(DEVELOPMENT_TEAM)</string>
         <key>signingStyle</key><string>automatic</string>
         <key>destination</key><string>export</string>
       </dict></plist>

   The `$(DEVELOPMENT_TEAM)` is substituted at script time with `sed`, not by xcodebuild — `xcodebuild -exportArchive` does not expand env vars in the plist.
4. Add `apps/mac/scripts/release.sh` with a `archive` subcommand:

       ./scripts/release.sh archive

   which runs `xcodebuild archive -workspace touch-code.xcworkspace -scheme touch-code -configuration Release -archivePath .build/release/TouchCode.xcarchive -destination "generic/platform=macOS" SKIP_INSTALL=NO`, then `xcodebuild -exportArchive -archivePath .build/release/TouchCode.xcarchive -exportPath .build/release/export -exportOptionsPlist Configurations/ExportOptions.plist`.

   Pre-flight checks: assert `Release.xcconfig` exists, assert `security find-identity -v -p codesigning` lists "Developer ID Application", assert `xcrun --find xcodebuild` succeeds. Fail with actionable messages.
5. After `exportArchive`, the script verifies `codesign --verify --strict --deep --verbose=2 ".build/release/export/Touch Code.app"` and `spctl -a -v -t exec ".build/release/export/Touch Code.app"` (latter will say "rejected — not notarized" — that's expected and not an error here; M3 fixes it).
6. Add `apps/mac/Makefile` target `mac-archive` that calls `./scripts/release.sh archive`.

Acceptance: With a valid `Release.xcconfig`, `make mac-archive` produces `.build/release/export/Touch Code.app` whose `codesign -dv` shows `Authority=Developer ID Application: <name> (TEAM)`, `Authority=Developer ID Certification Authority`, `Authority=Apple Root CA`, and `Runtime Version` non-empty. `spctl` returns the not-notarized status (expected).

### Milestone 3: Notarization + stapling

By the end of this milestone, the same script can submit the signed `.app` to Apple's notary service and staple the returned ticket.

Work:

1. Document the one-time setup in `apps/mac/scripts/release.sh --help` output: `xcrun notarytool store-credentials touch-code-notary --key <p8-path> --key-id <id> --issuer <issuer-uuid>` once on the maintainer's Mac.
2. Add `apps/mac/scripts/notarize.sh` that takes a path to a `.app` or `.dmg`:
   - If `AC_API_KEY_ID` env var is set (CI mode), write the base64-decoded P8 key to a temp file with `mktemp -t touch-code-notary` and pass `--key`, `--key-id`, `--issuer`. Always `trap` to remove the temp file.
   - Else, pass `--keychain-profile touch-code-notary`.
   - Call `xcrun notarytool submit "$1" --wait` and capture the JSON. On `status: Accepted`, call `xcrun stapler staple "$1"`. On any other status, dump the log via `xcrun notarytool log <submission-id>` and exit non-zero.
3. Extend `release.sh` with a `notarize` subcommand and a top-level `release` subcommand that runs `archive` → `notarize` → (M4: `dmg`) end-to-end.

Acceptance: `./scripts/release.sh archive && ./scripts/release.sh notarize ".build/release/export/Touch Code.app"` exits 0 on a valid binary. `stapler validate ".build/release/export/Touch Code.app"` says "The validate action worked!". `spctl -a -v -t exec` now says "accepted".

### Milestone 4: DMG packaging (signed + notarized)

By the end of this milestone, `make mac-release VERSION=0.2.0` produces `Touch Code 0.2.0.dmg` that opens with the app on the left and an `/Applications` symlink on the right.

Work:

1. Add `apps/mac/scripts/make-dmg.sh` using `hdiutil` (no `brew` dep). Steps:
   - Create a staging dir `mktemp -d`.
   - Copy `Touch Code.app` into it.
   - `ln -s /Applications` inside the staging dir.
   - `hdiutil create -volname "Touch Code" -srcfolder <stage> -ov -format UDZO <out>.dmg`.
   - `codesign --sign "Developer ID Application: <name> (TEAM)" --timestamp <out>.dmg`.
   - Print SHA256 to stdout and to a sidecar `.sha256` file.

   No `.DS_Store` background-image dance in v1 — that's polish work. The plain DMG with `/Applications` symlink covers the support-cost win.
2. Extend `release.sh` with a `dmg` subcommand and call it from `release` after `notarize` (and notarize the DMG too — Apple notarizes both the inner `.app` and the DMG separately; the DMG ticket is stapled to the DMG, the `.app` ticket to the `.app`).
3. Add `Makefile` target `mac-release` that takes `VERSION` (defaults to `MARKETING_VERSION` from xcconfig) and calls `./scripts/release.sh release`.

Acceptance: `make mac-release` produces `apps/mac/.build/release/Touch Code <version>.dmg` plus `Touch Code <version>.dmg.sha256`. Open the DMG by hand on the development Mac — drag to `/Applications`, launch, no Gatekeeper prompt. `xcrun stapler validate` passes on both the DMG and the inner app.

### Milestone 5: Single-source version + Makefile front door

By the end of this milestone, bumping the version is a one-line edit, and the Makefile help text shows the release flow.

Work:

1. Edit `apps/mac/Configurations/mac-Info.plist`: replace `<string>0.1.0</string>` for `CFBundleShortVersionString` with `<string>$(MARKETING_VERSION)</string>`, and `<string>1</string>` for `CFBundleVersion` with `<string>$(CURRENT_PROJECT_VERSION)</string>`. Verify with `make mac-build && /usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" "<bundle>/Contents/Info.plist"` — should print `0.1.0` from the xcconfig.
2. Add `Makefile` target `mac-bump-version VERSION=x.y.z` that uses `sed -i ''` on `Configurations/Project.xcconfig` to update `MARKETING_VERSION` and increments `CURRENT_PROJECT_VERSION` by 1. Refuses without a `VERSION=` argument. Refuses if the working tree is dirty in `Configurations/`.
3. Update `apps/mac/Makefile` `help` target with the new `mac-archive`, `mac-release`, `mac-bump-version` lines.
4. Update top-level `Makefile` to delegate: `mac-archive`, `mac-release`, `mac-bump-version`.

Acceptance: `make mac-bump-version VERSION=0.2.0 && make mac-build` produces a bundle whose Info.plist reports `0.2.0`. The diff is exactly two lines in `Project.xcconfig`.

### Milestone 6: GitHub Actions release workflow on tag (Deferred — see DEC-7)

Deferred until a GitHub-hosted release channel exists. The work below is preserved verbatim so a future maintainer can execute it without re-discovering the cert-import + notarytool-in-CI pattern.

By the end of this milestone, pushing a `v*` git tag produces a draft GitHub Release with the DMG attached.

Work:

1. Add `.github/workflows/release.yml` triggered on `push: tags: [ 'v*' ]`. Single job on `macos-14` runner.
2. Workflow steps:
   - `actions/checkout@v4` with `submodules: recursive`.
   - Cache `apps/mac/.build/ghostty/` keyed on the ghostty submodule SHA + `apps/mac/scripts/build-ghostty.sh` hash + `mise.toml` hash. (Reuses the script's existing fingerprint logic; just gives the runner a head start.)
   - Set up `mise` via `jdx/mise-action@v2`.
   - Trust mise: `mise trust . apps/mac`.
   - Decode `${{ secrets.DEVELOPER_ID_CERT_P12_BASE64 }}` to a temp file. Create a temp keychain, import the cert with `${{ secrets.DEVELOPER_ID_CERT_PASSWORD }}`, set as default, unlock for the duration of the run.
   - Write `apps/mac/Configurations/Release.xcconfig` from `${{ secrets.DEVELOPMENT_TEAM }}`.
   - `make mac-bootstrap mac-archive` (the workflow does not call `mac-bump-version` — the tag drives the version; the workflow asserts that the tag matches `MARKETING_VERSION` and aborts on mismatch).
   - `./apps/mac/scripts/release.sh notarize` with `AC_API_KEY_ID`, `AC_API_ISSUER_ID`, `AC_API_KEY_P8` (base64) from secrets.
   - `./apps/mac/scripts/release.sh dmg`.
   - `softwareupdate --install-rosetta --agree-to-license` is NOT needed (we don't ship Intel — `arch -arm64` only — confirm in M2 archive output).
   - `gh release create "$GITHUB_REF_NAME" --draft --title "$GITHUB_REF_NAME" --notes-from-tag <dmg-path> <sha256-path>`.
3. Workflow asserts the working tree is clean after the build (catches a script that wrote into a tracked path).
4. Add `.github/workflows/ci.yml` if not present (lint + Debug build on PR) — out of scope for this plan if it already exists; just confirm.

Required GitHub Secrets (documented in `docs/operations/release-secrets.md` written in this milestone):
- `DEVELOPER_ID_CERT_P12_BASE64` — `base64 -i certs.p12`
- `DEVELOPER_ID_CERT_PASSWORD`
- `DEVELOPMENT_TEAM` — 10-char team ID
- `AC_API_KEY_ID`, `AC_API_ISSUER_ID`, `AC_API_KEY_P8` (base64-encoded `.p8` contents)
- `KEYCHAIN_PASSWORD` — random per-run password for the temp keychain

Acceptance: `git tag v0.2.0 && git push origin v0.2.0` triggers the workflow; within ~25 minutes a draft release `v0.2.0` exists with `Touch Code 0.2.0.dmg` and `Touch Code 0.2.0.dmg.sha256` attached. Downloading and opening the DMG on a clean Mac shows no Gatekeeper warning.

### Milestone 7: Sparkle auto-update (deferred)

Captured for posterity. Sparkle integration adds:
- Sparkle SPM dep in `Project.swift`.
- `SUFeedURL` + `SUPublicEDKey` in `mac-Info.plist`.
- An `appcast.xml` published alongside the DMG (CI step).
- A "Check for Updates…" menu item.

This is its own design doc and exec plan when/if it lands. Recording the omission here so a future maintainer doesn't think we forgot.

## Concrete Steps

The full local release flow after all milestones land:

    # one-time, per maintainer Mac:
    cp apps/mac/Configurations/Release.xcconfig.example apps/mac/Configurations/Release.xcconfig
    $EDITOR apps/mac/Configurations/Release.xcconfig    # set your team ID
    xcrun notarytool store-credentials touch-code-notary \
      --key ~/keys/AuthKey_XXXX.p8 --key-id XXXX --issuer <uuid>

    # bump and ship:
    make mac-bump-version VERSION=0.2.0
    git commit -am "chore(mac): bump version to 0.2.0"
    git tag v0.2.0
    make mac-release      # locally — produces .build/release/Touch Code 0.2.0.dmg
    git push && git push --tags    # CI picks up the tag and re-produces the same DMG

Expected output of `make mac-release` (last lines):

    Notarization status: Accepted
    Stapled: .build/release/export/Touch Code.app
    Stapled: .build/release/Touch Code 0.2.0.dmg
    sha256: <hex>  Touch Code 0.2.0.dmg
    Done.

## Validation and Acceptance

End-to-end acceptance, exercised once on the maintainer's Mac and once via CI:

1. **Local release** — Run the Concrete Steps block. Resulting DMG opens cleanly on a separate, never-trusted Mac (or after `xattr -dr com.apple.quarantine ~ ; reboot` simulation). The app launches, the menu bar shows "Touch Code", `~/.local/bin/tc` does not exist yet but installing via the in-app prompt creates it, and `tc --version` reports `0.2.0`.
2. **CI release** — `git push origin v0.2.0` produces a draft GitHub Release whose DMG has the same SHA256 as the local one *minus* the embedded `_CodeSignature` timestamp (signatures differ between machines; that's expected). Stapled tickets validate. `gh release view v0.2.0` shows both assets.
3. **Regression** — `make mac-build` (Debug) still produces a launchable app on a contributor without a Developer ID certificate. `make mac-archive` on the same machine fails with the message "Developer ID Application certificate not found in keychain", not a cryptic xcodebuild error.

## Idempotence and Recovery

- `release.sh` uses `mktemp -d` for all staging; nothing leaks into the repo on Ctrl-C.
- `embed-tc.sh` uses `rm -rf` on the destination directory before copying — same pattern as `embed-git-wt.sh`. The script's `: "${SRCROOT:?…}"` guards prevent a stray run outside Xcode/xcodebuild from clobbering the wrong path.
- Re-running `make mac-release` against an already-notarized binary is safe: notarytool returns "already accepted" and stapler is a no-op on an already-stapled file.
- The CI workflow always creates the keychain with `mktemp` and removes it in `if: always()` — a failed run does not leave a Developer ID cert in the runner's persistent keychain (runners are ephemeral, but defense-in-depth).
- If notarization fails mid-flight (e.g., Apple service down): `release.sh notarize <path>` is re-runnable. The submission API is idempotent with respect to the same input.

## Artifacts and Notes

Notable transcript fragments to keep for verification:

- `codesign -dv --verbose=4 "Touch Code.app"` should show:

      Authority=Developer ID Application: <name> (TEAMID)
      Authority=Developer ID Certification Authority
      Authority=Apple Root CA
      Timestamp=<recent>
      Runtime Version=<macos sdk>
      Sealed Resources version=2 rules=…

- `spctl -a -v -t exec "Touch Code.app"` should print `accepted` after stapling.

- `xcrun notarytool log <submission-id>` JSON for the first run is worth pasting into the Surprises section if anything fails — the `issues` array is the diagnostic, not the human-readable summary.

## Interfaces and Dependencies

The release script surface (locked in M2–M4):

    ./apps/mac/scripts/release.sh archive
    ./apps/mac/scripts/release.sh notarize <path-to-app-or-dmg>
    ./apps/mac/scripts/release.sh dmg [--version X.Y.Z]
    ./apps/mac/scripts/release.sh release    # archive → notarize app → dmg → notarize dmg → staple both

Environment contract for the script (precedence: CLI flag > env > Release.xcconfig > xcconfig default):

- `DEVELOPMENT_TEAM`     — required, 10-char team ID
- `CODE_SIGN_IDENTITY`   — defaults to "Developer ID Application"
- `AC_API_KEY_ID`        — set in CI; absent locally
- `AC_API_ISSUER_ID`     — set in CI; absent locally
- `AC_API_KEY_P8`        — base64-encoded P8 contents; set in CI
- `KEYCHAIN_PROFILE`     — defaults to `touch-code-notary`; used when `AC_API_KEY_ID` is unset

External tools required (all on macOS-14 GitHub runners by default):

- `xcodebuild` (from Xcode 26+)
- `xcrun notarytool` (Xcode 13+)
- `xcrun stapler`
- `codesign`
- `hdiutil`
- `security`
- `gh` (CI only, for release create)
- `mise` (already required by bootstrap)

No new third-party dependency is introduced. `create-dmg` is intentionally avoided per DEC-1's implementation note.

## Open Questions

All three questions raised at draft time were resolved by Gump on 2026-04-28 and are kept here as a record:

1. **Apple Developer ID provisioned? — Yes.** Team ID, Developer ID Application `.p12`, and App Store Connect API key are available on the maintainer's Mac. M2–M5 unblocked.
2. **GitHub repo for releases? — No.** No GitHub-hosted release channel for v1; M6 deferred per DEC-7. Local `make mac-release` is the distribution path.
3. **PRODUCT_NAME with a space — accepted.** M1 sets `productName: "Touch Code"`; the on-disk bundle is `Touch Code.app`. M1 acceptance confirms no xcodebuild/Tuist regression from the embedded space.
