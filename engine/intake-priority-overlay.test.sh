#!/usr/bin/env bash
set -euo pipefail
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/test-env.sh"

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
test_root="$(mktemp -d)"
trap 'rm -rf -- "$test_root" "$test_env_root"' EXIT
mkdir -p "$test_root/bin" "$test_root/config"
export ZF_CONFIG_ROOT="$test_root/config"
export ZF_REPO_DIR="$(git -C "$SCRIPT_DIR/.." rev-parse --show-toplevel)"
export ZF_ROADMAP_TREE_CACHE_FILE="$test_root/roadmap.json"
export INTAKE_OVERLAY_ISSUES="$test_root/issues.json"
export INTAKE_OVERLAY_LOG="$test_root/gh.log"
export INTAKE_OVERLAY_WRITES="$test_root/gh-writes.log"
export INTAKE_OVERLAY_STATE_LOG="$test_root/judge-state.jsonl"
unset TYPESAFE_API_KEY TYPESAFE_ENV_FILE

jq -n '{intake_priority:{enabled:false}}' > "$ZF_CONFIG_ROOT/night.json"
printf '[]\n' > "$ZF_ROADMAP_TREE_CACHE_FILE"
jq -n '[
  {number:3066,title:"体育供应链计划",body:"",labels:[{name:"ready-for-agent"}],state:"OPEN"},
  {number:9001,title:"Founder meeting follow-up",body:"",labels:[{name:"ready-for-agent"},{name:"founder-test"}],state:"OPEN"},
  {number:9002,title:"Sports broadcast rights roadmap",body:"",labels:[{name:"ready-for-agent"}],state:"OPEN"},
  {number:9003,title:"New industry pack",body:"",labels:[{name:"ready-for-agent"},{name:"体育赛事"}],state:"OPEN"},
  {number:9004,title:"Fruit inventory workflow",body:"",labels:[{name:"ready-for-agent"}],state:"OPEN"},
  {number:9005,title:"Production outage",body:"",labels:[{name:"ready-for-agent"},{name:"hotfix"}],state:"OPEN"},
  {number:9006,title:"Totals are incorrect",body:"",labels:[{name:"ready-for-agent"},{name:"bug"}],state:"OPEN"},
  {number:9007,title:"Add harvest dashboard",body:"",labels:[{name:"ready-for-agent"},{name:"enhancement"}],state:"OPEN"},
  {number:9008,title:"Sports broadcast rights outage",body:"",labels:[{name:"ready-for-agent"},{name:"hotfix"}],state:"OPEN"},
  {number:9009,title:"Sports league totals bug",body:"",labels:[{name:"ready-for-agent"},{name:"bug"}],state:"OPEN"},
  {number:9010,title:"Incident: fruit tenant outage",body:"",labels:[{name:"ready-for-agent"},{name:"prod-anomaly"}],state:"OPEN"},
  {number:9011,title:"Incident: factory alarm",body:"",labels:[{name:"ready-for-agent"}],state:"OPEN"},
  {number:9012,title:"[HOT-FIX] fruit tenant outage",body:"",labels:[{name:"ready-for-agent"}],state:"OPEN"},
  {number:9013,title:"【热修】fruit tenant outage",body:"",labels:[{name:"ready-for-agent"}],state:"OPEN"},
  {number:6289,title:"New industry backlog item",body:"",labels:[{name:"ready-for-agent"}],state:"OPEN"}
]' > "$INTAKE_OVERLAY_ISSUES"

cat > "$test_root/bin/gh" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$INTAKE_OVERLAY_LOG"
case "${1:-} ${2:-}" in
  "issue list")
    if [[ " $* " == *" --search "* ]]; then printf '[]\n'; else cat "$INTAKE_OVERLAY_ISSUES"; fi
    ;;
  "label list") printf '[]\n' ;;
  "issue edit"|"label create") printf '%s\n' "$*" >> "$INTAKE_OVERLAY_WRITES" ;;
  *) exit 2 ;;
esac
EOF
chmod +x "$test_root/bin/gh"
export PATH="$test_root/bin:$PATH"

cat > "$test_root/ts-judge.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
state="$(cat)"
printf '%s\n' "$(jq -c '{number:.issue.number,overlay}' <<< "$state")" >> "$INTAKE_OVERLAY_STATE_LOG"
number="$(jq -r '.issue.number' <<< "$state")"
case "$number" in
  3066) priority=priority:normal ;;
  9001) priority=priority:high ;;
  9002|9003|6289|9008|9009|9010|9011|9012|9013) priority=priority:top ;;
  9004) priority=priority:high ;;
  9005) priority=priority:low ;;
  9006) priority=priority:top ;;
  9007) priority=priority:high ;;
  *) exit 3 ;;
esac
decision="$(jq -cn --arg priority "$priority" \
  '{priority:$priority,route:"none-fits",duplicate:false,duplicateCandidates:[],stale:false}')"
jq -cn --arg decision "$decision" \
  '{status:"answered",question_set:"intake-priority",candidate:$decision,confidence:0.99,decision:$decision,adopted:true}'
EOF
chmod +x "$test_root/ts-judge.sh"
export ZF_TS_JUDGE_SCRIPT="$test_root/ts-judge.sh"

config="$(bash "$SCRIPT_DIR/intake-priority.sh" config)"
report_file="$test_root/report.json"
bash "$SCRIPT_DIR/intake-backlog.sh" --repo fixture/repo --output "$report_file" --limit 9 --concurrency 2 --dry-stub
report="$(cat "$report_file")"

failures=0
expect_eq() {
  local label="$1" expected="$2" actual="$3"
  if [[ "$actual" != "$expected" ]]; then
    printf 'FAIL: %s expected %s, got %s\n' "$label" "$expected" "${actual:-<empty>}" >&2
    failures=$((failures + 1))
  fi
}
issue_priority() { jq -r --argjson n "$1" '.issues[] | select(.number == $n) | .priority' <<< "$report"; }
issue_overlay() { jq -r --argjson n "$1" '.issues[] | select(.number == $n) | (.overlay // "<none>")' <<< "$report"; }

expect_eq 'founder issue seed' '[3066,5663,5665,6120,6121,6123,6124,6126,6130,6131,6133,6167,6226,6235,6237,6238,6601,6611]' \
  "$(jq -c '.founder_issues // []' <<< "$config")"
expect_eq 'off-market issue seed' '[1158,1159,3299,4620,5298,5329,5341,5421,6208,6288,6289]' \
  "$(jq -c '.off_market_issues // [] | sort' <<< "$config")"
expect_eq 'off-market terms' '["体育","赛事","版权","转播","球队","联赛","运动员","sports","broadcast rights","league","athlete"]' \
  "$(jq -c '.off_market_terms // []' <<< "$config")"

# Founder asks floor at high; high and top judge scores become top. A founder ask wins over the market cap.
expect_eq 'founder ask floor' 'priority:high' "$(issue_priority 3066)"
expect_eq 'founder ask overlay event' 'founder-ask' "$(issue_overlay 3066)"
expect_eq 'founder reason reaches decision event' 'founder-ask' \
  "$(jq -r 'select(.number == 3066) | .overlay' "$INTAKE_OVERLAY_STATE_LOG")"
expect_eq 'founder marker promoted to top' 'priority:top' "$(issue_priority 9001)"
expect_eq 'founder marker overlay event' 'founder-ask' "$(issue_overlay 9001)"

# Off-market matching covers titles, labels and the configured issue list, and caps even a top judge score.
expect_eq 'sports title cap' 'priority:low' "$(issue_priority 9002)"
expect_eq 'sports title overlay event' 'off-market' "$(issue_overlay 9002)"
expect_eq 'off-market reason reaches decision event' 'off-market' \
  "$(jq -r 'select(.number == 9002) | .overlay' "$INTAKE_OVERLAY_STATE_LOG")"
expect_eq 'sports label cap' 'priority:low' "$(issue_priority 9003)"
expect_eq 'configured off-market issue cap' 'priority:low' "$(issue_priority 6289)"

# A fruit issue without a tier marker keeps the judge score; business classes impose hotfix > bug > fruit feature > off-market.
expect_eq 'fruit issue keeps judge score' 'priority:high' "$(issue_priority 9004)"
expect_eq 'hotfix tier' 'priority:top' "$(issue_priority 9005)"
expect_eq 'hotfix stays above off-market cap' 'priority:top' "$(issue_priority 9008)"
expect_eq 'bug tier' 'priority:high' "$(issue_priority 9006)"
expect_eq 'sports-titled bug is capped at low' 'priority:low' "$(issue_priority 9009)"
expect_eq 'sports-titled bug records off-market overlay' 'off-market' "$(issue_overlay 9009)"
expect_eq 'fruit feature tier' 'priority:normal' "$(issue_priority 9007)"
expect_eq 'prod-anomaly label is hotfix tier' 'priority:top' "$(issue_priority 9010)"
expect_eq 'Incident title is hotfix tier' 'priority:top' "$(issue_priority 9011)"
expect_eq 'existing [HOT-FIX] title marker is hotfix tier' 'priority:top' "$(issue_priority 9012)"
expect_eq 'existing Chinese title marker is hotfix tier' 'priority:top' "$(issue_priority 9013)"

issue_file="$test_root/off-market.issue.json"
result_file="$test_root/off-market.result.json"
jq -c '.[] | select(.number == 9002)' "$INTAKE_OVERLAY_ISSUES" > "$issue_file"
bash "$SCRIPT_DIR/intake-priority.sh" judge --repo fixture/repo --issue-file "$issue_file" --dry-stub > "$result_file"
bash "$SCRIPT_DIR/intake-priority.sh" apply --repo fixture/repo --issue-file "$issue_file" --result-file "$result_file"
expect_eq 'label writer uses the off-market overlay decision' true \
  "$(grep -F -- '--add-label priority:low' "$INTAKE_OVERLAY_WRITES" >/dev/null && echo true || echo false)"

founder_issue_file="$test_root/founder.issue.json"
founder_result_file="$test_root/founder.result.json"
jq -c '.[] | select(.number == 3066)' "$INTAKE_OVERLAY_ISSUES" > "$founder_issue_file"
bash "$SCRIPT_DIR/intake-priority.sh" judge --repo fixture/repo --issue-file "$founder_issue_file" --dry-stub > "$founder_result_file"
bash "$SCRIPT_DIR/intake-priority.sh" apply --repo fixture/repo --issue-file "$founder_issue_file" --result-file "$founder_result_file"
expect_eq 'missing priority:high label is created before founder issue edit' true \
  "$(awk '$0 ~ /^label create priority:high / { created=NR } $0 ~ /^issue edit 3066 / { edited=NR } END { print (created > 0 && edited > created) ? "true" : "false" }' "$INTAKE_OVERLAY_WRITES")"

# 11-13: the judge stays in shadow until rollout, so an unadopted answer must still write a code-owned overlay label,
# and must not write a label that only the unadopted model chose.
shadow_issue_file="$test_root/shadow-overlay.issue.json"
jq -c '.[] | select(.number == 9007)' "$INTAKE_OVERLAY_ISSUES" > "$shadow_issue_file"
jq -cn '{status:"answered",adopted:false,confidence:0.4,
  decision:({priority:"priority:normal",route:"none-fits",duplicate:false,duplicateCandidates:[],stale:false,overlay:"fruit-feature"} | tojson)}' \
  > "$test_root/shadow-overlay.result.json"
bash "$SCRIPT_DIR/intake-priority.sh" apply --repo fixture/repo --issue-file "$shadow_issue_file" --result-file "$test_root/shadow-overlay.result.json"
expect_eq 'an unadopted answer still writes the overlay label' true \
  "$(grep -E '^issue edit 9007 ' "$INTAKE_OVERLAY_WRITES" | grep -qF -- '--add-label priority:normal' && echo true || echo false)"
jq -cn '{number:9020,title:"Tweak dashboard spacing",body:"",labels:[{name:"ready-for-agent"}],state:"OPEN"}' > "$test_root/shadow-plain.issue.json"
jq -cn '{status:"answered",adopted:false,confidence:0.4,
  decision:({priority:"priority:top",route:"none-fits",duplicate:false,duplicateCandidates:[],stale:false,overlay:null} | tojson)}' \
  > "$test_root/shadow-plain.result.json"
bash "$SCRIPT_DIR/intake-priority.sh" apply --repo fixture/repo --issue-file "$test_root/shadow-plain.issue.json" --result-file "$test_root/shadow-plain.result.json"
expect_eq 'an unadopted answer without an overlay writes no label' false \
  "$(grep -qE '^issue edit 9020 ' "$INTAKE_OVERLAY_WRITES" && echo true || echo false)"

# Verify ready-unit order through dispatch_pending, the scheduler's public dispatch entry point.
scheduler_fixture="$test_root/scheduler"
export MAC_AUTOPILOT_ROOT="$scheduler_fixture/repo"
export MAC_AUTOPILOT_SUPERVISOR_DIR="$scheduler_fixture/supervisor"
export MAC_AUTOPILOT_RUNTIME_DIR="$scheduler_fixture/supervisor/autopi"
export REQUIRED_PR_CHECKS_FILE="$SCRIPT_DIR/mac-autopilot/required-pr-checks.json"
mkdir -p "$MAC_AUTOPILOT_ROOT" "$MAC_AUTOPILOT_RUNTIME_DIR/alerts"
jq '.max_workers=8 | .implement_cap=8 | .hotfix_lane.supervisor_owned=false
  | .dispatch_first_issues=[8201]' "$SCRIPT_DIR/mac-autopilot/config.template.json" > "$MAC_AUTOPILOT_RUNTIME_DIR/config.json"
printf '%s\n' '{"units":[]}' > "$MAC_AUTOPILOT_RUNTIME_DIR/units.json"
printf '%s\n' '{"workers":[]}' > "$MAC_AUTOPILOT_RUNTIME_DIR/workers.json"
export AUTOPI_TEST_LIBRARY_ONLY=true
source "$SCRIPT_DIR/mac-autopilot/scheduler.sh"
unset AUTOPI_TEST_LIBRARY_ONLY
LOG="$MAC_AUTOPILOT_RUNTIME_DIR/scheduler.log"
UNITS="$MAC_AUTOPILOT_RUNTIME_DIR/units.json"
WORKERS="$MAC_AUTOPILOT_RUNTIME_DIR/workers.json"
STAMP="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
NOW_EPOCH="$(date +%s)"
SCHED_LOCK_HELD=true
DRY_RUN=0
dispatch_live_prime() { :; }
paused_midrun() { return 1; }
footprint_waiters_revalidate() { :; }
dispatch_why_load() { :; }
dispatch_why_save() { :; }
dispatch_steps_say() { :; }
footprint_convoy_alert() { return 0; }
ticket_budget_reason() { return 0; }
park_if_body_blocked() { return 1; }
room_for() { return 0; }
pick() {
  PICK_MODEL=fixture PICK_EFFORT=high PICK_PROVIDER=fixture PICK_HARD=false
  PICK_REASON=fixture PICK_ROUTE_PROVIDER=fixture
}
footprint_room() { return 0; }
ensure_clone() { printf '%s\n' "$MAC_AUTOPILOT_ROOT"; }
resume_handoff_integration() { return 0; }
verification_plan_for_state() { printf '{}'; }
verification_plan_brief() { printf 'fixture'; }
matt_method_rule() { :; }
decision_scope() { :; }
feature_verification_prompt() { :; }
implement_report_sections() { printf 'fixture'; }
direct_main_worker_prompt() { printf '%s' "$1"; }
dispatches=()
dispatch_if_room() { dispatches+=("$1"); return 0; }
jq -n '{units:[
  {id:"off-market",issue:8201,title:"Sports broadcast rights",labels:["enhancement"],stage:"implement-pending",lane:"pr",task:"fixture",branch:"agent/off-market",main_red:true,critical:true,history:[]},
  {id:"off-market-bug",issue:8205,title:"Sports league totals bug",labels:["bug"],stage:"implement-pending",lane:"pr",task:"fixture",branch:"agent/off-market-bug",history:[]},
  {id:"fruit-feature",issue:8202,title:"Fruit feature",labels:["enhancement"],stage:"implement-pending",lane:"pr",task:"fixture",branch:"agent/fruit",history:[]},
  {id:"bug",issue:8203,title:"Bug fix",labels:["bug"],stage:"implement-pending",lane:"pr",task:"fixture",branch:"agent/bug",history:[]},
  {id:"hotfix",issue:8204,title:"Production incident",labels:["hotfix"],stage:"implement-pending",lane:"pr",task:"fixture",branch:"agent/hotfix",history:[]},
  {id:"founder",issue:3066,title:"Founder sports request",labels:["enhancement","priority:high"],stage:"implement-pending",lane:"pr",task:"fixture",branch:"agent/founder",history:[]}
 ]}' > "$UNITS"
dispatch_pending true
# The founder fixture shares the fruit tier; its priority:high label sorts it before the normal fruit feature.
expect_eq 'ready units dispatch in factory tier order' 'hotfix bug founder fruit-feature off-market off-market-bug' \
  "${dispatches[*]}"

# TypeSafe logs the code-owned overlay reason with the decision event without seeing or choosing the policy.
export TYPESAFE_JUDGE_LOG="$test_root/ts-judge.jsonl"
export INTAKE_OVERLAY_TS_JUDGE="$SCRIPT_DIR/ts-judge.mjs"
node --input-type=module <<'NODE'
import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import { pathToFileURL } from "node:url";

const { judge } = await import(pathToFileURL(process.env.INTAKE_OVERLAY_TS_JUDGE));
const state = {
  event_id: "intake-priority:9001:test",
  currentDecision: JSON.stringify({ priority: "priority:normal" }),
  overlay: "founder-ask",
  issue: { number: 9001, title: "Founder request", body: "" },
  roadmapContainers: [], duplicateCandidates: [], recentMainSubjects: [],
  policy: {
    labels: {
      top: "priority:top", high: "priority:high", normal: "priority:normal", low: "priority:low",
      needsTriage: "priority:unsure", routePrefix: "route:",
    },
    scoreThresholds: { normal: 0.5, high: 1.5, top: 2.5 }, minimumConfidence: 0.9,
  },
};
const answers = {
  priority: { score: 1, confidence: 0.99 },
  route: { choice: "none-fits", confidence: 0.99 },
  duplicate: { noul: 0.1 }, stale: { noul: 0.1 },
};
const result = await judge({
  questionSet: "intake-priority", state, apiKey: "fixture-key", file: process.env.TYPESAFE_JUDGE_LOG,
  client: { async systemOne() { return { answers }; } },
});
assert.equal(result.overlay, "founder-ask");
const row = JSON.parse((await readFile(process.env.TYPESAFE_JUDGE_LOG, "utf8")).trim().split("\n").at(-1));
assert.equal(row.overlay, "founder-ask");
NODE

if (( failures > 0 )); then
  printf 'intake-priority-overlay.test.sh: %s assertion(s) failed\n' "$failures" >&2
  exit 1
fi
printf 'intake-priority-overlay.test.sh: rc=0\n'
