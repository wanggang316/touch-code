#!/usr/bin/env bash
# Regenerate apps/mac/scripts/skill-golden-manifest.txt from a fresh install.
# Call whenever the touch-code-skill/ file SET (not content) intentionally changes.
# Content-only edits should leave the golden manifest untouched; a diff after this
# script runs points at an unintended file add/remove.
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
srcroot="$(cd "${script_dir}/../../.." && pwd)"

TC_BIN="${TC_BIN:-}"
if [ -z "${TC_BIN}" ]; then
  TC_BIN="$(find "${HOME}/Library/Developer/Xcode/DerivedData" \
    -type f -name tc -path '*Debug/tc' 2>/dev/null | head -n 1)"
fi
if [ -z "${TC_BIN}" ] || [ ! -x "${TC_BIN}" ]; then
  echo "skill-golden-update: tc binary not found; run 'make mac-build' first" >&2
  exit 1
fi

export TOUCH_CODE_SKILL_BUNDLE="${srcroot}/touch-code-skill"
export TOUCH_CODE_AGENTS_JSON="${srcroot}/apps/mac/Resources/agents.json"

# HOME-scope policy: SkillInstaller refuses to write outside $HOME (DEC-4). Create the
# tempdir under $HOME so the install survives the check.
mkdir -p "${HOME}/.cache/touch-code-tests"
tmp="$(mktemp -d "${HOME}/.cache/touch-code-tests/skill-golden.XXXXXX")"
trap 'rm -rf "${tmp}"' EXIT

target="${tmp}/dest/touch-code"
"${TC_BIN}" skill install --claude-code --dest "${target}" --force > /dev/null

(cd "${target}" && find . -type f | grep -v '\.touch-code-skill\.json$' | LC_ALL=C sort) \
  > "${script_dir}/skill-golden-manifest.txt"

echo "skill-golden-update: regenerated ${script_dir}/skill-golden-manifest.txt"
