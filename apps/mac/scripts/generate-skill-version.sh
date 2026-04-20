#!/usr/bin/env bash
# Sync the touch-code skill package version into VERSION + package.json.
#
# Source of truth: the version string literal inside apps/mac/tc/main.swift's
# CommandConfiguration.version. Pass an explicit version as $1 to override.
#
# Idempotent: running twice with the same value is a no-op diff.
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
srcroot="$(cd "${script_dir}/../../.." && pwd)"
main_swift="${srcroot}/apps/mac/tc/main.swift"
skill_root="${srcroot}/touch-code-skill"

if [ ! -f "${main_swift}" ]; then
  echo "generate-skill-version: missing ${main_swift}" >&2
  exit 1
fi
if [ ! -d "${skill_root}" ]; then
  echo "generate-skill-version: missing ${skill_root}" >&2
  exit 1
fi

# First argument wins; otherwise extract semver from the version: "…" literal.
version="${1:-}"
if [ -z "${version}" ]; then
  # Pulls the first X.Y.Z substring from any `version:` line in main.swift. Robust to
  # whatever surrounding text the banner has ("touch-code 0.1.0 (build 1)" etc.).
  version="$(sed -n 's/.*version:.*[^0-9]\([0-9][0-9]*\.[0-9][0-9]*\.[0-9][0-9]*\).*/\1/p' \
    "${main_swift}" | head -n 1)"
fi

if [ -z "${version}" ]; then
  echo "generate-skill-version: failed to extract version from ${main_swift}" >&2
  exit 1
fi

echo "${version}" > "${skill_root}/VERSION"

# Rewrite package.json's "version" field without disturbing other keys. jq preserves
# ordering since we also pipe through `--sort-keys`.
tmp="$(mktemp)"
trap 'rm -f "${tmp}"' EXIT
jq --sort-keys --arg v "${version}" '.version = $v' \
  "${skill_root}/package.json" > "${tmp}"
mv "${tmp}" "${skill_root}/package.json"
trap - EXIT

echo "skill: version pinned to ${version}"
