#!/usr/bin/env bash
set -euo pipefail

wt_script="${SRCROOT}/ThirdParty/git-wt/wt"
if [ ! -f "${wt_script}" ]; then
  echo "error: missing ${wt_script}. run: git submodule update --init apps/mac/ThirdParty/git-wt" >&2
  exit 1
fi

if [ ! -x "${wt_script}" ]; then
  echo "error: ${wt_script} is not executable" >&2
  exit 1
fi
