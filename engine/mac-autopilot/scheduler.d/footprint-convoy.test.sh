#!/usr/bin/env bash
set -euo pipefail
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)/test-env.sh"

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
engine_dir="$(cd -- "$script_dir/../.." && pwd -P)"
fixture="$test_env_root/footprint-convoy"
mkdir -p "$fixture/repo" "$fixture/supervisor/autopi/alerts"
export MAC_AUTOPILOT_ROOT="$fixture/repo"
export MAC_AUTOPILOT_SUPERVISOR_DIR="$fixture/supervisor"
export MAC_AUTOPILOT_RUNTIME_DIR="$fixture/supervisor/autopi"
export REQUIRED_PR_CHECKS_FILE="$engine_dir/mac-autopilot/required-pr-checks.json"
jq '.max_workers=8 | .implement_cap=8 | .hotfix_lane.supervisor_owned=false
  | .footprint_mutex.convoy_min_waiters=2 | .footprint_mutex.convoy_wait_minutes=1' \
  "$engine_dir/mac-autopilot/config.template.json" > "$MAC_AUTOPILOT_RUNTIME_DIR/config.json"
printf '%s\n' '{"units":[]}' > "$MAC_AUTOPILOT_RUNTIME_DIR/units.json"
printf '%s\n' '{"workers":[]}' > "$MAC_AUTOPILOT_RUNTIME_DIR/workers.json"
export AUTOPI_TEST_LIBRARY_ONLY=true
source "$engine_dir/mac-autopilot/scheduler.sh"
unset AUTOPI_TEST_LIBRARY_ONLY

LOG="$MAC_AUTOPILOT_RUNTIME_DIR/scheduler.log"
UNITS="$MAC_AUTOPILOT_RUNTIME_DIR/units.json"
WORKERS="$MAC_AUTOPILOT_RUNTIME_DIR/workers.json"
STAMP="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
NOW_EPOCH="$(date +%s)"
SCHED_LOCK_HELD=true
DRY_RUN=0

fail() { echo "footprint-convoy.test.sh: $*" >&2; exit 1; }
write_units() { jq -n "$@" > "$UNITS"; }
pending_fixture_stubs() {
  dispatch_calls=0
  dispatch_order() { jqf -c '.units[] | select(.stage | test("-pending$"))' "$UNITS"; }
  ticket_budget_reason() { return 0; }
  loop_rounds() { echo 0; }
  blocking_body_dependency() { return 0; }
  room_for() { return 0; }
  pick() { PICK_MODEL=fixture; PICK_EFFORT=high; return 0; }
  footprint_room() {
    local owner
    owner="$(unit_field "$1" '.footprint_wait_owner // empty')"
    if [[ -n "$owner" ]] && footprint_wait_owner_active "$owner"; then return 1; fi
    set_unit "$1" 'del(.footprint_wait_owner,.footprint_wait_since)'
  }
  ensure_clone() { printf '%s\n' "$ROOT"; }
  resume_handoff_integration() { return 0; }
  verification_plan_for_state() { echo '{}'; }
  verification_plan_brief() { echo focused; }
  matt_method_rule() { :; }
  decision_scope() { :; }
  dispatch_if_room() { dispatch_calls=$((dispatch_calls + 1)); return 0; }
  live_workers() { echo 0; }
  live_by_type() { echo 0; }
}

# Exercise the real expansion and admission path against a small, tracked history.
git -C "$ROOT" init -q -b main
git -C "$ROOT" config user.name fixture
git -C "$ROOT" config user.email fixture@example.invalid
mkdir -p "$ROOT/src"
printf 'x\n' > "$ROOT/src/candidate"
printf 'x\n' > "$ROOT/src/hot"
printf 'x\n' > "$ROOT/src/once"
git -C "$ROOT" add .
git -C "$ROOT" commit -qm base
git -C "$ROOT" update-ref refs/remotes/origin/main HEAD
HOTSPOT_LOG=$'\001\nsrc/candidate\nsrc/hot\n\001\nsrc/candidate\nsrc/hot\n\001\nsrc/candidate\nsrc/once'
HOTSPOT_LOG_LOADED=true HOTSPOT_LOG_OK=true
unset ZF_FOOTPRINT_HOTSPOT_MIN
[[ "$(hotspot_expand '["src/candidate"]')" == '["src/candidate"]' ]] || fail 'default minimum admitted weak hotspot'
saved_hotspot_log="$HOTSPOT_LOG"
for ((i=0;i<8;i++)); do HOTSPOT_LOG+=$'\001\nsrc/candidate\nsrc/hot\n'; done
[[ "$(hotspot_expand '["src/candidate"]')" == '["src/candidate","src/hot"]' ]] || fail 'default minimum excluded count 10'
HOTSPOT_LOG="$saved_hotspot_log"
ZF_FOOTPRINT_HOTSPOT_MIN=2
[[ "$(hotspot_expand '["src/candidate"]')" == '["src/candidate","src/hot"]' ]] || fail 'threshold did not include count 2'
ZF_FOOTPRINT_HOTSPOT_MIN=1
[[ "$(hotspot_expand '["src/candidate"]')" == '["src/candidate","src/hot"]' ]] || fail 'minimum 1 differs from old two-change floor'
# Compare against the former grouping, floor, ordering and top-12 algorithm.
old_result="$(jq -Rsc --argjson scope '["src/candidate"]' '
  def in_scope: . as $f | any($scope[]; . as $s | $s == $f or ($f | startswith($s + "/")));
  ([split("\u0001")[] | split("\n") | map(select(length > 0)) | unique
    | select(length > 1 and length <= 40) | select(any(.[]; in_scope))
    | .[] | select(in_scope | not)] | group_by(.)
    | map(select(length >= 2) | {f:.[0],n:length}) | sort_by(-.n) | .[:12] | map(.f)) as $added
  | ($scope + $added) | unique' <<<"$HOTSPOT_LOG")"
[[ "$(hotspot_expand '["src/candidate"]')" == "$old_result" ]] || fail 'minimum 1 diverged from the previous algorithm'
for invalid in 0 nope ""; do
  ZF_FOOTPRINT_HOTSPOT_MIN="$invalid"
  [[ "$(hotspot_expand '["src/candidate"]')" == '["src/candidate"]' ]] || fail "invalid minimum $invalid did not use default"
  grep -Fq "footprint-hotspot-invalid-min value=$invalid default=10" "$LOG" || fail 'invalid minimum was not logged'
done
unset ZF_FOOTPRINT_HOTSPOT_MIN
write_units '{units:[{id:"owner",stage:"implement",footprint:["src/hot"]},
 {id:"candidate",stage:"implement-pending",footprint:["src/candidate"]},
 {id:"direct",stage:"implement-pending",footprint:["src/hot"]}]}'
printf '%s\n' '{"workers":[{"pid":100,"unit":"owner","type":"implement"}]}' > "$WORKERS"
TICK_ACTIVE_FOOTPRINTS_VALID=false
TICK_FOOTPRINT_PREFLIGHT_STATUS=not-started
TICK_FOOTPRINT_CONFLICT_VALID=false
TICK_DISPATCH_LOCAL_REFILL=false
footprint_preflight_snapshot || fail 'batch preflight failed'
[[ -z "${TICK_FOOTPRINT_PREFLIGHT_CONFLICT[candidate]:-}" && "${TICK_FOOTPRINT_PREFLIGHT_CONFLICT[direct]:-}" == owner ]] || fail 'batch preflight applied wrong threshold'
footprint_room candidate "$(jq -c '.units[] | select(.id=="candidate")' "$UNITS")" true || fail 'weak expansion blocked admission'
grep -Fq 'footprint-shadow-old-rule-would-block unit=candidate owner=owner candidate_path=src/hot owner_path=src/hot source=expansion cochange_count=2' "$LOG" || fail 'shadow attribution missing'
if footprint_room direct "$(jq -c '.units[] | select(.id=="direct")' "$UNITS")" true; then fail 'direct overlap admitted'; fi
grep -Fq 'footprint wait unit=direct owner=owner candidate_path=src/hot owner_path=src/hot source=original cochange_count=not-applicable' "$LOG" || fail 'direct attribution missing'
ZF_FOOTPRINT_HOTSPOT_MIN=1
TICK_CHECK_SCOPE_SOURCE=()
if footprint_room candidate "$(jq -c '.units[] | select(.id=="candidate")' "$UNITS")" true; then fail 'old rule did not block weak expansion'; fi
grep -Fq 'footprint wait unit=candidate owner=owner candidate_path=src/hot owner_path=src/hot source=expansion cochange_count=2' "$LOG" || fail 'expansion attribution missing'
unset ZF_FOOTPRINT_HOTSPOT_MIN

# Directory predictions only conflict on known shared files, unless a side has no known files.
mkdir -p "$ROOT/packages/fleet-gateway/src/auth" "$ROOT/migrations/meta"
touch "$ROOT/packages/fleet-gateway/src/auth/browser-session.test.ts" "$ROOT/packages/fleet-gateway/src/other.ts" "$ROOT/migrations/meta/_journal.json"
git -C "$ROOT" add .
git -C "$ROOT" commit -qm directories
git -C "$ROOT" update-ref refs/remotes/origin/main HEAD
dirs='["packages/fleet-gateway","packages/fleet-gateway/src/other.ts"]'
owner='[{"id":"owner","footprint":["packages/fleet-gateway/src/auth/browser-session.test.ts"]}]'
[[ -z "$(active_footprint_conflict "$dirs" "$owner" candidate)" ]] || fail 'directory prefix blocked unrelated file'
shared='["packages/fleet-gateway","packages/fleet-gateway/src/auth/browser-session.test.ts"]'
[[ "$(active_footprint_conflict "$shared" "$owner" candidate)" == owner ]] || fail 'shared file admitted'
[[ "$(active_footprint_conflict '["packages/fleet-gateway"]' "$owner" candidate)" == owner ]] || fail 'unknown directory-only unit admitted'
[[ "$(active_footprint_conflict '["packages/fleet-gateway/src/other.ts"]' '[{"id":"owner","footprint":["packages/fleet-gateway"]}]' candidate)" == owner ]] || fail 'unknown directory-only owner admitted'
[[ "$(active_footprint_conflict "$dirs" "$owner" candidate '["packages/fleet-gateway"]')" == owner ]] || fail 'hotspot expansion masked unknown directory-only scope'
ZF_FOOTPRINT_DIRECTORY_PREFIX_MATCHING=1
[[ "$(active_footprint_conflict "$dirs" "$owner" candidate)" == owner ]] || fail 'legacy switch did not restore prefix matching'
unset ZF_FOOTPRINT_DIRECTORY_PREFIX_MATCHING
journal='[{"id":"owner","footprint":["migrations/meta/_journal.json"]}]'
[[ "$(active_footprint_conflict '["migrations/meta","packages/fleet-gateway/src/other.ts"]' "$journal" candidate)" == owner ]] || fail 'migration journal admitted'
SHARED_APPEND='["migrations/meta/_journal.json"]'
[[ "$(active_footprint_conflict '["migrations/meta/_journal.json"]' "$journal" candidate)" == owner ]] || fail 'shared-append removed migration journal lock'
SHARED_APPEND='[]'
TICK_OLD_SCOPE[candidate]="$dirs" TICK_CHECK_SCOPE[candidate]="$dirs"
footprint_shadow_directory_rule candidate "$owner"
grep -Fq 'footprint-shadow-old-rule-would-block unit=candidate owner=owner' "$LOG" || fail 'directory shadow missing'

# The merge skip records the main-side revision even when conflict files are unavailable.
(
  set_unit() { :; }
  hist() { printf '.'; }
  MAIN_HEAD=fixture-main-sha
  merge_conflict_to_repair fixture 123 'conflicts with main' hint ''
)
grep -Fq 'merge-conflict-attribution unit=fixture pr=123 pr_head=unknown main_sha=fixture-main-sha conflicting_files=unavailable' "$LOG" || fail 'merge attribution missing'

# Stale owner stage must stop suppressing the pending unit from intake and dispatch.
write_units '{units:[
  {id:"merged-owner",stage:"merged",footprint:["packages/fixture/shared.ts"]},
  {id:"stale-waiter",stage:"implement-pending",task:"fixture task",branch:"agent/stale-waiter",
   footprint:["packages/fixture/shared.ts"],footprint_wait_owner:"merged-owner",
   footprint_wait_since:"2026-11-03T00:00:00Z",history:[]}]}'
printf '%s\n' '{"workers":[]}' > "$WORKERS"
startable="$(startable_pending_count)"
[[ "$startable" == 1 ]] || fail "stale marker kept pending work unstartable (count=$startable)"
jqf -e '.units[] | select(.id=="stale-waiter") | has("footprint_wait_owner") | not' "$UNITS" >/dev/null \
  || fail 'stale owner marker was not cleared'
pending_fixture_stubs
dispatch_pending true
[[ "$dispatch_calls" == 1 ]] || fail "stale waiter did not reach dispatch (calls=$dispatch_calls)"

# A live owner retains the wait and its age; leaving the writer set clears its waiters.
write_units '{units:[
  {id:"live-owner",stage:"implement",footprint:["packages/fixture/shared.ts"]},
  {id:"live-waiter",stage:"implement-pending",task:"fixture task",branch:"agent/live-waiter",
   footprint:["packages/fixture/shared.ts"],footprint_wait_owner:"live-owner",history:[]}]}'
printf '%s\n' '{"workers":[{"pid":100,"unit":"live-owner","type":"implement"}]}' > "$WORKERS"
footprint_wait_mark live-waiter live-owner "$(jqf -c '.units[] | select(.id=="live-waiter")' "$UNITS")"
jqf -e '.units[] | select(.id=="live-waiter") | .footprint_wait_owner=="live-owner" and (.footprint_wait_since|type)=="string"' "$UNITS" >/dev/null \
  || fail 'live owner wait was not retained with an age marker'
[[ "$(startable_pending_count)" == 0 ]] || fail 'live owner waiter counted as startable'
pending_fixture_stubs
dispatch_pending true
[[ "$dispatch_calls" == 0 ]] || fail 'live owner waiter dispatched through the footprint lock'
set_unit live-owner '.stage="merged"'
jqf -e '.units[] | select(.id=="live-waiter") | (has("footprint_wait_owner") or has("footprint_wait_since")) | not' "$UNITS" >/dev/null \
  || fail 'owner transition to merged did not clear waiter markers'

# An aged convoy crosses the configured threshold once, even when checked on two ticks.
AGENT_HOME="$fixture/agent"; export AGENT_HOME
mkdir -p "$AGENT_HOME"
SCHEDULER_AGENT_LIB="$fixture/supervisor-inbox-test.sh"
cat > "$SCHEDULER_AGENT_LIB" <<'SH'
supervisor_inbox_append_once() {
  local key="$1" message="$2"
  grep -Fqx -- "$key" "$AGENT_HOME/footprint-convoy-keys" 2>/dev/null && return 0
  printf '%s\n' "$key" >> "$AGENT_HOME/footprint-convoy-keys"
  printf '%s\t%s\n' "$key" "$message" >> "$AGENT_HOME/footprint-convoy-inbox"
}
SH
since="$(date -u -d "@$((NOW_EPOCH - 180))" +%Y-%m-%dT%H:%M:%SZ)"
CFG="$(jq '.footprint_mutex.convoy_min_waiters=2 | .footprint_mutex.convoy_wait_minutes=1' <<<"$CFG")"
write_units --arg since "$since" '{units:[
  {id:"convoy-owner",stage:"implement",footprint:["packages/fixture/shared.ts"]},
  {id:"convoy-a",stage:"implement-pending",footprint_wait_owner:"convoy-owner",footprint_wait_since:$since},
  {id:"convoy-b",stage:"repair-pending",footprint_wait_owner:"convoy-owner",footprint_wait_since:$since}]}'
printf '%s\n' '{"workers":[{"pid":100,"unit":"convoy-owner","type":"implement"}]}' > "$WORKERS"
footprint_convoy_alert
footprint_convoy_alert
[[ "$(wc -l < "$AGENT_HOME/footprint-convoy-inbox")" == 1 ]] || fail 'convoy alert was not deduplicated across two ticks'
grep -Fq 'owner=convoy-owner' "$AGENT_HOME/footprint-convoy-inbox" \
  && grep -Fq 'waiters=convoy-a,convoy-b' "$AGENT_HOME/footprint-convoy-inbox" \
  || fail 'convoy inbox line omitted the owner or waiters'

# The refill summary combines slot state with footprint, handoff, and admission skips.
write_units '{units:[
  {id:"metric-owner",stage:"implement"},
  {id:"metric-footprint",stage:"implement-pending",footprint_wait_owner:"metric-owner"},
  {id:"metric-handoff",stage:"repair-pending",hold_handoff_waiting:true},
  {id:"metric-free",stage:"rereview-pending"}]}'
printf '%s\n' '{"workers":[{"pid":100,"unit":"metric-owner","type":"implement"}]}' > "$WORKERS"
: > "$LOG"
printf '%s\n' 'prior refill line' >> "$LOG"
log_start="$(wc -c < "$LOG")"
printf '%s\n' '[2026-11-03T00:00:00Z] execution admission decision mode=run-unit outcome=defer MemAvailable_mb=1 load1=0 ceiling=8 held=7 decision_cap=0 reason=resource-floor' >> "$LOG"
metrics="$(refill_dispatch_metrics "$log_start" 3)"
[[ "$metrics" == 'free_slots=5 pending=3 skips=footprint:1,handoff:1,memory:1' ]] \
  || fail "refill metrics were incomplete: $metrics"

echo 'footprint-convoy.test.sh: pass (stale-owner release, live-owner lock, convoy dedupe, refill metrics)'
