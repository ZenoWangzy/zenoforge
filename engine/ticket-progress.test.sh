#!/usr/bin/env bash
set -euo pipefail
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/test-env.sh"

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
root_tmp="$(mktemp -d)"
tmp="$root_tmp"
trap 'rm -rf -- "$root_tmp"' EXIT
now="$(date -u +%s)"
health="$tmp/health"
printf 'triage OK fixture\nadvisor OK fixture\nimplement OK fixture\ndeploy OK fixture\nacceptance OK fixture\n' > "$health"

issue_file="$tmp/issues.json"
transition_file="$tmp/home/state/ticket-transitions.jsonl"
mkdir -p "$tmp/home/state"
add_event() {
  local issue="$1" at="$2" from="$3" to="$4" kind="$5" progress="$6" writer="${7:-fixture}"
  jq -cn --arg ts "$(date -u -d "@$at" +%Y-%m-%dT%H:%M:%SZ)" \
    --arg from "$from" --arg to "$to" --arg kind "$kind" --arg writer "$writer" \
    --argjson issue "$issue" --argjson progress "$progress" \
    '{ts:$ts,issue:$issue,from_stage:$from,to_stage:$to,kind:$kind,progress:$progress,writer:$writer}' \
    >> "$transition_file"
}
run_eval() {
  AGENT_HOME="$tmp/home" bash "$SCRIPT_DIR/ticket-progress.sh" "$issue_file" "$health" "$now"
}

# Seven flips in 58 minutes, with no progress event, cross threshold before 60m.
loop_start="$((now - 58 * 60))"
for flip in {0..6}; do
  at="$((loop_start + flip * 8 * 60))"
  if (( flip % 2 == 0 )); then from=ready-for-agent; to=needs-advisor; writer=route_to_advisor
  else from=needs-advisor; to=ready-for-agent; writer=prepare_pipeline_system_issue; fi
  add_event 1813 "$at" "$from" "$to" flip false "$writer"
done
add_event 1815 "$((now - 60))" untracked needs-triage advance true
jq -n --arg updated "$(date -u -d "@$now" +%Y-%m-%dT%H:%M:%SZ)" \
  '[{number:1813,state:"OPEN",createdAt:$updated,updatedAt:$updated,labels:[{name:"needs-advisor"},{name:"pipeline-system"}]},
    {number:1814,state:"OPEN",createdAt:$updated,updatedAt:$updated,labels:[{name:"on-hold"},{name:"needs-advisor"}]},
    {number:1815,state:"OPEN",createdAt:$updated,updatedAt:$updated,labels:[]} ]' > "$issue_file"
first="$(run_eval)"
grep -Fq 'progress STUCK' <<< "$first"
grep -Fq '#1813 needs-advisor age=' <<< "$first"
test "$(jq -r '.expected_ticket_count' "$tmp/home/state/ticket-stage-status.json")" = 3
test "$(jq -r '.evaluated_ticket_count' "$tmp/home/state/ticket-stage-status.json")" = 3
test "$(jq -r '.pipeline_system_open_count' "$tmp/home/state/ticket-stage-status.json")" = 1
test "$(jq -r '.pipeline_system_evaluated_count' "$tmp/home/state/ticket-stage-status.json")" = 1
test "$(jq -r '.on_hold_ticket_count' "$tmp/home/state/ticket-stage-status.json")" = 1
test "$(jq -r '.on_hold_excluded_count' "$tmp/home/state/ticket-stage-status.json")" = 1
test "$(jq -r '.tickets["1814"].stage' "$tmp/home/state/ticket-stage-status.json")" = on-hold
test "$(jq -r '.tickets["1814"].verdict' "$tmp/home/state/ticket-stage-status.json")" = WAITING
test "$(jq -r '.tickets["1815"].stage' "$tmp/home/state/ticket-stage-status.json")" = needs-triage
run_eval >/dev/null
test "$(grep -cF 'ticket-progress issue=#1813' "$tmp/home/supervisor-inbox")" -eq 1
test "$(jq -r '.tickets["1813"].verdict' "$tmp/home/state/ticket-stage-status.json")" = STUCK

# Normal ticket advances through each consuming stage; no episode is raised.
tmp="$tmp/normal"
mkdir -p "$tmp/home/state"
transition_file="$tmp/home/state/ticket-transitions.jsonl"
issue_file="$tmp/issues.json"
write_current_stage() {
  local stage="$1"
  jq -n --arg stage "$stage" --arg updated "$(date -u -d "@$now" +%Y-%m-%dT%H:%M:%SZ)" \
    '[{number:1891,state:"OPEN",createdAt:$updated,updatedAt:$updated,labels:[{name:$stage}]}]' > "$issue_file"
}
for row in \
  'untracked needs-triage 45' \
  'needs-triage ready-for-agent 35' \
  'ready-for-agent ready-for-agent 27' \
  'ready-for-agent awaiting-release 20' \
  'awaiting-release released 10'; do
  read -r from to minutes <<< "$row"
  kind=advance; progress=true
  if [ "$from" = ready-for-agent ] && [ "$to" = ready-for-agent ]; then kind=implement; fi
  add_event 1891 "$((now - minutes * 60))" "$from" "$to" "$kind" "$progress"
  write_current_stage "$to"
  current="$(run_eval)"
  grep -Fq 'progress OK' <<< "$current"
done
add_event 1891 "$((now - 60))" released closed close true
printf '[]\n' > "$issue_file"
grep -Fq 'progress OK' <<< "$(run_eval)"
test ! -e "$tmp/home/supervisor-inbox"

# Maintainer-test work uses a 30m bound, tighter than ordinary triage's 120m.
tmp="$tmp/founder-test"
mkdir -p "$tmp/home/state"
transition_file="$tmp/home/state/ticket-transitions.jsonl"
issue_file="$tmp/issues.json"
maintainer_old="$(date -u -d "@$((now - 31 * 60))" +%Y-%m-%dT%H:%M:%SZ)"
jq -n --arg at "$maintainer_old" \
  '[{number:1894,state:"OPEN",createdAt:$at,updatedAt:$at,labels:[{name:"needs-triage"},{name:"founder-test"}]},
    {number:1895,state:"OPEN",createdAt:$at,updatedAt:$at,labels:[{name:"needs-triage"}]}]' > "$issue_file"
grep -Fq 'progress STUCK' <<< "$(run_eval)"
test "$(jq -r '.tickets["1894"].verdict' "$tmp/home/state/ticket-stage-status.json")" = STUCK
grep -Fq 'founder-test; stage-bound age=31m bound=30m' "$tmp/home/state/ticket-stage-status.json"
test "$(jq -r '.tickets["1895"].verdict' "$tmp/home/state/ticket-stage-status.json")" = OK

# Reproduce issue 2839 at admission: zero attempts, guarded, ready-for-agent,
# founder-test + priority:top, no implement decision yet, and six full slots.
# Also include a priority-only candidate missed under the same capacity wait.
tmp="$root_tmp/priority-top"
mkdir -p "$tmp/home/state"
transition_file="$tmp/home/state/ticket-transitions.jsonl"
issue_file="$tmp/issues.json"
priority_old="$(date -u -d "@$((now - 61 * 60))" +%Y-%m-%dT%H:%M:%SZ)"
maintainer_priority_old="$(date -u -d "@$((now - 31 * 60))" +%Y-%m-%dT%H:%M:%SZ)"
printf 'implement SLOW capacity-bound active=6/6, ready=166, oldest age=61m\n' > "$health"
jq -n --arg priority_at "$priority_old" --arg maintainer_at "$maintainer_priority_old" '[
  {number:2838,state:"OPEN",createdAt:$priority_at,updatedAt:$priority_at,labels:[{name:"ready-for-agent"},{name:"priority:top"}]},
  {number:2839,state:"OPEN",createdAt:$maintainer_at,updatedAt:$maintainer_at,labels:[{name:"bug"},{name:"ready-for-agent"},{name:"priority:top"},{name:"founder-test"}]}
]' > "$issue_file"
jq -n --arg at "$maintainer_priority_old" \
  '{attempts:0,guarded:true,guarded_at:$at}' \
  > "$tmp/home/state/2839.json"
priority_result="$(env -u PRIORITY_TOP_STAGE_BOUND_MINUTES AGENT_HOME="$tmp/home" \
  bash "$SCRIPT_DIR/ticket-progress.sh" "$issue_file" "$health" "$now")"
grep -Fq 'progress STUCK' <<< "$priority_result"
grep -Fq 'priority:top; stage-bound age=61m bound=60m' "$tmp/home/state/ticket-stage-status.json"
grep -Fq 'founder-test; stage-bound age=31m bound=30m' "$tmp/home/state/ticket-stage-status.json"
grep -Fq 'ticket-progress issue=#2838' "$tmp/home/supervisor-inbox"
grep -Fq 'ticket-progress issue=#2839' "$tmp/home/supervisor-inbox"

# The default is configurable, and a still-full lane waits until that bound.
tmp="$root_tmp/priority-top-override"
mkdir -p "$tmp/home/state"
transition_file="$tmp/home/state/ticket-transitions.jsonl"
issue_file="$tmp/issues.json"
jq -n --arg at "$priority_old" \
  '[{number:2838,state:"OPEN",createdAt:$at,updatedAt:$at,labels:[{name:"ready-for-agent"},{name:"priority:top"}]}]' > "$issue_file"
override_result="$(PRIORITY_TOP_STAGE_BOUND_MINUTES=90 AGENT_HOME="$tmp/home" \
  bash "$SCRIPT_DIR/ticket-progress.sh" "$issue_file" "$health" "$now")"
grep -Fq 'progress OK' <<< "$override_result"
test "$(jq -r '.tickets["2838"].verdict' "$tmp/home/state/ticket-stage-status.json")" = WAITING
test ! -e "$tmp/home/supervisor-inbox"

if PRIORITY_TOP_STAGE_BOUND_MINUTES=0 AGENT_HOME="$tmp/home" \
  bash "$SCRIPT_DIR/ticket-progress.sh" "$issue_file" "$health" "$now" >/dev/null 2>&1; then
  echo 'not ok - rejects invalid priority:top stage bound'
  exit 1
fi

# A priority ticket already running in the implement lane is not a starvation alert.
tmp="$root_tmp/priority-top-running"
mkdir -p "$tmp/home/state"
transition_file="$tmp/home/state/ticket-transitions.jsonl"
issue_file="$tmp/issues.json"
jq -n --arg at "$priority_old" \
  '[{number:2838,state:"OPEN",createdAt:$at,updatedAt:$at,labels:[{name:"ready-for-agent"},{name:"priority:top"}]}]' > "$issue_file"
jq -n '{implement_tick_decision:{outcome:"skipped",gate:"active-implement"}}' \
  > "$tmp/home/state/2838.json"
grep -Fq 'progress OK' <<< "$(env -u PRIORITY_TOP_STAGE_BOUND_MINUTES AGENT_HOME="$tmp/home" \
  bash "$SCRIPT_DIR/ticket-progress.sh" "$issue_file" "$health" "$now")"
test "$(jq -r '.tickets["2838"].verdict' "$tmp/home/state/ticket-stage-status.json")" = WAITING
test ! -e "$tmp/home/supervisor-inbox"

# A parked state has its own 60m bound; old advisor work waits on an unhealthy
# advisor node and does not generate a second ticket alarm.
tmp="$tmp/parked"
mkdir -p "$tmp/home/state"
transition_file="$tmp/home/state/ticket-transitions.jsonl"
issue_file="$tmp/issues.json"
parked_at="$(date -u -d "@$((now - 61 * 60))" +%Y-%m-%dT%H:%M:%SZ)"
jq -n --arg at "$parked_at" '[{number:1892,state:"OPEN",createdAt:$at,updatedAt:$at,labels:[{name:"ready-for-human"}]}]' > "$issue_file"
grep -Fq 'progress STUCK' <<< "$(run_eval)"
grep -Fq 'no-lane-consumer' "$tmp/home/state/ticket-stage-status.json"

tmp="$tmp/waiting"
mkdir -p "$tmp/home/state"
transition_file="$tmp/home/state/ticket-transitions.jsonl"
issue_file="$tmp/issues.json"
printf 'advisor BROKEN outage\n' > "$health"
advisor_old="$(date -u -d "@$((now - 4 * 60 * 60))" +%Y-%m-%dT%H:%M:%SZ)"
jq -n --arg at "$advisor_old" '[{number:1893,state:"OPEN",createdAt:$at,updatedAt:$at,labels:[{name:"needs-advisor"}]}]' > "$issue_file"
grep -Fq 'progress OK' <<< "$(run_eval)"
test "$(jq -r '.tickets["1893"].verdict' "$tmp/home/state/ticket-stage-status.json")" = WAITING

# An unclean shutdown leaves NUL bytes between appended rows; the evaluator
# repairs the log instead of failing every tick.
add_event 1893 "$((now - 120))" untracked needs-advisor advance true
head -c 223 /dev/zero >> "$transition_file"
add_event 1893 "$((now - 60))" needs-advisor needs-advisor advance true
grep -Fq 'progress OK' <<< "$(run_eval 2>/dev/null)"
test "$(tr -cd '\000' < "$transition_file" | wc -c)" -eq 0
test "$(wc -l < "$transition_file")" -eq 2

# Old ready tickets skipped for the same non-capacity reason keep one alert
# per blocker or gate, even while implement reports capacity saturation.
tmp="$root_tmp/blocked"
mkdir -p "$tmp/home/state"
transition_file="$tmp/home/state/ticket-transitions.jsonl"
issue_file="$tmp/issues.json"
health="$tmp/health"
blocked_at="$(date -u -d "@$((now - 600 * 60))" +%Y-%m-%dT%H:%M:%SZ)"
printf 'implement SLOW capacity-bound active=1/1, ready=4, oldest age=600m\n' > "$health"
jq -n --arg at "$blocked_at" '[
  {number:1237,title:"Open blocker",state:"OPEN",createdAt:$at,updatedAt:$at,labels:[],blockedBy:{nodes:[]}},
  {number:2201,title:"Blocked one",state:"OPEN",createdAt:$at,updatedAt:$at,labels:[{name:"ready-for-agent"}],blockedBy:{nodes:[{number:1237,state:"OPEN"}]}},
  {number:2202,title:"Blocked two",state:"OPEN",createdAt:$at,updatedAt:$at,labels:[{name:"ready-for-agent"}],blockedBy:{nodes:[{number:1237,state:"OPEN"}]}},
  {number:2203,title:"Gate one",state:"OPEN",createdAt:$at,updatedAt:$at,labels:[{name:"ready-for-agent"}],blockedBy:{nodes:[]}},
  {number:2204,title:"Gate two",state:"OPEN",createdAt:$at,updatedAt:$at,labels:[{name:"ready-for-agent"}],blockedBy:{nodes:[]}}
]' > "$issue_file"
for issue in 2201 2202; do
  jq -n '{implement_tick_decision:{outcome:"skipped",gate:"open-blocker",reason:"存在未关闭前置票",object:"阻塞票 #1237"}}' \
    > "$tmp/home/state/$issue.json"
done
for issue in 2203 2204; do
  jq -n '{implement_tick_decision:{outcome:"skipped",gate:"merged-agent-pr",reason:"已有 PR",object:"PR #2300"}}' \
    > "$tmp/home/state/$issue.json"
done
grep -Fq 'progress STUCK' <<< "$(run_eval)"
test "$(jq -r '.tickets["2201"].verdict' "$tmp/home/state/ticket-stage-status.json")" = STUCK
test "$(jq -r '.tickets["2203"].verdict' "$tmp/home/state/ticket-stage-status.json")" = STUCK
test "$(grep -c 'ticket-progress blocker=#1237 .*tickets=#2201,#2202' "$tmp/home/supervisor-inbox")" -eq 1
test "$(grep -c 'ticket-progress gate=merged-agent-pr .*tickets=#2203,#2204' "$tmp/home/supervisor-inbox")" -eq 1
run_eval >/dev/null
test "$(grep -c 'ticket-progress blocker=#1237 .*tickets=#2201,#2202' "$tmp/home/supervisor-inbox")" -eq 1
test "$(grep -c 'ticket-progress gate=merged-agent-pr .*tickets=#2203,#2204' "$tmp/home/supervisor-inbox")" -eq 1

# The supervisor archives and empties its inbox after reading it; an ongoing
# episode is not written again (every clear re-woke the bell, 2026-09-29).
: > "$tmp/home/supervisor-inbox"
run_eval >/dev/null
test ! -s "$tmp/home/supervisor-inbox"

# A candidate the implement scan did not reach waits on capacity like one that
# was refused a slot.
jq -n '{implement_tick_decision:{outcome:"skipped",gate:"budget-exhausted",reason:"implement 扫描预算耗尽",object:"#2203"}}' \
  > "$tmp/home/state/2203.json"
run_eval >/dev/null
test "$(jq -r '.tickets["2203"].verdict' "$tmp/home/state/ticket-stage-status.json")" = WAITING
test ! -s "$tmp/home/supervisor-inbox"
# A ticket whose implement is already running is in progress, not stuck; the
# implement node owns a run that hangs.
jq -n '{implement_tick_decision:{outcome:"skipped",gate:"active-implement",reason:"同一票已有 implement 在运行",object:"zf-implement-2203.service"}}' \
  > "$tmp/home/state/2203.json"
run_eval >/dev/null
test "$(jq -r '.tickets["2203"].verdict' "$tmp/home/state/ticket-stage-status.json")" = WAITING
test ! -s "$tmp/home/supervisor-inbox"
# A full pipeline-system lane waits even while the implement node reads OK
# because product slots are idle (issues 1989, 2023 and 2037, 2026-09-29).
printf 'implement OK 5 active, 84 ready\n' > "$health"
jq -n '{implement_tick_decision:{outcome:"skipped",gate:"capacity",reason:"pipeline-system implement capacity is full",object:"IMPLEMENT_CAP=4 PIPELINE_SYSTEM_IMPLEMENT_CAP=3"}}' \
  > "$tmp/home/state/2203.json"
run_eval >/dev/null
test "$(jq -r '.tickets["2203"].verdict' "$tmp/home/state/ticket-stage-status.json")" = WAITING
test ! -s "$tmp/home/supervisor-inbox"
# A ticket the latest tick dispatched is running, however long its label is old
# (issue 1906 was alerted 47h "stuck" minutes after dispatch, 2026-09-29).
jq -n '{implement_tick_decision:{outcome:"dispatched",gate:"implement-dispatch",reason:"dispatched",object:"#2203"}}' \
  > "$tmp/home/state/2203.json"
run_eval >/dev/null
test "$(jq -r '.tickets["2203"].verdict' "$tmp/home/state/ticket-stage-status.json")" = WAITING
test ! -s "$tmp/home/supervisor-inbox"
printf 'implement SLOW capacity-bound active=1/1, ready=4, oldest age=600m\n' > "$health"
# Host resources holding every dispatch is the same wait.
jq -n '{implement_tick_decision:{outcome:"skipped",gate:"dispatch-resources",reason:"主机资源不足",object:"host"}}' \
  > "$tmp/home/state/2203.json"
run_eval >/dev/null
test "$(jq -r '.tickets["2203"].verdict' "$tmp/home/state/ticket-stage-status.json")" = WAITING
test ! -s "$tmp/home/supervisor-inbox"
# Waiting for a running implement on the same files or package is the same wait:
# the gate clears when that run ends (issues 1909 and 1154 alerted, 2026-09-29).
for gate in active-scope-collision package-scope-cap; do
  jq -n --arg g "$gate" '{implement_tick_decision:{outcome:"skipped",gate:$g,reason:"wait",object:"scope"}}' \
    > "$tmp/home/state/2203.json"
  run_eval >/dev/null
  test "$(jq -r '.tickets["2203"].verdict' "$tmp/home/state/ticket-stage-status.json")" = WAITING
  test ! -s "$tmp/home/supervisor-inbox"
done

# run-recut.sh parks a recut parent as unrouted with no state label. While any
# child is open the parent waits on it (issue 1252 read as no-lane-consumer);
# once every child is closed an open parent is stuck again.
tmp="$root_tmp/umbrella"
mkdir -p "$tmp/home/state"
transition_file="$tmp/home/state/ticket-transitions.jsonl"
issue_file="$tmp/issues.json"
printf 'implement OK fixture\n' > "$health"
recut_at="$(date -u -d "@$((now - 120 * 60))" +%Y-%m-%dT%H:%M:%SZ)"
add_event 2210 "$((now - 120 * 60))" needs-recut unrouted park false run-recut.sh
jq -n '{recut_children:[2211]}' > "$tmp/home/state/2210.json"
jq -n --arg at "$recut_at" --arg now "$(date -u -d "@$now" +%Y-%m-%dT%H:%M:%SZ)" '[
  {number:2210,state:"OPEN",createdAt:$at,updatedAt:$at,labels:[{name:"enhancement"}]},
  {number:2211,state:"OPEN",createdAt:$now,updatedAt:$now,labels:[{name:"ready-for-agent"}]}
]' > "$issue_file"
grep -Fq 'progress OK' <<< "$(run_eval)"
test "$(jq -r '.tickets["2210"].stage' "$tmp/home/state/ticket-stage-status.json")" = recut-umbrella
test "$(jq -r '.tickets["2210"].verdict' "$tmp/home/state/ticket-stage-status.json")" = WAITING
test ! -e "$tmp/home/supervisor-inbox"
jq 'map(select(.number == 2210))' "$issue_file" > "$issue_file.tmp" && mv "$issue_file.tmp" "$issue_file"
grep -Fq 'progress STUCK' <<< "$(run_eval)"
grep -Fq 'ticket-progress issue=#2210 ' "$tmp/home/supervisor-inbox"


# An advisor "tracker" parent has no state label and no recut children: it waits on its child tickets and
# is never a no-lane-consumer (issue 1138 alerted hourly, 2026-10-03).
tmp="$root_tmp/tracker"
mkdir -p "$tmp/home/state"
transition_file="$tmp/home/state/ticket-transitions.jsonl"
issue_file="$tmp/issues.json"
printf 'implement OK fixture\n' > "$health"
tracker_at="$(date -u -d "@$((now - 120 * 60))" +%Y-%m-%dT%H:%M:%SZ)"
add_event 2212 "$((now - 120 * 60))" needs-advisor unrouted park false run-advisor-batch.sh
jq -n '{state:"tracker",tracker_parent:true}' > "$tmp/home/state/2212.json"
jq -n --arg at "$tracker_at" '[{number:2212,state:"OPEN",createdAt:$at,updatedAt:$at,labels:[{name:"enhancement"}]}]' > "$issue_file"
grep -Fq 'progress OK' <<< "$(run_eval)"
test "$(jq -r '.tickets["2212"].stage' "$tmp/home/state/ticket-stage-status.json")" = tracker
test "$(jq -r '.tickets["2212"].verdict' "$tmp/home/state/ticket-stage-status.json")" = WAITING
test ! -e "$tmp/home/supervisor-inbox"

# A founder-test ticket inside a running advisor batch waits on that batch; the 30m bound is not stuck
# (issue 2074, 2026-09-30). A batch job left behind by a dead unit hides nothing, and the triage batch
# marker counts the same way.
tmp="$root_tmp/batch"
mkdir -p "$tmp/home/state" "$tmp/bin"
transition_file="$tmp/home/state/ticket-transitions.jsonl"
issue_file="$tmp/issues.json"
printf 'triage OK fixture\nadvisor OK fixture\n' > "$health"
old_at="$(date -u -d "@$((now - 45 * 60))" +%Y-%m-%dT%H:%M:%SZ)"
add_event 2220 "$((now - 45 * 60))" needs-triage needs-advisor advance true
add_event 2221 "$((now - 45 * 60))" untracked needs-triage advance true
jq -n --arg at "$old_at" '[
  {number:2220,state:"OPEN",createdAt:$at,updatedAt:$at,labels:[{name:"needs-advisor"},{name:"founder-test"}]},
  {number:2221,state:"OPEN",createdAt:$at,updatedAt:$at,labels:[{name:"needs-triage"},{name:"founder-test"}]}]' > "$issue_file"
jq -n '{job:{job_id:"advisor-batch-7",members:[{issue:2220}]}}' > "$tmp/home/advisor-batch.json"
jq -n '{issues:[2221]}' > "$tmp/home/triage-batch-active.json"
cat > "$tmp/bin/systemctl" <<'STUB'
#!/usr/bin/env bash
case "$*" in
  *is-active*zf-web-advisor-provider-advisor-batch-7.service*) [ -f "$BATCH_UNITS_UP" ] ;;
  *list-units*zf-triage-batch.service*) [ -f "$BATCH_UNITS_UP" ] && echo 'zf-triage-batch.service loaded active running x'; exit 0 ;;
  *) exit 3 ;;
esac
STUB
chmod +x "$tmp/bin/systemctl"
run_batch_eval() {
  PATH="$tmp/bin:$PATH" BATCH_UNITS_UP="$tmp/units-up" AGENT_HOME="$tmp/home" \
    bash "$SCRIPT_DIR/ticket-progress.sh" "$issue_file" "$health" "$now"
}
touch "$tmp/units-up"
run_batch_eval >/dev/null
test "$(jq -r '.tickets["2220"].verdict' "$tmp/home/state/ticket-stage-status.json")" = WAITING
test "$(jq -r '.tickets["2221"].verdict' "$tmp/home/state/ticket-stage-status.json")" = WAITING
test ! -s "$tmp/home/supervisor-inbox"
rm -f "$tmp/units-up"
run_batch_eval >/dev/null
test "$(jq -r '.tickets["2220"].verdict' "$tmp/home/state/ticket-stage-status.json")" = STUCK
test "$(jq -r '.tickets["2221"].verdict' "$tmp/home/state/ticket-stage-status.json")" = STUCK
echo 'ticket-progress.test.sh: PASS'
