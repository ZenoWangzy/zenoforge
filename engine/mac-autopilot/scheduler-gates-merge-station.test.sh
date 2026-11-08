#!/usr/bin/env bash
# The merge station (loop.sh launches scheduler.sh --merge): it merges while a full tick holds the ledger lock and the refill budget is spent; the refill
# and the tick leave the pass to a fresh station and run it again when the station is stale; and the station and the fallback never merge one PR twice.
set -euo pipefail
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/test-env.sh"
source "$(dirname -- "${BASH_SOURCE[0]}")/test-scheduler-gates-fixture.sh"
fail() { echo "scheduler-gates-merge-station.test.sh: $*" >&2; exit 1; }
units() { printf '%s\n' "$1" > "$UNITS"; echo '{"workers":[]}' > "$WORKERS"; }
field() { jq -r --arg id "$1" ".units[] | select(.id==\$id) | $2" "$UNITS"; }
H1=1111111111111111111111111111111111111111
M1=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
M2=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
source "$script_dir/test-scheduler-gates-gh-fixture.sh"
MAIN_HEAD="$M1"
gate_eval_sha() { printf '%s' "$M1"; }
git() {
  if [[ "${3:-}" == rev-parse && "${!#}" == refs/remotes/origin/main ]]; then printf '%s\n' "$M1"
  elif [[ " $* " == *" ls-remote "* ]]; then printf '%s\trefs/heads/main\n' "$MAIN_HEAD"
  elif [[ "${1:-}" == -C && "${3:-}" == fetch && ( "${!#}" == refs/pull/*/head || "${!#}" == +refs/pull/*/head:refs/autopi/merge-candidates/* ) ]]; then return 0
  elif [[ "${1:-}" == -C && "${3:-}" == rev-parse && ( "${5:-}" == FETCH_HEAD* || "${5:-}" == refs/autopi/merge-candidates/* ) ]]; then echo "$GH_HEAD"
  else command git "$@"; fi
}
mkdir -p "$ROOT/engine"
printf '#!/usr/bin/env bash\nprintf "rule-lane: decision=pass actor=unit touched=0\\n"\n' > "$ROOT/engine/rule-lane.sh"
GH_RUNS="[{\"headSha\":\"$M1\",\"conclusion\":\"success\",\"status\":\"completed\",\"createdAt\":\"2026-10-19T00:00:00Z\",\"databaseId\":7}]"
GH_MERGE_SHA="$M2"
TICK_HOTFIX_ISSUES='[]'; TICK_HOTFIX_ISSUES_LOADED=true
GH_PR_TABLE="$fixture/merge-station-prs.json"
ready_unit() { units "$(jq -cn --arg sha "$H1" '{units:[{id:"pr-clean",pr:21,stage:"ready-to-merge",approved_sha:$sha,history:[]}]}')"; }
open_pr() { echo '[]' > "$GH_PR_TABLE"; gh_pr_open 21 "$H1" false MERGEABLE agent/issue-21 '[{"__typename":"CheckRun","name":"ci","status":"COMPLETED","conclusion":"SUCCESS"}]'; }
# Every merge call goes to a file, so background passes and subshells count too; MERGE_CALL_SLEEP widens the window between two passes' reads and their merges.
MERGE_LOG="$fixture/merge-calls"; MERGE_CALL_SLEEP=0
gh_inner_def="$(declare -f gh)"; eval "${gh_inner_def/gh ()/gh_inner ()}"
gh() {
  if [[ "$1 $2" == "pr merge" ]]; then
    printf '%s lock=%s\n' "$*" "$([[ -d "$SCHED_LOCK" ]] && echo held || echo free)" >> "$MERGE_LOG"
    [[ "$MERGE_CALL_SLEEP" == 0 ]] || command sleep "$MERGE_CALL_SLEEP"
  fi
  gh_inner "$@"
}
merges() { grep -c . "$MERGE_LOG" 2>/dev/null || true; }
fresh_epoch() { date +%s > "$A/.merge-station-epoch"; }

# ---- (a) starvation: a full tick holds the ledger lock and the refill budget is spent; the station still merges ----
open_pr; ready_unit; : > "$MERGE_LOG"; : > "$LOG"; rm -f "$A/.merge-station-epoch" "$A/.merge-pass-epoch"
bash -c 'mkdir "$1" && echo $$ > "$1/pid" && sleep 3 && rm -rf "$1"' _ "$SCHED_LOCK" & fake_tick=$!
for _ in $(seq 50); do [[ -s "$SCHED_LOCK/pid" ]] && break; command sleep 0.1; done
[[ -s "$SCHED_LOCK/pid" ]] || fail 'the fake tick did not take the scheduler lock'
SECONDS=290; AUTOPI_REFILL_LIMIT_SECONDS=300 # the refill's budget is spent (a refill-side pass would stop: refill-merge-pass.test.sh)
merge_entry
wait "$fake_tick" || :
[[ "$(merges)" == 1 && "$(cat "$MERGE_LOG")" == *"pr merge 21"*"lock=held" ]] || fail "the station did not merge while the tick held the lock: $(cat "$MERGE_LOG")"
[[ "$(field pr-clean .stage)" == merged ]] || fail "the ledger write after the lock was released did not land: $(field pr-clean .stage)"
[[ -s "$A/.merge-station-epoch" && -s "$A/.merge-pass-epoch" ]] || fail 'the station left no freshness or pass epoch'
SECONDS=0

# ---- (b) the refill and the tick leave the pass to a fresh station and take it back when it is stale ----
passes=0; real_pass="$(declare -f run_merge_lane_pass)"; run_merge_lane_pass() { passes=$((passes + 1)); }
ready_unit; rm -f "$A/.merge-station-epoch" "$A/.refill-merge-epoch"
merge_station_fresh && fail 'no epoch file counted as a fresh station (an older loop.sh would never merge)'
refill_merge_pass; (( passes == 1 )) || fail "the refill did not merge with no station: passes=$passes"
rm -f "$A/.refill-merge-epoch"; fresh_epoch
merge_station_fresh || fail 'a station that just started was not fresh'
refill_merge_pass; (( passes == 1 )) || fail "the refill merged beside a fresh station: passes=$passes"
echo $(( $(date +%s) - 601 )) > "$A/.merge-station-epoch"; rm -f "$A/.refill-merge-epoch"
merge_station_fresh && fail 'a station silent for 601 s was fresh'
refill_merge_pass; (( passes == 2 )) || fail "the refill did not take the pass back from a stale station: passes=$passes"
AUTOPI_MERGE_STATION_FRESH_SECONDS=1000 merge_station_fresh || fail 'the freshness window is not configurable'
grep -Fq 'merge_station_fresh || phase_yield_lock run_merge_lane' "$script_dir/scheduler.sh" || fail 'the full tick does not leave its merge pass to a fresh station'
# the station records itself even when it does not merge (paused), so the tick does not start a second merger
rm -f "$A/.merge-station-epoch"; : > "$fixture/PAUSE"; PAUSE_FILE="$fixture/PAUSE" merge_entry; rm -f "$fixture/PAUSE"
merge_station_fresh || fail 'a paused station pass did not record itself'
eval "$real_pass"; unset passes

# loop.sh launches --merge on its own cadence (like the ci station: not before it, once per cadence, a hung pass does not hold the poll)
ms="$fixture/merge-station-loop"; mkdir -p "$ms/live" "$ms/state"
cat > "$ms/live/scheduler.sh" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$MS_CALLS"
while [[ ! -e "$MS_RELEASE" ]]; do command sleep 0.1; done
SH
( AUTOPI_LOOP_LIBRARY_ONLY=true; source "$script_dir/loop.sh"
  A="$ms/state"; LIVE="$ms/live"; export MS_CALLS="$ms/calls" MS_RELEASE="$ms/release"; : > "$MS_CALLS"
  export AUTOPI_MERGE_STATION_SECONDS=30 AUTOPI_REFILL_SECONDS=2147483647 AUTOPI_DASHBOARD_SECONDS=2147483647 AUTOPI_CI_ADMISSION_SECONDS=2147483647
  echo '{"workers":[]}' > "$A/workers.json"
  sleep() { SECONDS=$((SECONDS + 5)); }
  refill_window 25 ) || fail 'refill window failed before the merge station cadence'
[[ ! -s "$ms/calls" ]] || fail "the merge station started before its cadence ($(cat "$ms/calls"))"
( AUTOPI_LOOP_LIBRARY_ONLY=true; source "$script_dir/loop.sh"
  A="$ms/state"; LIVE="$ms/live"; export MS_CALLS="$ms/calls" MS_RELEASE="$ms/release"
  export AUTOPI_MERGE_STATION_SECONDS=30 AUTOPI_REFILL_SECONDS=2147483647 AUTOPI_DASHBOARD_SECONDS=2147483647 AUTOPI_CI_ADMISSION_SECONDS=2147483647
  sleep() { SECONDS=$((SECONDS + 5)); }
  refill_window 40 ) || fail 'refill window blocked on a running merge station pass'
for _ in $(seq 50); do [[ -s "$ms/calls" ]] && break; command sleep 0.1; done
touch "$ms/release"
[[ "$(cat "$ms/calls")" == '--merge' ]] || fail "the merge station was not launched once on cadence ($(cat "$ms/calls" 2>/dev/null))"

# ---- (c) no double merge: the station (skips a busy lane), a tick-style pass (waits) and a refill-style pass (skips) race on one CLEAN PR ----
race() { # label: the merge calls of the three passes started together
  open_pr; ready_unit; : > "$MERGE_LOG"; : > "$LOG"; MERGE_CALL_SLEEP=1
  ( merge_entry ) & p1=$!
  ( MERGE_LANE_WAIT=120 run_merge_lane ) & p2=$!
  ( MERGE_LANE_WAIT=0 run_merge_lane ) & p3=$!
  wait "$p1" "$p2" "$p3" || :
  MERGE_CALL_SLEEP=0
}
race
[[ "$(merges)" == 1 ]] || fail "the station and the fallback passes merged PR 21 $(merges) times: $(cat "$MERGE_LOG")"
[[ "$(field pr-clean .stage)" == merged && "$(jq -r '[.units[0].history[]? | select(.stage == "merged")] | length' "$UNITS")" == 1 ]] || fail 'the unit was not recorded as merged exactly once'
# Control: without the lane flock the same race merges twice, so the count above is the flock's doing and not luck.
open_pr; ready_unit; : > "$MERGE_LOG"; MERGE_CALL_SLEEP=1
( run_merge_lane_pass ) & p1=$!
( run_merge_lane_pass ) & p2=$!
wait "$p1" "$p2" || :
MERGE_CALL_SLEEP=0
[[ "$(merges)" == 2 ]] || fail "control: two unguarded passes did not both merge ($(merges)); the race fixture proves nothing"
printf 'ok - merge station: merges under a held tick lock and a spent refill budget; refill and tick defer to a fresh station and take over a stale one; no double merge\n'
