#!/usr/bin/env bash
# check-rebase.sh <repo> <old-head> <new-head>: refuse a rebased PR whose own patch changed in a file main did not touch.
# 10-29: a rebase-only worker flipped release_train.enabled to false in config.template.json (no conflict there) and edited the test to match.
set -uo pipefail
repo=$1 old=$2 new=$3
ob=$(git -C "$repo" merge-base "$old" origin/main) nb=$(git -C "$repo" merge-base "$new" origin/main)
main_changed=$(git -C "$repo" diff --name-only "$ob" "$nb")
out=$(for f in $(git -C "$repo" diff --name-only "$ob" "$old"; git -C "$repo" diff --name-only "$nb" "$new"); do
  a=$(git -C "$repo" diff "$ob" "$old" -- "$f" | git patch-id --stable | cut -d' ' -f1)
  b=$(git -C "$repo" diff "$nb" "$new" -- "$f" | git patch-id --stable | cut -d' ' -f1)
  [[ $a == "$b" ]] && continue
  grep -qxF "$f" <<<"$main_changed" && { echo "ok (main also changed): $f"; continue; }
  echo "CHANGED BY REBASE, main did not touch it: $f"
done | sort -u)
echo "$out"
! grep -q '^CHANGED BY REBASE' <<<"$out"
