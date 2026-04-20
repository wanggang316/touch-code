# Mission complete: C5 design doc

**Deliverable:** `docs/design-docs/c5-agent-skill.md` (481 lines after review
pass).

## Key decisions (locked in Decisions section)

1. Skill source lives in `touch-code-skill/` subdirectory of this repo; a mirror
   repo is auto-published on release tag for out-of-app consumption (`pi
   install git:...`). Resolves product-spec Open Q#2.
2. Single canonical `SKILL.md` + `references/`; per-agent quirks under
   `agents/{claude-code,codex,pi}/`. No per-agent forks.
3. Install paths sourced from `apps/mac/Resources/agents.json` (shipped with
   the app); claude-code / codex default under their respective skill dirs, pi
   installs via `pi install git:<mirrorURL>`.
4. Copy by default (`--link` opt-in for contributors).
5. Install marker `.touch-code-skill.json` (`version`, `installedAt`,
   `source`, `bundlePath`, `bundleSha256`) — enables idempotent install,
   `tc skill status`, clean uninstall, and user-edit detection.
6. Skill version == `tc` version, always; single tag ships both.
7. No auto-install on first launch — explicit user action + non-blocking
   banner when installed version lags bundled.
8. SKILL.md teaches the `tc` CLI surface only; no Swift, no architecture.
9. Testing is tiered: unit + skill-vs-`tc --help` roundtrip run on every PR;
   live per-agent smoke tests gate release tags but do not block C5 on
   `tc ls` / Panel IPC arriving first.
10. `tc skill` is the only `tc` subcommand that bypasses IPC (operates on user
    files, not live app state).
11. `agents.json` is the single source of truth for per-agent paths and the pi
    mirror URL; forks override by replacing the file.
12. Default pi mirror URL: `github.com/wanggang316/touch-code-skill`
    (placeholder — swap by editing `agents.json`).
13. `SkillBundleLocator` lives in `apps/mac/tc/`, not `TouchCodeCore` — keeps
    host-environment code out of the pure-domain target.

## Review fixes applied (2026-04-20 second pass)

- **Critical-1:** Moved `SkillBundleLocator.swift` from `TouchCodeCore/` to
  `apps/mac/tc/`; documented the dependency-direction rationale.
- **Critical-2:** `agents.json` (schema + example) is now the declared source
  of truth for pi mirror URL and per-agent paths. Default owner pinned to
  `wanggang316/touch-code-skill` with an `agents.json`-level override path.
- Added Data Storage section with full schemas for `agents.json` and
  `.touch-code-skill.json`; scoped the app's launch-time version check as a
  one-field read with an explicit `InstalledSkillMarker` struct.
- Added `bundleSha256` to the marker; R3 now points at it.
- Tiered testing strategy so Tier-A (unit + `tc --help` roundtrip) can ship
  independently of `tc ls` / Panel IPC.
- `generate-skill-version.sh` relocated to `apps/mac/scripts/`, wired via
  `apps/mac/Makefile` as `skill-version`.
- Nits: `--dest` in usage; clarified pi row in status table; added Swift-level
  anti-example; softened A6 symlink wording; added API Design / Data Storage
  template headers.

## Orthogonality preserved

Zero app-side runtime coupling. The only Swift code that touches the skill is
`SkillInstaller` (pure file ops), `SkillBundleLocator` (path resolver),
`AgentsConfig` (reads shipped JSON), and `SkillVersionBanner` (reads one
version field from the marker). No code opens `SKILL.md`. Invariant "Agent
Skill is consumed, never loaded" holds.

## Next step

`/hs-planner` when ready to schedule implementation.
