#!/usr/bin/env bash
# Enforce: Skill (under skills/) is pure text describing CLI usage.
# Engineering code — Swift targets, Tuist, build scripts, app UI — must not
# read, locate, install, version-sync with, or bundle Skill content.
#
# Any violation is a hard CI failure. The rule is simple: the dependency
# arrow goes one way (Skill describes project; project does not know about
# Skill). Comments are exempt from the string scan — they don't create
# runtime coupling — but Swift files whose names or symbols claim Skill
# duty (SkillInstaller, SkillBundleLocator, etc.) are hard-forbidden.
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
srcroot="$(cd "${script_dir}/../../.." && pwd)"
scan_root="${srcroot}/apps"

violations=0

# 1. No Swift source files whose names claim Skill coupling.
while IFS= read -r f; do
  echo "forbidden file (Skill coupling by filename): ${f#${srcroot}/}" >&2
  violations=1
done < <(find "${scan_root}" -type f -name '*.swift' \
  \( -name 'Skill*.swift' -o -name '*SkillVersion*.swift' -o -name 'AgentsConfig*.swift' \
     -o -name 'PiMirror*.swift' -o -name 'HomeScopeGuard*.swift' \
     -o -name 'AgentID+*.swift' \) 2>/dev/null)

# 2. No engineering file references Skill content paths, the Skill bundle
#    folder name, the install-marker filename, or the SKILL.md header. This
#    catches both code literals and #filePath-relative fixture paths.
#    Excludes the check script itself and any generated completions (those
#    regenerate from the CLI command tree).
pattern='skills/touch-code-cli|touch-code-skill|SKILL\.md|\.touch-code-skill'

matches="$(grep -rnE "${pattern}" "${scan_root}" \
  --include='*.swift' \
  --include='*.json' \
  --include='Makefile' \
  2>/dev/null \
  | grep -v '/Resources/completions/' \
  || true)"

if [ -n "${matches}" ]; then
  echo "forbidden Skill reference(s) in engineering tree:" >&2
  echo "${matches}" >&2
  violations=1
fi

# 3. No agents.json bundled as a Mac app resource. It was a Skill-install
#    config and has no other purpose.
if [ -f "${srcroot}/apps/mac/Resources/agents.json" ]; then
  echo "forbidden: apps/mac/Resources/agents.json is Skill-install config" >&2
  violations=1
fi

if [ "${violations}" -ne 0 ]; then
  echo "" >&2
  echo "Skill is pure text under skills/; engineering code must not reference it." >&2
  echo "See feedback memory: skill-is-pure-text-no-engineering-coupling." >&2
  exit 1
fi

echo "check-skill-decoupling: clean"
