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
  9002|9003|6289) priority=priority:top ;;
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

expect_eq 'founder issue seed' '[3066,5663,5665,6120,6121,6123,6124,6126,6130,6131,6133,6167,6226,6235,6237,6238]' \
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
expect_eq 'bug tier' 'priority:high' "$(issue_priority 9006)"
expect_eq 'fruit feature tier' 'priority:normal' "$(issue_priority 9007)"

issue_file="$test_root/off-market.issue.json"
result_file="$test_root/off-market.result.json"
jq -c '.[] | select(.number == 9002)' "$INTAKE_OVERLAY_ISSUES" > "$issue_file"
bash "$SCRIPT_DIR/intake-priority.sh" judge --repo fixture/repo --issue-file "$issue_file" --dry-stub > "$result_file"
bash "$SCRIPT_DIR/intake-priority.sh" apply --repo fixture/repo --issue-file "$issue_file" --result-file "$result_file"
expect_eq 'label writer uses the off-market overlay decision' true \
  "$(grep -F -- '--add-label priority:low' "$INTAKE_OVERLAY_WRITES" >/dev/null && echo true || echo false)"

# The scheduler consumes ready units from dispatch_order, so verify the same tiers at the actual pick seam.
CFG="$(cat -- "$SCRIPT_DIR/mac-autopilot/config.template.json")"
DISPATCH_PRIORITY_ORDER='["hotfix","opt","normal"]'
jq -n '{units:[
  {id:"off-market",issue:8201,title:"Sports broadcast rights",labels:["enhancement"],stage:"implement-pending",lane:"pr",history:[]},
  {id:"fruit-feature",issue:8202,title:"Fruit feature",labels:["enhancement"],stage:"implement-pending",lane:"pr",history:[]},
  {id:"bug",issue:8203,title:"Bug fix",labels:["bug"],stage:"implement-pending",lane:"pr",history:[]},
  {id:"hotfix",issue:8204,title:"Production incident",labels:["hotfix"],stage:"implement-pending",lane:"pr",history:[]}
 ]}' > "$test_root/units.json"
UNITS="$test_root/units.json"
DISPATCH_FIRST_ISSUES='[]'
TICK_DISPATCH_PENDING_ACTIVE=false
jqf() { jq "$@"; }
say() { :; }
source "$SCRIPT_DIR/mac-autopilot/scheduler.d/stop-loss.sh"
expect_eq 'ready units dispatch in business tier order' 'hotfix bug fruit-feature off-market' \
  "$(dispatch_order | jq -r '.id' | paste -sd ' ' -)"

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
