#!/usr/bin/env bash
set -euo pipefail
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/test-env.sh"
script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"

fail() { printf 'scheduler-tick-latency.test.sh: %s\n' "$*" >&2; exit 1; }

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
export GH_TEST_CALLS="$fixture/gh-calls" GH_TEST_LOCKS="$fixture/gh-locks" GH_TEST_COUNT=12
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

# The real lock helper releases the ledger around registration's remote reads.
acquire_scheduler_lock || fail 'could not acquire fixture ledger lock'
phase_yield_lock register_new_issues || fail 'issue intake phase failed'
[[ "$SCHED_LOCK_HELD" == true && -d "$SCHED_LOCK" ]] || fail 'yield helper did not reacquire the ledger lock'

calls="$(wc -l < "$GH_TEST_CALLS" | tr -d ' ')"
failures=()
(( calls <= ISSUE_INTAKE_REMOTE_READ_CAP )) \
  || failures+=("remote reads exceeded cap $ISSUE_INTAKE_REMOTE_READ_CAP: $calls calls")
[[ "$(jq -r '.units | length' "$UNITS")" == "$GH_TEST_COUNT" ]] \
  || failures+=('bounded census did not preserve all eligible issue registrations')
[[ -z "$(grep -v '^unlocked$' "$GH_TEST_LOCKS" || true)" ]] \
  || failures+=('a remote intake read ran while the ledger lock was held')

# Guard the production call sites as well as the helper: registration and dispatch
# must keep the same release/read/commit/reacquire flow as the runtime lock helper.
grep -Fq 'phase_yield_lock_batch run_issue_intake_phases' "$script_dir/scheduler.sh" \
  || failures+=('full-tick issue registration does not yield the ledger lock')
# The tick's opening holds the lock; a yield around the census prime let a refill in at tick start, and 9 of 37 such refills were killed.
tick_body="$(sed -n '/^main() {/,/^}/p' "$script_dir/scheduler.sh")"
grep -Fq 'phase tick_prs_prime' <<<"$tick_body" && ! grep -Fq 'phase_yield_lock tick_prs_prime' <<<"$tick_body" \
  || failures+=('the full tick yields the ledger lock at tick start, so a refill can queue behind its opening')
# The closing steps (focus alert, snapshot, views, cleanup) run without the ledger lock: 128s of lock hold there blocked a refill's writes.
[[ "${tick_body%%phase_mark flush_focus_alert*}" == *release_scheduler_lock* ]] \
  || failures+=('the full tick still holds the ledger lock through its closing steps')
grep -Fq 'phase_yield_lock dispatch_pending' "$script_dir/scheduler.sh" \
  || failures+=('full-tick dispatch does not yield the ledger lock')
grep -Fq 'phase_yield_lock_batch run_refill_intake_dispatch_phases' "$script_dir/scheduler.sh" \
  || failures+=('refill issue registration and dispatch do not yield the ledger lock')

# Exercise the full tick call site. The arbiter probe is another process: it must
# be able to acquire the shared ledger lock while dispatch_supervisor_arbiters runs.
(
  arbiter_tick="$fixture/supervisor-arbiter-yield"
  mkdir -p "$arbiter_tick/repo" "$arbiter_tick/supervisor/autopi/alerts"
  ROOT="$arbiter_tick/repo"; SUP="$arbiter_tick/supervisor"; A="$arbiter_tick/supervisor/autopi"
  UNITS="$A/units.json"; WORKERS="$A/workers.json"; LOG="$A/scheduler.log"
  SCHED_LOCK="$A/.scheduler.lock"; SCHED_LOCK_HELD=false; PAUSE_FILE="$A/PAUSE"
  arbiter_lock_taken="$A/arbiter-lock-taken"
  printf '{"units":[]}\n' > "$UNITS"; printf '{"workers":[]}\n' > "$WORKERS"
  GH_TICK_CALLS_FILE=""; TICK_INTAKE_READS_FILE=""; TICK_PHASES=""; TICK_PHASE_DETAILS=""; TICK_LOCK_WAIT=0
  state_schema_ok() { return 0; }
  tick_gh_calls_begin() { :; }; tick_gh_calls_count() { printf '0\n'; }
  tick_roadmap_cache_begin() { :; }; tick_roadmap_cache_end() { :; }
  harvest_station_fresh() { return 0; }; supervisor_marking_deferred() { return 1; }
  paused_midrun() { return 1; }; phase_mark() { :; }; say() { :; }
  git() { return 1; }; update_budget() { return 0; }; record_run_spend() { return 0; }
  live_workers() { printf '0\n'; }; dispatch_skip_summary() { printf '\n'; }
  tick_prs_changed() { :; }; run_issue_intake_phases() { :; }
  ci_station_fresh() { return 0; }; merge_station_fresh() { return 0; }
  for stub in rotate_logs budget_alert_if_needed flush_focus_alert publish_pr_run_snapshot launch_views cleanup_tick; do
    eval "$stub() { :; }"
  done
  phase() {
    if [[ "$1" == dispatch_supervisor_arbiters ]]; then dispatch_supervisor_arbiters; fi
  }
  dispatch_supervisor_arbiters() {
    [[ ! -e "$SCHED_LOCK" ]] || fail 'full-tick arbiter dispatch still holds the ledger lock'
    (
      acquire_scheduler_lock || exit 1
      printf 'taken\n' > "$arbiter_lock_taken"
      release_scheduler_lock
    ) &
    arbiter_pid=$!
    wait "$arbiter_pid" || fail 'another process could not take the ledger lock during arbiter dispatch'
    [[ -s "$arbiter_lock_taken" ]] || fail 'arbiter lock probe did not run'
  }
  main
  [[ ! -e "$SCHED_LOCK" ]] || fail 'full tick left its ledger lock held'
)

# Refill dispatches startable work first, then merges, then takes in issues, and dispatches again only when intake added some.
phase() { order+=("$1"); [[ "$1" != register_new_issues ]] || INTAKE_ADDED=$intake_adds; }
for intake_adds in 0 1; do
  order=(); run_refill_intake_dispatch_phases
  want='dispatch_pending refill_merge_pass register_new_issues'; (( intake_adds == 0 )) || want+=' dispatch_pending'
  [[ "${order[*]}" == "$want" ]] || failures+=("refill phase order with $intake_adds new issues was '${order[*]}', want '$want'")
done

# Late in the refill window the post-intake pass is left to the next refill.
for late in 180 240; do
  SECONDS=$late; order=(); intake_adds=1; run_refill_intake_dispatch_phases
  want='dispatch_pending refill_merge_pass register_new_issues dispatch_pending'; (( late < 240 )) || want='dispatch_pending refill_merge_pass register_new_issues'
  [[ "${order[*]}" == "$want" ]] || failures+=("refill phase order at ${late}s was '${order[*]}', want '$want'")
done
SECONDS=0

if ((${#failures[@]})); then
  printf 'not ok - %s\n' "${failures[@]}" >&2
  exit 1
fi
printf 'ok - issue intake caps remote reads and keeps reads outside the ledger lock (%s reads for %s issues; cap %s)\n' \
  "$calls" "$GH_TEST_COUNT" "$ISSUE_INTAKE_REMOTE_READ_CAP"
