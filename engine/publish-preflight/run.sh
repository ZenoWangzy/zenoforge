#!/usr/bin/env bash
set -euo pipefail
here=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
if [[ $# -lt 5 || $# -gt 6 || ( $# -eq 6 && -z "$6" ) ]]; then
  echo "usage: run.sh <live version dir> <new version dir> <target repo> <live ref> <new ref> [intended-change list]" >&2
  exit 2
fi
live_version=$1
new_version=$2
target_repo=$3
live_ref=$4
new_ref=$5
intended=()
[[ $# -eq 5 ]] || intended=("$6")

echo "publish-preflight: checking unit paths"
if ! bash "$here/unit-paths-check.sh" "$live_version" "$new_version"; then
  echo "publish-preflight: unit-paths check failed" >&2
  exit 1
fi

echo "publish-preflight: checking resolved config"
if ! python3 -I "$here/resolved-config-check.py" \
  "$live_version" "$target_repo" "$live_ref" "$new_version" "$target_repo" "$new_ref" "${intended[@]}"; then
  echo "publish-preflight: resolved-config check failed" >&2
  exit 1
fi

echo "publish-preflight: checking suite set"
if ! python3 -I "$here/suite-set-check.py" "$live_version" "$new_version" "$target_repo" "$new_ref"; then
  echo "publish-preflight: suite-set check failed" >&2
  exit 1
fi

echo "publish-preflight: OK"
