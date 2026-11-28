#!/usr/bin/env bash
set -euo pipefail
source "$(dirname -- "${BASH_SOURCE[0]}")/../../lib.d/transport.sh"
effect_key="${2:-}"
[[ "$effect_key" =~ ^merge:pr-([1-9][0-9]*)$ ]] || exit 3
pr="${BASH_REMATCH[1]}"
record="$(gh pr view "$pr" --repo "${REPO:-${ZF_REPO:?ZF_REPO is not set}}" --json state,mergeCommit)" || exit 3
jq -e 'type == "object" and (.state | type == "string")' <<<"$record" >/dev/null || exit 3
state="$(jq -r '.state' <<<"$record")"
if [[ "$state" == MERGED ]]; then
  merge_commit="$(jq -r '.mergeCommit.oid // empty' <<<"$record")"
  [[ "$merge_commit" =~ ^[0-9a-f]{40,64}$ ]] || exit 3
  jq -cn --arg merge_commit "$merge_commit" '{merge_commit:$merge_commit}'
  exit 0
fi
[[ "$state" == OPEN ]] && exit 1
exit 2
