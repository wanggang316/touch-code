#!/usr/bin/env bash
#
# notarize.sh — submit a signed .app or .dmg to Apple's notary service,
# wait for the verdict, and staple the ticket on success.
#
# Usage:
#   ./scripts/notarize.sh <path-to-app-or-dmg>
#
# Credentials (precedence: env > keychain):
#   AC_API_KEY_ID + AC_API_ISSUER_ID + AC_API_KEY_P8 (base64)
#                                — CI mode; the P8 is decoded to a
#                                  tempfile cleaned up via trap.
#   else: --keychain-profile "${KEYCHAIN_PROFILE:-touch-code-notary}"
#         (one-time setup: xcrun notarytool store-credentials).
#
set -euo pipefail

target="${1:-}"
[ -n "${target}" ] || {
  echo "usage: notarize.sh <path-to-app-or-dmg>" >&2
  exit 2
}
[ -e "${target}" ] || {
  echo "error: ${target} does not exist" >&2
  exit 1
}

cleanup_files=()
cleanup() {
  for f in "${cleanup_files[@]}"; do
    [ -n "${f}" ] && rm -f "${f}" || true
  done
}
trap cleanup EXIT

if [ -n "${AC_API_KEY_ID:-}" ]; then
  : "${AC_API_ISSUER_ID:?AC_API_ISSUER_ID must be set when AC_API_KEY_ID is set}"
  : "${AC_API_KEY_P8:?AC_API_KEY_P8 must be set when AC_API_KEY_ID is set}"
  key_path="$(mktemp -t touch-code-notary).p8"
  cleanup_files+=("${key_path}")
  printf '%s' "${AC_API_KEY_P8}" | base64 --decode > "${key_path}"
  notary_args=(--key "${key_path}" --key-id "${AC_API_KEY_ID}" --issuer "${AC_API_ISSUER_ID}")
else
  profile="${KEYCHAIN_PROFILE:-touch-code-notary}"
  notary_args=(--keychain-profile "${profile}")
fi

echo "==> submitting ${target} to Apple notary service"
submit_log="$(mktemp -t touch-code-notary-submit).json"
cleanup_files+=("${submit_log}")

# notarytool wants a zip when notarizing a .app; DMGs go in directly.
case "${target}" in
  *.app)
    zip_path="$(mktemp -d -t touch-code-notary)/$(basename "${target}").zip"
    /usr/bin/ditto -c -k --keepParent "${target}" "${zip_path}"
    cleanup_files+=("${zip_path}")
    submission="${zip_path}"
    ;;
  *.dmg)
    submission="${target}"
    ;;
  *)
    echo "error: unsupported target type: ${target} (expected .app or .dmg)" >&2
    exit 1
    ;;
esac

xcrun notarytool submit "${submission}" \
  "${notary_args[@]}" \
  --wait \
  --output-format json \
  > "${submit_log}"

status="$(/usr/bin/python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("status",""))' "${submit_log}")"
submission_id="$(/usr/bin/python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("id",""))' "${submit_log}")"

echo "==> notarization status: ${status} (id: ${submission_id})"
if [ "${status}" != "Accepted" ]; then
  echo "==> dumping notarytool log for failed submission" >&2
  xcrun notarytool log "${submission_id}" "${notary_args[@]}" >&2 || true
  exit 1
fi

echo "==> stapling ticket onto ${target}"
xcrun stapler staple "${target}"
xcrun stapler validate "${target}"
echo "==> ${target} notarized and stapled"
