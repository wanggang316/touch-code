#!/usr/bin/env bash
# Tier-B: Codex CLI smoke test against the installed touch-code skill.
# Mirrors the structure of skill-tier-b-claude.sh; see its header for context.
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
srcroot="$(cd "${script_dir}/../../.." && pwd)"

TC_BIN="${TC_BIN:-}"
if [ -z "${TC_BIN}" ]; then
  TC_BIN="$(find "${HOME}/Library/Developer/Xcode/DerivedData" \
    -type f -name tc -path '*Debug/tc' 2>/dev/null | head -n 1)"
fi
if [ -z "${TC_BIN}" ] || [ ! -x "${TC_BIN}" ]; then
  echo "skill-tier-b-codex: tc binary not found; set TC_BIN or run 'make mac-build'" >&2
  exit 1
fi

export TOUCH_CODE_SKILL_BUNDLE="${TOUCH_CODE_SKILL_BUNDLE:-${srcroot}/touch-code-skill}"
export TOUCH_CODE_AGENTS_JSON="${TOUCH_CODE_AGENTS_JSON:-${srcroot}/apps/mac/Resources/agents.json}"

if ! command -v codex >/dev/null 2>&1; then
  echo "skill-tier-b-codex: SKIP — codex CLI not on \$PATH (DEC-5 graceful degradation)" >&2
  exit 0
fi

"${TC_BIN}" skill install --codex --force > /dev/null

mkdir -p "${HOME}/.cache/touch-code-tests"
tmp="$(mktemp -d "${HOME}/.cache/touch-code-tests/skill-tier-b-codex.XXXXXX")"
trap 'rm -rf "${tmp}"' EXIT

# Ask about a currently-shipped command so Tier-B can gate the v0.1.0 release. Once
# tc worktree / tc tab / tc panel ship, extend this to exercise those surfaces too.
PROMPT='Using the touch-code skill, what is the tc command to install this skill into Codex? Respond with only the command on the last line.'

# Codex non-interactive: `codex exec "..."` as of 2026-Q2. Re-verify at release time.
# If the flag changes, update the single line below.
if ! codex exec "${PROMPT}" > "${tmp}/answer.txt" 2> "${tmp}/err.txt"; then
  echo "skill-tier-b-codex: codex CLI failed" >&2
  cat "${tmp}/err.txt" >&2
  echo "  if 'codex exec' is no longer the non-interactive form, update this script" >&2
  exit 1
fi

if ! grep -q 'tc skill install' "${tmp}/answer.txt"; then
  echo "skill-tier-b-codex: FAIL — codex answer did not reference 'tc skill install'" >&2
  cat "${tmp}/answer.txt" >&2
  exit 1
fi
if ! grep -q -- '--codex' "${tmp}/answer.txt"; then
  echo "skill-tier-b-codex: FAIL — codex answer did not mention --codex flag" >&2
  cat "${tmp}/answer.txt" >&2
  exit 1
fi

echo "skill-tier-b-codex: PASS"
