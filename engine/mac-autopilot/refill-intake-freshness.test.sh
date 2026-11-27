#!/usr/bin/env bash
set -euo pipefail
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/test-env.sh"
script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"

fail() { printf 'refill-intake-freshness.test.sh: %s\n' "$*" >&2; exit 1; }

fixture="$test_env_root/tick-latency"
mkdir -p "$fixture/repo" "$fixture/supervisor/autopi/alerts" "$fixture/sessions"
jq '.max_workers=20 | .implement_cap=20 | .auto_merge=false | .release_train.enabled=false
  | .issue_intake={enabled:true,max_upstream:100,max_ready:300,labels:[],product_labels:["ready-for-agent"],ready_buffer:100,remote_reads_per_tick:3}' \
  "$script_dir/config.template.json" > "$fixture/supervisor/autopi/config.json"
printf '{"units":[]}\n' > "$fixture/supervisor/autopi/units.json"
printf '{"workers":[]}\n' > "$fixture/supervisor/autopi/workers.json"
export MAC_AUTOPILOT_ROOT="$fixture/repo"
export MAC_AUTOPILOT_SUPERVISOR_DIR="$fixture/supervisor"
export MAC_AUTOPILOT_RUNTIME_DIR="$fixture/supervisor/autopi"
export GH_TEST_CALLS="$fixture/gh-calls" GH_TEST_LOCKS="$fixture/gh-locks" GH_TEST_COUNT=4
export AUTOPI_TEST_LIBRARY_ONLY=true
source "$script_dir/scheduler.sh"
unset AUTOPI_TEST_LIBRARY_ONLY

ROOT="$fixture/repo"; SUP="$fixture/supervisor"; A="$fixture/supervisor/autopi"
UNITS="$A/units.json"; WORKERS="$A/workers.json"; LOG="$A/scheduler.log"
STAMP=tick-latency-test; NOW_EPOCH=1793577600; MAX=20; IMPLEMENT_CAP=20
ISSUE_INTAKE_REMOTE_READ_CAP=3
SCHED_LOCK="$A/.scheduler.lock"; SCHED_LOCK_HELD=false
TICK_PRS='[]'; HANDOFF_PR_CENSUS='[]'; HANDOFF_CENSUS_PARTIAL=0
TICK_HOTFIX_ISSUES_LOADED=false; TICK_HOTFIX_ISSUES='[]'
TICK_INTAKE_READS_FILE="$A/intake-reads.test"; printf '0\n' > "$TICK_INTAKE_READS_FILE"
: > "$LOG"; : > "$GH_TEST_CALLS"; : > "$GH_TEST_LOCKS"

gh() {
  printf '%s\n' "$*" >> "$GH_TEST_CALLS"
  if [[ -e "$SCHED_LOCK" ]]; then printf 'locked\n' >> "$GH_TEST_LOCKS"; else printf 'unlocked\n' >> "$GH_TEST_LOCKS"; fi
  if [[ "$1 $2" == 'api graphql' ]]; then
    local context='{}' n
    while IFS= read -r n; do
      [[ "$n" =~ ^[1-9][0-9]*$ ]] || continue
      context="$(jq -cn --argjson context "$context" --argjson n "$n" '$context + {("i" + ($n | tostring)):{number:$n,blockedBy:{nodes:[]},subIssues:{totalCount:0,nodes:[]},subIssuesSummary:{total:0,completed:0}}}')"
    done < <(grep -oE 'issue\(number: [0-9]+\)' <<<"$*" | grep -oE '[0-9]+')
    jq -cn --argjson context "$context" '{data:{repository:$context}}'
  elif [[ "$1" == api && "$2" == repos/*/issues\?* ]]; then
    [[ "${GH_FAIL_LIST:-false}" != true ]] || return 1
    if [[ "$2" == *'labels=hotfix'* ]]; then
      printf '[]\n'
    elif [[ "$2" == *'labels=ready-for-agent'* ]]; then
      jq -cn --argjson n "$GH_TEST_COUNT" '[range(1; $n+1) as $i | {number:(7000+$i),title:("candidate "+($i|tostring)),body:"",state:"open",created_at:"2026-11-26T00:00:00Z",updated_at:"2026-11-26T00:00:00Z",labels:[{name:"ready-for-agent"}],user:{login:"fixture"}}]'
    else
      printf 'unexpected issue-list query: %s\n' "$*" >&2; return 97
    fi
  else
    printf 'unexpected gh query: %s\n' "$*" >&2; return 97
  fi
}
live_workers() { printf '0\n'; }
intake_footprint_snapshot() { printf '[]\n'; }
scheduler_footprint() { printf '[]\n'; }
active_footprint_conflict() { printf '\n'; }


phase register_new_issues || fail 'full intake failed'
printf '{"units":[]}\n' > "$UNITS"
: > "$GH_TEST_CALLS"
rm -f "$A/intake-candidates.json"
printf '0\n' > "$TICK_INTAKE_READS_FILE"
phase register_new_issues 0 true || fail 'fresh refill failed'
[[ ! -s "$GH_TEST_CALLS" ]] || fail 'fresh full intake did not suppress refill reads'
printf '0\n' > "$A/intake-full-tick-at"
rm -f "$A/intake-candidates.json"
printf '0\n' > "$TICK_INTAKE_READS_FILE"
phase register_new_issues 0 true || fail 'stale refill failed'
calls="$(wc -l < "$GH_TEST_CALLS")"
(( calls > 0 && calls <= ISSUE_INTAKE_REMOTE_READ_CAP )) || fail "stale refill reads=$calls outside cap"
printf 'ok - fresh full intake skips refill reads; stale intake reads within cap (%s)\n' "$calls"

rm -f "$A/intake-full-tick-at" "$A/intake-candidates.json"
printf '{"units":[]}\n' > "$UNITS"
printf '0\n' > "$TICK_INTAKE_READS_FILE"
GH_FAIL_LIST=true phase register_new_issues || fail 'failed census should be handled'
[[ ! -e "$A/intake-full-tick-at" ]] || fail 'failed full census marked fresh'
printf 'ok - failed full census does not mark intake fresh\n'

# A held read lock makes the reserve give up after its wait instead of blocking the tick.
printf '0\n' > "$TICK_INTAKE_READS_FILE"
exec 8>"$TICK_INTAKE_READS_FILE.lock"; flock -x 8
ISSUE_INTAKE_REMOTE_READ_LOCK_WAIT=1
( intake_remote_read_reserve ) & waiter=$!
for _ in 1 2 3 4 5 6 7 8 9 10; do kill -0 "$waiter" 2>/dev/null || break; sleep 1; done
if kill -0 "$waiter" 2>/dev/null; then
  pkill -P "$waiter" 2>/dev/null || true; kill "$waiter" 2>/dev/null || true
  flock -u 8; exec 8>&-
  fail 'reserve blocked on a held read lock'
fi
rc=0; wait "$waiter" || rc=$?
flock -u 8; exec 8>&-
(( rc == 75 )) || fail "reserve rc=$rc after lock wait, want 75"
grep -Fq 'intake remote read lock wait timed out after 1s' "$LOG" || fail 'lock wait timeout not logged'
printf 'ok - held intake read lock times out and skips the read\n'
