#!/usr/bin/env bash
set -euo pipefail
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/test-env.sh"

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
STAMP="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
LOG="$test_env_root/scheduler.log"
: > "$LOG"
source "$script_dir/scheduler.d/core.sh"

fail() { printf 'not ok - %s\n' "$*" >&2; exit 1; }
check() { [[ "$2" == "$3" ]] || fail "$1: got '$2', want '$3'"; printf 'ok - %s\n' "$1"; }

ADVISOR_PROVIDER_SCRIPT=""
ADVISOR_LAUNCHES=0
SET_UNIT_CALLS=0
LAST_UNIT_ID=""
LAST_UNIT_VALUE=""
decision_entry() { printf 'decision:%s' "$1"; }
hist() { printf 'history:%s:%s' "$1" "$2"; }
set_unit() {
  LAST_UNIT_ID="$1"
  LAST_UNIT_VALUE="$2"
  SET_UNIT_CALLS=$((SET_UNIT_CALLS + 1))
}
advisor_launch() { ADVISOR_LAUNCHES=$((ADVISOR_LAUNCHES + 1)); }

missing="$test_env_root/version/.agents/skills/web-advisor-provider/ask.cjs"
ADVISOR_PROVIDER_SCRIPT="$missing"
unit='{"id":"unit-fixture"}'
advisor_dispatch_or_route "$unit" 3 || fail 'missing provider fallback failed'
[[ "$LAST_UNIT_VALUE" == *'advisor provider missing at round 3'* && "$LAST_UNIT_VALUE" == *'arbiter=true'* \
  && "$LAST_UNIT_VALUE" == *'review-pending'* ]] || fail 'missing provider did not route the unit to arbiter review'
advisor_dispatch_or_route "$unit" 3 || fail 'repeated missing provider fallback failed'
check 'missing provider emits one stable scheduler diagnostic' \
  "$(grep -Fc "advisor provider missing: $missing" "$LOG" || true)" 1
check 'missing provider routes each unit without launching the advisor' "$ADVISOR_LAUNCHES|$SET_UNIT_CALLS" '0|2'
grep -Fq 'advisor_dispatch_or_route "$u" "$total"' "$script_dir/scheduler.d/dispatch-queue.sh" \
  || fail 'scheduler dispatch does not use the guarded advisor entry point'

readable="$test_env_root/version-good/.agents/skills/web-advisor-provider/ask.cjs"
mkdir -p "$(dirname -- "$readable")"
: > "$readable"
ADVISOR_PROVIDER_SCRIPT="$readable"
advisor_dispatch_or_route "$unit" 3 || fail 'readable provider launch failed'
check 'readable provider is allowed to launch' "$ADVISOR_LAUNCHES|$SET_UNIT_CALLS" '1|2'

# The exact scheduler diagnostic is consumed by the bell and filed through
# the #166 pipeline issue-upsert entry point. Keep all writes in this fixture.
autopi="$test_env_root/autopi"
repo="$test_env_root/repo"
engine="$test_env_root/engine"
supervisor="$test_env_root/supervisor"
upsert_calls="$test_env_root/upsert-calls"
upsert_body="$test_env_root/upsert-body"
mkdir -p "$autopi/alerts" "$repo" "$engine" "$supervisor"
cat > "$autopi/config.json" <<'JSON'
{"bell":{"enabled":true},"incident":{"file_min_severity":"medium"}}
JSON
printf 'window.DASH={};\n' > "$autopi/dashboard.data.js"
cp "$LOG" "$autopi/scheduler.log"
printf '%s\n' '{"units":[]}' > "$autopi/units.json"
printf '%s\n' '{"workers":[]}' > "$autopi/workers.json"
jq -n '{monitor_initialized:true,scheduler_lines:0,alert_mtimes:{},merge_events:{},signatures:{},pending:[]}' \
  > "$autopi/bell-state.json"
cat > "$engine/pipeline-issue-upsert.sh" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
class="" body_file=""
while (($#)); do
  case "$1" in
    --class) class="$2"; shift 2 ;;
    --body-file) body_file="$2"; shift 2 ;;
    *) shift ;;
  esac
done
printf '%s\n' "$class" >> "$BELL_TEST_UPSERT_CALLS"
cat "$body_file" > "$BELL_TEST_UPSERT_BODY"
printf 'stub filed %s\n' "$class"
SH
chmod +x "$engine/pipeline-issue-upsert.sh"
export MAC_AUTOPILOT_ROOT="$repo" MAC_AUTOPILOT_RUNTIME_DIR="$autopi" MAC_AUTOPILOT_SUPERVISOR_DIR="$supervisor"
export BELL_AUTOPI_DIR="$autopi" BELL_SUPERVISOR_DIR="$supervisor" BELL_STALE_CI_DISABLE=1
export ZF_ENGINE_DIR="$engine" ZF_GH_REPO=example/incident-test ZF_REPO=example/incident-test
export BELL_TEST_UPSERT_CALLS="$upsert_calls" BELL_TEST_UPSERT_BODY="$upsert_body"
bash "$script_dir/bell.sh" > "$test_env_root/bell-first.out" 2>&1 || {
  cat "$test_env_root/bell-first.out" "$autopi/bell.log" >&2
  fail 'bell failed to process the missing-provider diagnostic'
}
check 'bell files the missing provider through incident upsert' \
  "$(cat "$upsert_calls")" sched-advisor-provider-missing
grep -Fq 'advisor provider missing:' "$upsert_body" || fail 'incident body omitted the missing-provider evidence'
grep -Fq 'incident filed class=sched-advisor-provider-missing count=1' "$autopi/bell.log" \
  || fail 'bell did not record successful incident filing'
bash "$script_dir/bell.sh" > "$test_env_root/bell-second.out" 2>&1 \
  || fail 'bell failed on the repeated diagnostic scan'
check 'repeated scan does not file a second incident' "$(wc -l < "$upsert_calls" | tr -d ' ')" 1

printf '[%s] issue-pipeline: maintenance deferred streak section=needs-info-recovery consecutive=3 tick=20261103T000003Z\n' \
  "$STAMP" >> "$autopi/scheduler.log"
bash "$script_dir/bell.sh" > "$test_env_root/bell-maintenance.out" 2>&1 \
  || fail 'bell failed to process the repeated maintenance deferral'
check 'maintenance deferral uses the #166 incident intake class' \
  "$(tail -n 1 "$upsert_calls")" sched-maintenance-deferral-needs-info-recovery
grep -Fq 'consecutive=3' "$upsert_body" || fail 'maintenance incident body omitted the deferral streak evidence'
printf '[%s] issue-pipeline: maintenance deferred streak section=needs-info-recovery consecutive=4 tick=20261103T000004Z\n' \
  "$STAMP" >> "$autopi/scheduler.log"
bash "$script_dir/bell.sh" > "$test_env_root/bell-maintenance-repeat.out" 2>&1 \
  || fail 'bell failed on a repeated maintenance signature'
# A repeat inside the 24h window now reaches the class upsert (it comments an
# occurrence on the open issue), so the call count grows; the dedup contract is
# that it is the same class, i.e. no third issue.
check 'repeated maintenance signature upserts the same class' "$(tail -n 1 "$upsert_calls")" sched-maintenance-deferral-needs-info-recovery
check 'repeated maintenance signature stays deduplicated' "$(sort -u "$upsert_calls" | wc -l | tr -d ' ')" 2

echo 'advisor-provider-missing.test.sh: PASS'
