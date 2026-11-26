#!/usr/bin/env bash
set -euo pipefail
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/test-env.sh"
engine_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
fail() { echo "gh-budget.test.sh: $*" >&2; exit 1; }
tmp="$(mktemp -d)"
trap 'rm -rf -- "$tmp" "$test_env_root"' EXIT
mkdir -p "$tmp/bin"
export AGENT_HOME="$tmp/agent" GH_BUDGET_NOW_FILE="$tmp/now" GH_BUDGET_RESPONSE_FILE="$tmp/response" GH_BUDGET_CALLS="$tmp/calls"
export GH_BUDGET_REAL_DATE="$(command -v date)"
mkdir -p "$AGENT_HOME"
printf '1795651200\n' > "$GH_BUDGET_NOW_FILE"
cat > "$tmp/bin/date" <<'DATE'
#!/usr/bin/env bash
case "$*" in
  +%s) cat "$GH_BUDGET_NOW_FILE" ;;
  '-u +%FT%TZ') "$GH_BUDGET_REAL_DATE" -u -d "@$(cat "$GH_BUDGET_NOW_FILE")" +%FT%TZ ;;
  '-u +%Y-%m') "$GH_BUDGET_REAL_DATE" -u -d "@$(cat "$GH_BUDGET_NOW_FILE")" +%Y-%m ;;
  *) exit 64 ;;
esac
DATE
cat > "$tmp/bin/gh" <<'GH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$GH_BUDGET_CALLS"
[[ "$1 ${2:-}" == 'api rate_limit' ]] || exit 43
[[ "${GH_BUDGET_FAIL:-0}" != 1 ]] || exit 1
cat "$GH_BUDGET_RESPONSE_FILE"
GH
chmod +x "$tmp/bin/date" "$tmp/bin/gh"
export PATH="$tmp/bin:$PATH"
export ZF_AGENT_TEST_MODE=0
source "$engine_dir/lib.d/gh-budget.sh"
source "$engine_dir/lib.d/transport.sh"

rate_response() {
  jq -cn --argjson gu "$1" --argjson gr "$2" --argjson ru "$3" --argjson rr "$4" \
    '{resources:{graphql:{used:$gu,remaining:(5000-$gu),reset:$gr},core:{used:$ru,remaining:(5000-$ru),reset:$rr}}}' > "$GH_BUDGET_RESPONSE_FILE"
}

rate_response 100 1795654800 200 1795654800
gh_budget_sample 1795651200
[[ "$(wc -l < "$GH_BUDGET_CALLS" | tr -d ' ')" == 1 ]] || fail 'the first call did not create a sample'
samples="$AGENT_HOME/metrics/gh-budget-2026-11.jsonl"
[[ "$(wc -l < "$samples" | tr -d ' ')" == 1 ]] || fail 'the sample file did not get one row'
[[ "$(gh_rate_limit_quota graphql)" == '4900 1795654800' ]] || fail 'GraphQL quota did not read the sample'
[[ "$(wc -l < "$GH_BUDGET_CALLS" | tr -d ' ')" == 1 ]] || fail 'quota lookup made another rate_limit request'

rate_response 150 1795654800 250 1795654800
gh_budget_sample 1795651259
[[ "$(wc -l < "$GH_BUDGET_CALLS" | tr -d ' ')" == 1 ]] || fail 'sample repeated before 60 seconds'
rate_response 2601 1795654800 3501 1795654800
printf '1795651260\n' > "$GH_BUDGET_NOW_FILE"
gh_budget_sample 1795651260
[[ "$(wc -l < "$GH_BUDGET_CALLS" | tr -d ' ')" == 2 ]] || fail 'sample did not refresh at 60 seconds'
[[ "$(wc -l < "$samples" | tr -d ' ')" == 2 ]] || fail 'the second sample did not append one row'

python3 - "$engine_dir/mac-autopilot" "$AGENT_HOME" "$tmp/runtime" <<'PY'
import datetime as dt, os, sys
sys.path.insert(0, sys.argv[1])
import gh_budget_health as budget
import node_health as health
home, runtime = sys.argv[2:]
now = dt.datetime(2026, 11, 26, 0, 1, tzinfo=dt.timezone.utc)
metrics = budget.collect(home, now)
assert metrics["gh_budget.graphql_used_per_hour"] == 2601, metrics
assert metrics["gh_budget.rest_used_per_hour"] == 3501, metrics
criteria, minimums, bases, invalid = health.resolve_health_standards()
assert criteria["gh_budget.graphql_used_per_hour"][2:4] == (600, 2500)
assert criteria["gh_budget.rest_used_per_hour"][2:4] == (2000, 3500)
rows = [row for row in health.score(metrics, criteria, {}, minimums, invalid)
        if row[1] in ("gh_budget.graphql_used_per_hour", "gh_budget.rest_used_per_hour")]
assert all(row[7] == "UNHEALTHY" for row in rows), rows
write = health.health_standards.write_health_alerts
display = lambda value: str(value)
doc = lambda: "engine/mac-autopilot/NODE-HEALTH.md"
write(runtime, home, rows, now, display, doc)
write(runtime, home, rows, now, display, doc)
alerts = open(os.path.join(runtime, "alerts", "node-health.md")).read()
assert alerts.count("metric=gh_budget.graphql_used_per_hour") == 1, alerts
assert alerts.count("metric=gh_budget.rest_used_per_hour") == 1, alerts
PY

rate_response 7 1795658400 9 1795658400
printf '1795654800\n' > "$GH_BUDGET_NOW_FILE"
gh_budget_sample 1795654800
hourly="$AGENT_HOME/metrics/gh-budget-hourly-2026-11.jsonl"
[[ "$(wc -l < "$hourly" | tr -d ' ')" == 2 ]] || fail 'reset did not roll up both resources'
jq -e 'select(.resource == "graphql" and .reset == 1795654800 and .used == 2601)' "$hourly" >/dev/null \
  || fail 'GraphQL roll-up did not use the last sample before reset'
jq -e 'select(.resource == "rest" and .reset == 1795654800 and .used == 3501)' "$hourly" >/dev/null \
  || fail 'REST roll-up did not use the last sample before reset'
python3 - "$engine_dir/mac-autopilot" "$AGENT_HOME" <<'PY'
import sys
sys.path.insert(0, sys.argv[1])
import gh_budget_health as budget
hourly = budget.hourly_rollup(sys.argv[2])
assert hourly["graphql"]["reset"] == 1795654800 and hourly["graphql"]["used"] == 2601, hourly
assert hourly["rest"]["reset"] == 1795654800 and hourly["rest"]["used"] == 3501, hourly
PY
[[ "$(wc -l < "$samples" | tr -d ' ')" == 3 ]] || fail 'reset sample was not appended once'

printf '1795654860\n' > "$GH_BUDGET_NOW_FILE"
GH_BUDGET_FAIL=1 gh_budget_sample 1795654860 2> "$tmp/sample.err"
[[ "$(wc -l < "$samples" | tr -d ' ')" == 3 ]] || fail 'failed sample wrote a metrics row'
grep -q 'gh-budget: rate_limit sample failed' "$tmp/sample.err" || fail 'failed sample was not logged'
if gh_rate_limit_quota graphql >/dev/null; then fail 'quota lookup accepted a sample that was 60 seconds old'; fi
echo 'gh-budget.test.sh: PASS'
