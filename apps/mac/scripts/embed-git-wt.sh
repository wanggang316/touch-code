#!/usr/bin/env bash
set -euo pipefail

destination_root="${TARGET_BUILD_DIR}/${UNLOCALIZED_RESOURCES_FOLDER_PATH}"
git_wt_source="${SRCROOT}/ThirdParty/git-wt/wt"
git_wt_destination_dir="${destination_root}/git-wt"

if [ ! -f "${git_wt_source}" ]; then
  echo "error: missing ${git_wt_source}" >&2
  exit 1
fi

rm -rf "${git_wt_destination_dir}"
mkdir -p "${git_wt_destination_dir}"
/bin/cp -f "${git_wt_source}" "${git_wt_destination_dir}/wt"
chmod +x "${git_wt_destination_dir}/wt"
