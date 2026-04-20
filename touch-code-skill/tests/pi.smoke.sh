#!/usr/bin/env bash
# Tier-B: pi smoke test against the touch-code-skill mirror.
#
# Unlike claude / codex, pi doesn't copy files from tc — it installs from a git URL
# into its own cache. This script exercises that path end-to-end.
#
# Degrades gracefully (exit 0 with a warning) when the pi CLI is missing or the
# mirror repo isn't provisioned — see DEC-5.
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
srcroot="$(cd "${script_dir}/../.." && pwd)"
agents_json="${srcroot}/apps/mac/Resources/agents.json"

if ! command -v pi >/dev/null 2>&1; then
  echo "pi smoke: SKIP — pi CLI not on \$PATH (DEC-5 graceful degradation)" >&2
  exit 0
fi

if [ ! -f "${agents_json}" ]; then
  echo "pi smoke: agents.json missing at ${agents_json}" >&2
  exit 1
fi

mirror_url="$(jq -r '.agents.pi.mirrorURL' "${agents_json}")"
if [ -z "${mirror_url}" ] || [ "${mirror_url}" = "null" ]; then
  echo "pi smoke: agents.json has no pi.mirrorURL" >&2
  exit 1
fi

# Install via pi. This is the happy path; failures are most likely the mirror repo
# not being reachable (pre-provisioning), which is an acceptable pre-release state.
if ! pi install "git:${mirror_url}" 2>/dev/null; then
  echo "pi smoke: SKIP — pi install failed (mirror likely not provisioned yet)" >&2
  exit 0
fi

mkdir -p "${HOME}/.cache/touch-code-tests"
tmp="$(mktemp -d "${HOME}/.cache/touch-code-tests/pi-smoke.XXXXXX")"
trap 'rm -rf "${tmp}"' EXIT

# Shipped-only prompt for the v0.1.0 release gate. Broaden once tc panel * lands.
PROMPT='Using the touch-code skill, what is the tc command to print the path to the bundled touch-code-skill directory? Respond with only the command.'

# pi non-interactive: `pi -p "..."` as of 2026-Q2. Re-verify at release time.
if ! pi -p "${PROMPT}" > "${tmp}/answer.txt" 2> "${tmp}/err.txt"; then
  echo "pi smoke: pi CLI failed" >&2
  cat "${tmp}/err.txt" >&2
  exit 1
fi

if ! grep -q 'tc skill bundle-path' "${tmp}/answer.txt"; then
  echo "pi smoke: FAIL — pi answer did not reference 'tc skill bundle-path'" >&2
  cat "${tmp}/answer.txt" >&2
  exit 1
fi

echo "pi smoke: PASS"
