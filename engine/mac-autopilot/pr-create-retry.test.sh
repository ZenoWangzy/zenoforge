#!/usr/bin/env bash
set -euo pipefail
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/test-env.sh"
source "$(dirname -- "${BASH_SOURCE[0]}")/test-scheduler-gates-fixture.sh"
fail() { echo "pr-create-retry.test.sh: $*" >&2; exit 1; }
units() { printf '%s\n' "$1" > "$UNITS"; echo '{"workers":[]}' > "$WORKERS"; }
field() { jq -r --arg id "$1" ".units[] | select(.id==\$id) | $2" "$UNITS"; }
retry_count() { jq -r --arg id "$1" "[.units[] | select(.id==\$id) | (.history // [])[] | select(.stage==\"pr-create-retry\")] | length" "$UNITS"; }

fixture="$test_env_root/pr-create-retry"
origin="$fixture/origin.git"
seed="$fixture/seed"
GH_CALLS="$fixture/gh-calls"
WT_ROOT="$fixture/worktrees"
mkdir -p "$fixture" "$WT_ROOT"
command git init -q --bare -b main "$origin"
command git init -q -b main "$seed"
command git -C "$seed" config user.email t@example.invalid
command git -C "$seed" config user.name t
printf 'base\n' > "$seed/base.txt"
command git -C "$seed" add -A
command git -C "$seed" commit -qm base
command git -C "$seed" remote add origin "$origin"
command git -C "$seed" push -q origin main
command git -C "$seed" checkout -q -b stack/base
printf 'stack base\n' > "$seed/stack-base.txt"
command git -C "$seed" add -A
command git -C "$seed" commit -qm 'stack base'
command git -C "$seed" push -q origin stack/base
command git -C "$seed" checkout -q main

prepare_branch() { # unit branch → local worktree and pushed topic branch
  local id="$1" branch="$2" dir="$WT_ROOT/wt-$1"
  command git clone -q "$origin" "$dir"
  command git -C "$dir" config user.email t@example.invalid
  command git -C "$dir" config user.name t
  command git -C "$dir" checkout -q -b "$branch"
  printf '%s\n' "$id" > "$dir/$id.txt"
  command git -C "$dir" add -A
  command git -C "$dir" commit -qm "$id"
  command git -C "$dir" push -q origin "$branch"
}

# A failing create can still have made the PR; the post-failure census must adopt it.
GH_MODE=adopt
gh() {
  case "$1 $2" in
    'pr list')
      printf 'pr list\n' >> "$GH_CALLS"
      if [[ "$GH_MODE" == adopt ]] && grep -q '^pr create$' "$GH_CALLS"; then printf '4401 false\n'; fi
      ;;
    'pr create') printf 'pr create\n' >> "$GH_CALLS"; printf 'HTTP 502 Bad Gateway\n'; return 1 ;;
    *) return 0 ;;
  esac
}
prepare_branch adopt-1 agent/pr-create-adopt
printf 'implementation delivered\n' > "$sup/impl-adopt-1.md"
units '{"units":[{"id":"adopt-1","issue":1001,"title":"adopt after 502","branch":"agent/pr-create-adopt","lane":"pr","stage":"implement","history":[]}]}'
: > "$GH_CALLS"
harvest_pr_implement adopt-1 "$sup/impl-adopt-1.md" || :
[[ "$(field adopt-1 .stage)" == review-pending && "$(field adopt-1 .pr)" == 4401 ]] \
  || fail "the PR created during a 502 was not adopted ($(field adopt-1 .stage), pr=$(field adopt-1 .pr))"
[[ "$(grep -c '^pr create$' "$GH_CALLS")" == 1 && "$(grep -c '^pr list$' "$GH_CALLS")" == 2 ]] \
  || fail 'the failed create was not followed by exactly one open-PR lookup'
[[ "$(retry_count adopt-1)" == 0 ]] || fail 'adopting the PR consumed a retry'

# With no PR to adopt, the configured default allows three transient failures and escalates on the third.
GH_MODE=retry
prepare_branch retry-1 agent/pr-create-retry
printf 'implementation delivered\n' > "$sup/impl-retry-1.md"
units '{"units":[{"id":"retry-1","issue":1002,"title":"retry after 502","branch":"agent/pr-create-retry","lane":"pr","stage":"implement","history":[]}]}'
: > "$GH_CALLS"
harvest_pr_implement retry-1 "$sup/impl-retry-1.md" || :
[[ "$(field retry-1 .stage)" == implement && "$(retry_count retry-1)" == 1 ]] \
  || fail 'first transient failure did not leave the unit in implement with retry 1'
harvest_pr_implement retry-1 "$sup/impl-retry-1.md" || :
[[ "$(field retry-1 .stage)" == implement && "$(retry_count retry-1)" == 2 ]] \
  || fail 'second transient failure did not leave the unit in implement with retry 2'
harvest_pr_implement retry-1 "$sup/impl-retry-1.md" || :
[[ "$(field retry-1 .stage)" == supervisor-review && "$(retry_count retry-1)" == 3 ]] \
  || fail 'third transient failure did not escalate after the configured default of three'
[[ "$(field retry-1 .note)" == *'HTTP 502 Bad Gateway'* ]] || fail 'transient retry escalation lost the last create error'
[[ "$(grep -c '^pr create$' "$GH_CALLS")" == 3 ]] || fail 'transient failure did not retry PR creation once per attempt'

# A permanent create error retains the existing immediate supervisor route.
GH_MODE=permanent
prepare_branch permanent-1 agent/pr-create-permanent
printf 'implementation delivered\n' > "$sup/impl-permanent-1.md"
units '{"units":[{"id":"permanent-1","issue":1003,"title":"permanent create error","branch":"agent/pr-create-permanent","lane":"pr","stage":"implement","history":[]}]}'
: > "$GH_CALLS"
gh() {
  case "$1 $2" in
    'pr list') printf 'pr list\n' >> "$GH_CALLS" ;;
    'pr create') printf 'pr create\n' >> "$GH_CALLS"; printf 'GraphQL: Resource not accessible by integration\n'; return 1 ;;
    *) return 0 ;;
  esac
}
harvest_pr_implement permanent-1 "$sup/impl-permanent-1.md" || :
[[ "$(field permanent-1 .stage)" == supervisor-review && "$(retry_count permanent-1)" == 0 ]] \
  || fail 'a non-transient create error did not escalate immediately'
[[ "$(grep -c '^pr create$' "$GH_CALLS")" == 1 ]] || fail 'a non-transient create error was retried'

# A transient base-edit error is not a create failure and must not adopt the PR with the wrong base.
prepare_branch base-edit-1 agent/pr-create-base-edit
printf 'implementation delivered\n' > "$sup/impl-base-edit-1.md"
units '{"units":[{"id":"base-edit-1","issue":1004,"title":"retain stacked base","branch":"agent/pr-create-base-edit","lane":"pr","stage":"implement","stacked_on_branch":"stack/base","history":[]}]}'
: > "$GH_CALLS"
gh() {
  case "$1 $2" in
    'pr list') printf 'pr list\n' >> "$GH_CALLS"; printf '4402 false\n' ;;
    'pr edit') printf 'pr edit\n' >> "$GH_CALLS"; printf 'HTTP 502 Bad Gateway\n'; return 1 ;;
    'pr create') printf 'pr create\n' >> "$GH_CALLS"; printf 'should not create\n'; return 1 ;;
    *) return 0 ;;
  esac
}
harvest_pr_implement base-edit-1 "$sup/impl-base-edit-1.md" || :
[[ "$(field base-edit-1 .stage)" == supervisor-review && "$(retry_count base-edit-1)" == 0 ]] \
  || fail 'a base-edit failure was mistaken for a transient create failure'
[[ "$(grep -c '^pr create$' "$GH_CALLS" || true)" == 0 ]] \
  || fail 'a failed base edit retried create or advanced the PR with the wrong base'

pr_create_failure_transient 'connect ETIMEDOUT' 1 || fail 'ETIMEDOUT was not classified as transient'
pr_create_failure_transient '' 124 || fail 'exit code 124 was not classified as transient'

echo 'pr-create-retry.test.sh: PASS'
