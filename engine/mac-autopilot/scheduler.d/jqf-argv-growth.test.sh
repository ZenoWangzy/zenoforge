#!/usr/bin/env bash
set -euo pipefail
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../../" && pwd -P)/test-env.sh"

here="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
engine="$(cd -- "$here/../.." && pwd -P)"
repo="$(cd -- "$engine/.." && pwd -P)"
tmp="$(mktemp -d)"
trap 'rm -rf -- "$tmp" "$test_env_root"' EXIT

source "$here/core.sh"
LOG="$tmp/jqf.log"
STAMP=JQF-ARGV-TEST

large_json="$(python3 -c 'import json; print(json.dumps("x" * 70000))')"
small_json="$(python3 -c 'import json; print(json.dumps("x" * 60000))')"
large_rc=0
if jqf -n --argjson payload "$large_json" '$payload' >"$tmp/large.out" 2>"$tmp/large.err"; then
  large_rc=0
else
  large_rc=$?
fi
[[ "$large_rc" == 126 ]] || { echo "not ok - 70 KiB --argjson refusal rc=$large_rc"; exit 1; }
grep -Fxq 'jqf: argv value payload is 70002 bytes > 65536; pass it via stdin or --slurpfile' "$tmp/large.err" \
  || { echo 'not ok - --argjson refusal did not name the value and byte count'; cat "$tmp/large.err"; exit 1; }
grep -Fq 'jqf error (rc=126) in main: jqf: argv value payload is 70002 bytes > 65536; pass it via stdin or --slurpfile' "$LOG" \
  || { echo 'not ok - --argjson refusal was not recorded by jqf'; exit 1; }
echo 'ok - jqf refuses a 70 KiB --argjson value with the named 64 KiB diagnostic'

small_len="$(jqf -n --argjson payload "$small_json" '$payload | length')"
[[ "$small_len" == 60000 ]] || { echo "not ok - 60 KiB --argjson value failed ($small_len)"; exit 1; }
echo 'ok - jqf accepts a 60 KiB --argjson value'

arg_rc=0
if jqf -n --arg payload "$(python3 -c 'print("y" * 70000)')" '$payload' >"$tmp/arg.out" 2>"$tmp/arg.err"; then
  arg_rc=0
else
  arg_rc=$?
fi
[[ "$arg_rc" == 126 ]] && grep -Fq 'jqf: argv value payload is 70000 bytes > 65536;' "$tmp/arg.err" \
  || { echo 'not ok - jqf did not refuse a 70 KiB --arg value'; exit 1; }
echo 'ok - jqf refuses a 70 KiB --arg value'

fixture="$tmp/runtime"
mkdir -p "$fixture/supervisor/autopi/alerts" "$fixture/repo"
cp "$engine/mac-autopilot/config.template.json" "$fixture/supervisor/autopi/config.json"
printf '{"units":[]}\n' > "$fixture/supervisor/autopi/units.json"
printf '{"workers":[]}\n' > "$fixture/supervisor/autopi/workers.json"
export MAC_AUTOPILOT_ROOT="$fixture/repo"
export MAC_AUTOPILOT_SUPERVISOR_DIR="$fixture/supervisor"
export MAC_AUTOPILOT_RUNTIME_DIR="$fixture/supervisor/autopi"
export REQUIRED_PR_CHECKS_FILE="$fixture/required-pr-checks.json"
export AUTOPI_TEST_LIBRARY_ONLY=true
printf '%s\n' '{"required":[],"current_regression":"","legacy_regression":[]}' > "$REQUIRED_PR_CHECKS_FILE"
source "$engine/mac-autopilot/scheduler.sh"

large_history_result="$(python3 -c 'print("r" * 70000, end="")')"
large_hist_filter="$(hist write-start "$large_history_result")" \
  || { echo 'not ok - hist rejected a 70 KiB result'; exit 1; }
printf '%s\n' "$large_hist_filter" > "$tmp/hist-filter.jq"
jqf -f "$tmp/hist-filter.jq" <<< '{"history":[]}' > "$tmp/hist-result.json" \
  || { echo 'not ok - hist emitted an invalid filter for a 70 KiB result'; exit 1; }
large_hist_len="$(jqf -r '.history[-1].result | length' "$tmp/hist-result.json")"
[[ "$large_hist_len" == 70000 ]] || { echo "not ok - hist result length is $large_hist_len"; exit 1; }
echo 'ok - hist preserves a 70 KiB result through jqf'

(
  python3 - "$UNITS" <<'PY'
import json, sys
footprint = [f"packages/large/{i:04d}/" + "x" * 100 for i in range(800)]
with open(sys.argv[1], "w", encoding="utf-8") as f:
    json.dump({"units": [{"id": "large-footprint", "stage": "implement-pending", "footprint": footprint}]}, f)
    f.write("\n")
PY
  large_footprint="$(jq -c '.units[0].footprint' "$UNITS")"
  large_footprint_bytes="$(printf '%s' "$large_footprint" | wc -c | tr -d ' ')"
  (( large_footprint_bytes > 65536 )) || { echo "not ok - dispatch footprint fixture is only $large_footprint_bytes bytes"; exit 1; }
  TICK_FOOTPRINT_CACHE[large-footprint]="$large_footprint"
  TICK_ACTIVE_FOOTPRINTS='[]'
  TICK_ACTIVE_FOOTPRINTS_VALID=true
  refill_stopped() { return 1; }
  incident_worker_prompt() { printf '%s' "$3"; }
  pre_dispatch_skip() { return 1; }
  room_for() { return 0; }
  size_admission_write_start() { return 0; }
  footprint_recurrence_brief() { :; }
  dispatch() { return 0; }
  dispatch_why_clear() { :; }
  dispatch_attempt_fields() { printf '.history[-1].attempt=null'; }
  footprint_merge_changed_owners() { :; }
  unit_json="$(jqf -c '.units[0]' "$UNITS")"
  if dispatch_if_room large-footprint implement implement impl.log impl.md model high prompt \
    '' "$fixture/repo" '' '' "$unit_json" true codex false configured codex; then
    :
  else
    dispatch_rc=$?
    echo "not ok - dispatch_if_room failed with a large footprint (rc=$dispatch_rc)"
    cat "$LOG"
    exit 1
  fi
  printf '%s\n' "$TICK_ACTIVE_FOOTPRINTS" > "$tmp/large-active-footprints.json"
  jq -e --arg id large-footprint --slurpfile expected "$UNITS" \
    'map(select(.id == $id))[0].footprint == $expected[0].units[0].footprint' \
    "$tmp/large-active-footprints.json" >/dev/null \
    || { echo 'not ok - dispatch_if_room lost the large footprint'; exit 1; }
  jq -c '{count:length,first_paths:.[0:5]}' <<<"$large_footprint" > "$tmp/large-summary.json"
  jq -e --slurpfile expected "$tmp/large-summary.json" \
    '.units[0].history[-1].result | fromjson == $expected[0]' "$UNITS" >/dev/null \
    || { echo 'not ok - write-start history did not use a compact footprint summary'; exit 1; }
  echo "ok - dispatch_if_room keeps a ${large_footprint_bytes}-byte footprint off argv and records a compact summary"
)

python3 - "$UNITS" <<'PY'
import json, sys
units = []
for i in range(320):
    units.append({
        "id": f"issue-{i:04d}",
        "stage": "implement-pending",
        "task": "queued work",
        "footprint_source": "pr-diff",
        "footprint": ["packages/shared/file.ts"],
        "history": [{"stage": "old", "result": "h" * 720} for _ in range(1)],
    })
with open(sys.argv[1], "w", encoding="utf-8") as f:
    json.dump({"units": units}, f)
    f.write("\n")
PY
legacy_owners_bytes="$(jq -c '[.units[] | . + {footprint:(.footprint // [])}]' "$UNITS" | wc -c | tr -d ' ')"
(( legacy_owners_bytes > 131072 )) || { echo "not ok - legacy owners fixture is only $legacy_owners_bytes bytes"; exit 1; }
owners="$(intake_footprint_snapshot)" || { echo 'not ok - large intake footprint snapshot failed'; exit 1; }
owner_count="$(jq -r 'length' <<<"$owners")"
[[ "$owner_count" == 320 ]] || { echo "not ok - footprint snapshot returned $owner_count owners"; exit 1; }
jq -e 'all(.[]; (keys | sort) == ["footprint","id","stage"] and .stage == "implement-pending" and .footprint == ["packages/shared/file.ts"])' <<<"$owners" >/dev/null \
  || { echo 'not ok - footprint snapshot did not retain only id, stage, and footprint'; exit 1; }
conflict="$(active_footprint_conflict '["packages/shared/file.ts"]' "$owners" '__new-intake-unit')" \
  || { echo 'not ok - footprint guard evaluation failed'; exit 1; }
[[ -n "$conflict" ]] || { echo 'not ok - large snapshot did not activate the overlapping-footprint guard'; exit 1; }
echo "ok - intake footprint snapshot covers 320 units (legacy owner JSON ${legacy_owners_bytes} bytes) and blocks an overlap"

python3 - "$UNITS" "$fixture/pr-census.json" <<'PY'
import json, sys
units = [{
    "id": "pr-starved", "pr": 9000, "stage": "ready-to-merge", "lane": "pr",
    "approved_sha": "a" * 40, "ci_slot_wait_since": "2026-11-03T00:00:00Z",
    "ci_slot_wait_ticks": 1,
}]
with open(sys.argv[1], "w", encoding="utf-8") as f:
    json.dump({"units": units}, f)
    f.write("\n")
prs = [{"number": i, "isDraft": False, "body": "x" * 700} for i in range(1, 320)]
prs[-1] = {"number": 9000, "isDraft": True, "body": "x" * 700}
with open(sys.argv[2], "w", encoding="utf-8") as f:
    json.dump(prs, f)
    f.write("\n")
PY
pr_census_bytes="$(wc -c < "$fixture/pr-census.json" | tr -d ' ')"
(( pr_census_bytes > 131072 )) || { echo "not ok - PR census fixture is only $pr_census_bytes bytes"; exit 1; }
tick_prs() { cat "$fixture/pr-census.json"; }
ci_pr_free_slots() { printf '1\n'; }
CI_SLOT_STARVE_SLOW_TICKS=2
ci_slot_starve_watch || { echo 'not ok - ci_slot_starve_watch failed on a large PR census'; exit 1; }
grep -Fq 'CI-SLOT-STARVE unit=pr-starved PR#9000' "$A/alerts/slo.md" \
  || { echo 'not ok - large PR census did not activate the starvation alert'; exit 1; }
jq -e '.units[0].ci_slot_starve_alerted == true' "$UNITS" >/dev/null \
  || { echo 'not ok - large PR census starvation marker was not persisted'; exit 1; }
echo "ok - ci_slot_starve_watch reads a ${pr_census_bytes}-byte PR census from a file and applies its guard"

echo 'ALL PASSED'
