#!/usr/bin/env bash
set -euo pipefail
unset GH_TOKEN
branch=$(git symbolic-ref --quiet --short HEAD)
case "$branch" in hotfix/*|agent/issue-hf-*) ;; *) echo 'hf-pr: expected a hotfix branch' >&2; exit 1 ;; esac
# Hotfix workers bypass the scheduler's footprint mutex; #4681/#4682 changed one contract in opposite directions (10-29).
# Overlapping another open hotfix PR refuses until it merges (then rebase onto main), or HF_OVERLAP_ACK lists it after
# checking the two contracts agree. Never rebase onto an unmerged PR: #4689 did, and would have reverted 10 files.
mine=$(git diff --name-only origin/main...HEAD | sort)
clash=
while read -r n ref; do
  [[ -z $n || $ref == "$branch" ]] && continue
  both=$(comm -12 <(printf '%s\n' "$mine") <(gh pr view "$n" --json files -q '.files[].path' | sort))
  [[ -z $both ]] && continue
  [[ " ${HF_OVERLAP_ACK:-} " == *" $n "* ]] && continue
  clash+="#$n: ${both//$'\n'/ }"$'\n'
done < <(gh pr list --label hotfix --state open --json number,headRefName -q '.[]|"\(.number) \(.headRefName)"')
[[ -z $clash ]] || { printf 'hf-pr: overlaps open hotfix PRs; wait for them to merge and rebase onto main, or set HF_OVERLAP_ACK="<pr> ..." after checking the contracts agree (never rebase onto an unmerged PR):\n%s' "$clash" >&2; exit 1; }
gh pr create --base main --head "$branch" --label hotfix "$@"
