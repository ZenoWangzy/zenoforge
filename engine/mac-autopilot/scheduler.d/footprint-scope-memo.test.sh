#!/usr/bin/env bash
# scheduler_footprint costs about 24 processes and is a pure function of the unit row and origin/main. Inside dispatch_pending
# (TICK_FOOTPRINT_MAIN set) a repeated row, whether asked for as a candidate or scanned as a live owner at each fresh snapshot,
# must not run it again; outside a pass (empty main) nothing is memoised.
set -euo pipefail
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)/test-env.sh"

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
engine_dir="$(cd -- "$script_dir/../.." && pwd -P)"
fixture="$test_env_root/footprint-scope-memo"
mkdir -p "$fixture/repo" "$fixture/supervisor/autopi/alerts"
export MAC_AUTOPILOT_ROOT="$fixture/repo"
export MAC_AUTOPILOT_SUPERVISOR_DIR="$fixture/supervisor"
export MAC_AUTOPILOT_RUNTIME_DIR="$fixture/supervisor/autopi"
export REQUIRED_PR_CHECKS_FILE="$engine_dir/mac-autopilot/required-pr-checks.json"
cp "$engine_dir/mac-autopilot/config.template.json" "$MAC_AUTOPILOT_RUNTIME_DIR/config.json"
printf '%s\n' '{"units":[]}' > "$MAC_AUTOPILOT_RUNTIME_DIR/units.json"
printf '%s\n' '{"workers":[]}' > "$MAC_AUTOPILOT_RUNTIME_DIR/workers.json"
export AUTOPI_TEST_LIBRARY_ONLY=true
source "$engine_dir/mac-autopilot/scheduler.sh"
unset AUTOPI_TEST_LIBRARY_ONLY

LOG="$MAC_AUTOPILOT_RUNTIME_DIR/scheduler.log"
UNITS="$MAC_AUTOPILOT_RUNTIME_DIR/units.json"
WORKERS="$MAC_AUTOPILOT_RUNTIME_DIR/workers.json"
STAMP="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
SCHED_LOCK_HELD=true

fail() { echo "footprint-scope-memo.test.sh: $*" >&2; exit 1; }
SF="$fixture/sf-calls"
scheduler_footprint() { echo c >> "$SF"; jq -c '.footprint // []' <<<"$1"; } # counts through a file: calls in $( ) and background jobs are invisible to variables
calls() { wc -l < "$SF" | tr -d ' '; }
rows='[{"id":"o1","stage":"implement","footprint":["src/a"]},{"id":"o2","stage":"repair","footprint":["src/b"]},{"id":"o3","stage":"implement","footprint":["src/c"]}]'
row1='{"id":"u1","stage":"implement-pending","footprint":["src/a","src/z"]}'
row2='{"id":"u2","stage":"implement-pending","footprint":["src/b"]}'

# Outside a pass: no memo.
: > "$SF"; TICK_FOOTPRINT_SCOPE_MEMO=(); TICK_FOOTPRINT_MAIN=''
footprint_scope_for "$row1" s1; footprint_scope_for "$row1" s2
[[ "$s1" == '["src/a","src/z"]' && "$s2" == "$s1" && "$(calls)" == 2 ]] || fail "without a main key the memo must be bypassed (calls=$(calls) s1=$s1)"

# In a pass: one call per distinct row and main.
: > "$SF"; TICK_FOOTPRINT_MAIN=aaa
footprint_scope_for "$row1" s1; footprint_scope_for "$row1" s2; footprint_scope_for "$row1" s3
[[ "$s1" == '["src/a","src/z"]' && "$s2" == "$s1" && "$s3" == "$s1" && "$(calls)" == 1 ]] || fail "a repeated row recomputed (calls=$(calls))"
footprint_scope_for "$row2" s4
[[ "$s4" == '["src/b"]' && "$(calls)" == 2 ]] || fail "a different row must compute (calls=$(calls) s4=$s4)"
TICK_FOOTPRINT_MAIN=bbb; footprint_scope_for "$row1" s5
[[ "$(calls)" == 3 ]] || fail "a new origin/main must recompute (calls=$(calls))"

# Live owners at each fresh snapshot: the first scan computes three, a repeat computes none, and the answer is the same.
: > "$SF"; TICK_FOOTPRINT_SCOPE_MEMO=(); TICK_FOOTPRINT_MAIN=ccc
first="$(resolve_active_footprints "$rows")"; after_first="$(calls)"
# The scan's own $( ) cannot keep the memo (the old shell never sees it), so the real call sits in this shell.
resolve_active_footprints "$rows" > "$fixture/scan1.json"
: > "$SF"
resolve_active_footprints "$rows" > "$fixture/scan2.json"
[[ "$(calls)" == 0 ]] || fail "the second snapshot of the same owners recomputed $(calls) scopes"
cmp -s "$fixture/scan1.json" "$fixture/scan2.json" || fail "memoised snapshot differs: $(cat "$fixture/scan1.json") vs $(cat "$fixture/scan2.json")"
[[ "$first" == "$(cat "$fixture/scan1.json")" && "$after_first" == 3 ]] || fail "first scan wrong (calls=$after_first)"
: > "$SF"; TICK_FOOTPRINT_MAIN=''
resolve_active_footprints "$rows" >/dev/null; resolve_active_footprints "$rows" >/dev/null
[[ "$(calls)" == 6 ]] || fail "outside a pass every scan must recompute (calls=$(calls))"
# The real callers snapshot inside $( ), which cannot fill the memo: priming in the caller's shell does, and the snapshot then computes nothing.
jq -n --argjson rows "$rows" '{units:$rows}' > "$UNITS"
jq -n '{workers:[range(1; 4) | {pid:(100000 + .),unit:("o" + tostring),type:"implement",workdir:""}]}' > "$WORKERS"
: > "$SF"; TICK_FOOTPRINT_SCOPE_MEMO=(); TICK_FOOTPRINT_MAIN=ddd
footprint_prime_owner_scopes
[[ "$(calls)" == 3 ]] || fail "priming must compute each live owner once (calls=$(calls))"
snap1="$(active_footprint_snapshot)"; snap2="$(active_footprint_snapshot)"; footprint_prime_owner_scopes
[[ "$(calls)" == 3 && "$snap1" == "$snap2" ]] || fail "a snapshot of primed owners recomputed (calls=$(calls))"
jq -e 'length == 3 and (map(.id) | sort) == ["o1","o2","o3"]' <<<"$snap1" >/dev/null || fail "snapshot lost an owner: $snap1"
echo "footprint-scope-memo.test.sh: pass (repeated rows and live-owner snapshots compute once per main; no memo outside a pass)"
