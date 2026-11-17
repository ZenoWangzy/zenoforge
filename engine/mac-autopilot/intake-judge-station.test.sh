#!/usr/bin/env bash
set -euo pipefail
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)/test-env.sh"

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
engine_dir="$(cd -- "$script_dir/.." && pwd -P)"
fixture="$test_env_root/intake-judge-station"
mkdir -p "$fixture/bin" "$fixture/repo" "$fixture/supervisor/autopi"
export MAC_AUTOPILOT_ROOT="$fixture/repo" MAC_AUTOPILOT_SUPERVISOR_DIR="$fixture/supervisor" \
  MAC_AUTOPILOT_RUNTIME_DIR="$fixture/supervisor/autopi" REQUIRED_PR_CHECKS_FILE="$fixture/required-pr-checks.json"
printf '%s\n' '{"required":[],"current_regression":"","legacy_regression":[]}' > "$REQUIRED_PR_CHECKS_FILE"
cp "$engine_dir/mac-autopilot/config.template.json" "$MAC_AUTOPILOT_RUNTIME_DIR/config.json"
export AUTOPI_TEST_LIBRARY_ONLY=true
source "$engine_dir/mac-autopilot/scheduler.sh"
unset AUTOPI_TEST_LIBRARY_ONLY

A="$fixture/runtime"; LOG="$A/scheduler.log"; PAUSE_FILE="$A/PAUSE"
INTAKE_JUDGE_LOCK="$A/.intake-judge-station.lock"; STAMP="$(date -u +%FT%TZ)"
REPO="$ZF_REPO"; CFG="$(cat "$MAC_AUTOPILOT_RUNTIME_DIR/config.json")"
mkdir -p "$A"
export A HERE LOG STAMP REPO
export ZF_INTAKE_PRIORITY_SCRIPT="$fixture/intake-priority.sh"
export JUDGE_CALLS="$fixture/judge-calls" JUDGE_MODE=apply JUDGE_FALLBACK_NUMBERS=2,4
export ACTIVE_FILE="$fixture/active" ACTIVE_LOCK="$fixture/active.lock" MAX_ACTIVE_FILE="$fixture/max-active"
export CANDIDATE_FILE="$fixture/candidates.json"

fail() { printf 'intake-judge-station.test.sh: %s\n' "$*" >&2; exit 1; }

cat > "$ZF_INTAKE_PRIORITY_SCRIPT" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
issue="$(cat)"
number="$(jq -r '.number' <<<"$issue")"
printf '%s\n' "$number" >>"$JUDGE_CALLS"
exec 9>>"$ACTIVE_LOCK"
flock -x 9
active="$(cat "$ACTIVE_FILE" 2>/dev/null || echo 0)"
active=$((active + 1))
printf '%s\n' "$active" >"$ACTIVE_FILE"
max="$(cat "$MAX_ACTIVE_FILE" 2>/dev/null || echo 0)"
(( active <= max )) || printf '%s\n' "$active" >"$MAX_ACTIVE_FILE"
flock -u 9
sleep 0.15
flock -x 9
active="$(cat "$ACTIVE_FILE")"
printf '%s\n' "$((active - 1))" >"$ACTIVE_FILE"
flock -u 9
case "$JUDGE_MODE" in
  apply) printf 'intake-priority: applied issue=#%s priority=normal route=none-fits\n' "$number" ;;
  fail) printf 'intake-priority: answer not adopted for issue #%s reason=credits-exhausted\n' "$number" ;;
  skip) echo 'intake-priority: skipped (missing-typesafe-key)' ;;
  *) exit 2 ;;
esac
STUB
cat > "$fixture/bin/gh" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
case "${1:-} ${2:-}" in
  'issue view')
    number="${3:-}"
    if [[ ",$JUDGE_FALLBACK_NUMBERS," == *",$number,"* ]]; then
      echo '{"labels":[{"name":"judge:fallback"}]}'
    else
      echo '{"labels":[]}'
    fi
    ;;
  *) exit 2 ;;
esac
STUB
chmod +x "$ZF_INTAKE_PRIORITY_SCRIPT" "$fixture/bin/gh"
export PATH="$fixture/bin:$PATH"

state_schema_ok() { [[ "${SCHEMA_OK:-true}" == true ]]; }
intake_judge_station_raw_candidates() { cat "$CANDIDATE_FILE"; }
git() { :; }

make_candidates() {
  jq -cn '([6,5,4,3,2,1] | map({number:.,title:("issue " + tostring),body:"",state:"OPEN",labels:[]})) + [
    {number:7,title:"needs triage",body:"",state:"OPEN",labels:[{name:"needs-triage"}]},
    {number:8,title:"already prioritized",body:"",state:"OPEN",labels:[{name:"priority:high"}]},
    {number:9,title:"closed",body:"",state:"CLOSED",labels:[]}
  ]' > "$CANDIDATE_FILE"
}
reset() {
  rm -rf "$INTAKE_JUDGE_LOCK" "$A/.intake-judge-epoch" "$A/.intake-judge-claims" "$PAUSE_FILE"
  rm -f "$A/intake-skip-noted.tsv" "$A/intake-skip-noted.tsv.lock"
  : > "$LOG"; : > "$JUDGE_CALLS"; echo 0 > "$ACTIVE_FILE"; echo 0 > "$MAX_ACTIVE_FILE"
  JUDGE_MODE=apply; SCHEMA_OK=true; make_candidates
}

# Six candidates, cap four, and two in flight: the four oldest are selected, the active count stays at two.
reset
ZF_INTAKE_JUDGE_PER_PASS=4 ZF_INTAKE_JUDGE_PARALLEL=2 intake_judge_station_pass || fail 'the bounded pass failed'
[[ "$(sort -n "$JUDGE_CALLS" | paste -sd, -)" == '1,2,3,4' ]] || fail "the pass did not judge the oldest four: $(cat "$JUDGE_CALLS")"
[[ "$(wc -l < "$JUDGE_CALLS" | tr -d ' ')" == 4 ]] || fail 'the pass judged more than its cap'
[[ "$(cat "$MAX_ACTIVE_FILE")" == 2 ]] || fail "parallelism was not bounded at two: $(cat "$MAX_ACTIVE_FILE")"
line="$(grep 'intake-judge done' "$LOG")"
[[ "$line" =~ intake-judge\ done\ secs=[0-9]+\ judged=4\ applied=4\ fallback=2\ deferred=2\ rc=0 ]] || fail "pass summary was wrong: $line"

# A pass without a tick cache uses the configured intake-label query and current issue labels.
reset
intake_judge_station_raw_candidates() { intake_judge_station_query_candidates; }
gh() {
  [[ "$1 $2" == 'issue list' && "$*" == *'--label ready-for-agent'* ]] || return 97
  cat "$CANDIDATE_FILE"
}
ZF_INTAKE_JUDGE_PER_PASS=4 ZF_INTAKE_JUDGE_PARALLEL=2 intake_judge_station_pass || fail 'the live-query pass failed'
[[ "$(sort -n "$JUDGE_CALLS" | paste -sd, -)" == '1,2,3,4' ]] || fail 'the live query did not choose the oldest eligible issues'
intake_judge_station_raw_candidates() { cat "$CANDIDATE_FILE"; }
unset -f gh

# A live claim excludes that issue; the remaining oldest issues still run.
reset
mkdir -p "$A/.intake-judge-claims/1"; printf '%s\ttest\n' "$(date +%s)" > "$A/.intake-judge-claims/1/start"
ZF_INTAKE_JUDGE_PER_PASS=6 ZF_INTAKE_JUDGE_PARALLEL=2 intake_judge_station_pass || fail 'the claimed-issue pass failed'
! grep -qx 1 "$JUDGE_CALLS" || fail 'a held claim was judged'
[[ "$(grep 'intake-judge done' "$LOG")" =~ deferred=1\ rc=0 ]] || fail 'a held claim was not reported as deferred'

# The existing six-hour stamp removes its issue before the pass cap is counted.
reset
jq -c '. + [{number:10,title:"cooldown",body:"",state:"OPEN",labels:[]}]' "$CANDIDATE_FILE" > "$CANDIDATE_FILE.tmp" && mv -f "$CANDIDATE_FILE.tmp" "$CANDIDATE_FILE"
intake_skip_stamp 10 'intake priority label not applied'
ZF_INTAKE_JUDGE_PER_PASS=10 ZF_INTAKE_JUDGE_PARALLEL=4 intake_judge_station_pass || fail 'the cooldown pass failed'
[[ "$(sort -n "$JUDGE_CALLS" | paste -sd, -)" == '1,2,3,4,5,6' ]] || fail 'the station ignored the existing cooldown'
[[ "$(grep 'intake-judge done' "$LOG")" =~ judged=6\ applied=6\ fallback=2\ deferred=0\ rc=0 ]] || fail 'filtered candidate counts were wrong'

# A claim older than the station kill timeout is atomically reclaimed.
reset
mkdir -p "$A/.intake-judge-claims/1"; printf '%s\ttest\n' "$(( $(date +%s) - 1201 ))" > "$A/.intake-judge-claims/1/start"
ZF_INTAKE_JUDGE_PER_PASS=1 ZF_INTAKE_JUDGE_PARALLEL=1 intake_judge_station_pass || fail 'the stale-claim pass failed'
grep -qx 1 "$JUDGE_CALLS" || fail 'an expired claim was not reclaimed'
[[ ! -e "$A/.intake-judge-claims/1" ]] || fail 'the finished call left its claim behind'

# A fresh station epoch suppresses the full tick's in-intake fallback.
reset
date +%s > "$A/.intake-judge-epoch"
intake_priority_open_unlabelled_candidates '' '' <<<"$(jq -cn '{number:77,title:"tick candidate",body:"",state:"OPEN",labels:[]}')" >/dev/null
[[ ! -s "$JUDGE_CALLS" ]] || fail 'a fresh epoch did not suppress the tick judge'

# Disabled-key skips keep #1206's no-stamp behavior.
reset; JUDGE_MODE=skip
ZF_INTAKE_JUDGE_PER_PASS=1 ZF_INTAKE_JUDGE_PARALLEL=1 intake_judge_station_pass || fail 'the skipped pass failed'
[[ ! -e "$A/intake-skip-noted.tsv" ]] || fail 'a missing-key skip was stamped'

# PAUSE and an invalid state schema stop external work but still leave the epoch and pass line.
reset; touch "$PAUSE_FILE"
intake_judge_station_pass || fail 'a paused pass returned nonzero'
[[ ! -s "$JUDGE_CALLS" && -s "$A/.intake-judge-epoch" ]] || fail 'a paused pass judged or left no epoch'
[[ "$(grep 'intake-judge done' "$LOG")" =~ rc=0 ]] || fail 'a paused pass did not log its completion'
reset; SCHEMA_OK=false
rc=0; intake_judge_station_pass || rc=$?
[[ "$rc" == 2 && ! -s "$JUDGE_CALLS" ]] || fail 'an invalid schema pass made an external call'
[[ "$(grep 'intake-judge done' "$LOG")" =~ rc=2 ]] || fail 'an invalid schema pass did not log its refusal'
SCHEMA_OK=true

# Simultaneous non-applied results serialize the read-modify-write and retain every cooldown row.
reset; JUDGE_MODE=fail
ZF_INTAKE_JUDGE_PER_PASS=6 ZF_INTAKE_JUDGE_PARALLEL=4 intake_judge_station_pass || fail 'the parallel stamping pass failed'
[[ "$(awk -F'\t' '{print $1}' "$A/intake-skip-noted.tsv" | awk '{print $1}' | sort -n | paste -sd, -)" == '1,2,3,4,5,6' ]] \
  || fail "parallel stamp writes lost rows: $(cat "$A/intake-skip-noted.tsv")"

# The station route bypasses config reconciliation, and loop.sh launches the detached station on the requested cadence and timeout.
grep -Fq -- '--intake-judge) SCHED_STATION=true; intake_judge_station_tick ;;' "$engine_dir/mac-autopilot/scheduler.sh" || fail 'scheduler.sh does not route --intake-judge'
grep -Fq '"${1:-}" != --intake-judge' "$engine_dir/mac-autopilot/scheduler.sh" || fail 'the station would reconcile runtime config'
grep -Fq '"${AUTOPI_INTAKE_JUDGE_KILL_SECONDS:-1200}" bash "$LIVE/scheduler.sh" --intake-judge' "$engine_dir/mac-autopilot/loop.sh" || fail 'loop.sh does not apply the station kill timeout'

echo 'intake-judge-station.test.sh: pass (oldest-first cap, parallel bound, claims, freshness fallback, no-stamp skip and concurrent cooldown writes)'
