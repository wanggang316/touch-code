#!/usr/bin/env bash
#
# bump-version.sh — set MARKETING_VERSION + CURRENT_PROJECT_VERSION in
# apps/mac/Configurations/Project.xcconfig.
#
# This is the single source of truth the release CI checks against
# (.github/workflows/release.yml verifies tag vX.Y.Z matches
# MARKETING_VERSION before building). After this file is updated,
# sync-product-version.sh projects MARKETING_VERSION into the co-versioned
# CLI and Agent Skill metadata.
#
# Build-number scheme: today's date as YYYYMMDD for the first release of
# the day; same-day re-releases append an incrementing sequence digit.
# e.g. 20260506 (1st of day), 202605062 (2nd), 202605063 (3rd), ...
# Numerically monotonic across all sane release cadences (the digit
# concatenation grows the integer by ~10x per re-release on the same day,
# so a fresh next-day "YYYYMMDD" remains greater than any plausible
# same-day suffix). If a day exceeds 9 same-day re-releases the
# next-day rollover guard will refuse and require an explicit BUILD=
# override; in practice we will not get there.
#
# Usage:
#   bump-version.sh <X.Y.Z>          # marketing version; build = today (or todayN if same day)
#   bump-version.sh <X.Y.Z> <BUILD>  # set both explicitly (BUILD must be > current)
#   bump-version.sh --print          # show current values + suggested next bump
#   bump-version.sh --help
#
# Examples:
#   bump-version.sh 0.1.4               # build becomes e.g. 20260506
#   bump-version.sh 0.1.5               # later same day → build becomes 202605062
#   bump-version.sh 0.2.0 20260601      # explicit override
#
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
srcroot="$(cd "${script_dir}/.." && pwd)"
xcconfig="${srcroot}/Configurations/Project.xcconfig"

die() { echo "error: $*" >&2; exit 1; }
log() { echo "==> $*"; }

print_usage() {
  cat <<'EOF'
bump-version.sh — bump MARKETING_VERSION + CURRENT_PROJECT_VERSION.

Usage:
  bump-version.sh <X.Y.Z>          set marketing version, increment build by 1
  bump-version.sh <X.Y.Z> <BUILD>  set both explicitly
  bump-version.sh --print          show current values + suggested patch bump
  bump-version.sh --help
EOF
}

read_field() {
  local key="$1"
  awk -F'=' -v k="$key" '
    $0 ~ "^"k"[[:space:]]*=" {
      gsub(/[ \t\r]/, "", $2); print $2; exit
    }' "$xcconfig"
}

semver_check() {
  [[ "$1" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] \
    || die "version '$1' must match X.Y.Z (digits only)"
}

# Returns 0 (true) if $1 is strictly greater than $2 (both X.Y.Z).
semver_gt() {
  local a="$1" b="$2"
  IFS=. read -r a1 a2 a3 <<<"$a"
  IFS=. read -r b1 b2 b3 <<<"$b"
  (( a1 != b1 )) && { (( a1 > b1 )); return; }
  (( a2 != b2 )) && { (( a2 > b2 )); return; }
  (( a3 >  b3 ))
}

next_patch() {
  local v="$1"
  IFS=. read -r x y z <<<"$v"
  echo "$x.$y.$((z + 1))"
}

# Compute the next date-based build number given the current value.
# - If $1 starts with today's date, append (or increment) the suffix.
# - Otherwise return today's date as-is.
next_build() {
  local cur="$1"
  local today
  today="$(date +%Y%m%d)"

  if [[ "$cur" == "$today" ]]; then
    printf '%s2\n' "$today"
  elif [[ "$cur" =~ ^${today}([0-9]+)$ ]]; then
    printf '%s%d\n' "$today" $((BASH_REMATCH[1] + 1))
  else
    printf '%s\n' "$today"
  fi
}

cmd_print() {
  local mv pv next_mv next_pv
  mv="$(read_field MARKETING_VERSION)"
  pv="$(read_field CURRENT_PROJECT_VERSION)"
  next_mv="$(next_patch "$mv")"
  next_pv="$(next_build "$pv")"
  cat <<EOF
xcconfig: $xcconfig

  MARKETING_VERSION       = $mv
  CURRENT_PROJECT_VERSION = $pv

next patch: $next_mv (build $next_pv)
EOF
}

cmd_bump() {
  local new_mv="$1" new_pv="${2:-}"
  semver_check "$new_mv"

  [[ -f "$xcconfig" ]] || die "$xcconfig not found"

  local cur_mv cur_pv
  cur_mv="$(read_field MARKETING_VERSION)"
  cur_pv="$(read_field CURRENT_PROJECT_VERSION)"
  [[ -n "$cur_mv" ]] || die "MARKETING_VERSION not found in $xcconfig"
  [[ -n "$cur_pv" ]] || die "CURRENT_PROJECT_VERSION not found in $xcconfig"

  if [[ "$new_mv" == "$cur_mv" ]]; then
    die "new MARKETING_VERSION ($new_mv) == current; nothing to bump"
  fi
  if ! semver_gt "$new_mv" "$cur_mv"; then
    die "new MARKETING_VERSION ($new_mv) is not greater than current ($cur_mv); use a forward-rolling version"
  fi

  if [[ -z "$new_pv" ]]; then
    new_pv="$(next_build "$cur_pv")"
    if (( new_pv <= cur_pv )); then
      die "computed date-based build ($new_pv) is not > current ($cur_pv); pass an explicit BUILD= override"
    fi
  else
    [[ "$new_pv" =~ ^[0-9]+$ ]] || die "build number '$new_pv' must be a positive integer"
    (( new_pv > cur_pv )) || die "new build ($new_pv) must be > current ($cur_pv)"
  fi

  log "MARKETING_VERSION:       $cur_mv -> $new_mv"
  log "CURRENT_PROJECT_VERSION: $cur_pv -> $new_pv"

  # Two anchored substitutions — use a tmpfile so we never half-write.
  local tmp
  tmp="$(mktemp "${xcconfig}.bump.XXXXXX")"
  awk -v mv="$new_mv" -v pv="$new_pv" '
    BEGIN { OFS="=" }
    /^MARKETING_VERSION[[:space:]]*=/       { print "MARKETING_VERSION = " mv; next }
    /^CURRENT_PROJECT_VERSION[[:space:]]*=/ { print "CURRENT_PROJECT_VERSION = " pv; next }
    { print }
  ' "$xcconfig" >"$tmp"

  # Sanity: post-condition matches what we asked for.
  local check_mv check_pv
  check_mv="$(awk -F'=' '/^MARKETING_VERSION/ {gsub(/[ \t\r]/,"",$2); print $2}' "$tmp")"
  check_pv="$(awk -F'=' '/^CURRENT_PROJECT_VERSION/ {gsub(/[ \t\r]/,"",$2); print $2}' "$tmp")"
  if [[ "$check_mv" != "$new_mv" || "$check_pv" != "$new_pv" ]]; then
    rm -f "$tmp"
    die "post-write verification failed (mv=$check_mv, pv=$check_pv); xcconfig left unchanged"
  fi

  mv "$tmp" "$xcconfig"
  log "wrote $xcconfig"
  "${script_dir}/sync-product-version.sh"
}

main() {
  case "${1-}" in
    ""|-h|--help)
      print_usage
      ;;
    --print)
      cmd_print
      ;;
    *)
      cmd_bump "$@"
      ;;
  esac
}

main "$@"
