# Mission complete: C5 design doc

**Deliverable:** `docs/design-docs/c5-agent-skill.md` (~409 lines).

## Key decisions (locked in Decisions section)

1. Skill source lives in `touch-code-skill/` subdirectory of this repo; a mirror
   repo (`touch-code-skill`) is auto-published on release tag for out-of-app
   consumption (`pi install git:...`). Resolves product-spec Open Q#2.
2. Single canonical `SKILL.md` + `references/`; per-agent quirks under
   `agents/{claude-code,codex,pi}/`. No per-agent forks.
3. Install paths: `~/.claude/skills/touch-code/`, `~/.codex/skills/touch-code/`;
   pi installs via `pi install git:...` against the mirror.
4. Copy by default (`--link` opt-in for contributors).
5. Install marker (`.touch-code-skill.json`) enables idempotent install,
   `tc skill status`, and clean uninstall.
6. Skill version == `tc` version, always; single tag ships both.
7. No auto-install on first launch — explicit user action + non-blocking banner
   when installed version lags bundled.
8. SKILL.md teaches the `tc` CLI surface only; no Swift, no architecture.
9. Per-agent smoke tests gate tagged releases.
10. `tc skill` is the only `tc` subcommand that bypasses IPC (it operates on
    user files, not live app state).

## Orthogonality preserved

Zero app-side runtime coupling. The app bundles `touch-code-skill/` as
resources; the only code that touches it is `SkillInstaller` (pure file ops)
and `SkillBundleLocator` (path resolver). No Swift file reads SKILL.md
content. Architecture invariant "Agent Skill is consumed, never loaded" is
honoured.

## Next step

`/hs-planner` when ready to schedule implementation.
