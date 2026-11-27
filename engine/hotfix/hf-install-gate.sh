#!/usr/bin/env bash
set -euo pipefail
unset GH_TOKEN
[[ $# == 1 && $1 =~ ^[0-9]+$ ]] || { echo 'usage: hf-install-gate.sh <pr-number>' >&2; exit 3; }
info=$(gh pr view "$1" --json state,mergeCommit) || { echo 'hf-install-gate: cannot read PR' >&2; exit 3; }
merge=$(jq -r 'select(.state == "MERGED") | .mergeCommit.oid // empty' <<<"$info")
[[ -n "$merge" ]] || { echo 'hf-install-gate: PR has no merge commit' >&2; exit 3; }
git fetch -q origin main || { echo 'hf-install-gate: cannot fetch main' >&2; exit 3; }
git merge-base --is-ancestor "$merge" origin/main || { echo 'hf-install-gate: merge is not on main' >&2; exit 3; }
runs=$(gh run list --workflow CI --branch main --event push --status success --limit 100 --json databaseId,headSha,conclusion,status,event,workflowName) || { echo 'hf-install-gate: cannot read CI runs' >&2; exit 3; }
while IFS=$'\t' read -r id sha; do
  if git merge-base --is-ancestor "$merge" "$sha" && git merge-base --is-ancestor "$sha" origin/main; then
    jobs=$(gh run view "$id" --json jobs) || continue
    if jq -e '.jobs | any(.name == "Postsubmit validate" and .status == "completed" and .conclusion == "success")' <<<"$jobs" >/dev/null; then
      echo "hf-install-gate: green main Postsubmit at $sha includes PR #$1"
      exit 0
    fi
  fi
done < <(jq -r '.[] | select(.status == "completed" and .conclusion == "success" and .event == "push" and .workflowName == "CI") | [.databaseId, .headSha] | @tsv' <<<"$runs")
echo 'hf-install-gate: no green main CI includes the merge commit' >&2
exit 3
