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
  if [[ "$1 $2" == 'issue list' ]]; then
    [[ "${GH_FAIL_LIST:-false}" != true ]] || return 1
    if [[ " $* " == *' --label hotfix '* ]]; then
      printf '[]\n'
    elif [[ " $* " == *' --label ready-for-agent '* ]]; then
      if [[ " $* " == *'subIssuesSummary'* ]]; then
        jq -cn --argjson n "$GH_TEST_COUNT" '[range(1; $n+1) as $i | {number:(7000+$i),title:("candidate "+($i|tostring)),body:"",state:"OPEN",labels:[{name:"ready-for-agent"}],subIssuesSummary:{total:0,completed:0}}]'
      else
        jq -cn --argjson n "$GH_TEST_COUNT" '[range(1; $n+1) as $i | {number:(7000+$i),title:("candidate "+($i|tostring)),body:"",state:"OPEN",labels:[{name:"ready-for-agent"}]}]'
      fi
    else
      printf 'unexpected issue-list query: %s\n' "$*" >&2; return 97
    fi
  elif [[ "$1 $2" == 'api repos/example-maintainer/example-repo/issues/'*'/sub_issues?per_page=100' ]]; then
    printf '[]\n'
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
