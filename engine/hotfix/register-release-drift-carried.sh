#!/usr/bin/env bash
set -euo pipefail

usage() { echo 'usage: register-release-drift-carried.sh <registry> <container> <path> <main-sha|pr-number> <copy> (use a bare PR number or a 40/64-hex main SHA; never combine a SHA and PRs)' >&2; exit 2; }
(($# == 5)) || usage
registry=$1 container=$2 path=$3 main_sha=$4 copy=$5
# A PR number (install from an open hotfix PR head) is carried once that PR merges; a main SHA is carried by ancestry.
# Write only what release-drift-carried.sh reads back: any other row turns the registry unknown and blocks releases.
if [[ $main_sha =~ ^[1-9][0-9]*$ ]]; then
  carrier=$main_sha
elif [[ $main_sha =~ ^([0-9a-f]{40}|[0-9a-f]{64})$ ]]; then
  carrier=installed_from=$main_sha
else
  usage
fi
registry_tmp=$(mktemp "$registry.tmp.XXXXXX")
if [[ -r "$registry" ]]; then
  awk -F '\t' -v container="$container" -v path="$path" -v carrier="$carrier" \
    'NF != 4 || $1 == "image" || $1 != container || $2 != path || !(carrier ~ /^installed_from=/ ? $3 ~ /^installed_from=/ : $3 == carrier)' \
    "$registry" > "$registry_tmp"
fi
printf '%s\t%s\t%s\t%s\n' \
  "$container" "$path" "$carrier" "$copy" >> "$registry_tmp"
mv -f -- "$registry_tmp" "$registry"
