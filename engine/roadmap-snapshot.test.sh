#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "$0")/test-env.sh"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/lib.sh"
source "$(dirname "${BASH_SOURCE[0]}")/issue-pipeline-slices.sh"
export REPO=fixture/repo DRY_RUN=0
export ROADMAP_TEST_RESPONSE="$AGENT_HOME/response.json"
export ROADMAP_TEST_FAIL="$AGENT_HOME/fail"
cat > "$test_env_bin/gh" <<'GH'
#!/usr/bin/env bash
[[ ! -f "$ROADMAP_TEST_FAIL" ]] || exit 1
cat "$ROADMAP_TEST_RESPONSE"
GH
chmod +x "$test_env_bin/gh"
jq -cn '[{data:{repository:{issues:{nodes:[
  {number:1,title:"Roadmap",state:"OPEN",labels:{nodes:[{name:"roadmap"}]},subIssues:{nodes:[{number:2},{number:3},{number:4}]}},
  {number:2,title:"Ready",state:"OPEN",labels:{nodes:[]},subIssues:{nodes:[]}},
  {number:3,title:"Held",state:"OPEN",labels:{nodes:[{name:"on-hold"}]},subIssues:{nodes:[]}},
  {number:4,title:"Blocked",state:"OPEN",labels:{nodes:[]},blockedBy:{nodes:[{number:9,state:"OPEN"}]},subIssues:{nodes:[]}}
]}}}}]' > "$ROADMAP_TEST_RESPONSE"
ZF_ROADMAP_TREE_CACHE_FILE="$AGENT_HOME/tick-1.json"
roadmap_fetch_for_admission "$ZF_ROADMAP_TREE_CACHE_FILE" "$REPO"
snapshot="$AGENT_HOME/night/roadmap-tree.snapshot.json"
jq -e '.repo == "fixture/repo" and (.fetched_at | type == "number") and (.tree.roots | length == 1)' "$snapshot" >/dev/null
echo 'ok - successful read persists validated tree across ticks'

# Replay the scheduler's actual startup and decision writer in a second tick.
jq '.switches["roadmap-order"] = true | .roles.advisor.disabled = false' "$MODEL_POLICY_FILE" > "$AGENT_HOME/policy.next"
mv "$AGENT_HOME/policy.next" "$MODEL_POLICY_FILE"
touch "$ROADMAP_TEST_FAIL"
TEST_NOW="$(jq '.fetched_at + 60' "$snapshot")"
date() {
  if [[ "$*" == +%s ]]; then printf '%s\n' "$TEST_NOW"; else command date "$@"; fi
}
NIGHT="$AGENT_HOME/night"
ZF_ROADMAP_TREE_CACHE_FILE="$AGENT_HOME/tick-2.json"
eval "$(sed -n '/^ROADMAP_ORDER_ENABLED=/,/^source .*hand-agent-watchdog.sh/p' "$SCRIPT_DIR/issue-pipeline.sh" | sed '$d')"
[[ "$ROADMAP_TREE_READY:$ROADMAP_TREE_STALE:$ROADMAP_SNAPSHOT_AGE_SECONDS" == 1:1:60 ]]
candidates='[{"number":1,"labels":[]},{"number":2,"labels":[]},{"number":3,"labels":[]},{"number":4,"labels":[]}]'
[[ "$(roadmap_order_candidates "$ROADMAP_TREE_JSON" "$candidates")" == 2 ]]
cmp "$AGENT_HOME/tick-1.json" "$AGENT_HOME/tick-2.json"
eval "$(sed -n '/^record_implement_decision() {/,/^}/p' "$SCRIPT_DIR/issue-pipeline.sh")"
IMPLEMENT_TICK_ID=stale-fixture
efficiency_metrics_record_implement_decision() { :; }
record_implement_decision 2 dispatched implement-dispatch 'fixture admission allowed' zf-implement-2.service 2> "$AGENT_HOME/decision.log"
jq -e '.implement_tick_decision.outcome == "dispatched" and (.implement_tick_decision.reason | contains("roadmap_snapshot=stale age_seconds=60 ttl_seconds=7200"))' "$STATE_DIR/2.json" >/dev/null
grep -q 'roadmap_snapshot=stale' "$AGENT_HOME/decision.log"
[[ "$(wc -l < "$AGENT_HOME/supervisor-inbox")" == 1 ]]
# A fresh shell has no in-memory tree. Failed reads never renew fetched_at.
AGENT_HOME="$AGENT_HOME" DRY_RUN=0 ZF_REPO="$REPO" bash -c '
  source "$1/lib.sh"
  roadmap_fetch_for_admission "$AGENT_HOME/tick-3.json" "$REPO"
  [[ "$ROADMAP_TREE_STALE" == 1 ]]
' _ "$SCRIPT_DIR"
[[ "$(wc -l < "$AGENT_HOME/supervisor-inbox")" == 1 ]]
echo 'ok - recent snapshot admits leaf across ticks/processes; hold/blocker/parent gates preserved; stale decision and one bell'

TEST_NOW="$(jq '.fetched_at + 7201' "$snapshot")"
if roadmap_fetch_for_admission "$AGENT_HOME/tick-2.json" "$REPO"; then exit 1; fi
[[ "$ROADMAP_TREE_STALE" == 0 && ! -e "$AGENT_HOME/tick-2.json" ]]
[[ "$(wc -l < "$AGENT_HOME/supervisor-inbox")" == 2 ]]
if roadmap_fetch_for_admission "$AGENT_HOME/tick-2.json" "$REPO"; then exit 1; fi
[[ "$(wc -l < "$AGENT_HOME/supervisor-inbox")" == 2 ]]
echo 'ok - expired snapshot closes admission and rings once'

rm "$snapshot"
ZF_ROADMAP_TREE_CACHE_FILE="$AGENT_HOME/tick-4.json"
eval "$(sed -n '/^ROADMAP_ORDER_ENABLED=/,/^source .*hand-agent-watchdog.sh/p' "$SCRIPT_DIR/issue-pipeline.sh" | sed '$d')"
[[ "$ROADMAP_TREE_READY:$ROADMAP_TREE_STALE" == 0:0 ]]
[[ ! -e "$ZF_ROADMAP_TREE_CACHE_FILE" ]]
[[ "$(wc -l < "$AGENT_HOME/supervisor-inbox")" == 3 ]]
echo 'ok - missing snapshot keeps scheduler admission closed and rings'

rm "$ROADMAP_TEST_FAIL"
roadmap_fetch_for_admission "$AGENT_HOME/tick-5.json" "$REPO"
[[ "$ROADMAP_TREE_STALE:$ROADMAP_SNAPSHOT_AGE_SECONDS" == 0:0 ]]
jq -e '.repo == "fixture/repo"' "$snapshot" >/dev/null
touch "$ROADMAP_TEST_FAIL"
TEST_NOW="$(jq '.fetched_at + 10' "$snapshot")"
ZF_ROADMAP_SNAPSHOT_TTL_SECONDS=5
if roadmap_fetch_for_admission "$AGENT_HOME/tick-6.json" "$REPO"; then exit 1; fi
ZF_ROADMAP_SNAPSHOT_TTL_SECONDS=7200
if roadmap_fetch_for_admission "$AGENT_HOME/tick-6.json" other/repo; then exit 1; fi
TEST_NOW="$(jq '.fetched_at - 1' "$snapshot")"
if roadmap_fetch_for_admission "$AGENT_HOME/tick-6.json" "$REPO"; then exit 1; fi
echo 'ok - recovery resets stale flag; configurable TTL, repository mismatch and future timestamps fail closed'

TEST_NOW="$(jq '.fetched_at + 60' "$snapshot")"
jq '.tree.roots[0].children_truncated = true' "$snapshot" > "$snapshot.next"
mv "$snapshot.next" "$snapshot"
if roadmap_fetch_for_admission "$AGENT_HOME/tick-6.json" "$REPO"; then exit 1; fi
[[ ! -e "$AGENT_HOME/tick-6.json" ]]
printf '{broken\n' > "$snapshot"
if roadmap_fetch_for_admission "$AGENT_HOME/tick-6.json" "$REPO"; then exit 1; fi
rm "$ROADMAP_TEST_FAIL"
roadmap_fetch_for_admission "$AGENT_HOME/tick-7.json" "$REPO"
jq -e '.fetched_at > 1 and .tree.roots[0].children_truncated == false' "$snapshot" >/dev/null
echo 'ok - truncated/corrupt snapshots fail closed; next successful read replaces invalid state'
