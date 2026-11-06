#!/usr/bin/env bash
# Focused regression for accounting and routing empty repair rounds.
set -euo pipefail
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/test-env.sh"

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
fixture="$test_env_root/noop-repair-rounds"
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

fail() { printf 'noop-repair-rounds.test.sh: %s\n' "$*" >&2; exit 1; }
units() { printf '%s\n' "$1" > "$UNITS"; printf '%s\n' '{"workers":[]}' > "$WORKERS"; }
field() { jq -r --arg id "$1" ".units[] | select(.id==\$id) | $2" "$UNITS"; }
sha1=1111111111111111111111111111111111111111
sha2=2222222222222222222222222222222222222222
now="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

# Replay: implement + a real repair, followed by an empty review and a repair
# that delivered no new head. The three write-starts must spend only two rounds.
replay="$(jq -cn --arg sha1 "$sha1" --arg sha2 "$sha2" --arg at "$now" '{
  units:[{id:"pr-noop",pr:91,lane:"pr",branch:"agent/pr-noop",stage:"supervisor-review",
    reviewed_sha:$sha2,reviewed_pr_head:$sha2,
    review_findings:[
      {round:1,block:"ok",findings:[{id:"F1",severity:"P1",status:"open"}],all_findings:[{id:"F1",severity:"P1",status:"open"}]},
      {round:2,block:"ok",findings:[],all_findings:[]}
    ],
    history:[
      {stage:"write-start",work_type:"implement",at:$at},
      {stage:"review-request-changes",result:$sha1},
      {stage:"write-start",work_type:"repair",at:$at},
      {stage:"repair-delivered"},
      {stage:"review-request-changes",result:$sha2},
      {stage:"write-start",work_type:"repair",at:$at},
      {stage:"repair-delivered"},
      {stage:"repair-no-push",result:("head "+$sha2+" unchanged after repair")}
    ]
  }]
}')"
unit="$(jq -c '.units[0]' <<<"$replay")"
TICKET_ROUND_BUDGET=2
[[ "$(ticket_budget_reason "$unit")" == 'rounds 2 of 2' ]] \
  || fail "the findings-less unchanged repair must be excluded so exactly two rounds count (got: $(ticket_budget_reason "$unit"))"
TICKET_ROUND_BUDGET=3
[[ -z "$(ticket_budget_reason "$unit")" ]] \
  || fail "three write-starts with one findings-less no-op must not trip 3 of 3 (got: $(ticket_budget_reason "$unit"))"
[[ "$(repair_rounds_since_ruling "$unit")" == 1 ]] \
  || fail "the no-op repair must not consume the repair cap (got: $(repair_rounds_since_ruling "$unit"))"
mismatched_head="$(jq -c --arg sha "$sha1" '.units[0] | .history[-1].result=("head "+$sha+" unchanged after repair")' <<<"$replay")"
TICKET_ROUND_BUDGET=3
[[ "$(ticket_budget_reason "$mismatched_head")" == 'rounds 3 of 3' && "$(repair_rounds_since_ruling "$mismatched_head")" == 2 ]] \
  || fail 'a no-push event naming a different SHA must remain counted'

# The same history must requeue to a fresh rereview, not another empty repair.
units "$replay"
supervisor_requeue_unit pr-noop requeue 'fresh independent review' null
[[ "$(field pr-noop .stage)" == rereview-pending ]] \
  || fail "an unchanged head after a findings-less review must requeue to rereview-pending (got: $(field pr-noop .stage))"
[[ "$(field pr-noop .reviewed_sha)" == null && "$(field pr-noop .reviewed_pr_head)" == null ]] \
  || fail 'the fresh rereview must clear the prior reviewed-head pair'
[[ "$(field pr-noop '.history[-1].stage')" == supervisor-requeue ]] \
  || fail 'rereview requeue must keep its supervisor-requeue history entry'

# A valid no-actionable review with no intervening write is also sent directly
# to a fresh reviewer.
empty_review="$(jq -cn --arg sha "$sha1" '{units:[{id:"pr-empty",pr:93,lane:"pr",branch:"agent/pr-empty",stage:"supervisor-review",
  reviewed_sha:$sha,reviewed_pr_head:$sha,review_findings:[{round:1,block:"ok",findings:[],all_findings:[]}],
  history:[{stage:"review-request-changes",result:$sha}]}]}')"
units "$empty_review"
supervisor_requeue_unit pr-empty requeue 'fresh independent review' null
[[ "$(field pr-empty .stage)" == rereview-pending ]] \
  || fail 'a no-actionable unchanged review must requeue to rereview-pending'

# A repair that made no push also gets a fresh review, even when its triggering
# review did contain an actionable finding.
noop_with_finding="$(jq -cn --arg sha "$sha1" --arg at "$now" '{units:[{id:"pr-no-push",pr:94,lane:"pr",branch:"agent/pr-no-push",stage:"supervisor-review",
  reviewed_sha:$sha,reviewed_pr_head:$sha,
  review_findings:[{round:1,block:"ok",findings:[{id:"F1",severity:"P1",status:"open"}],all_findings:[{id:"F1",severity:"P1",status:"open"}]}],
  history:[{stage:"review-request-changes",result:$sha},{stage:"write-start",work_type:"repair",at:$at},
    {stage:"repair-delivered"},{stage:"repair-no-push",result:("head "+$sha+" unchanged after repair")}]}]}')"
noop_with_finding_unit="$(jq -c '.units[0]' <<<"$noop_with_finding")"
TICKET_ROUND_BUDGET=1
[[ "$(ticket_budget_reason "$noop_with_finding_unit")" == 'rounds 1 of 1' && "$(repair_rounds_since_ruling "$noop_with_finding_unit")" == 1 ]] \
  || fail 'a repair-no-push after an actionable finding must still count as a failed repair'
units "$noop_with_finding"
supervisor_requeue_unit pr-no-push requeue 'fresh independent review' null
[[ "$(field pr-no-push .stage)" == rereview-pending ]] \
  || fail 'a confirmed no-push repair must requeue to rereview-pending'

# A real unresolved finding and a delivered repair remain counted and return to repair.
real="$(jq -cn --arg sha1 "$sha1" --arg sha2 "$sha2" --arg at "$now" '{units:[{id:"pr-real",pr:92,lane:"pr",branch:"agent/pr-real",stage:"supervisor-review",
  reviewed_sha:$sha2,reviewed_pr_head:$sha2,
  review_findings:[
    {round:1,block:"ok",findings:[{id:"F1",severity:"P1",status:"open"}],all_findings:[{id:"F1",severity:"P1",status:"open"}]},
    {round:2,block:"ok",findings:[{id:"F1",severity:"P1",status:"open"}],all_findings:[{id:"F1",severity:"P1",status:"open"}]}
  ],
  history:[{stage:"review-request-changes",result:$sha1},{stage:"write-start",work_type:"repair",at:$at},
    {stage:"repair-delivered"},{stage:"review-request-changes",result:$sha2}]}]}')"
real_unit="$(jq -c '.units[0]' <<<"$real")"
[[ "$(repair_rounds_since_ruling "$real_unit")" == 1 ]] \
  || fail 'a real failed repair must still consume one repair round'
TICKET_ROUND_BUDGET=1
[[ "$(ticket_budget_reason "$real_unit")" == 'rounds 1 of 1' ]] \
  || fail 'a real failed repair must still consume the stop-loss budget'
units "$real"
supervisor_requeue_unit pr-real requeue 'repair the open finding' null
[[ "$(field pr-real .stage)" == repair-pending ]] \
  || fail "a real failed repair must still requeue to repair-pending (got: $(field pr-real .stage))"

# The wall counts worker time, not queue: 2295 read 1688min after 1 round and was stopped on arrival.
wall_unit() { # history-json stage → budget reason
  TICKET_ROUND_BUDGET=3 TICKET_WALL_BUDGET_SECONDS=14400 NOW_EPOCH=1800000000 ticket_budget_reason "$(jq -cn --argjson h "$1" --arg stage "$2" '{stage:$stage,history:$h}')"
}
day() { date -u -d "@$(( 1800000000 - $1 ))" +%Y-%m-%dT%H:%M:%SZ; }
released_days_later="$(jq -cn --arg s "$(day 864000)" --arg e "$(day 863400)" '[{stage:"write-start",work_type:"repair",at:$s},{stage:"write-end",at:$e},{stage:"blocked-on",result:"#1"},{stage:"unblocked",result:"#1 delivered"}]')"
[[ -z "$(wall_unit "$released_days_later" repair-pending)" ]] || fail "a unit released after days with 10min of work must not stop on arrival: $(wall_unit "$released_days_later" repair-pending)"
three_rounds="$(jq -cn --arg s "$(day 864000)" --arg e "$(day 863400)" '[range(3) | {stage:"write-start",work_type:"repair",at:$s},{stage:"write-end",at:$e},{stage:"repair-delivered"}]')"
[[ "$(wall_unit "$three_rounds" repair-pending)" == 'rounds 3 of 3' ]] || fail "three rounds must still stop: $(wall_unit "$three_rounds" repair-pending)"
long_work="$(jq -cn --arg s "$(day 864000)" --arg e "$(day 840000)" '[{stage:"write-start",work_type:"repair",at:$s},{stage:"write-end",at:$e}]')"
[[ "$(wall_unit "$long_work" repair-pending)" == 'wall 400min of 240min after 1 rounds' ]] || fail "worker time past the budget must stop: $(wall_unit "$long_work" repair-pending)"
open_now="$(jq -cn --arg s "$(day 18000)" '[{stage:"write-start",work_type:"repair",at:$s}]')"
[[ "$(wall_unit "$open_now" repair)" == 'wall 300min of 240min after 1 rounds' ]] || fail "a running worker must count to now: $(wall_unit "$open_now" repair)"
[[ -z "$(wall_unit "$open_now" repair-pending)" ]] || fail "a killed worker must not count queue time: $(wall_unit "$open_now" repair-pending)"
killed="$(jq -cn --arg s "$(day 864000)" --arg n "$(day 840000)" '[{stage:"write-start",work_type:"repair",at:$s},{stage:"write-start",work_type:"repair",at:$n},{stage:"write-end",at:$n}]')"
[[ "$(wall_unit "$killed" repair-pending)" == 'wall 400min of 240min after 2 rounds' ]] || fail "a write with no end must close at the next start: $(wall_unit "$killed" repair-pending)"
noop_only="$(jq -cn --arg sha2 "$sha2" --arg s "$(day 20000)" --arg e "$(day 2000)" '{stage:"repair-pending",
  review_findings:[{round:1,block:"ok",findings:[],all_findings:[]}],
  history:[{stage:"review-request-changes",result:$sha2},{stage:"write-start",work_type:"repair",at:$s},{stage:"write-end",at:$e},
    {stage:"repair-no-push",result:("head "+$sha2+" unchanged after repair")}]}')"
noop_wall="$(TICKET_ROUND_BUDGET=3 TICKET_WALL_BUDGET_SECONDS=14400 NOW_EPOCH=1800000000 ticket_budget_reason "$noop_only")"
[[ "$noop_wall" == 'wall 300min of 240min after 0 rounds' ]] || fail "no-op work must still spend the wall: $noop_wall"

# The same history through both implementations: the shell stop-loss and the replay must reach the same wall verdict.
replay_wall() { # history-json -> "wall Nmin" or nothing
  node --input-type=module -e '
    const { replayRule } = await import(process.argv[3]);
    const unit = { id: "agree", issue: 1, stage: "repair-pending", history: JSON.parse(process.argv[1]) };
    const rule = { id: "wall", predicate: { path: "metrics.workerSeconds", op: "gt", value: 14400 } };
    const report = replayRule({ units: [unit] }, rule, { asOf: process.argv[2] });
    const hit = [...report.falseStops, ...report.intercepted, ...report.unresolved][0];
    if (hit) console.log(`wall ${Math.floor(hit.trigger.metrics.workerSeconds / 60)}min`);
  ' "$1" "$(day 0)" "$script_dir/rule-replay.mjs"
}
check_wall_agreement() { # label expected (stage seconds-ago)...
  local label="$1" expected="$2" history='[]' budget replay
  shift 2
  while (( $# )); do
    history="$(jq -c --arg stage "$1" --arg at "$(day "$2")" '. + [{stage:$stage,work_type:"implement",at:$at}]' <<<"$history")"
    shift 2
  done
  budget="$(wall_unit "$history" repair-pending)"
  replay="$(replay_wall "$history")"
  [[ "${budget%% of *}" == "$expected" && "$replay" == "$expected" ]] \
    || fail "$label: stop-loss '$budget' and replay '$replay' must both give '$expected'"
}
check_wall_agreement 'queue after short work' '' write-start 300000 write-end 299400 unblocked 3600
check_wall_agreement 'closed work over budget' 'wall 300min' write-start 20000 write-end 2000
check_wall_agreement 'killed write closes at next start' 'wall 300min' write-start 20000 write-start 9200 write-end 2000
check_wall_agreement 'ruling resets worker time' '' write-start 30000 write-end 19200 supervisor-requeue 19000 write-start 18000 write-end 7200
check_wall_agreement 'expired write stops at its next row' '' write-start 20000 worker-no-output 19400 write-start 5000 write-end 4400
check_wall_agreement 'unended write with no later write' 'wall 300min' write-start 20000 worker-no-output 2000
check_wall_agreement 'expired write keeps the time before its next row' 'wall 300min' write-start 20000 worker-no-output 2000 write-start 1000 write-end 1000

node "$script_dir/../lesson-guard-schema.mjs"
printf 'noop-repair-rounds.test.sh: 3 write-starts -> 2 counted; 3-of-3 stop-loss clear; repair-cap count 1\n'
printf 'noop-repair-rounds.test.sh: 27 focused assertions passed\n'
