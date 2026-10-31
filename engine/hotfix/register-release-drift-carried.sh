#!/usr/bin/env bash
set -euo pipefail

usage() { echo 'usage: register-release-drift-carried.sh <registry> <container> <path> <main-sha|pr-number> <copy> (use a bare PR number or a 40/64-hex main SHA; never combine a SHA and PRs)' >&2; exit 2; }
image_usage() {
  echo 'usage: register-release-drift-carried.sh --image <registry> <service> <image-id> <pr-number> (images require a bare PR number; a main SHA is not accepted)' >&2
  exit 2
}

if [[ "${1:-}" == --image ]]; then
  (($# == 5)) || image_usage
  registry=$2 service=$3 image_id=$4 pr_number=$5
  [[ "$service" =~ ^[A-Za-z0-9_.-]+$ \
    && "$image_id" =~ ^sha256:[A-Za-z0-9._-]{1,128}$ \
    && "$pr_number" =~ ^[1-9][0-9]*$ ]] || image_usage

  registry_tmp=$(mktemp "$registry.tmp.XXXXXX")
  if [[ -r "$registry" ]]; then
    output_has_bytes=0
    output_ends_newline=1
    while :; do
      line=
      if IFS= read -r line; then
        read_status=0
      else
        read_status=$?
        [[ -n "$line" ]] || break
      fi

      row_kind="${line%%$'\t'*}"
      if [[ "$row_kind" == image && "$line" == *$'\t'* ]]; then
        row_rest="${line#*$'\t'}"
        row_service="${row_rest%%$'\t'*}"
        [[ "$row_service" != "$service" ]] || continue
      fi

      output_has_bytes=1
      if (( read_status == 0 )); then
        printf '%s\n' "$line" >> "$registry_tmp"
        output_ends_newline=1
      else
        printf '%s' "$line" >> "$registry_tmp"
        output_ends_newline=0
      fi
    done < "$registry"
    if (( output_has_bytes && ! output_ends_newline )); then
      printf '\n' >> "$registry_tmp"
    fi
  fi
  printf 'image\t%s\t%s\t%s\n' "$service" "$image_id" "$pr_number" >> "$registry_tmp"
  mv -f -- "$registry_tmp" "$registry"
  exit 0
fi

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
