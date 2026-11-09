#!/usr/bin/env bash
# A requeue to repair with no red check and no open P0/P1 finding routes to CI admission (approved head) or review, never to repair.
# Refs queue row 120 (2026-11-08: issue-5306 went to repair three times with cancelled checks and no finding).
set -euo pipefail
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/test-env.sh"

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
fixture="$test_env_root/no-finding-repair-route"
sup="$fixture/supervisor"
mkdir -p "$sup/autopi/alerts" "$fixture/repo"
jq '.auto_merge = false | .advisor = false | .precheck = false' \
  "$script_dir/config.template.json" > "$sup/autopi/config.json"
printf '%s\n' '{"units":[]}' > "$sup/autopi/units.json"
printf '%s\n' '{"workers":[]}' > "$sup/autopi/workers.json"
export MAC_AUTOPILOT_ROOT="$fixture/repo" MAC_AUTOPILOT_SUPERVISOR_DIR="$sup" MAC_AUTOPILOT_RUNTIME_DIR="$sup/autopi"
export REQUIRED_PR_CHECKS_FILE="$fixture/required-pr-checks.json"
printf '%s\n' '{"required":[],"current_regression":"","legacy_regression":[]}' > "$REQUIRED_PR_CHECKS_FILE"
export AUTOPI_TEST_LIBRARY_ONLY=true
source "$script_dir/scheduler.sh"
unset AUTOPI_TEST_LIBRARY_ONLY
SCHED_LOCK_HELD=true

fail() { printf 'no-finding-repair-route.test.sh: %s\n' "$*" >&2; exit 1; }
field() { jq -r --arg id "$1" ".units[] | select(.id==\$id) | $2" "$UNITS"; }
head_now=1111111111111111111111111111111111111111
head_old=2222222222222222222222222222222222222222
ROWS='[]'
# Stubs for the census-backed lookups: the current head, mergeability and the check rows of the PR.
tick_pr_head() { printf '%s' "$head_now"; }
tick_pr_mergeable() { printf '%s' MERGEABLE; }
repair_check_rows() { printf '%s' "$ROWS"; }
pass_row='[{"name":"gate","bucket":"pass","link":""}]'
cancel_row='[{"name":"gate","bucket":"cancel","link":""}]'
red_row='[{"name":"gate","bucket":"fail","link":""}]'
p1_open='[{"id":"F1","severity":"P1","status":"open"}]'

# One unit per case; each case calls supervisor_requeue_unit (action requeue) once.
jq -n --arg now "$head_now" --arg old "$head_old" --argjson p1 "$p1_open" '{units:[
  {id:"pr-approved-cancel",pr:7,lane:"pr",branch:"agent/a",stage:"repair-pending",
    history:[{stage:"review-approve",result:$now},{stage:"repair-delivered"}]},
  {id:"pr-stale-approval",pr:8,lane:"pr",branch:"agent/b",stage:"repair-pending",
    history:[{stage:"review-approve",result:$old},{stage:"repair-delivered"}]},
  {id:"pr-no-review-green",pr:9,lane:"pr",branch:"agent/c",stage:"repair-pending",
    history:[{stage:"repair-delivered"}]},
  {id:"pr-red",pr:10,lane:"pr",branch:"agent/d",stage:"repair-pending",
    history:[{stage:"review-approve",result:$now},{stage:"repair-delivered"}]},
  {id:"pr-open-p1",pr:11,lane:"pr",branch:"agent/e",stage:"repair-pending",
    history:[{stage:"review-request-changes",result:$now}],
    reviewed_sha:$now,reviewed_pr_head:$now,
    review_findings:[{round:1,block:"ok",findings:$p1,all_findings:$p1}]},
  {id:"pr-land-failed",pr:12,lane:"pr",branch:"agent/f",stage:"repair-pending",
    history:[{stage:"review-approve",result:$now},{stage:"land-failed",result:"push rejected"}]}
]}' > "$UNITS"
printf '%s\n' '{"workers":[]}' > "$WORKERS"

# 1. Cancelled checks, no open finding, approval on the current head: CI admission, not repair.
ROWS="$cancel_row"; supervisor_requeue_unit pr-approved-cancel requeue 'resume' null
[[ "$(field pr-approved-cancel .stage)" == ready-to-merge ]] \
  || fail "cancelled checks with no finding and the current head approved must go to CI admission, not repair (got: $(field pr-approved-cancel .stage))"
[[ "$(field pr-approved-cancel .approved_sha)" == "$head_now" ]] || fail 'CI admission must carry the approved head'
# The cancelled runs are rerun by the merge lane's ci_cancelled on ready-to-merge units: exactly one rerun call for this head.
reruns="$fixture/reruns"; : > "$reruns"
gh() { if [[ "$1 $2" == "run list" ]]; then echo 555; elif [[ "$1 $2" == "run rerun" ]]; then echo "$3" >> "$reruns"; fi; }
ci_cancelled pr-approved-cancel 7 "$head_now" gate
[[ "$(wc -l < "$reruns")" == 1 && "$(cat "$reruns")" == 555 ]] || fail "a cancelled ready-to-merge head must get exactly one rerun (got: $(cat "$reruns"))"
unset -f gh

# 2. Cancelled checks, approval only on an older head: the current head needs a review first.
ROWS="$cancel_row"; supervisor_requeue_unit pr-stale-approval requeue 'resume' null
[[ "$(field pr-stale-approval .stage)" == review-pending ]] \
  || fail "a stale approval must send the current head to review, not CI admission (got: $(field pr-stale-approval .stage))"

# 3. Green checks, no review at all: review.
ROWS="$pass_row"; supervisor_requeue_unit pr-no-review-green requeue 'resume' null
[[ "$(field pr-no-review-green .stage)" == review-pending ]] \
  || fail "green checks with no current review must go to review (got: $(field pr-no-review-green .stage))"

# 4. A red required check still goes to repair.
ROWS="$red_row"; supervisor_requeue_unit pr-red requeue 'fix the red gate' null
[[ "$(field pr-red .stage)" == repair-pending ]] \
  || fail "a red check must still go to repair (got: $(field pr-red .stage))"

# 5. An open P1 finding still goes to repair, even with cancelled checks.
ROWS="$cancel_row"; supervisor_requeue_unit pr-open-p1 requeue 'repair the finding' null
[[ "$(field pr-open-p1 .stage)" == repair-pending ]] \
  || fail "an open P1 finding must still go to repair (got: $(field pr-open-p1 .stage))"

# 6. A land failure carries its own repair reason, so it stays in repair even with green checks and an approval.
ROWS="$pass_row"; supervisor_requeue_unit pr-land-failed requeue 'fix the land failure' null
[[ "$(field pr-land-failed .stage)" == repair-pending ]] \
  || fail "a land failure must stay in repair (got: $(field pr-land-failed .stage))"

echo 'no-finding-repair-route.test.sh: ok'
