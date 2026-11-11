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
  # Stands in for the real check: a live owner defers the unit only while the walk's first pass asks for a verdict.
  footprint_room() {
    local owner
    owner="$(unit_field "$1" '.footprint_wait_owner // empty')"
    if [[ -n "$owner" && "$TICK_FOOTPRINT_DEFER" == true ]] && footprint_wait_owner_active "$owner"; then
      TICK_FOOTPRINT_DEFERRED["$1"]="$owner"; return 1
    fi
    set_unit "$1" 'del(.footprint_wait_owner,.footprint_wait_since)'
  }
  ensure_clone() { printf '%s\n' "$ROOT"; }
  resume_handoff_integration() { return 0; }
  verification_plan_for_state() { echo '{}'; }
  verification_plan_brief() { echo focused; }
  matt_method_rule() { :; }
  decision_scope() { :; }
  dispatch_ids=""
  dispatch_if_room() { dispatch_calls=$((dispatch_calls + 1)); dispatch_ids+="$1 "; return 0; }
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
[[ "$(hotspot_expand '["src/candidate"]')" == '["src/candidate"]' ]] || fail 'default admitted weak hotspot'
saved_hotspot_log="$HOTSPOT_LOG"
for ((i=0;i<8;i++)); do HOTSPOT_LOG+=$'\001\nsrc/candidate\nsrc/hot\n'; done
[[ "$(hotspot_expand '["src/candidate"]')" == '["src/candidate"]' ]] || fail 'expansion is not off by default'
ZF_FOOTPRINT_HOTSPOT_MIN=10
[[ "$(hotspot_expand '["src/candidate"]')" == '["src/candidate","src/hot"]' ]] || fail 'minimum 10 did not restore the previous default'
unset ZF_FOOTPRINT_HOTSPOT_MIN
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
  grep -Fq "footprint-hotspot-invalid-min value=$invalid default=off" "$LOG" || fail 'invalid minimum was not logged'
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
TICK_FOOTPRINT_DEFER=true
footprint_preflight_snapshot || fail 'batch preflight failed'
[[ -z "${TICK_FOOTPRINT_PREFLIGHT_CONFLICT[candidate]:-}" && "${TICK_FOOTPRINT_PREFLIGHT_CONFLICT[direct]:-}" == owner ]] || fail 'batch preflight applied wrong threshold'
# A second preflight over the same heads and main reads the cache and reaches the same verdicts.
TICK_FOOTPRINT_PREFLIGHT_STATUS=not-started TICK_FOOTPRINT_CONFLICT_VALID=false TICK_ACTIVE_FOOTPRINTS_VALID=false
footprint_preflight_snapshot || fail 'second preflight failed'
[[ "$FOOTPRINT_CACHE_PREFLIGHT" == hit && -z "${TICK_FOOTPRINT_PREFLIGHT_CONFLICT[candidate]:-}" && "${TICK_FOOTPRINT_PREFLIGHT_CONFLICT[direct]:-}" == owner ]] \
  || fail "second preflight did not hit the expansion cache (state=$FOOTPRINT_CACHE_PREFLIGHT)"
footprint_room candidate "$(jq -c '.units[] | select(.id=="candidate")' "$UNITS")" true || fail 'weak expansion blocked admission'
grep -Fq 'footprint-shadow-old-rule-would-block unit=candidate owner=owner candidate_path=src/hot owner_path=src/hot source=expansion cochange_count=2' "$LOG" || fail 'shadow attribution missing'
TICK_FOOTPRINT_ROOM_USEC=0 TICK_FOOTPRINT_ROOM_CALLS=0 TICK_FOOTPRINT_ROOM_WAITS=0
if footprint_room direct "$(jq -c '.units[] | select(.id=="direct")' "$UNITS")" true; then fail 'direct overlap admitted'; fi
(( TICK_FOOTPRINT_ROOM_CALLS == 1 && TICK_FOOTPRINT_ROOM_WAITS == 1 && TICK_FOOTPRINT_ROOM_USEC > 0 )) || fail 'a waiter was not counted in the phase summary'
grep -Fq 'footprint wait unit=direct owner=owner candidate_path=src/hot owner_path=src/hot source=original cochange_count=not-applicable' "$LOG" || fail 'direct attribution missing'
# Footprint orders and never refuses: outside the walk's first pass the deferred unit starts, and the shadow logs what the old gate held.
TICK_FOOTPRINT_DEFER=false
footprint_room direct "$(jq -c '.units[] | select(.id=="direct")' "$UNITS")" true || fail 'a deferred unit was refused outside the first pass'
grep -Fq 'footprint-shadow-old-rule-would-block unit=direct owner=owner candidate_path=src/hot owner_path=src/hot source=original' "$LOG" || fail 'forced start did not log the old-rule shadow'
(( ${#TICK_FOOTPRINT_DEFERRED[@]} == 0 )) || fail 'a started unit stayed in the deferred set'
TICK_FOOTPRINT_DEFER=true
ZF_FOOTPRINT_HOTSPOT_MIN=1
TICK_CHECK_SCOPE_SOURCE=()
if footprint_room candidate "$(jq -c '.units[] | select(.id=="candidate")' "$UNITS")" true; then fail 'old rule did not block weak expansion'; fi
grep -Fq 'footprint wait unit=candidate owner=owner candidate_path=src/hot owner_path=src/hot source=expansion cochange_count=2' "$LOG" || fail 'expansion attribution missing'
unset ZF_FOOTPRINT_HOTSPOT_MIN
TICK_FOOTPRINT_DEFER=false

# Three recent conflicts make the path hot. A live writer whose file is inside the candidate's
# predicted directory scope makes it wait; a two-event overlap on another file keeps today's behavior.
mkdir -p "$ROOT/packages/fixture/src"
printf 'hot\n' > "$ROOT/packages/fixture/src/hot.ts"
printf 'cold\n' > "$ROOT/packages/fixture/src/cold.ts"
printf 'owner\n' > "$ROOT/packages/fixture/owner-marker.ts"
printf 'candidate\n' > "$ROOT/packages/fixture/candidate-marker.ts"
git -C "$ROOT" add .
git -C "$ROOT" commit -qm 'hot conflict scope fixture'
git -C "$ROOT" update-ref refs/remotes/origin/main HEAD
hot_path=packages/fixture/src/hot.ts
cold_path=packages/fixture/src/cold.ts
candidate_scope='["packages/fixture/src","packages/fixture/candidate-marker.ts"]'
jq -n --arg at "$STAMP" --arg hot "$hot_path" --arg cold "$cold_path" '
  {units:
    ([range(0;3) as $i | {id:("hot-history-" + ($i|tostring)),history:[{stage:"merge-conflict",at:$at,conflict_files:($hot+" count=1")}]}]
     + [range(0;2) as $i | {id:("cold-history-" + ($i|tostring)),history:[{stage:"merge-conflict",at:$at,conflict_files:($cold+" count=1")}]}])}
' > "$UNITS_ARCHIVE"
write_units --argjson scope "$candidate_scope" '{units:[
  {id:"hot-candidate",stage:"implement-pending",footprint:$scope},
  {id:"cold-candidate",stage:"implement-pending",footprint:$scope}]}'
: > "$LOG"
TICK_FOOTPRINT_HOT_CONFLICT_PATHS='[]'
TICK_FOOTPRINT_HOT_CONFLICT_PATHS_LOADED=false
TICK_FOOTPRINT_PREFLIGHT_STATUS=ready; TICK_FOOTPRINT_CONFLICT_VALID=true
footprint_preflight_snapshot || fail 'hot conflict paths did not load through preflight'
[[ "$TICK_FOOTPRINT_HOT_CONFLICT_PATHS_LOADED" == true ]] || fail 'per-tick footprint preflight did not load hot conflict paths'
[[ "$TICK_FOOTPRINT_HOT_CONFLICT_PATHS" == '["packages/fixture/src/hot.ts"]' ]] || fail "three events did not select only the hot path: $TICK_FOOTPRINT_HOT_CONFLICT_PATHS"
hot_owner='[{"id":"hot-owner","stage":"implement","footprint":["packages/fixture/src/hot.ts","packages/fixture/owner-marker.ts"]}]'
hot_rows=$'hot-candidate\t'"$candidate_scope"$'\t'"$candidate_scope"
hot_conflict="$(active_footprint_conflicts_batch "$hot_owner" "$hot_rows")"
[[ "$hot_conflict" == $'hot-candidate\thot-owner' ]] || fail "hot live-writer overlap was not ordered: $hot_conflict"
TICK_ACTIVE_FOOTPRINTS="$hot_owner"; TICK_ACTIVE_FOOTPRINTS_VALID=true
TICK_FOOTPRINT_PREFLIGHT_STATUS=ready; TICK_FOOTPRINT_CONFLICT_VALID=true
TICK_FOOTPRINT_PREFLIGHT_CONFLICT=(); TICK_FOOTPRINT_PREFLIGHT_CONFLICT[hot-candidate]=hot-owner
TICK_FOOTPRINT_CACHE[hot-candidate]="$candidate_scope"; TICK_CHECK_SCOPE[hot-candidate]="$candidate_scope"; TICK_HOTSPOT_COUNTS[hot-candidate]='{}'
TICK_FOOTPRINT_DEFER=true
hot_unit="$(jqf -c '.units[] | select(.id=="hot-candidate")' "$UNITS")"
if _footprint_room hot-candidate "$hot_unit" false; then fail 'hot candidate did not wait behind its live writer'; fi
[[ "$(jqf -r '.units[] | select(.id=="hot-candidate") | .footprint_wait_owner // empty' "$UNITS")" == hot-owner ]] || fail 'hot wait was not recorded on the candidate'
cold_owner='[{"id":"cold-owner","stage":"implement","footprint":["packages/fixture/src/cold.ts","packages/fixture/owner-marker.ts"]}]'
cold_rows=$'cold-candidate\t'"$candidate_scope"$'\t'"$candidate_scope"
cold_conflict="$(active_footprint_conflicts_batch "$cold_owner" "$cold_rows")"
[[ -z "$cold_conflict" ]] || fail "non-hot directory/file overlap changed today's behavior: $cold_conflict"
TICK_ACTIVE_FOOTPRINTS="$cold_owner"; TICK_ACTIVE_FOOTPRINTS_VALID=true
TICK_FOOTPRINT_PREFLIGHT_STATUS=ready; TICK_FOOTPRINT_CONFLICT_VALID=true; TICK_FOOTPRINT_PREFLIGHT_CONFLICT=()
cold_unit="$(jqf -c '.units[] | select(.id=="cold-candidate")' "$UNITS")"
_footprint_room cold-candidate "$cold_unit" false || fail 'non-hot overlap was made to wait'
[[ -z "$(jqf -r '.units[] | select(.id=="cold-candidate") | .footprint_wait_owner // empty' "$UNITS")" ]] || fail 'non-hot candidate retained a wait marker'
[[ "$(grep -cF 'footprint hot-conflict paths window=24h threshold=3' "$LOG")" == 1 ]] || fail 'hot paths were not logged once per tick'
grep -Fq "paths=$hot_path" "$LOG" || fail 'hot path was omitted from the tick log'
grep -Fq "$cold_path" "$LOG" && fail 'the two-event cold path was logged as hot'

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
[[ "$dispatch_calls" == 1 ]] || fail 'a live owner left a free slot idle: its waiter never started'
footprint_wait_mark live-waiter live-owner "$(jqf -c '.units[] | select(.id=="live-waiter")' "$UNITS")"
# Order only: the unit a live owner overlaps starts after the one nobody overlaps, even when it comes first.
write_units '{units:[
  {id:"live-owner",stage:"implement",footprint:["packages/fixture/shared.ts"]},
  {id:"overlap-first",stage:"implement-pending",task:"fixture task",branch:"agent/overlap-first",
   footprint:["packages/fixture/shared.ts"],footprint_wait_owner:"live-owner",history:[]},
  {id:"free-second",stage:"implement-pending",task:"fixture task",branch:"agent/free-second",footprint:["packages/fixture/free.ts"],history:[]}]}'
pending_fixture_stubs
dispatch_pending true
[[ "$dispatch_ids" == 'free-second overlap-first ' ]] || fail "footprint did not order the walk: [$dispatch_ids]"
write_units '{units:[
  {id:"live-owner",stage:"implement",footprint:["packages/fixture/shared.ts"]},
  {id:"live-waiter",stage:"implement-pending",task:"fixture task",branch:"agent/live-waiter",
   footprint:["packages/fixture/shared.ts"],footprint_wait_owner:"live-owner",history:[]}]}'
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

# Expansion cache: the same head and main hit without the expensive step; a moved main, a new head, another hotspot floor and require_fresh miss.
git -C "$ROOT" init -q
git -C "$ROOT" config user.email t@t.invalid; git -C "$ROOT" config user.name t
printf 'a\n' > "$ROOT/a.txt"; git -C "$ROOT" add a.txt; git -C "$ROOT" commit -qm one
git -C "$ROOT" update-ref refs/remotes/origin/main HEAD
expand_count_file="$test_env_root/expand-calls"; : > "$expand_count_file"
hotspot_expand_batch() { echo x >> "$expand_count_file"; jq -c '[.[] | {id,scope,old_scope:.scope,counts:{}}]' <<<"$1"; }
expand_calls() { wc -l < "$expand_count_file" | tr -d ' '; }
cache_rows='[{"id":"c1","scope":["a.txt"],"head":"h1"}]'
footprint_expand_rows "$cache_rows" false
[[ "$(expand_calls)" == 1 && "$FOOTPRINT_CACHE_STATE" == miss && "${TICK_CHECK_SCOPE[c1]}" == '["a.txt"]' ]] || fail 'first expansion was not a computed miss'
TICK_CHECK_SCOPE[c1]=cleared; TICK_OLD_SCOPE[c1]=cleared; TICK_HOTSPOT_COUNTS[c1]=cleared
footprint_expand_rows "$cache_rows" false
[[ "$(expand_calls)" == 1 && "$FOOTPRINT_CACHE_STATE" == hit ]] || fail "same head and main did not hit (calls=$(expand_calls) state=$FOOTPRINT_CACHE_STATE)"
[[ "${TICK_CHECK_SCOPE[c1]}" == '["a.txt"]' && "${TICK_OLD_SCOPE[c1]}" == '["a.txt"]' && "${TICK_HOTSPOT_COUNTS[c1]}" == '{}' ]] || fail 'a hit did not restore scope, old scope and counts'
footprint_expand_rows "$cache_rows" true
[[ "$(expand_calls)" == 2 && "$FOOTPRINT_CACHE_STATE" == miss ]] || fail 'require_fresh did not bypass the cache'
footprint_expand_rows '[{"id":"c1","scope":["a.txt"],"head":"h2"}]' false
[[ "$(expand_calls)" == 3 && "$FOOTPRINT_CACHE_STATE" == miss ]] || fail 'a new PR head did not miss'
ZF_FOOTPRINT_HOTSPOT_MIN=5 footprint_expand_rows "$cache_rows" false
[[ "$(expand_calls)" == 4 && "$FOOTPRINT_CACHE_STATE" == miss ]] || fail 'another hotspot floor did not miss'
old_main="$(git -C "$ROOT" rev-parse refs/remotes/origin/main)"
printf 'b\n' > "$ROOT/b.txt"; git -C "$ROOT" add b.txt; git -C "$ROOT" commit -qm two
git -C "$ROOT" update-ref refs/remotes/origin/main HEAD
footprint_expand_rows "$cache_rows" false
[[ "$(expand_calls)" == 5 && "$FOOTPRINT_CACHE_STATE" == miss ]] || fail 'a moved main did not miss'
footprint_expand_rows "$cache_rows" false
[[ "$(expand_calls)" == 5 && "$FOOTPRINT_CACHE_STATE" == hit ]] || fail 'the new main did not hit on its second call'
[[ -z "$(ls "$A/footprint-cache" | grep -v "^$(git -C "$ROOT" rev-parse refs/remotes/origin/main)-" || true)" ]] || fail 'entries of the old main were not pruned'
[[ -n "$old_main" ]] || fail 'fixture lost the old main'
unset -f hotspot_expand_batch

echo 'footprint-convoy.test.sh: pass (stale-owner release, live-owner lock, convoy dedupe, refill metrics, expansion cache)'
