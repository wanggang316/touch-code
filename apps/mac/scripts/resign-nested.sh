#!/usr/bin/env bash
#
# resign-nested.sh — re-sign every nested executable / framework /
# helper inside a Developer-ID-signed .app with the same identity and
# Hardened Runtime flags that the outer signature uses.
#
# Sparkle (and any other framework that ships pre-signed XPC services)
# leaves those inner binaries with ad-hoc / 'not set' team signatures
# after xcodebuild's "deep" signing. `codesign --verify --strict --deep`
# treats those as valid because the hashes match, but Apple's notary
# service rejects an outer Developer-ID-signed bundle that contains
# ad-hoc inner code.
#
# Usage:
#   ./scripts/resign-nested.sh <path-to-app>
#
# Requires DEVELOPER_ID_IDENTITY_SHA env (40-char SHA-1) — release.sh
# already resolves it via 'security find-identity'.
#
set -euo pipefail

: "${DEVELOPER_ID_IDENTITY_SHA:?must be set (release.sh exports it)}"

app_path="${1:?usage: resign-nested.sh <path-to-app>}"
[ -d "$app_path" ] || { echo "error: $app_path is not a directory" >&2; exit 1; }

sign_path() {
  local path="$1"
  local -a args=(-f -s "$DEVELOPER_ID_IDENTITY_SHA" -o runtime --timestamp -v)
  case "$path" in
    *.app|*.appex|*.xpc)
      # Preserve the helper's own entitlements / requirements rather
      # than inheriting the outer app's. Sparkle's XPC services in
      # particular declare a tight com.apple.security.app-sandbox
      # plist that must survive the re-sign.
      args+=(--preserve-metadata=entitlements,requirements,flags)
      ;;
  esac
  codesign "${args[@]}" "$path"
}

# Roots inside an .app bundle that can hold signable code.
roots=(
  "$app_path/Contents/Frameworks"
  "$app_path/Contents/PlugIns"
  "$app_path/Contents/Resources"
  "$app_path/Contents/XPCServices"
  "$app_path/Contents/Library/LoginItems"
)

paths=()
for root in "${roots[@]}"; do
  [ -d "$root" ] || continue
  while IFS= read -r -d '' p; do
    paths+=("$p")
  done < <(
    find "$root" \
      \( -type d \( -name '*.app' -o -name '*.appex' -o -name '*.framework' -o -name '*.xpc' \) \
      -o -type f \( -name '*.dylib' -o -perm -111 \) \) \
      -print0
  )
done

# Sign deepest-first so each container's resource hash is computed over
# already-signed children. Sort by slash count (= path depth) descending.
if [ "${#paths[@]}" -gt 0 ]; then
  while IFS=$'\t' read -r _ p; do
    sign_path "$p"
  done < <(
    for p in "${paths[@]}"; do
      slashes="${p//[^\/]/}"
      printf '%s\t%s\n' "${#slashes}" "$p"
    done | sort -rn -k1,1
  )
fi

# Finally re-seal the outer app bundle so its CodeResources hashes
# capture the just-replaced inner signatures.
codesign -f -s "$DEVELOPER_ID_IDENTITY_SHA" -o runtime --timestamp \
  --preserve-metadata=entitlements,requirements,flags -v "$app_path"

# Verification: every nested binary should now show our team ID.
codesign --verify --strict --deep --verbose=2 "$app_path"
