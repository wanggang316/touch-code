#!/usr/bin/env bash
#
# make-dmg.sh — package a signed Touch Code.app into a Developer-ID-
# signed DMG using only hdiutil + codesign (no brew dependency).
#
# Usage:
#   ./scripts/make-dmg.sh <path-to-app> <output-dmg> <signing-identity>
#
# The DMG layout is plain: app on the left, /Applications symlink on
# the right, no background image. Polish is M7+ work.
#
set -euo pipefail

app_path="${1:?usage: make-dmg.sh <app> <out-dmg> <signing-identity>}"
dmg_path="${2:?usage: make-dmg.sh <app> <out-dmg> <signing-identity>}"
identity="${3:?usage: make-dmg.sh <app> <out-dmg> <signing-identity>}"

[ -d "${app_path}" ] || { echo "error: ${app_path} is not a directory" >&2; exit 1; }

stage_dir="$(mktemp -d -t touch-code-dmg)"
cleanup() { rm -rf "${stage_dir}"; }
trap cleanup EXIT

echo "==> staging DMG contents"
/bin/cp -R "${app_path}" "${stage_dir}/"
ln -s /Applications "${stage_dir}/Applications"

mkdir -p "$(dirname "${dmg_path}")"
rm -f "${dmg_path}"

echo "==> hdiutil create ${dmg_path}"
hdiutil create \
  -volname "Touch Code" \
  -srcfolder "${stage_dir}" \
  -ov \
  -format UDZO \
  -fs HFS+ \
  "${dmg_path}" \
  >/dev/null

echo "==> signing DMG"
codesign --sign "${identity}" --timestamp "${dmg_path}"
codesign --verify --verbose=2 "${dmg_path}"

echo "==> writing checksum"
sha256_path="${dmg_path}.sha256"
( cd "$(dirname "${dmg_path}")" && shasum -a 256 "$(basename "${dmg_path}")" > "${sha256_path}" )
cat "${sha256_path}"

echo "==> ${dmg_path}"
