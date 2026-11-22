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

# A hold older than three hours (counted from the unit's .pr_open_held.since) escalates with the reason and writes no new hold.
GH_MODE=backoff
stale_at="$(date -u -d "@$(( $(date -u -d "$STAMP" +%s) - 10860 ))" +%Y-%m-%dT%H:%M:%SZ)"
prepare_branch held-4 agent/pr-create-held-old
printf 'implementation delivered\n' > "$sup/impl-held-4.md"
units "{\"units\":[{\"id\":\"held-4\",\"issue\":1008,\"title\":\"held too long\",\"branch\":\"agent/pr-create-held-old\",\"lane\":\"pr\",\"stage\":\"implement\",\"pr_open_held\":{\"report\":\"$sup/impl-held-4.md\",\"since\":\"$stale_at\"},\"history\":[]}]}"
gh() {
  case "$1 $2" in
    'pr list') printf 'pr list\n' >> "$GH_CALLS" ;;
    'pr create') printf 'pr create\n' >> "$GH_CALLS"; printf 'gh: graphql rate-limit backoff active until epoch=1795309393 (rc 75)\n'; return 75 ;;
    *) return 0 ;;
  esac
}
harvest_pr_implement held-4 "$sup/impl-held-4.md" || :
[[ "$(field held-4 .stage)" == supervisor-review && "$(held_count held-4)" == 0 ]] \
  || fail "a three-hour back-off hold did not escalate ($(field held-4 .stage), held=$(held_count held-4)) log=$(tail -n 3 "$LOG" | tr '\n' '|') hist=$(jq -c --arg id held-4 '.units[] | select(.id==$id) | .history' "$UNITS")"
[[ "$(field held-4 .note)" == 'PR open held by GitHub back-off for 3 h on agent/pr-create-held-old: gh: graphql rate-limit backoff active until epoch=1795309393 (rc 75)' ]] \
  || fail "the three-hour escalation reason is wrong: $(field held-4 .note)"

pr_create_failure_transient 'connect ETIMEDOUT' 1 || fail 'ETIMEDOUT was not classified as transient'
pr_create_failure_transient '' 124 || fail 'exit code 124 was not classified as transient'

# ---- Round 2: an owed PR open is retried by recover_orphans on the finished clone, never by a new implement worker. ----
# Every case drives whole ticks through the real harvest_workers and the real recover_orphans (round 1 called harvest_pr_implement by hand).
alive() { return 1; }
tick_prs_prime() { :; }
tick_prs_changed() { :; }
incident_report_pre_review() { return 0; }
TICK_PRS=""
GH_GQL=refused GH_REST=refused
REST_ARGS="$fixture/rest-args"; : > "$REST_ARGS"
gh() {
  case "$1 $2" in
    'pr list') printf 'pr list\n' >> "$GH_CALLS"
      [[ "$GH_GQL" != refused ]] || { printf 'gh: graphql rate-limit backoff active until epoch=1795309393 (rc 75)\n' >&2; return 75; } ;;
    'pr create') printf 'pr create\n' >> "$GH_CALLS"
      case "$GH_GQL" in
        ok) printf 'https://github.com/example/repo/pull/4403\n' ;;
        5xx) printf 'HTTP 502 Bad Gateway\n'; return 1 ;;
        *) printf 'gh: graphql rate-limit backoff active until epoch=1795309393 (rc 75)\n'; return 75 ;;
      esac ;;
    'api repos/{owner}/{repo}/pulls') printf 'rest pulls\n' >> "$GH_CALLS"; printf '%s\n' "$*" >> "$REST_ARGS"
      [[ "$GH_REST" == ok ]] || { printf 'gh: rest rate-limit backoff active until epoch=1795309393 (rc 75)\n'; return 75; }
      printf '4410\n' ;;
    'api repos/{owner}/{repo}/issues/'*) printf 'rest label\n' >> "$GH_CALLS"; printf '%s\n' "$*" >> "$REST_ARGS" ;;
    *) return 0 ;;
  esac
}
tick() { # one tick is one process: its caches and its refused-call flag start empty
  HARVEST_COLLECT=() HARVEST_REPAIR_CLS=()
  unset PR_OPEN_REFUSED_THIS_TICK
  harvest_workers || :
  recover_orphans || :
}
calls() { grep -c "^$1\$" "$GH_CALLS" || true; }
ev() { jq -r --arg id "$1" --arg s "$2" '[.units[] | select(.id==$id) | (.history // [])[] | select(.stage==$s)] | length' "$UNITS"; }
worker_row() { jq -cn --arg u "$1" --arg d "$WT_ROOT/wt-$1" --argjson pid "$2" '{pid:$pid,unit:$u,type:"implement",log:"none.log",report:("impl-"+$u+".md"),workdir:$d,started:"2026-11-22T00:00:00Z"}'; }
fresh_unit() { # id branch extra-json → a unit whose implement worker has finished and pushed; the ledger holds that unit and its worker row
  prepare_branch "$1" "$2"
  printf 'implementation delivered\n' > "$sup/impl-$1.md"
  jq -cn --arg id "$1" --arg b "$2" --argjson extra "${3:-{\}}" '{units:[({id:$id,issue:2001,title:"owed PR open",branch:$b,lane:"pr",stage:"implement",history:[]} + $extra)]}' > "$UNITS"
  printf '{"workers":[%s]}\n' "$(worker_row "$1" 4301)" > "$WORKERS"
  : > "$GH_CALLS"
}
no_orphan_redo() { ! grep -q "orphan-recover unit=$1 " "$LOG" || fail "unit $1 was sent back to implement-pending: a new worker would redo the change"; }

# (a) tick 1: the create and the REST create are refused: held, one refused call, no escalation. Tick 2: the create works.
GH_GQL=refused GH_REST=refused
fresh_unit r2-a agent/r2-a
tick
[[ "$(field r2-a .stage)" == implement && "$(field r2-a '.pr_open_held.report')" == "$sup/impl-r2-a.md" && -n "$(field r2-a '.pr_open_held.since')" ]] \
  || fail "tick 1 did not hold the PR open ($(field r2-a .stage), $(field r2-a '.pr_open_held | tojson'))"
[[ "$(ev r2-a supervisor-escalated)" == 0 && "$(ev r2-a pr-create-held)" == 1 ]] || fail 'a refused PR open escalated or lost its hold event'
[[ "$(calls 'pr create')" == 1 && "$(calls 'rest pulls')" == 1 ]] || fail "recover_orphans made a second refused call in the tick of the hold (create=$(calls 'pr create'), rest=$(calls 'rest pulls'))"
[[ "$(jq '[.workers[] | select(.harvested == true)] | length' "$WORKERS")" == 1 ]] || fail 'the implement worker row was not harvested in tick 1'
GH_GQL=ok
tick
[[ "$(field r2-a .stage)" == review-pending && "$(field r2-a .pr)" == 4403 && "$(field r2-a '.pr_open_held // "gone"')" == gone ]] \
  || fail "tick 2 did not open the PR from recover_orphans ($(field r2-a .stage), pr=$(field r2-a .pr), held=$(field r2-a '.pr_open_held | tojson'))"
no_orphan_redo r2-a
[[ "$(jq '.workers | length' "$WORKERS")" == 1 ]] || fail 'a worker was dispatched for the retry'

# (b) tick 2 finds the branch's open PR in the census: adopted with no create call.
GH_GQL=refused GH_REST=refused
fresh_unit r2-b agent/r2-b
tick
[[ "$(field r2-b .stage)" == implement ]] || fail 'case b: tick 1 did not hold'
creates="$(calls 'pr create')"
TICK_PRS='[{"headRefName":"agent/r2-b","number":4405,"isDraft":false}]'
tick
TICK_PRS=""
[[ "$(field r2-b .stage)" == review-pending && "$(field r2-b .pr)" == 4405 && "$(ev r2-b supervisor-escalated)" == 0 ]] \
  || fail "the PR in the census was not adopted ($(field r2-b .stage), pr=$(field r2-b .pr))"
[[ "$(calls 'pr create')" == "$creates" ]] || fail 'adopting the census PR still called create'
no_orphan_redo r2-b

# (c) only the GraphQL back-off refuses: the REST create opens the PR at once; a gated branch gets a draft and the gated label.
GH_GQL=refused GH_REST=ok
: > "$REST_ARGS"
fresh_unit r2-c agent/issue-9103
tick
[[ "$(field r2-c .stage)" == review-pending && "$(field r2-c .pr)" == 4410 && "$(field r2-c .gated)" == true && "$(ev r2-c pr-create-held)" == 0 ]] \
  || fail "the REST create did not open the PR in tick 1 ($(field r2-c .stage), pr=$(field r2-c .pr))"
grep -qF -- '-F draft=true' "$REST_ARGS" && grep -qF -- 'head=agent/issue-9103' "$REST_ARGS" && grep -qF -- 'base=main' "$REST_ARGS" \
  || fail "the REST create lost the draft flag, head or base: $(cat "$REST_ARGS")"
grep -qF -- 'labels[]=agent/ci-gated' "$REST_ARGS" || fail 'the REST-created gated PR did not get the gated label'

# (d) two held units, the first retry is refused: the second unit makes no GitHub call in that tick.
GH_GQL=refused GH_REST=refused
now_iso="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
since_1h="$(date -u -d "@$(( $(date -u +%s) - 3600 ))" +%Y-%m-%dT%H:%M:%SZ)"
prepare_branch r2-d1 agent/r2-d1; prepare_branch r2-d2 agent/r2-d2
printf 'implementation delivered\n' > "$sup/impl-r2-d1.md"; printf 'implementation delivered\n' > "$sup/impl-r2-d2.md"
held_unit() { jq -cn --arg id "$1" --arg b "agent/$1" --arg rep "$sup/impl-$1.md" --arg since "$2" '{id:$id,issue:2100,title:"held unit",branch:$b,lane:"pr",stage:"implement",history:[],pr_open_held:{report:$rep,since:$since}}'; }
printf '{"units":[%s,%s]}\n' "$(held_unit r2-d1 "$since_1h")" "$(held_unit r2-d2 "$since_1h")" > "$UNITS"
echo '{"workers":[]}' > "$WORKERS"
: > "$GH_CALLS"
tick
[[ "$(ev r2-d1 pr-create-held)" == 1 && "$(field r2-d1 .stage)" == implement && "$(field r2-d1 .pr_open_held.since)" == "$since_1h" ]] \
  || fail "the first held unit was not retried and held again with its first since ($(field r2-d1 '.pr_open_held | tojson'))"
[[ "$(calls 'pr create')" == 1 && "$(calls 'pr list')" == 1 && "$(calls 'rest pulls')" == 1 ]] \
  || fail "the second held unit made a GitHub call in the tick of a refusal (list=$(calls 'pr list') create=$(calls 'pr create') rest=$(calls 'rest pulls'))"
[[ "$(ev r2-d2 pr-create-held)" == 0 && "$(field r2-d2 .stage)" == implement && "$(field r2-d2 .pr_open_held.since)" == "$since_1h" ]] || fail 'the skipped held unit changed'
no_orphan_redo r2-d2

# (e) a hold whose .pr_open_held.since is 3 h 1 min old escalates; a newer write-end event does not reset the bound.
stale_since="$(date -u -d "@$(( $(date -u +%s) - 10860 ))" +%Y-%m-%dT%H:%M:%SZ)"
fresh_unit r2-e agent/r2-e "$(jq -cn --arg rep "$sup/impl-r2-e.md" --arg since "$stale_since" --arg now "$now_iso" '{pr_open_held:{report:$rep,since:$since},history:[{stage:"write-end",result:"[]",at:$now}]}')"
echo '{"workers":[]}' > "$WORKERS" # a held unit's worker was harvested in the tick of the hold
tick
[[ "$(field r2-e .stage)" == supervisor-review && "$(field r2-e .note)" == 'PR open held by GitHub back-off for 3 h on agent/r2-e: '* && "$(field r2-e '.pr_open_held // "gone"')" == gone ]] \
  || fail "a 3 h 1 min hold did not escalate ($(field r2-e .stage), $(field r2-e .note))"

# (f) the 5xx branch retries through recover_orphans without a worker; the third failure escalates as before.
GH_GQL=5xx GH_REST=refused
fresh_unit r2-f agent/r2-f
tick
[[ "$(field r2-f .stage)" == implement && "$(retry_count r2-f)" == 1 && -n "$(field r2-f '.pr_open_held.report')" && "$(calls 'pr create')" == 1 ]] \
  || fail "the first 5xx did not leave an owed PR open ($(field r2-f .stage), retries=$(retry_count r2-f), creates=$(calls 'pr create'))"
tick
[[ "$(field r2-f .stage)" == implement && "$(retry_count r2-f)" == 2 && "$(calls 'pr create')" == 2 ]] || fail "the second 5xx was not retried by recover_orphans ($(field r2-f .stage), retries=$(retry_count r2-f))"
tick
[[ "$(field r2-f .stage)" == supervisor-review && "$(retry_count r2-f)" == 3 && "$(field r2-f '.pr_open_held // "gone"')" == gone && "$(calls 'pr create')" == 3 && "$(calls 'rest pulls')" == 0 ]] \
  || fail "the third 5xx did not escalate ($(field r2-f .stage), retries=$(retry_count r2-f))"
no_orphan_redo r2-f

# (g) units the old code escalated for a refused PR open come back to the owed-PR-open retry; others stay.
GH_GQL=refused GH_REST=refused
refused_reason='could not open a PR for agent/issue-7644: gh: graphql rate-limit backoff active until epoch=1795309393 (rc 75)'
esc_unit() { # id reason age-seconds
  jq -cn --arg id "$1" --arg reason "$2" --arg at "$(date -u -d "@$(( $(date -u +%s) - $3 ))" +%Y-%m-%dT%H:%M:%SZ)" \
    '{id:$id,issue:2200,title:"escalated",branch:("agent/"+$id),lane:"pr",stage:"supervisor-review",report:("impl-"+$id+".md"),history:[{stage:"write-end",result:"[]",at:$at},{stage:"supervisor-escalated",result:$reason,at:$at}]}'
}
for u in r2-ga r2-gb r2-gc r2-gd; do prepare_branch "$u" "agent/$u"; printf 'implementation delivered\n' > "$sup/impl-$u.md"; done
printf '{"units":[%s,%s,%s,%s]}\n' "$(esc_unit r2-ga "$refused_reason" 7200)" "$(esc_unit r2-gb "$refused_reason" 25200)" \
  "$(esc_unit r2-gc 'could not open a PR for agent/r2-gc: GraphQL: Resource not accessible by integration' 7200)" "$(esc_unit r2-gd "$refused_reason" 7200)" > "$UNITS"
jq -cn '{workers:[{pid:4399,unit:"r2-gd",type:"supervise",log:"none.log",report:"arbiter.md",harvested:false}]}' > "$WORKERS"
: > "$GH_CALLS"
unset PR_OPEN_REFUSED_THIS_TICK
recover_orphans || :
[[ "$(field r2-ga .stage)" == implement && "$(ev r2-ga pr-open-requeued)" == 1 && -n "$(field r2-ga '.pr_open_held.report')" && "$(ev r2-ga supervisor-escalated)" == 1 ]] \
  || fail "the unit escalated 2 h ago for the back-off was not requeued ($(field r2-ga .stage), requeued=$(ev r2-ga pr-open-requeued))"
for u in r2-gb r2-gc r2-gd; do
  [[ "$(field "$u" .stage)" == supervisor-review && "$(ev "$u" pr-open-requeued)" == 0 ]] || fail "unit $u must stay at supervisor-review"
done
no_orphan_redo r2-ga

# (h) the older cases above ran unchanged except that case e of round 1 now carries its first hold time in .pr_open_held.since.
echo 'pr-create-retry.test.sh: PASS'
