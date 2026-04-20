#!/usr/bin/env bash
# Tier-A test harness for the touch-code agent skill.
#
# Runs three checks that do NOT depend on the rest of the app (tc ls / Panel IPC /
# libghostty). Safe to run on any PR.
#   1. tc help-json roundtrip — every `tc …` in references/*.md resolves to a real
#      subcommand. (skill-help-roundtrip.py)
#   2. Install-into-tempdir + golden manifest diff — the exact file set that ends up
#      at the install destination must match skill-golden-manifest.txt.
#   3. Orthogonality check — no unauthorised Swift file reads skill content.
#
# Requires: built `tc` binary, jq, python3, /usr/bin/find.
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
srcroot="$(cd "${script_dir}/../../.." && pwd)"

TC_BIN="${TC_BIN:-}"
if [ -z "${TC_BIN}" ]; then
  TC_BIN="$(find "${HOME}/Library/Developer/Xcode/DerivedData" \
    -type f -name tc -path '*Debug/tc' 2>/dev/null | head -n 1)"
fi
if [ -z "${TC_BIN}" ] || [ ! -x "${TC_BIN}" ]; then
  echo "skill-tier-a: tc binary not found" >&2
  echo "  set TC_BIN=/path/to/tc or run 'make mac-build' first" >&2
  exit 1
fi

skill_bundle="${srcroot}/touch-code-skill"
agents_json="${srcroot}/apps/mac/Resources/agents.json"
manifest_golden="${script_dir}/skill-golden-manifest.txt"

# Every tc invocation below inherits the dev-run env so the binary resolves fixtures
# from the worktree rather than from whatever DerivedData layout Xcode picked.
export TOUCH_CODE_SKILL_BUNDLE="${skill_bundle}"
export TOUCH_CODE_AGENTS_JSON="${agents_json}"

# Tempdir under $HOME — SkillInstaller refuses to write outside (DEC-4).
mkdir -p "${HOME}/.cache/touch-code-tests"
tmp="$(mktemp -d "${HOME}/.cache/touch-code-tests/skill-tier-a.XXXXXX")"
trap 'rm -rf "${tmp}"' EXIT

echo "--- 1/3: tc help-json roundtrip against references/*.md"
"${TC_BIN}" help-json > "${tmp}/help.json"
python3 "${script_dir}/skill-help-roundtrip.py" \
  "${skill_bundle}/references" "${tmp}/help.json"

echo "--- 2/3: install-into-tempdir + golden manifest diff"
target="${tmp}/dest/touch-code"
"${TC_BIN}" skill install --claude-code --dest "${target}" --force \
  > "${tmp}/install.log" 2>&1 \
  || { echo "tc skill install failed:"; cat "${tmp}/install.log" >&2; exit 1; }

# Compare installed file list against the golden, excluding the install marker (its
# content is timestamped; schema is covered by unit tests).
(cd "${target}" && find . -type f | grep -v '\.touch-code-skill\.json$' | LC_ALL=C sort) \
  > "${tmp}/manifest.txt"

if [ ! -f "${manifest_golden}" ]; then
  echo "skill-tier-a: golden manifest missing at ${manifest_golden}" >&2
  echo "  run 'make mac-skill-golden-update' to regenerate" >&2
  exit 1
fi

if ! diff -u "${manifest_golden}" "${tmp}/manifest.txt"; then
  echo "" >&2
  echo "skill-tier-a: installed file set drifted from golden" >&2
  echo "  if intentional, run 'make mac-skill-golden-update'" >&2
  exit 1
fi

echo "--- 3/3: orthogonality check"
"${script_dir}/skill-orthogonality-check.sh"

echo ""
echo "tier-A: all checks passed"
