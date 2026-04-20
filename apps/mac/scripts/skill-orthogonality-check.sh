#!/usr/bin/env bash
# Enforce architecture invariant: "Agent Skill is consumed, never loaded."
#
# Only a handful of Swift source files are allowed to reference the skill bundle or
# its content:
#   - SkillBundleLocator / SkillInstaller / SkillFileSystem / SkillCommand / SkillRunners
#   - AgentsConfig (reads the sibling agents.json, not skill content)
#   - SkillVersionBanner / SkillVersionBannerView (one-field marker read only)
#   - HelpJSONCommand (the roundtrip-check target, no skill content)
#
# Any other file under apps/mac that mentions SKILL.md or touch-code-skill/ is a
# violation. CI fails loudly; contributors fix the file or add an explicit allowlist
# entry here with a justification.
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
srcroot="$(cd "${script_dir}/../../.." && pwd)"

ALLOWED_BASENAMES=(
  "SkillBundleLocator.swift"
  "SkillInstaller.swift"
  "SkillFileSystem.swift"
  "SkillCommand.swift"
  "SkillRunners.swift"
  "AgentsConfig.swift"
  "AgentID+EnumerableFlag.swift"
  "ProcessSpawner.swift"
  "SkillVersionBanner.swift"
  "SkillVersionBannerView.swift"
  "HelpJSONCommand.swift"
)

allowed_pattern=""
for name in "${ALLOWED_BASENAMES[@]}"; do
  allowed_pattern+="${name}|"
done
allowed_pattern="${allowed_pattern%|}"

scan_targets=(
  "${srcroot}/apps/mac/TouchCodeCore"
  "${srcroot}/apps/mac/TouchCodeIPC"
  "${srcroot}/apps/mac/touch-code"
  "${srcroot}/apps/mac/tc"
  "${srcroot}/apps/mac/tcKit"
)

# Remove missing directories before grep so a worktree that omits one (say TouchCodeIPC
# during an early milestone) doesn't fail the check spuriously.
present_targets=()
for target in "${scan_targets[@]}"; do
  [ -d "${target}" ] && present_targets+=("${target}")
done

matches="$(grep -rn 'SKILL.md\|touch-code-skill' \
  "${present_targets[@]}" \
  --include='*.swift' \
  2>/dev/null \
  | grep -v -E "${allowed_pattern}" \
  || true)"

if [ -n "${matches}" ]; then
  echo "skill-orthogonality-check: unauthorised reference(s) to skill content:" >&2
  echo "${matches}" >&2
  echo "" >&2
  echo "Either remove the reference or add the file to ALLOWED_BASENAMES in" >&2
  echo "  apps/mac/scripts/skill-orthogonality-check.sh" >&2
  exit 1
fi

echo "skill-orthogonality-check: clean (no unauthorised skill-content references)"
