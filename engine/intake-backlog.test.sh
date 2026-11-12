#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
source "$SCRIPT_DIR/test-env.sh"

test_root="$(mktemp -d)"
trap 'rm -rf -- "$test_root"' EXIT
mkdir -p "$test_root/bin" "$test_root/config"
export ZF_CONFIG_ROOT="$test_root/config"
export ZF_REPO_DIR="$(git rev-parse --show-toplevel)"
export MODEL_POLICY_FILE="$test_root/model-policy.json"
export ZF_ROADMAP_TREE_CACHE_FILE="$test_root/roadmap.json"
export INTAKE_BACKLOG_ISSUES="$test_root/issues.json"
export INTAKE_BACKLOG_GH_LOG="$test_root/gh.log"
export INTAKE_BACKLOG_JUDGE_LOG="$test_root/judge.log"
unset TYPESAFE_API_KEY TYPESAFE_ENV_FILE

jq -n '{intake_priority:{enabled:false}}' > "$ZF_CONFIG_ROOT/night.json"
jq '.switches["roadmap-order"] = true' "$SCRIPT_DIR/model-policy.default.json" > "$MODEL_POLICY_FILE"
jq -n '{roots:[{number:90,title:"Roadmap",state:"open",labels:["roadmap"],children:[{number:91,title:"Theme",state:"open",labels:["roadmap-theme"],children:[{number:101,title:"Release work",state:"open",labels:["roadmap-epic"],children:[]},{number:102,title:"Reliability",state:"open",labels:["roadmap-epic"],children:[]}]}]}]}' > "$ZF_ROADMAP_TREE_CACHE_FILE"
jq -n '[
  {number:11,title:"Alpha release",body:"Release hardening.",labels:[{name:"priority:normal"}],comments:[{body:"Release context."}],state:"OPEN"},
  {number:12,title:"Beta duplicate",body:"A repeated request.",labels:[],comments:[{body:"Duplicate context."}],state:"OPEN"},
  {number:13,title:"Gamma obsolete",body:"An old behavior.",labels:[],comments:[],state:"OPEN"}
]' > "$INTAKE_BACKLOG_ISSUES"

cat > "$test_root/bin/gh" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$INTAKE_BACKLOG_GH_LOG"
case "${1:-} ${2:-}" in
  "issue list")
    if [[ " $* " == *' --jq '* ]]; then
      jq '[.[] | {number,title,body,labels:[.labels[]?.name],comments:[.comments[]?.body]}]' "$INTAKE_BACKLOG_ISSUES"
    else
      cat "$INTAKE_BACKLOG_ISSUES"
    fi
    ;;
  "label list") printf '%s\n' '[]' ;;
  "issue edit"|"label create") exit 0 ;;
  *) exit 2 ;;
esac
EOF
chmod +x "$test_root/bin/gh"
export PATH="$test_root/bin:$PATH"

cat > "$test_root/ts-judge.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$1" >> "$INTAKE_BACKLOG_JUDGE_LOG"
state="$(cat)"
number="$(jq -r '.issue.number' <<< "$state")"
case "$number" in
  11) decision='{"priority":"priority:top","route":"101","duplicate":false,"duplicateCandidates":[],"stale":false}'; confidence=0.95 ;;
  12) decision='{"priority":"priority:high","route":"102","duplicate":true,"duplicateCandidates":[11],"stale":false}'; confidence=0.96 ;;
  13) decision='{"priority":"priority:low","needsTriage":true,"route":"none-fits","duplicate":false,"duplicateCandidates":[],"stale":true}'; confidence=0.85 ;;
  *) exit 3 ;;
esac
jq -cn --arg decision "$decision" --argjson confidence "$confidence" \
  '{status:"answered",adopted:true,confidence:$confidence,decision:$decision,candidate:$decision}'
EOF
chmod +x "$test_root/ts-judge.sh"
export ZF_TS_JUDGE_SCRIPT="$test_root/ts-judge.sh"

bash "$SCRIPT_DIR/intake-backlog.sh" --repo fixture/repo --output "$test_root/report.json" --limit 3 --concurrency 2 --dry-stub
report="$(cat "$test_root/report.json")"
[[ "$(jq -r '.scanned' <<< "$report")" == 3 ]]
[[ "$(jq -r '.priority_counts["priority:top"]' <<< "$report")" == 1 ]]
[[ "$(jq -r '.priority_counts["priority:high"]' <<< "$report")" == 1 ]]
[[ "$(jq -r '.priority_counts["priority:low"]' <<< "$report")" == 1 ]]
[[ "$(jq -r '.issues[] | select(.number == 13) | .low_confidence' <<< "$report")" == true ]]
[[ "$(jq -r '.route_counts["101"]' <<< "$report")" == 1 ]]
[[ "$(jq -r '.route_counts["102"]' <<< "$report")" == 1 ]]
[[ "$(jq -r '.route_counts["none-fits"]' <<< "$report")" == 1 ]]
[[ "$(jq -r '.duplicate_candidates[0].issue' <<< "$report")" == 12 ]]
[[ "$(jq -r '.duplicate_candidates[0].candidates[0].number' <<< "$report")" == 11 ]]
[[ "$(jq -r '.stale_candidates[0].issue' <<< "$report")" == 13 ]]
[[ "$(jq -r '.low_confidence_count' <<< "$report")" == 1 ]]
[[ "$(grep -F 'issue list' "$INTAKE_BACKLOG_GH_LOG")" == *'--json number,title,body,labels,comments --jq'* ]]
[[ "$(grep -E '^(issue edit|label create)' "$INTAKE_BACKLOG_GH_LOG" 2>/dev/null || true)" == '' ]]
[[ "$(wc -l < "$INTAKE_BACKLOG_JUDGE_LOG")" == 3 ]]

set +e
bash "$SCRIPT_DIR/intake-backlog.sh" --repo fixture/repo --output "$test_root/refused.json" --limit 3 >/dev/null 2>&1
refused_rc=$?
set -e
[[ "$refused_rc" == 78 ]]
printf 'intake-backlog.test.sh rc=0\n'
