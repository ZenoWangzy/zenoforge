#!/usr/bin/env bash
set -euo pipefail
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)/test-env.sh"

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
engine_dir="$(cd -- "$script_dir/../.." && pwd -P)"
fixture="$test_env_root/checkout-pr-head"
mkdir -p "$fixture"
source "$engine_dir/mac-autopilot/scheduler.d/clones.sh"

fail() { echo "checkout-pr-head.test.sh: $*" >&2; exit 1; }

git init -q --bare "$fixture/origin.git"
git init -q -b main "$fixture/source"
git -C "$fixture/source" config user.name t
git -C "$fixture/source" config user.email t@example.invalid
git -C "$fixture/source" remote add origin "$fixture/origin.git"
printf 'base\n' > "$fixture/source/base.txt"
git -C "$fixture/source" add base.txt
git -C "$fixture/source" commit -qm base
git -C "$fixture/source" push -q origin main
git -C "$fixture/source" checkout -q -b pr
git -C "$fixture/source" commit -q --allow-empty -m pr-head
pr_head="$(git -C "$fixture/source" rev-parse HEAD)"
git -C "$fixture/source" push -q origin pr:refs/heads/pr
git --git-dir="$fixture/origin.git" update-ref refs/pull/40/head "$pr_head"
git -C "$fixture/source" checkout -q main
printf 'main-only\n' > "$fixture/source/main-only.txt"
git -C "$fixture/source" add main-only.txt
git -C "$fixture/source" commit -qm main-only
git -C "$fixture/source" push -q origin main
main_head="$(git -C "$fixture/source" rev-parse HEAD)"
git --git-dir="$fixture/origin.git" symbolic-ref HEAD refs/heads/main

main_only_clone="$fixture/main-only-clone"
git clone -q "$fixture/origin.git" "$main_only_clone"
git -C "$main_only_clone" checkout -q -b agent/issue-1 refs/remotes/origin/main
if git -C "$main_only_clone" merge-base --is-ancestor "$main_head" "$pr_head"; then
  fail 'fixture main commit unexpectedly belongs to the PR history'
fi
checkout_pr_head "$main_only_clone" 40 "$pr_head" "$pr_head" agent/issue-1 \
  || fail 'branch at an origin/main commit was refused'
[[ "$(git -C "$main_only_clone" rev-parse refs/heads/agent/issue-1)" == "$pr_head" ]] \
  || fail 'origin/main-only branch did not move to the PR candidate'

unique_clone="$fixture/unique-clone"
git clone -q "$fixture/origin.git" "$unique_clone"
git -C "$unique_clone" checkout -q -b agent/issue-2 refs/remotes/origin/main
git -C "$unique_clone" config user.name t
git -C "$unique_clone" config user.email t@example.invalid
git -C "$unique_clone" commit -q --allow-empty -m unique-local
unique_head="$(git -C "$unique_clone" rev-parse HEAD)"
if checkout_pr_head "$unique_clone" 40 "$pr_head" "$pr_head" agent/issue-2; then
  fail 'branch with a unique local commit was accepted'
fi
[[ "$(git -C "$unique_clone" rev-parse refs/heads/agent/issue-2)" == "$unique_head" ]] \
  || fail 'refused branch with a unique local commit moved'

equal_clone="$fixture/equal-clone"
git clone -q "$fixture/origin.git" "$equal_clone"
git -C "$equal_clone" fetch -q origin refs/pull/40/head
git -C "$equal_clone" checkout -q -b agent/issue-3 "$pr_head"
checkout_pr_head "$equal_clone" 40 "$pr_head" "$pr_head" agent/issue-3 \
  || fail 'branch equal to the candidate was refused'
[[ "$(git -C "$equal_clone" rev-parse refs/heads/agent/issue-3)" == "$pr_head" ]] \
  || fail 'branch equal to the candidate changed'
[[ "$(git -C "$equal_clone" symbolic-ref --short HEAD)" == agent/issue-3 ]] \
  || fail 'branch equal to the candidate was detached'

echo 'checkout-pr-head.test.sh: all assertions passed'
