#!/usr/bin/env bash
# hf-source-check.sh <file>...: exit 0 only if every file is byte-identical to a blob in origin/main
# or in the head of an open `hotfix`-labelled PR. 10-29: a regex intent router (#4505, never merged)
# lived in prod for 9 h because later live patches were built on the live file; anonymous code is refused.
set -euo pipefail
unset GH_TOKEN
(($#)) || { echo 'usage: hf-source-check.sh <file>...' >&2; exit 2; }
rc=0
for f in "$@"; do
  if ! repo=$(git -C "$(dirname -- "$f")" rev-parse --show-toplevel 2>/dev/null); then
    echo "hf-source-check: REFUSED $f (cannot resolve a git repository for file)" >&2
    rc=1
    continue
  fi
  file_path=$f
  [[ $file_path == /* ]] || file_path=$PWD/$file_path
  git -C "$repo" fetch -q origin main
  refs=(origin/main)
  while read -r n sha; do
    git -C "$repo" fetch -q origin "pull/$n/head" && refs+=("$sha")
  done < <(cd "$repo" && gh pr list --label hotfix --state open --json number,headRefOid -q '.[] | "\(.number) \(.headRefOid)"')
  known=$(for r in "${refs[@]}"; do git -C "$repo" ls-tree -r "$r" | awk '{print $3}'; done | sort -u)
  b=$(git -C "$repo" hash-object -- "$file_path")
  if grep -qx "$b" <<<"$known"; then echo "hf-source-check: ok $f ($b)"; else echo "hf-source-check: REFUSED $f ($b) matches no blob in origin/main or an open hotfix PR head" >&2; rc=1; fi
done
exit $rc
