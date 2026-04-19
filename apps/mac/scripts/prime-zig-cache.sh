#!/usr/bin/env bash
# Populate Zig's global cache with ghostty's deps, bypassing Zig's HTTP client.
#
# Why: Zig 0.15.2's std.http.Client TLS fingerprint is rejected by Cloudflare
# (400 Bad Request) on deps.files.ghostty.org. curl's TLS (OpenSSL/LibreSSL) is
# accepted. We therefore download each tarball with curl, then hand the LOCAL
# FILE to `zig fetch` — zig unpacks, hashes, and stores it in the cache without
# ever talking to the network. Pattern mirrors ghostty's nix build at
# ThirdParty/ghostty/build.zig.zon.nix.
#
# Idempotent: skips URLs whose cache entry already exists.
# Usage:
#   ./scripts/prime-zig-cache.sh            # default cache dir
#   ZIG_GLOBAL_CACHE_DIR=/path ./scripts/prime-zig-cache.sh
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
srcroot="$(cd "${script_dir}/.." && pwd)"
ghostty_dir="${srcroot}/ThirdParty/ghostty"
zon_txt="${ghostty_dir}/build.zig.zon.txt"
cache_dir="${ZIG_GLOBAL_CACHE_DIR:-${srcroot}/.build/ghostty/.zig-global-cache}"

if [ ! -f "${zon_txt}" ]; then
  echo "error: missing ${zon_txt}; did you init the ghostty submodule?" >&2
  exit 1
fi

mkdir -p "${cache_dir}/p"
tmp_dir="$(mktemp -d -t zig-prime-cache)"
trap 'rm -rf "${tmp_dir}"' EXIT

total=0
fetched=0
skipped=0
repo_root="$(cd "${srcroot}/../.." && pwd)"

fetch_tarball() {
  local url="$1"
  local tarball="${tmp_dir}/$(basename "${url}")"
  curl -fsSL --retry 5 --retry-delay 2 --retry-all-errors --http1.1 "${url}" -o "${tarball}" || {
    echo "  curl failed: ${url}" >&2
    exit 1
  }
  local hash_name
  hash_name="$(mise exec -C "${repo_root}" -- \
    zig fetch --global-cache-dir "${cache_dir}" "${tarball}")"
  rm -f "${tarball}"
  [ -d "${cache_dir}/p/${hash_name}" ] || {
    echo "  zig fetch produced no ${cache_dir}/p/${hash_name}" >&2
    exit 1
  }
}

fetch_git() {
  # git+https://host/owner/repo#<rev-or-branch>
  local spec="${1#git+}"
  local url_base rev checkout
  url_base="${spec%%#*}"
  rev="${spec##*#}"
  checkout="${tmp_dir}/git-$(basename "${url_base}")-$$"
  git clone --quiet "${url_base}" "${checkout}"
  git -C "${checkout}" fetch --quiet origin "${rev}" 2>/dev/null || true
  git -C "${checkout}" -c advice.detachedHead=false checkout --quiet "${rev}"
  local hash_name
  hash_name="$(mise exec -C "${repo_root}" -- \
    zig fetch --global-cache-dir "${cache_dir}" "${checkout}")"
  rm -rf "${checkout}"
  [ -d "${cache_dir}/p/${hash_name}" ] || {
    echo "  zig fetch produced no ${cache_dir}/p/${hash_name}" >&2
    exit 1
  }
}

while IFS= read -r url || [ -n "${url}" ]; do
  [ -z "${url}" ] && continue
  total=$((total + 1))
  echo "[${total}] ${url}"
  case "${url}" in
    git+*) fetch_git "${url}" ;;
    *)     fetch_tarball "${url}" ;;
  esac
  fetched=$((fetched + 1))
done < "${zon_txt}"

echo ""
echo "done: ${fetched}/${total} tarballs primed into ${cache_dir}/p/"
