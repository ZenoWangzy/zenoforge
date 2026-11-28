#!/usr/bin/env bash
set -euo pipefail
effect_key="${2:-}"
[[ "$effect_key" =~ ^revert:([0-9a-f]{12})$ ]] || exit 3
sha="${BASH_REMATCH[1]}"
output="$(git -C "${REPO_DIR:-${ZF_REPO_DIR:?ZF_REPO_DIR is not set}}" \
  ls-remote --heads origin "refs/heads/agent/revert-main-*-$sha")" || exit 3
[[ -n "$output" ]] || exit 1
branch=""
while IFS=$'\t' read -r oid ref extra; do
  [[ "$oid" =~ ^[0-9a-f]{40,64}$ && "$ref" =~ ^refs/heads/agent/revert-main-[1-9][0-9]*-$sha$ \
    && -z "${extra:-}" ]] || exit 3
  branch="${ref#refs/heads/}"
done <<<"$output"
[[ -n "$branch" ]] || exit 3
jq -cn --arg branch "$branch" '{branch:$branch}'
