#!/usr/bin/env bash
#
# release.sh — orchestrate Touch Code's Developer ID release pipeline.
#
# Subcommands:
#   archive     xcodebuild archive + extract signed .app from xcarchive
#   notarize    Submit a path to Apple notary, wait, and staple
#   dmg         Package the exported .app into a signed DMG
#   release     archive → notarize app → dmg → notarize dmg → staple both
#
# Usage:
#   ./scripts/release.sh archive
#   ./scripts/release.sh --help
#
# Signing identity is resolved (in order):
#   1. DEVELOPER_ID_IDENTITY_SHA  env (40-char SHA-1 fingerprint, exact match)
#   2. First "Developer ID Application" entry from `security find-identity`
# Team ID is resolved (in order):
#   1. APPLE_TEAM_ID env  (or DEVELOPMENT_TEAM env, both work)
#   2. Parsed from the cert's CN: "...(<TEAMID>)"
#
# Signing is driven by xcodebuild command-line build settings rather
# than xcconfig or target buildSettings entries. Command-line settings
# sit at the top of Xcode's resolution chain, so they win regardless of
# what the project file or any included xcconfig contains — which keeps
# the script's behaviour independent of how Tuist regenerates the
# project on each run.
#
set -euo pipefail

# ----- paths --------------------------------------------------------------

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
srcroot="$(cd "${script_dir}/.." && pwd)"

release_dir="${srcroot}/.build/release"
archive_path="${release_dir}/TouchCode.xcarchive"
export_dir="${release_dir}/export"
app_path="${export_dir}/TouchCode.app"

workspace="${srcroot}/touch-code.xcworkspace"
scheme="touch-code"

# ----- helpers ------------------------------------------------------------

die() { echo "error: $*" >&2; exit 1; }
log() { echo "==> $*"; }

print_usage() {
  cat <<'EOF'
release.sh — orchestrate Touch Code's Developer ID release pipeline.

Subcommands:
  archive     xcodebuild archive + extract signed .app from xcarchive
  notarize    Submit a path to Apple notary, wait, and staple
  dmg         Package the exported .app into a signed DMG
  release     archive → notarize app → dmg → notarize dmg → staple both

Usage:
  ./scripts/release.sh archive
  ./scripts/release.sh --help

Signing identity is resolved from DEVELOPER_ID_IDENTITY_SHA env if set,
else autodetected by 'security find-identity' picking the first
"Developer ID Application" entry. Team ID is resolved from APPLE_TEAM_ID
(or DEVELOPMENT_TEAM) env, else parsed from the cert's CN.
EOF
}

# Pipe stdout/stderr from xcodebuild through xcbeautify when mise has
# it, else through cat. Using a function (not a $() expansion) so the
# multi-word command does not get word-collapsed into a single argv.
beautify() {
  if command -v mise >/dev/null 2>&1 && mise exec -- xcbeautify --version >/dev/null 2>&1; then
    mise exec -- xcbeautify --is-ci
  else
    cat
  fi
}

resolve_identity_sha() {
  if [ -n "${DEVELOPER_ID_IDENTITY_SHA:-}" ]; then
    printf '%s' "${DEVELOPER_ID_IDENTITY_SHA}"
    return
  fi
  local sha
  sha="$(security find-identity -v -p codesigning 2>/dev/null \
    | grep 'Developer ID Application' \
    | head -1 \
    | awk '{print $2}')"
  [ -n "${sha}" ] || die "Developer ID Application identity not found in keychain. Import the .p12 first."
  printf '%s' "${sha}"
}

resolve_team_id() {
  if [ -n "${APPLE_TEAM_ID:-}" ]; then
    printf '%s' "${APPLE_TEAM_ID}"
    return
  fi
  if [ -n "${DEVELOPMENT_TEAM:-}" ]; then
    printf '%s' "${DEVELOPMENT_TEAM}"
    return
  fi
  # Parse the (TEAMID) suffix from the cert's CN. Apple guarantees it
  # for Developer ID certs.
  local team
  team="$(security find-identity -v -p codesigning 2>/dev/null \
    | grep 'Developer ID Application' \
    | head -1 \
    | sed -nE 's/.*\(([A-Z0-9]{10})\).*/\1/p')"
  [ -n "${team}" ] || die "could not determine team ID from keychain. Set APPLE_TEAM_ID."
  printf '%s' "${team}"
}

# ----- archive subcommand -------------------------------------------------

cmd_archive() {
  "${script_dir}/sync-product-version.sh" --check

  log "archiving ${scheme} (Release)"
  rm -rf "${archive_path}" "${export_dir}"
  mkdir -p "${release_dir}" "${export_dir}"

  local identity_sha team_id
  identity_sha="$(resolve_identity_sha)"
  team_id="$(resolve_team_id)"
  log "signing identity SHA: ${identity_sha}"
  log "team ID:              ${team_id}"

  # Pass signing as xcodebuild command-line build settings (highest
  # precedence in Xcode's resolution chain). This sidesteps any
  # CODE_SIGN_IDENTITY = "-" defaults Tuist may have baked into target
  # buildSettings, and any xcconfig fight that came with #include?
  # gymnastics.
  xcodebuild archive \
    -workspace "${workspace}" \
    -scheme "${scheme}" \
    -configuration Release \
    -destination "generic/platform=macOS" \
    -archivePath "${archive_path}" \
    SKIP_INSTALL=NO \
    ARCHS=arm64 \
    ONLY_ACTIVE_ARCH=NO \
    CODE_SIGN_STYLE=Manual \
    DEVELOPMENT_TEAM="${team_id}" \
    CODE_SIGN_IDENTITY="${identity_sha}" \
    OTHER_CODE_SIGN_FLAGS="--timestamp" \
    | beautify

  # Bypass `xcodebuild -exportArchive` deliberately. exportArchive is
  # designed for distribution methods that re-sign with a profile (App
  # Store Connect, TestFlight, ad-hoc) — Developer ID does not use
  # provisioning profiles, so the only useful thing exportArchive would
  # do is `cp -R`. In return it drags in IDEDistributionMethodManager,
  # which fails with "Unknown Distribution Error" / "expected one {} but
  # found developer-id" whenever the Xcode app has no logged-in Apple
  # ID — a hard requirement for headless and CI flows. Copying the
  # already-signed bundle out of the .xcarchive ourselves avoids the
  # entire IDE-distribution code path while preserving the signature
  # produced by xcodebuild archive.
  log "extracting signed app from ${archive_path}"
  /bin/cp -R "${archive_path}/Products/Applications/TouchCode.app" "${export_dir}/"

  [ -d "${app_path}" ] || die "TouchCode.app not found inside the xcarchive"

  # Re-sign nested helpers. xcodebuild's deep signing leaves any
  # framework-bundled XPC services (e.g. Sparkle's Installer.xpc and
  # Downloader.xpc) with their pre-existing ad-hoc signatures —
  # codesign --strict --deep accepts that, but Apple's notary service
  # rejects an outer Developer-ID-signed bundle that contains ad-hoc
  # inner code. The nested re-sign runs deepest-first to keep parent
  # CodeResources hashes consistent.
  log "re-signing nested helpers under ${app_path}"
  DEVELOPER_ID_IDENTITY_SHA="${identity_sha}" "${script_dir}/resign-nested.sh" "${app_path}"

  if codesign -dv "${app_path}" 2>&1 | grep -q "Signature=adhoc"; then
    die "archive produced an ad-hoc signature instead of Developer ID. Verify the cert is in your keychain (security find-identity -v -p codesigning)."
  fi

  # spctl will say "rejected: source=Notarization" until notarize runs; expected.
  spctl -a -v -t exec "${app_path}" || true

  log "archive ready at ${app_path}"
}

cmd_notarize() {
  local target="${1:-${app_path}}"
  [ -e "${target}" ] || die "missing ${target}. Run release.sh archive first."
  "${script_dir}/notarize.sh" "${target}"
}

read_marketing_version() {
  /usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" \
    "${app_path}/Contents/Info.plist" 2>/dev/null || die "cannot read CFBundleShortVersionString from ${app_path}"
}

cmd_dmg() {
  [ -d "${app_path}" ] || die "missing ${app_path}. Run release.sh archive first."
  local version="${1:-$(read_marketing_version)}"
  local identity_sha
  identity_sha="$(resolve_identity_sha)"
  local dmg_path="${release_dir}/TouchCode-${version}.dmg"
  "${script_dir}/make-dmg.sh" "${app_path}" "${dmg_path}" "${identity_sha}"
  printf '%s\n' "${dmg_path}"
}

cmd_release() {
  cmd_archive
  log "notarizing app"
  "${script_dir}/notarize.sh" "${app_path}"
  log "packaging DMG"
  local version
  version="$(read_marketing_version)"
  local dmg_path="${release_dir}/TouchCode-${version}.dmg"
  cmd_dmg "${version}"
  log "notarizing DMG"
  "${script_dir}/notarize.sh" "${dmg_path}"
  log "release ready: ${dmg_path}"
}

# ----- main ---------------------------------------------------------------

main() {
  case "${1:-}" in
    archive)   shift; cmd_archive "$@" ;;
    notarize)  shift; cmd_notarize "$@" ;;
    dmg)       shift; cmd_dmg "$@" ;;
    release)   shift; cmd_release "$@" ;;
    -h|--help|help|"") print_usage ;;
    *) die "unknown subcommand: ${1}. Run release.sh --help." ;;
  esac
}

main "$@"
