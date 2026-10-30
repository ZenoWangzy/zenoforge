#!/usr/bin/env bash
# List open hotfix-labelled PRs nobody has pushed to for HF_STALE_MINUTES (default 30). Exit 1 if any.
# 10-29: #4576/#4587/#4588 sat red or conflicted for 6 h after a supervisor handover because open hotfix
# work lived only in session notes; GitHub's label is the queue, this makes an idle one loud.
set -euo pipefail
unset GH_TOKEN
limit=${HF_STALE_MINUTES:-30}
now=${HF_NOW:-$(date -u +%s)}
stale=$(gh pr list --label hotfix --state open --json number,title,updatedAt,isDraft \
  | jq -r --argjson now "$now" --argjson limit "$limit" \
    '.[] | select(.isDraft | not) | (($now - (.updatedAt | fromdateiso8601)) / 60 | floor) as $m
         | select($m >= $limit) | "#\(.number) idle \($m) min: \(.title)"')
[[ -z $stale ]] && exit 0
printf 'hf-stale: open hotfix PRs with no push for %s+ min:\n%s\n' "$limit" "$stale"
exit 1
