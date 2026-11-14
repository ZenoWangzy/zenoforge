#!/usr/bin/env bash
set -euo pipefail
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/test-env.sh"
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"

test_root="$(mktemp -d)"
trap 'rm -rf -- "$test_root" "$test_env_root"' EXIT
mkdir -p "$test_root/bin" "$test_root/config"
export ZF_CONFIG_ROOT="$test_root/config"
export ZF_REPO_DIR="$(git rev-parse --show-toplevel)"
export MODEL_POLICY_FILE="$test_root/model-policy.json"
export ZF_ROADMAP_TREE_CACHE_FILE="$test_root/roadmap.json"
export INTAKE_BACKLOG_ISSUES="$test_root/issues.json"
export INTAKE_BACKLOG_GH_LOG="$test_root/gh.log"
export INTAKE_BACKLOG_JUDGE_LOG="$test_root/judge.log"
export INTAKE_BACKLOG_EVENTS="$test_root/events.log"
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
    if [[ " $* " == *' --search '* && -n "${INTAKE_BACKLOG_RATE_LIMIT_SEARCH:-}" \
      && " $* " == *"$INTAKE_BACKLOG_RATE_LIMIT_SEARCH"* ]]; then
      printf '%s\n' 'GraphQL: API rate limit already exceeded for user ID 1.' >&2
      exit 1
    elif [[ " $* " == *' --jq '* ]]; then
      jq '[.[] | {number,title,body,labels:[.labels[]?.name],comments:[.comments[]?.body]}]' "$INTAKE_BACKLOG_ISSUES"
    else
      if [[ -n "${INTAKE_BACKLOG_DELAY_SEARCH:-}" && " $* " == *"$INTAKE_BACKLOG_DELAY_SEARCH"* ]]; then
        sleep 0.5
      fi
      cat "$INTAKE_BACKLOG_ISSUES"
    fi
    ;;
  "label list") printf '%s\n' '[]' ;;
  "api"*)
    if [[ "$*" == *"rate_limit"* ]]; then
      jq -cn --argjson core "${INTAKE_BACKLOG_RATE_CORE_REMAINING:-5000}" \
        --argjson graphql "${INTAKE_BACKLOG_RATE_GRAPHQL_REMAINING:-5000}" \
        '{resources:{core:{remaining:$core},graphql:{remaining:$graphql}}}'
    elif [[ "$*" == *"/issues/"*"/labels"* && "$*" == *"-X POST"* ]]; then
      number="$(sed -nE 's#.*issues/([0-9]+)/labels.*#\1#p' <<< "$*")"
      printf 'labels:%s\n' "$number" >> "$INTAKE_BACKLOG_EVENTS"
      if [[ -n "${INTAKE_BACKLOG_RATE_LIMIT_NUMBER:-}" && "$number" == "$INTAKE_BACKLOG_RATE_LIMIT_NUMBER" ]]; then
        printf '%s\n' 'gh: API rate limit already exceeded for user ID 1. (HTTP 403)' >&2
        exit 1
      fi
    elif [[ -n "${INTAKE_BACKLOG_ROUTE_RATE_LIMIT_PARENT:-}" \
      && "$*" == *"/issues/${INTAKE_BACKLOG_ROUTE_RATE_LIMIT_PARENT}/sub_issues"* ]]; then
      printf '%s\n' 'gh: API rate limit already exceeded for user ID 1. (HTTP 403)' >&2
      exit 1
    elif [[ "$*" == *"/sub_issues"* ]]; then
      printf '{}\n'
    elif [[ "$*" =~ /issues/([0-9]+)[[:space:]] ]]; then
      printf '%s\n' "$((10000 + BASH_REMATCH[1]))"
    fi
    ;;
  "issue edit"|"label create") exit 0 ;;
  *) exit 2 ;;
esac
EOF
chmod +x "$test_root/bin/gh"
export PATH="$test_root/bin:$PATH"

cat > "$test_root/ts-judge.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
state="$(cat)"
number="$(jq -r '.issue.number' <<< "$state")"
printf '%s %s\n' "$1" "$number" >> "$INTAKE_BACKLOG_JUDGE_LOG"
printf 'judge:%s\n' "$number" >> "$INTAKE_BACKLOG_EVENTS"
case "$number" in
  11) decision='{"priority":"priority:top","route":"101","duplicate":false,"duplicateCandidates":[],"stale":false}'; confidence=0.95 ;;
  12) decision='{"priority":"priority:high","route":"102","duplicate":true,"duplicateCandidates":[11],"stale":false}'; confidence=0.96 ;;
  13) decision='{"priority":"priority:low","unsure":"priority:unsure","route":"none-fits","duplicate":false,"duplicateCandidates":[],"stale":true}'; confidence=0.85 ;;
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
[[ "$(jq -r '.priority_counts["priority:top"] // 0' <<< "$report")" == 0 ]]
[[ "$(jq -r '.priority_counts["priority:high"] // 0' <<< "$report")" == 0 ]]
[[ "$(jq -r '.priority_counts["priority:normal"]' <<< "$report")" == 2 ]]
[[ "$(jq -r '.priority_counts["priority:low"]' <<< "$report")" == 1 ]]
[[ "$(jq -r '.issues[] | select(.number == 11) | .overlay' <<< "$report")" == default-tier ]]
[[ "$(jq -r '.issues[] | select(.number == 12) | .overlay' <<< "$report")" == default-tier ]]
[[ "$(jq -r '.issues[] | select(.number == 13) | .low_confidence' <<< "$report")" == true ]]
[[ "$(jq -r '.route_counts["101"]' <<< "$report")" == 1 ]]
[[ "$(jq -r '.route_counts["102"]' <<< "$report")" == 1 ]]
[[ "$(jq -r '.route_counts["none-fits"]' <<< "$report")" == 1 ]]
[[ "$(jq -r '.duplicate_candidates[0].issue' <<< "$report")" == 12 ]]
[[ "$(jq -r '.duplicate_candidates[0].candidates[0].number' <<< "$report")" == 11 ]]
[[ "$(jq -r '.stale_candidates[0].issue' <<< "$report")" == 13 ]]
[[ "$(jq -r '.low_confidence_count' <<< "$report")" == 1 ]]
[[ "$(grep -F 'issue list' "$INTAKE_BACKLOG_GH_LOG")" == *'--json number,title,body,labels'* ]]
[[ "$(grep -E '^(issue edit|label create)' "$INTAKE_BACKLOG_GH_LOG" 2>/dev/null || true)" == '' ]]
[[ "$(wc -l < "$INTAKE_BACKLOG_JUDGE_LOG")" == 3 ]]

: > "$INTAKE_BACKLOG_JUDGE_LOG"
: > "$INTAKE_BACKLOG_EVENTS"
bash "$SCRIPT_DIR/intake-backlog.sh" --repo fixture/repo --output "$test_root/skip-labelled.json" --limit 3 --concurrency 2 --dry-stub --skip-labelled
skip_report="$(cat "$test_root/skip-labelled.json")"
[[ "$(jq -r '.scanned' <<< "$skip_report")" == 2 ]]
[[ "$(jq -r '[.issues[].number] | sort | join(",")' <<< "$skip_report")" == '12,13' ]]
[[ "$(grep -F 'intake-priority 11' "$INTAKE_BACKLOG_JUDGE_LOG" || true)" == '' ]]
[[ "$(wc -l < "$INTAKE_BACKLOG_JUDGE_LOG")" == 2 ]]

jq -n '{intake_priority:{enabled:true}}' > "$ZF_CONFIG_ROOT/night.json"
export TYPESAFE_API_KEY=fixture-key
export INTAKE_BACKLOG_RATE_LIMIT_NUMBER=12
: > "$INTAKE_BACKLOG_JUDGE_LOG"
: > "$INTAKE_BACKLOG_EVENTS"
bash "$SCRIPT_DIR/intake-backlog.sh" --repo fixture/repo --output "$test_root/rate-limit.json" --limit 3 --concurrency 1 --apply
rate_report="$(cat "$test_root/rate-limit.json")"
[[ "$(jq -r '.partial' <<< "$rate_report")" == true ]]
[[ "$(jq -r '.stop_reason' <<< "$rate_report")" == rate-limit ]]
[[ "$(jq -r '.scanned' <<< "$rate_report")" == 2 ]]
[[ "$(jq -r '[.issues[].number] | sort | join(",")' <<< "$rate_report")" == '11,12' ]]
[[ "$(awk '$0 == "labels:11" { applied=NR } $0 == "judge:12" { judged=NR } END { print (applied > 0 && judged > applied) ? "true" : "false" }' "$INTAKE_BACKLOG_EVENTS")" == true ]]
[[ "$(grep -F 'judge:13' "$INTAKE_BACKLOG_EVENTS" || true)" == '' ]]

unset INTAKE_BACKLOG_RATE_LIMIT_NUMBER
export INTAKE_BACKLOG_ROUTE_RATE_LIMIT_PARENT=102
: > "$INTAKE_BACKLOG_JUDGE_LOG"
: > "$INTAKE_BACKLOG_EVENTS"
bash "$SCRIPT_DIR/intake-backlog.sh" --repo fixture/repo --output "$test_root/rate-limit-route.json" --limit 3 --concurrency 1 --apply
route_rate_report="$(cat "$test_root/rate-limit-route.json")"
[[ "$(jq -r '.partial' <<< "$route_rate_report")" == true ]]
[[ "$(jq -r '.stop_reason' <<< "$route_rate_report")" == rate-limit ]]
[[ "$(jq -r '[.issues[].number] | sort | join(",")' <<< "$route_rate_report")" == '11,12' ]]
[[ "$(grep -F 'labels:12' "$INTAKE_BACKLOG_EVENTS" || true)" != '' ]]
[[ "$(grep -F 'judge:13' "$INTAKE_BACKLOG_EVENTS" || true)" == '' ]]

unset INTAKE_BACKLOG_ROUTE_RATE_LIMIT_PARENT
export INTAKE_BACKLOG_RATE_CORE_REMAINING=1499
: > "$INTAKE_BACKLOG_JUDGE_LOG"
: > "$INTAKE_BACKLOG_EVENTS"
: > "$INTAKE_BACKLOG_GH_LOG"
bash "$SCRIPT_DIR/intake-backlog.sh" --repo fixture/repo --output "$test_root/rate-floor.json" --limit 3 --concurrency 1 --apply --rate-floor 1500
floor_report="$(cat "$test_root/rate-floor.json")"
[[ "$(jq -r '.partial' <<< "$floor_report")" == true ]]
[[ "$(jq -r '.stop_reason' <<< "$floor_report")" == rate-limit ]]
[[ "$(jq -r '.scanned' <<< "$floor_report")" == 1 ]]
[[ "$(jq -r '[.issues[].number] | join(",")' <<< "$floor_report")" == '11' ]]
[[ "$(grep -F 'judge:11' "$INTAKE_BACKLOG_EVENTS" || true)" != '' ]]
[[ "$(grep -F 'labels:11' "$INTAKE_BACKLOG_EVENTS" || true)" == '' ]]
[[ "$(grep -F 'api rate_limit' "$INTAKE_BACKLOG_GH_LOG" || true)" != '' ]]
unset INTAKE_BACKLOG_RATE_CORE_REMAINING

export INTAKE_BACKLOG_RATE_LIMIT_SEARCH='beta duplicate in:title'
export INTAKE_BACKLOG_DELAY_SEARCH='alpha release in:title'
: > "$INTAKE_BACKLOG_JUDGE_LOG"
: > "$INTAKE_BACKLOG_EVENTS"
bash "$SCRIPT_DIR/intake-backlog.sh" --repo fixture/repo --output "$test_root/rate-limit-judge.json" --limit 3 --concurrency 2 --apply
judge_rate_report="$(cat "$test_root/rate-limit-judge.json")"
[[ "$(jq -r '.partial' <<< "$judge_rate_report")" == true ]]
[[ "$(jq -r '.stop_reason' <<< "$judge_rate_report")" == rate-limit ]]
[[ "$(jq -r '[.issues[].number] | sort | join(",")' <<< "$judge_rate_report")" == '11,12' ]]
[[ "$(grep -F 'judge:12' "$INTAKE_BACKLOG_EVENTS" || true)" != '' ]]
[[ "$(grep -F 'labels:12' "$INTAKE_BACKLOG_EVENTS" || true)" == '' ]]
[[ "$(grep -F 'labels:11' "$INTAKE_BACKLOG_EVENTS" || true)" == '' ]]
[[ "$(grep -F 'judge:13' "$INTAKE_BACKLOG_EVENTS" || true)" == '' ]]
unset TYPESAFE_API_KEY INTAKE_BACKLOG_RATE_LIMIT_SEARCH INTAKE_BACKLOG_DELAY_SEARCH
jq -n '{intake_priority:{enabled:false}}' > "$ZF_CONFIG_ROOT/night.json"

set +e
bash "$SCRIPT_DIR/intake-backlog.sh" --repo fixture/repo --output "$test_root/refused.json" --limit 3 >/dev/null 2>&1
refused_rc=$?
set -e
[[ "$refused_rc" == 78 ]]
printf 'intake-backlog.test.sh rc=0\n'
