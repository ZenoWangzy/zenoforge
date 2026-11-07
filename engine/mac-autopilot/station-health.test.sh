#!/usr/bin/env bash
# station_health.py: a station with work waiting and nothing out for longer than its bound is STALLED and alerts;
# a station with nothing waiting is OK however long it was idle; a paused pipeline is PAUSED and alerts nothing.
set -euo pipefail
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/test-env.sh"
here="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
fail() { echo "not ok - station-health.test.sh: $*" >&2; jq -c .stations.review "$R/station-health.json" >&2 || true; exit 1; }
NOW=2026-11-07T06:00:00Z
R="$test_env_root/runtime"; mkdir -p "$R/alerts" "$AGENT_HOME/state" "$AGENT_HOME/logs"

# Shapes follow the live ledger, state files, triage logs, advisor results and scheduler.log.
python3 - "$R" "$AGENT_HOME" <<'PY'
import json, os, sys
R, H = sys.argv[1:]
def u(id, stage, hist, **extra):
    return {"id": id, "stage": stage, "history": [{"stage": s, "at": a, "result": ""} | ({"work_type": w} if w else {}) for s, a, w in hist], **extra}
units = [
    # review: pending since 03:00, last review verdict 02:00 -> 180 min with work waiting, bound 60
    u("issue-1", "review-pending", [("write-start", "2026-11-07T02:20:00Z", "implement"), ("write-end", "2026-11-07T02:50:00Z", None), ("pr-opened", "2026-11-07T03:00:00Z", None)]),
    u("issue-2", "merged", [("review-approve", "2026-11-07T01:55:00Z", None), ("review-approve", "2026-11-07T02:00:00Z", None)]),
    # repair: idle since 2026-11-01, nothing waits
    u("issue-3", "merged", [("write-start", "2026-11-01T10:00:00Z", "repair"), ("write-end", "2026-11-01T10:30:00Z", None)]),
    # implement: idle for days, a ticket entered the buffer 5 min ago -> not a stall yet
    u("issue-4", "implement-pending", [("write-start", "2026-11-02T10:00:00Z", "implement"), ("write-end", "2026-11-02T10:30:00Z", None), ("unblocked", "2026-11-07T05:55:00Z", None)]),
    # merge/CI: ci-ready 20 min after the previous event
    u("issue-5", "ready-to-merge", [("review-approve", "2026-11-07T01:00:00Z", None), ("ci-ready", "2026-11-07T01:20:00Z", None), ("slot-sync", "2026-11-07T05:50:00Z", None)], ci_wip_wait="abc"),
]
json.dump({"units": units}, open(f"{R}/units.json", "w"))
def state(n, **kw): json.dump(kw, open(f"{H}/state/{n}.json", "w"))
state(10, state="needs-triage", state_changed_at="2026-11-07T04:00:00Z")
state(11, state="needs-advisor", state_changed_at="2026-11-07T04:00:00Z")
state(12, state="ready-for-agent", state_changed_at="2026-11-07T05:30:00Z")
state(1, state="ready-for-agent", state_changed_at="2026-11-07T05:30:00Z")  # has issue-1: not waiting at intake
state(13, state="awaiting-release", deploy_state="pending", state_changed_at="2026-11-01T01:00:00Z")
state(14, state="awaiting-release", deploy_state="deployed", state_changed_at="2026-11-07T01:00:00Z")
open(f"{H}/logs/triage-triage-batch-20261107T050000Z-1.log", "w").write("tick_id=x\napplied_count=2\n")
json.dump({"tick": "a", "recorded_at": "2026-11-07T05:30:00Z", "outcome": "completed", "applied_count": 3}, open(f"{H}/logs/advisor-batch-20261107T053000Z.result.json", "w"))
json.dump({"tick": "b", "recorded_at": "2026-11-07T05:40:00Z", "outcome": "job-failed", "applied_count": 0}, open(f"{H}/logs/advisor-batch-20261107T054000Z.result.json", "w"))
open(f"{R}/scheduler.log", "w").write(
    "[2026-11-07T05:30:00Z] dispatch claim=owned issue=1 mode=fresh reason=initial pid=7 type=review unit=issue-1\n"
    "[2026-11-07T05:31:00Z] dispatch claim=owned issue=1 mode=fresh reason=initial pid=8 type=implement unit=issue-1\n")
PY
touch -d "$NOW - 1 hour" "$AGENT_HOME/logs/triage-triage-batch-20261107T050000Z-1.log"
run() { python3 "$here/station_health.py" --runtime "$R" --agent-home "$AGENT_HOME" --pause-file "$AGENT_HOME/PAUSE" --now "$NOW" --alert; }
field() { jq -r ".stations.$1.$2" "$R/station-health.json"; }

run
[[ "$(field review status)" == STALLED && "$(field review waiting)" == 1 && "$(field review stall_min)" == 180.0 ]] || fail 'review should be STALLED at 180 min'
[[ "$(field review out_24h)" == 3 && "$(field review last_out)" == 2026-11-07T02:00:00Z ]] || fail 'review out counts'
grep -q 'STATION-STALLED station=review waiting=1 stall-min=180 bound-min=60 last-out=2026-11-07T02:00:00Z' "$R/alerts/node-health.md" || fail 'no review alert line'
echo 'ok - stalled station reports and alerts'

[[ "$(field repair status)" == OK && "$(field repair waiting)" == 0 && "$(field repair stall_min)" == 0.0 ]] || fail 'idle repair with nothing waiting must be OK'
[[ "$(field implement status)" == OK && "$(field implement stall_min)" == 5.0 ]] || fail 'a fresh item after a long idle is not a stall'
[[ "$(field merge waiting)" == 0 && "$(field ci waiting)" == 1 ]] || fail 'a CI-slot wait belongs to the CI buffer, not merge'
[[ "$(field intake waiting)" == 1 && "$(field triage waiting)" == 1 && "$(field advisor waiting)" == 1 && "$(field release waiting)" == 1 ]] || fail 'buffer counts'
[[ "$(field triage out_24h)" == 2 && "$(field advisor out_24h)" == 3 && "$(field advisor out_1h)" == 3 ]] || fail 'triage/advisor outs (failed advisor job is not an out)'
[[ "$(field triage status)" == OK && "$(field advisor status)" == OK && "$(field release status)" == STALLED ]] || fail 'statuses'
[[ "$(grep -c STATION-STALLED "$R/alerts/node-health.md")" == 2 ]] || fail 'only review and release alert'
echo 'ok - idle station with nothing waiting is OK'

run
[[ "$(grep -c STATION-STALLED "$R/alerts/node-health.md")" == 2 ]] || fail 'the same hour must not alert twice'
jq -e '.admission_gaps.review.n == 1 and .admission_gaps.review.p50 == 150 and .admission_gaps.ci.p50 == 20' "$R/station-health.json" >/dev/null || fail 'review gap comes from the live dispatch line; ci gap from ci-ready'
grep -q '^review ' "$R/station-health.txt" || fail 'text view missing'
echo 'ok - admission gaps and repeat alert suppression'

: > "$R/alerts/node-health.md"
echo '{"reason":"test"}' > "$AGENT_HOME/PAUSE"
run
[[ "$(field review status)" == PAUSED && "$(field release status)" == PAUSED ]] || fail 'pause should report PAUSED'
[[ ! -s "$R/alerts/node-health.md" ]] || fail 'PAUSED must raise no alert'
echo 'ok - pause reports PAUSED and raises no alert'

# Intake held: a pass that took nothing on purpose is HELD, not STALLED, until the hold is 2 x the bound (90 -> 180 min) old.
R="$test_env_root/runtime-held"; H="$test_env_root/home-held"; mkdir -p "$R/alerts" "$H/state" "$H/logs"
echo '{"units":[]}' > "$R/units.json"
echo '{"state":"ready-for-agent","state_changed_at":"2026-11-07T01:00:00Z"}' > "$H/state/20.json"
run() { python3 "$here/station_health.py" --runtime "$R" --agent-home "$H" --pause-file "$H/PAUSE" --now "$NOW" --alert; }
stalls() { grep -c 'STATION-STALLED station=intake ' "$R/alerts/node-health.md" || true; }
run
[[ "$(field intake status)" == STALLED && "$(stalls)" == 1 ]] || fail 'no marker: intake with a 300 min wait must stay STALLED and alert'
: > "$R/alerts/node-health.md"
echo 2026-11-07T04:20:00Z > "$R/intake-held-since"
run
[[ "$(field intake status)" == HELD && "$(stalls)" == 0 ]] || fail 'a hold younger than 2 x bound must be HELD with no alert'
grep -q '^intake  *HELD' "$R/station-health.txt" || fail 'text view must show HELD'
echo 2026-11-07T02:00:00Z > "$R/intake-held-since"
touch "$R/intake-held-since"  # a fresh file time must not restart the clock: the hold start is the content
run
[[ "$(field intake status)" == STALLED && "$(stalls)" == 1 ]] || fail 'a hold older than 2 x bound must be STALLED and alert, measured from its start'
echo 'ok - held intake is HELD under 2 x bound and STALLED past it'

rm "$R/intake-held-since"; : > "$R/alerts/node-health.md"
# A re-entry to an existing unit (hold-handoff) is intake output, not only a unit's first history row.
jq -n '{units: [{id:"issue-30", stage:"implement-pending", history:[{stage:"pr-opened", at:"2026-11-06T01:00:00Z"}, {stage:"hold-handoff", at:"2026-11-07T05:50:00Z"}]}]}' > "$R/units.json"
run
[[ "$(field intake out_1h)" == 1 && "$(field intake last_out)" == 2026-11-07T05:50:00Z && "$(field intake status)" == OK ]] || fail 'hold-handoff must count as an intake out'
echo 'ok - hold-handoff counts as intake output'
