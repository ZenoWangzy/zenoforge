#!/usr/bin/env bash
set -euo pipefail
effect_key="${2:-}"
[[ "$effect_key" =~ ^comment:([1-9][0-9]*):([A-Za-z0-9._:-]+)$ ]] || exit 3
issue="${BASH_REMATCH[1]}"
repo="${REPO:-${ZF_REPO:?ZF_REPO is not set}}"
marker="<!-- zf-intent:$effect_key -->"
comments="$(gh api --paginate --slurp "repos/$repo/issues/$issue/comments")" || exit 3
jq -e 'type == "array" and all(.[]; type == "array")
  and all(.[][]; type == "object" and (.body | type == "string"))' \
  <<<"$comments" >/dev/null 2>&1 || exit 3
jq -e --arg marker "$marker" '[.[][] | select(.body | contains($marker))] | length > 0' \
  <<<"$comments" >/dev/null 2>&1 || exit 2
jq -cn --argjson issue "$issue" --arg marker "$marker" '{issue:$issue,marker:$marker}'
