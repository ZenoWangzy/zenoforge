#!/usr/bin/env bash
# hf-source-check.sh <file>...: exit 0 only if every file is byte-identical to a blob in origin/main
# or in the head of an open `hotfix`-labelled PR. 10-29: a regex intent router (#4505, never merged)
# lived in prod for 9 h because later live patches were built on the live file; anonymous code is refused.
set -euo pipefail
unset GH_TOKEN
(($#)) || { echo 'usage: hf-source-check.sh <file>...' >&2; exit 2; }
git fetch -q origin main
refs=(origin/main)
while read -r n sha; do
  git fetch -q origin "pull/$n/head" && refs+=("$sha")
done < <(gh pr list --label hotfix --state open --json number,headRefOid -q '.[] | "\(.number) \(.headRefOid)"')
known=$(for r in "${refs[@]}"; do git ls-tree -r "$r" | awk '{print $3}'; done | sort -u)
rc=0
for f in "$@"; do
  b=$(git hash-object "$f")
  if grep -qx "$b" <<<"$known"; then echo "hf-source-check: ok $f ($b)"; else echo "hf-source-check: REFUSED $f ($b) matches no blob in origin/main or an open hotfix PR head" >&2; rc=1; fi
done
exit $rc
