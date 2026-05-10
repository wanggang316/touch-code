#!/usr/bin/env bash
#
# sync-product-version.sh — keep co-versioned release artifacts aligned with
# apps/mac/Configurations/Project.xcconfig MARKETING_VERSION.
#
# The Mac app remains the source of truth. This script projects that version
# into the CLI's ArgumentParser version string and the published Agent Skill
# package metadata.
#
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
srcroot="$(cd "${script_dir}/.." && pwd)"
repo_root="$(cd "${srcroot}/../.." && pwd)"

xcconfig="${srcroot}/Configurations/Project.xcconfig"
cli_source="${srcroot}/tc/TouchCodeCLI.swift"
skill_version="${repo_root}/skills/touch-code-cli/VERSION"
skill_package="${repo_root}/skills/touch-code-cli/package.json"

die() { echo "error: $*" >&2; exit 1; }
log() { echo "==> $*"; }

print_usage() {
  cat <<'EOF'
sync-product-version.sh — sync tc + skill versions from MARKETING_VERSION.

Usage:
  sync-product-version.sh           update files in place
  sync-product-version.sh --check   verify files are already synchronized
  sync-product-version.sh --help
EOF
}

read_marketing_version() {
  awk -F'=' '
    /^MARKETING_VERSION[[:space:]]*=/ {
      gsub(/[ \t\r]/, "", $2); print $2; exit
    }' "$xcconfig"
}

semver_check() {
  [[ "$1" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] \
    || die "MARKETING_VERSION '$1' must match X.Y.Z"
}

replace_file() {
  local file="$1"
  local expression="$2"
  local tmp
  tmp="$(mktemp "${file}.sync.XXXXXX")"
  perl -0pe "$expression" "$file" >"$tmp"
  if cmp -s "$file" "$tmp"; then
    rm -f "$tmp"
  else
    mv "$tmp" "$file"
    log "updated ${file#${repo_root}/}"
  fi
}

sync_files() {
  local version="$1"
  printf '%s\n' "$version" >"${skill_version}"
  replace_file "$cli_source" "s/static let version = \"[^\"]+\"/static let version = \"$version\"/"
  replace_file "$skill_package" "s/\"version\"\\s*:\\s*\"[^\"]+\"/\"version\": \"$version\"/"
}

check_files() {
  local version="$1"
  local failed=0

  if ! grep -q "static let version = \"${version}\"" "$cli_source"; then
    echo "out of sync: ${cli_source#${repo_root}/}" >&2
    failed=1
  fi
  if [[ "$(tr -d '\r\n' <"$skill_version")" != "$version" ]]; then
    echo "out of sync: ${skill_version#${repo_root}/}" >&2
    failed=1
  fi
  if ! grep -q "\"version\": \"${version}\"" "$skill_package"; then
    echo "out of sync: ${skill_package#${repo_root}/}" >&2
    failed=1
  fi

  return "$failed"
}

main() {
  case "${1:-}" in
    -h|--help)
      print_usage
      return
      ;;
    ""|--check)
      ;;
    *)
      die "unknown argument: $1"
      ;;
  esac

  [[ -f "$xcconfig" ]] || die "$xcconfig not found"
  local version
  version="$(read_marketing_version)"
  [[ -n "$version" ]] || die "MARKETING_VERSION not found in $xcconfig"
  semver_check "$version"

  if [[ "${1:-}" == "--check" ]]; then
    check_files "$version"
  else
    sync_files "$version"
  fi
}

main "$@"
