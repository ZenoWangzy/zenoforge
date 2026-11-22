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

# A GitHub back-off refusal holds the unit at implement (no supervisor, no retry count) until the create goes through.
held_count() { jq -r --arg id "$1" "[.units[] | select(.id==\$id) | (.history // [])[] | select(.stage==\"pr-create-held\")] | length" "$UNITS"; }
GH_MODE=backoff
gh() {
  case "$1 $2" in
    'pr list') printf 'pr list\n' >> "$GH_CALLS" ;;
    'pr create') printf 'pr create\n' >> "$GH_CALLS"
      if [[ "$GH_MODE" == backoff ]]; then printf 'gh: graphql rate-limit backoff active until epoch=1795309393 (rc 75)\n'; return 75; fi
      if [[ "$GH_MODE" == secondary ]]; then printf 'gh: graphql secondary rate limit; shared backoff 60s until epoch=1795309393\nerror fetching labels: non-200 OK status code: 403\n'; return 75; fi
      printf 'https://github.com/example/repo/pull/4403\n' ;;
    'pr edit') printf 'pr edit\n' >> "$GH_CALLS"; printf 'gh: graphql rate-limit backoff active until epoch=1795309393 (rc 75)\n'; return 75 ;;
    *) return 0 ;;
  esac
}
prepare_branch held-1 agent/pr-create-held
printf 'implementation delivered\n' > "$sup/impl-held-1.md"
units '{"units":[{"id":"held-1","issue":1005,"title":"held by back-off","branch":"agent/pr-create-held","lane":"pr","stage":"implement","history":[]}]}'
: > "$GH_CALLS"
harvest_pr_implement held-1 "$sup/impl-held-1.md" || :
[[ "$(field held-1 .stage)" == implement && "$(retry_count held-1)" == 0 && "$(held_count held-1)" == 1 ]] \
  || fail "a create refused by the back-off was not held ($(field held-1 .stage), retries=$(retry_count held-1), held=$(held_count held-1))"
grep -qF 'unit held-1 PR open held by GitHub back-off on agent/pr-create-held; retry next tick' "$LOG" \
  || fail 'a held back-off refusal did not log the retry line'
harvest_pr_implement held-1 "$sup/impl-held-1.md" || :
[[ "$(field held-1 .stage)" == implement && "$(held_count held-1)" == 1 ]] \
  || fail 'a second back-off refusal added another pr-create-held event'

# The adopt read (stacked base edit) can be the refused call: no create is attempted, the hold still applies.
GH_MODE=backoff
prepare_branch held-2 agent/pr-create-held-adopt
printf 'implementation delivered\n' > "$sup/impl-held-2.md"
units '{"units":[{"id":"held-2","issue":1006,"title":"held on adopt","branch":"agent/pr-create-held-adopt","lane":"pr","stage":"implement","stacked_on_branch":"stack/base","history":[]}]}'
: > "$GH_CALLS"
gh() {
  case "$1 $2" in
    'pr list') printf 'pr list\n' >> "$GH_CALLS"; printf '4404 false\n' ;;
    'pr edit') printf 'pr edit\n' >> "$GH_CALLS"; printf 'gh: graphql rate-limit backoff active until epoch=1795309393 (rc 75)\n'; return 75 ;;
    'pr create') printf 'pr create\n' >> "$GH_CALLS"; return 1 ;;
    *) return 0 ;;
  esac
}
harvest_pr_implement held-2 "$sup/impl-held-2.md" || :
[[ "$(field held-2 .stage)" == implement && "$(retry_count held-2)" == 0 && "$(held_count held-2)" == 1 ]] \
  || fail "a refused adopt read was not held ($(field held-2 .stage), held=$(held_count held-2))"
[[ "$(grep -c '^pr create$' "$GH_CALLS" || true)" == 0 ]] || fail 'a refused adopt read still attempted create'

# The secondary-limit 403 that meets the back-off returns rc 75 with its own text.
GH_MODE=secondary
prepare_branch held-3 agent/pr-create-held-secondary
printf 'implementation delivered\n' > "$sup/impl-held-3.md"
units '{"units":[{"id":"held-3","issue":1007,"title":"held on secondary limit","branch":"agent/pr-create-held-secondary","lane":"pr","stage":"implement","history":[]}]}'
: > "$GH_CALLS"
gh() {
  case "$1 $2" in
    'pr list') printf 'pr list\n' >> "$GH_CALLS" ;;
    'pr create') printf 'pr create\n' >> "$GH_CALLS"; printf 'gh: graphql secondary rate limit; shared backoff 60s until epoch=1795309393\nerror fetching labels: non-200 OK status code: 403\n'; return 75 ;;
    *) return 0 ;;
  esac
}
harvest_pr_implement held-3 "$sup/impl-held-3.md" || :
[[ "$(field held-3 .stage)" == implement && "$(retry_count held-3)" == 0 && "$(held_count held-3)" == 1 ]] \
  || fail "a secondary-limit refusal was not held ($(field held-3 .stage), held=$(held_count held-3))"

# After a hold the next create succeeds and the PR number is recorded.
GH_MODE=ok
units "{\"units\":[{\"id\":\"held-1\",\"issue\":1005,\"title\":\"held by back-off\",\"branch\":\"agent/pr-create-held\",\"lane\":\"pr\",\"stage\":\"implement\",\"history\":[{\"stage\":\"pr-create-held\",\"result\":\"held\",\"at\":\"$(date -u +%Y-%m-%dT%H:%M:%SZ)\"}]}]}"
gh() {
  case "$1 $2" in
    'pr list') printf 'pr list\n' >> "$GH_CALLS" ;;
    'pr create') printf 'pr create\n' >> "$GH_CALLS"; printf 'https://github.com/example/repo/pull/4403\n' ;;
    *) return 0 ;;
  esac
}
harvest_pr_implement held-1 "$sup/impl-held-1.md" || :
[[ "$(field held-1 .stage)" == review-pending && "$(field held-1 .pr)" == 4403 ]] \
  || fail "the create after a back-off hold did not record the PR ($(field held-1 .stage), pr=$(field held-1 .pr))"

# A hold older than three hours escalates with the reason and writes no new hold.
GH_MODE=backoff
stale_at="$(date -u -d "@$(( $(date -u -d "$STAMP" +%s) - 10860 ))" +%Y-%m-%dT%H:%M:%SZ)"
prepare_branch held-4 agent/pr-create-held-old
printf 'implementation delivered\n' > "$sup/impl-held-4.md"
units "{\"units\":[{\"id\":\"held-4\",\"issue\":1008,\"title\":\"held too long\",\"branch\":\"agent/pr-create-held-old\",\"lane\":\"pr\",\"stage\":\"implement\",\"history\":[{\"stage\":\"pr-create-held\",\"result\":\"old\",\"at\":\"$stale_at\"}]}]}"
gh() {
  case "$1 $2" in
    'pr list') printf 'pr list\n' >> "$GH_CALLS" ;;
    'pr create') printf 'pr create\n' >> "$GH_CALLS"; printf 'gh: graphql rate-limit backoff active until epoch=1795309393 (rc 75)\n'; return 75 ;;
    *) return 0 ;;
  esac
}
harvest_pr_implement held-4 "$sup/impl-held-4.md" || :
[[ "$(field held-4 .stage)" == supervisor-review && "$(held_count held-4)" == 1 ]] \
  || fail "a three-hour back-off hold did not escalate ($(field held-4 .stage), held=$(held_count held-4)) log=$(tail -n 3 "$LOG" | tr '\n' '|') hist=$(jq -c --arg id held-4 '.units[] | select(.id==$id) | .history' "$UNITS")"
[[ "$(field held-4 .note)" == 'PR open held by GitHub back-off for 3 h on agent/pr-create-held-old: gh: graphql rate-limit backoff active until epoch=1795309393 (rc 75)' ]] \
  || fail "the three-hour escalation reason is wrong: $(field held-4 .note)"

pr_create_failure_transient 'connect ETIMEDOUT' 1 || fail 'ETIMEDOUT was not classified as transient'
pr_create_failure_transient '' 124 || fail 'exit code 124 was not classified as transient'

echo 'pr-create-retry.test.sh: PASS'
