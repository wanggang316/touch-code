#!/usr/bin/env bash
#
# release.sh — orchestrate Touch Code's Developer ID release pipeline.
#
# Subcommands:
#   archive     Archive + exportArchive to .build/release/export/Touch Code.app
#   notarize    Submit a path to Apple notary, wait, and staple (M3, wired later)
#   dmg         Package the exported .app into a signed DMG (M4, wired later)
#   release     archive → notarize app → dmg → notarize dmg → staple both (M4)
#
# Usage:
#   ./scripts/release.sh archive
#   ./scripts/release.sh --help
#
# Environment (precedence: env > Release.xcconfig > defaults):
#   DEVELOPMENT_TEAM     required (10-char team ID)
#   CODE_SIGN_IDENTITY   default "Developer ID Application"
#
set -euo pipefail

# ----- paths --------------------------------------------------------------

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
srcroot="$(cd "${script_dir}/.." && pwd)"

release_dir="${srcroot}/.build/release"
archive_path="${release_dir}/TouchCode.xcarchive"
export_dir="${release_dir}/export"
app_path="${export_dir}/Touch Code.app"
export_options_template="${srcroot}/Configurations/ExportOptions.plist"
release_xcconfig="${srcroot}/Configurations/Release.xcconfig"

workspace="${srcroot}/touch-code.xcworkspace"
scheme="touch-code"

# ----- helpers ------------------------------------------------------------

die() { echo "error: $*" >&2; exit 1; }
log() { echo "==> $*"; }

print_usage() {
  sed -n '3,18p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
}

read_xcconfig_value() {
  # $1 = key. Looks up the key in Release.xcconfig (ignores comments,
  # tolerates surrounding whitespace and quotes). Empty when absent.
  [ -f "${release_xcconfig}" ] || return 0
  awk -v k="$1" '
    /^[[:space:]]*\/\// { next }
    {
      line = $0
      sub(/\/\/.*/, "", line)
      n = split(line, parts, "=")
      if (n < 2) next
      key = parts[1]
      gsub(/[[:space:]]/, "", key)
      if (key != k) next
      val = parts[2]
      for (i = 3; i <= n; i++) val = val "=" parts[i]
      sub(/^[[:space:]]+/, "", val)
      sub(/[[:space:]]+$/, "", val)
      gsub(/^"|"$/, "", val)
      print val
      exit
    }
  ' "${release_xcconfig}"
}

resolve_team_id() {
  if [ -n "${DEVELOPMENT_TEAM:-}" ]; then
    printf '%s' "${DEVELOPMENT_TEAM}"
    return
  fi
  read_xcconfig_value DEVELOPMENT_TEAM
}

resolve_signing_identity() {
  if [ -n "${CODE_SIGN_IDENTITY:-}" ]; then
    printf '%s' "${CODE_SIGN_IDENTITY}"
    return
  fi
  local from_xcconfig
  from_xcconfig="$(read_xcconfig_value CODE_SIGN_IDENTITY)"
  if [ -n "${from_xcconfig}" ]; then
    printf '%s' "${from_xcconfig}"
  else
    printf 'Developer ID Application'
  fi
}

preflight_signing() {
  [ -f "${release_xcconfig}" ] || die "missing ${release_xcconfig}. Copy Release.xcconfig.example and fill in DEVELOPMENT_TEAM."
  local team
  team="$(resolve_team_id)"
  [ -n "${team}" ] && [ "${team}" != "XXXXXXXXXX" ] || die "DEVELOPMENT_TEAM is not set in ${release_xcconfig}."
  if ! security find-identity -v -p codesigning 2>/dev/null | grep -q "Developer ID Application"; then
    die "Developer ID Application certificate not found in keychain. Import it via Keychain Access first."
  fi
}

# ----- archive subcommand -------------------------------------------------

cmd_archive() {
  preflight_signing
  log "archiving ${scheme} (Release)"
  rm -rf "${archive_path}" "${export_dir}"
  mkdir -p "${release_dir}"

  xcodebuild archive \
    -workspace "${workspace}" \
    -scheme "${scheme}" \
    -configuration Release \
    -destination "generic/platform=macOS" \
    -archivePath "${archive_path}" \
    SKIP_INSTALL=NO \
    | "$(mise_xcbeautify_cmd)" --is-ci

  log "exporting archive (developer-id method)"
  local export_options
  export_options="$(mktemp -t touch-code-export-options).plist"
  trap 'rm -f "${export_options}"' EXIT
  local team
  team="$(resolve_team_id)"
  sed "s/__DEVELOPMENT_TEAM__/${team}/" "${export_options_template}" > "${export_options}"

  xcodebuild -exportArchive \
    -archivePath "${archive_path}" \
    -exportPath "${export_dir}" \
    -exportOptionsPlist "${export_options}" \
    | "$(mise_xcbeautify_cmd)" --is-ci

  rm -f "${export_options}"
  trap - EXIT

  [ -d "${app_path}" ] || die "exportArchive did not produce ${app_path}"

  log "verifying signature on ${app_path}"
  codesign --verify --strict --deep --verbose=2 "${app_path}"
  # spctl will say "rejected: source=Notarization" until M3; that's expected.
  spctl -a -v -t exec "${app_path}" || true

  log "archive ready at ${app_path}"
}

cmd_notarize() {
  local target="${1:-${app_path}}"
  [ -e "${target}" ] || die "missing ${target}. Run release.sh archive first."
  "${script_dir}/notarize.sh" "${target}"
}

mise_xcbeautify_cmd() {
  # Best effort — falls back to cat when xcbeautify is missing so the
  # script still works on a runner that has not run mise install.
  if command -v mise >/dev/null 2>&1 && mise exec -- xcbeautify --version >/dev/null 2>&1; then
    printf 'mise exec -- xcbeautify'
  else
    printf 'cat'
  fi
}

# ----- main ---------------------------------------------------------------

main() {
  case "${1:-}" in
    archive)   shift; cmd_archive "$@" ;;
    notarize)  shift; cmd_notarize "$@" ;;
    dmg)       die "dmg: not yet wired (M4)." ;;
    release)   die "release: not yet wired (M4)." ;;
    -h|--help|help|"") print_usage ;;
    *) die "unknown subcommand: ${1}. Run release.sh --help." ;;
  esac
}

main "$@"
