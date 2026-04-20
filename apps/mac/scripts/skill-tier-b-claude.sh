#!/usr/bin/env bash
# Tier-B: Claude Code smoke test against the installed touch-code skill.
#
# Prompts a fresh non-interactive Claude session and asserts it produces a tc-shaped
# answer. Degrades gracefully (exit 0 with a warning) when the claude CLI is missing
# or its non-interactive flag has drifted — per DEC-5, C5 releases do not gate on
# every agent being provisioned on the runner.
#
# Preconditions:
#   - `tc` binary on $PATH (set TC_BIN to override)
#   - `claude` CLI on $PATH (optional; skipped if missing)
#   - TOUCH_CODE_SKILL_BUNDLE / TOUCH_CODE_AGENTS_JSON exported if `tc` is not inside
#     a built touch_code.app
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
srcroot="$(cd "${script_dir}/../../.." && pwd)"

TC_BIN="${TC_BIN:-}"
if [ -z "${TC_BIN}" ]; then
  TC_BIN="$(find "${HOME}/Library/Developer/Xcode/DerivedData" \
    -type f -name tc -path '*Debug/tc' 2>/dev/null | head -n 1)"
fi
if [ -z "${TC_BIN}" ] || [ ! -x "${TC_BIN}" ]; then
  echo "skill-tier-b-claude: tc binary not found; set TC_BIN or run 'make mac-build'" >&2
  exit 1
fi

export TOUCH_CODE_SKILL_BUNDLE="${TOUCH_CODE_SKILL_BUNDLE:-${srcroot}/touch-code-skill}"
export TOUCH_CODE_AGENTS_JSON="${TOUCH_CODE_AGENTS_JSON:-${srcroot}/apps/mac/Resources/agents.json}"

# Degrade if claude isn't installed.
if ! command -v claude >/dev/null 2>&1; then
  echo "skill-tier-b-claude: SKIP — claude CLI not on \$PATH (DEC-5 graceful degradation)" >&2
  exit 0
fi

# Make sure the skill is installed for claude before prompting. Force-install so any
# pre-existing copy is replaced with the current bundle.
"${TC_BIN}" skill install --claude-code --force > /dev/null

mkdir -p "${HOME}/.cache/touch-code-tests"
tmp="$(mktemp -d "${HOME}/.cache/touch-code-tests/skill-tier-b-claude.XXXXXX")"
trap 'rm -rf "${tmp}"' EXIT

# Ask a question whose answer depends on the currently-shipped surface (tc skill *)
# rather than the planned tc ls / tc panel surface. When C1-C3 land, additional prompts
# can be appended to exercise those surfaces.
PROMPT='Using the touch-code skill, what is the exact tc command to check which agents have the touch-code skill installed? Respond with only the command on the last line.'

# Claude Code non-interactive: -p is the canonical short form as of 2026-Q2. Re-verify
# against `claude --help` at release time; if it changes, update this one line.
if ! claude -p "${PROMPT}" > "${tmp}/answer.txt" 2> "${tmp}/err.txt"; then
  echo "skill-tier-b-claude: claude CLI failed" >&2
  cat "${tmp}/err.txt" >&2
  echo "  if 'claude -p' is no longer the non-interactive flag, update this script" >&2
  exit 1
fi

if ! grep -q 'tc skill status' "${tmp}/answer.txt"; then
  echo "skill-tier-b-claude: FAIL — claude's answer did not reference 'tc skill status'" >&2
  echo "----- claude output -----" >&2
  cat "${tmp}/answer.txt" >&2
  exit 1
fi

echo "skill-tier-b-claude: PASS"
