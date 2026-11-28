#!/usr/bin/env bash
set -euo pipefail
effect_key="${2:-}"
[[ "$effect_key" =~ ^push:([A-Za-z0-9._/@+.-]+)$ ]] || exit 3
branch="${BASH_REMATCH[1]}"
git check-ref-format "refs/heads/$branch" || exit 3
output="$(git -C "${REPO_DIR:-${ZF_REPO_DIR:?ZF_REPO_DIR is not set}}" ls-remote --heads origin "$branch")" || exit 3
[[ -n "$output" ]] || exit 1
IFS=$'\t' read -r oid ref extra <<<"$output"
[[ "$output" != *$'\n'* && "$oid" =~ ^[0-9a-f]{40,64}$ \
  && "$ref" == "refs/heads/$branch" && -z "${extra:-}" ]] || exit 3
jq -cn --arg branch "$branch" '{branch:$branch}'
