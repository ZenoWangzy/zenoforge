#!/usr/bin/env bash
set -euo pipefail

if (($# < 2 || $# > 4)); then
  echo "Usage: $0 <open-issues.json> <health-rows> [now-epoch] [state-index.json]" >&2
  exit 2
fi

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
source "$SCRIPT_DIR/lib.sh"
issues_file="$1"
health_file="$2"
now="${3:-$(date +%s)}"
[[ "$now" =~ ^[0-9]+$ ]] || { echo 'ticket-progress: now must be an epoch integer' >&2; exit 2; }
[[ "${LOOP_BREAK_THRESHOLD:-4}" =~ ^[1-9][0-9]*$ ]] || { echo 'ticket-progress: LOOP_BREAK_THRESHOLD must be a positive integer' >&2; exit 2; }
priority_top_stage_bound="${PRIORITY_TOP_STAGE_BOUND_MINUTES:-60}"
[[ "$priority_top_stage_bound" =~ ^[1-9][0-9]*$ ]] || { echo 'ticket-progress: PRIORITY_TOP_STAGE_BOUND_MINUTES must be a positive integer' >&2; exit 2; }
jq -e 'type == "array"' "$issues_file" >/dev/null
[ -r "$health_file" ] || { echo "ticket-progress: unreadable HEALTH rows: $health_file" >&2; exit 1; }

mkdir -p "$STATE_DIR"
transition_file="$STATE_DIR/ticket-transitions.jsonl"
events_file="$transition_file"
status_file="$STATE_DIR/ticket-stage-status.json"
episodes_file="$STATE_DIR/ticket-progress-episodes.json"
ticket_transitions_repair
[ -r "$events_file" ] || events_file=/dev/null
if ! jq -en --slurpfile events "$events_file" 'all($events[]; type == "object")' >/dev/null; then
  echo "ticket-progress: invalid transition record in $transition_file" >&2
  exit 1
fi
previous='{}'
if [ -r "$episodes_file" ]; then previous="$(jq -c '.episodes // {}' "$episodes_file" 2>/dev/null || printf '{}')"; fi
state_labels="$(printf '%s\n' "${ALL_STATE_LABELS[@]}" | jq -R . | jq -cs '.')"
lane_labels="$(pipeline_system_issue_labels_json 2>/dev/null || printf '[]')"
health_nodes="$(awk 'NF >= 2 { detail=""; for (i=3; i<=NF; i++) detail=detail (i==3 ? "" : " ") $i; print $1 "\t" $2 "\t" detail }' "$health_file" | jq -Rn '
  [inputs | split("\t") | {key:.[0],value:{status:.[1],detail:(.[2] // "")}}] | from_entries
')"
# Reuse node-health's one-pass state index; standalone callers build same maps
# in one Python pass rather than starting jq once per issue.
state_index_file="${4:-$AGENT_HOME/night/health-state-index-last-result.json}"
decisions_file="$(mktemp "$STATE_DIR/.ticket-progress-decisions.XXXXXX")"
umbrellas_file="$(mktemp "$STATE_DIR/.ticket-progress-umbrellas.XXXXXX")"
if jq -e --argjson now "$now" '
  def sampled: try (.sampled_at | fromdateiso8601) catch 0;
  (.state_index.implement_decisions | type == "object")
  and (.state_index.umbrellas | type == "object")
  and (sampled > 0 and sampled <= $now and ($now - sampled) <= 900)
' "$state_index_file" >/dev/null 2>&1; then
  jq -c '.state_index.implement_decisions' "$state_index_file" > "$decisions_file"
  jq -c '.state_index.umbrellas' "$state_index_file" > "$umbrellas_file"
else
  python3 - "$issues_file" "$STATE_DIR" "$state_labels" "$decisions_file" "$umbrellas_file" <<'PY'
import json
import sys
from pathlib import Path

issues_path, state_dir = Path(sys.argv[1]), Path(sys.argv[2])
state_labels = set(json.loads(sys.argv[3]))
decisions_path, umbrellas_path = Path(sys.argv[4]), Path(sys.argv[5])
issues = json.loads(issues_path.read_text(encoding="utf-8"))
decisions, umbrellas = {}, {}
for issue in issues:
    number = issue.get("number")
    if not isinstance(number, int) or isinstance(number, bool) or number < 1:
        continue
    labels = [label.get("name") for label in issue.get("labels", []) if isinstance(label, dict)]
    wants_decision = "ready-for-agent" in labels
    wants_umbrella = all(label not in state_labels for label in labels)
    if not wants_decision and not wants_umbrella:
        continue
    try:
        state = json.loads((state_dir / f"{number}.json").read_text(encoding="utf-8"))
    except (OSError, UnicodeError, json.JSONDecodeError):
        continue
    if not isinstance(state, dict):
        continue
    decision = state.get("implement_tick_decision")
    if wants_decision and isinstance(decision, dict):
        decisions[str(number)] = decision
    if wants_umbrella:
        if state.get("tracker_parent") is True or state.get("state") == "tracker":
            umbrellas[str(number)] = ["tracker"]
        else:
            children = state.get("recut_children")
            if isinstance(children, list) and children:
                umbrellas[str(number)] = [str(child) for child in children]
decisions_path.write_text(json.dumps(decisions, separators=(",", ":")) + "\n", encoding="utf-8")
umbrellas_path.write_text(json.dumps(umbrellas, separators=(",", ":")) + "\n", encoding="utf-8")
PY
fi
# A ticket a running triage or advisor batch is working on waits on that batch, not on its stage bound: on
# 2026-09-30 issue 2074 sat in a running advisor batch and was alerted as stuck at the 30m maintainer-test bound.
# The member files only count while their unit runs, so a killed batch cannot hide a ticket.
batch_members='[]'
if [ -r "$AGENT_HOME/triage-batch-active.json" ] && triage_batch_unit_active 2>/dev/null; then
  batch_members="$(jq -c '[.issues[]? | tostring]' "$AGENT_HOME/triage-batch-active.json" 2>/dev/null || printf '[]')"
fi
advisor_job="$(advisor_batch_job_json 2>/dev/null || true)"
advisor_job_id="$(jq -r '.job_id // empty' <<< "$advisor_job" 2>/dev/null || true)"
if [ -n "$advisor_job_id" ] && systemctl --user is-active --quiet "zf-web-advisor-provider-$advisor_job_id.service" 2>/dev/null; then
  batch_members="$(jq -c --argjson prior "$batch_members" '$prior + [.members[]?.issue | tostring]' <<< "$advisor_job" 2>/dev/null \
    || printf '%s' "$batch_members")"
fi
now_iso="$(date -u -d "@$now" +%Y-%m-%dT%H:%M:%SZ)"

result="$(jq -n \
  --slurpfile issues "$issues_file" \
  --slurpfile events "$events_file" \
  --argjson prior "$previous" \
  --argjson states "$state_labels" \
  --argjson lane_labels "$lane_labels" \
  --argjson health "$health_nodes" \
  --argjson batch_members "$batch_members" \
  --slurpfile decisions "$decisions_file" \
  --slurpfile umbrellas "$umbrellas_file" \
  --argjson priority_top_stage_bound "$priority_top_stage_bound" \
  --argjson now "$now" \
  --argjson flip_threshold "${LOOP_BREAK_THRESHOLD:-4}" \
  --arg now_iso "$now_iso" '
  def epoch: if type == "number" then . else try fromdateiso8601 catch 0 end;
  def age($at): if $at > 0 then (($now - $at) / 60 | floor | if . < 0 then 0 else . end) else 0 end;
  # Bounds: maintainer-test 30m; priority:top configurable (60m default); triage 120m, advisor 180m, implement 9h, release/acceptance 2h;
  # needs-recut and needs-owner 3h/2h, needs-info 24h, ready-for-human and
  # unrouted 60m, legacy parked labels 2h, terminal labels 24h.
  def bound($s):
    if $s == "needs-triage" then 120
    elif $s == "needs-advisor" then 180
    elif $s == "ready-for-agent" then 540
    elif $s == "awaiting-release" or $s == "released" then 120
    elif $s == "needs-recut" then 180
    elif $s == "needs-info" then 1440
    elif $s == "ready-for-human" then 60
    elif $s == "needs-owner" then 120
    elif $s == "awaiting-pipeline-sync" or $s == "awaiting-pipeline-health" then 120
    elif $s == "duplicate" or $s == "finish-first" or $s == "wontfix" or $s == "concluded" then 1440
    else 60 end;
  def no_lane($s):
    ($s == "unrouted" or $s == "ready-for-human" or $s == "needs-owner"
     or $s == "awaiting-pipeline-sync" or $s == "awaiting-pipeline-health"
     or $s == "duplicate" or $s == "finish-first" or $s == "wontfix" or $s == "concluded");
  def upstream($s):
    if $s == "needs-triage" then "triage"
    elif $s == "needs-advisor" then "advisor"
    elif $s == "ready-for-agent" then "implement"
    elif $s == "awaiting-release" then "deploy"
    elif $s == "released" then "acceptance"
    else "" end;
  ($issues[0] | map({key:(.number|tostring),value:true}) | from_entries) as $open_ids
  | ($events | map(. as $event | select($open_ids | has($event.issue|tostring)))
   | group_by(.issue | tostring)
   | map({key:(.[0].issue|tostring),value:sort_by(.ts|epoch)}) | from_entries) as $events_by_issue
  | ($issues[0] | map(
    . as $issue
    | ($issue.number | tostring) as $id
    | [$issue.labels[]?.name] as $labels
    | select(any($labels[]; . as $name | ($states | index($name)) != null)
        or any($labels[]; . as $name | ($lane_labels | index($name)) != null)
        or ($events_by_issue | has($id)))
    | (($labels | index("on-hold")) != null) as $held
    | (any($labels[]; . as $name | ($lane_labels | index($name)) != null)) as $pipeline_system
    | ((($labels | index("maintainer-test")) != null) and ($pipeline_system | not)) as $maintainer_test
    | (($labels | index("priority:top")) != null) as $priority_top
    | ([$states[] as $state | select(($labels | index($state)) != null) | $state][0] // null) as $labeled_stage
    | ($events_by_issue[$id] // []) as $ticket_events
    | ($labeled_stage == null and any(($umbrellas[0][$id] // [])[]; $open_ids[.] == true)) as $umbrella
    | ($labeled_stage == null and (($umbrellas[0][$id] // []) | index("tracker")) != null) as $tracker
    | (if $held then "on-hold" elif $umbrella then "recut-umbrella" elif $tracker then "tracker" else ($labeled_stage // ([$ticket_events[] | select(.to_stage != "closed")][-1].to_stage // "unrouted")) end) as $stage
    | ([$ticket_events[] | select(.to_stage == $stage)][-1].ts // $issue.updatedAt // $issue.createdAt // $now_iso | epoch) as $stage_at
    | ([$ticket_events[] | select(.progress == true)][-1].ts | epoch) as $last_progress_event
    | (if $last_progress_event > 0 then $last_progress_event
       elif ($ticket_events | length) > 0 then ($ticket_events[0].ts | epoch)
       else ($issue.updatedAt // $issue.createdAt // $now_iso | epoch) end) as $last_progress_at
    | ([$ticket_events[] | select(.kind == "flip")
         | select((.ts | epoch) >= ($now - 3600) and (.ts | epoch) > $last_progress_at)] ) as $flips
    | ($flips | map(.writer // empty) | unique | .[0:2] | join(",")) as $writers
    | age($stage_at) as $stage_age
    | age($last_progress_at) as $since_progress
    | (if $maintainer_test then 30 elif $priority_top then $priority_top_stage_bound else bound($stage) end) as $stage_bound
    | upstream($stage) as $upstream
    | ($health[$upstream] // {}) as $upstream_health
    | ($upstream_health.status // "") as $upstream_status
    | ($upstream_health.detail // "") as $upstream_detail
    | ($decisions[0][$id] // {}) as $implement_decision
    | ($implement_decision.gate // "") as $implement_gate
    | (($implement_decision.outcome // "") == "skipped" and $implement_gate != "" and $implement_gate != "capacity"
        and $implement_gate != "budget-exhausted" and $implement_gate != "dispatch-resources"
        and $implement_gate != "active-implement" and $implement_gate != "active-scope-collision"
        and $implement_gate != "package-scope-cap") as $noncapacity_skip
    | ([$issue.blockedBy.nodes[]? | select((.state // "" | ascii_downcase) == "open") | (.number | tostring)]
        | unique | sort_by(tonumber)) as $open_blockers
    | (if ($open_blockers | length) > 0 then $open_blockers[0]
       elif $implement_gate == "open-blocker" then
         (try ($implement_decision.object | capture("#(?<number>[0-9]+)").number) catch "")
       else "" end) as $blocker
    | (($flips | length) >= $flip_threshold) as $looping
    | (($stage == "needs-triage" or $stage == "needs-advisor") and ($batch_members | index($id)) != null) as $in_batch
    | ($stage_age > $stage_bound) as $over_bound
    | ((($implement_decision.outcome // "") == "dispatched")
       or (($implement_decision.outcome // "") == "skipped" and $implement_gate == "active-implement")) as $implement_running
    | ($stage == "ready-for-agent" and $priority_top and $over_bound and ($implement_running | not)) as $priority_overdue
    # The decision recorded for this ticket says its lane had no slot (or it is already running). The implement
    # node summarises all lanes, so a full pipeline-system lane beside idle product slots reads OK.
    # A ticket this tick dispatched is running now; its label age is not a stall.
    | ($stage == "ready-for-agent" and $blocker == ""
       and ((($implement_decision.outcome // "") == "skipped" and $implement_gate != "" and ($noncapacity_skip | not))
            or ($implement_decision.outcome // "") == "dispatched") and ($priority_overdue | not)) as $lane_wait
    | ($upstream == "implement" and $upstream_status == "SLOW"
       and ($upstream_detail | startswith("capacity-bound"))
       and ($noncapacity_skip | not) and ($blocker == "")) as $capacity_wait
    | (if $priority_overdue then false else
        (($upstream_status == "BROKEN" or $upstream_status == "STUCK" or $upstream_status == "SLOW" or $upstream_status == "WAITING")
       and $upstream != ""
       and (if $upstream == "implement" then
              ($capacity_wait or ($over_bound | not)
               or (($noncapacity_skip | not) and ($blocker == "") and $upstream_status != "STUCK"))
            else true end))
       end) as $waiting
    | ([if $looping then "loop flips=\($flips|length)/60m threshold=\($flip_threshold)\(if $writers != "" then " writers=\($writers)" else "" end)" else empty end,
        if $over_bound and no_lane($stage) then "no-lane-consumer age=\($stage_age)m bound=\($stage_bound)m"
        elif $over_bound then "stage-bound age=\($stage_age)m bound=\($stage_bound)m" else empty end] | join("; ")) as $reason
    | (if $maintainer_test and $over_bound then "maintainer-test; \($reason)"
       elif $priority_top and $over_bound then "priority:top; \($reason)" else $reason end) as $reason
    | (if $stage == "ready-for-agent" and $over_bound and $blocker != "" then "blocker:\($blocker)"
       elif $stage == "ready-for-agent" and $over_bound and $noncapacity_skip then "gate:\($implement_gate)"
       else $id end) as $alert_key
    | (if $blocker != "" then "blocked by #\($blocker)"
       elif $noncapacity_skip then "gate=\($implement_gate)"
       else $reason end) as $alert_reason
    | {issue:$id,stage:$stage,stage_age_minutes:$stage_age,since_progress_minutes:$since_progress,
       flips:($flips|length),flip_writers:($writers|split(",")|map(select(length>0))),
       verdict:(if $held or $waiting or $umbrella or $tracker or $lane_wait or $in_batch then "WAITING" elif $looping or $over_bound then "STUCK" else "OK" end),
       reason:(if $held then "on-hold excluded" elif $umbrella then "WAITING on open recut children"
               elif $tracker then "WAITING on child tickets (tracker parent)"
               elif $waiting then "WAITING on \($upstream)"
               elif $in_batch then "WAITING on running \($upstream) batch"
               elif $lane_wait then "WAITING on implement \($implement_gate)"
               elif $blocker != "" then "\($reason); blocked by #\($blocker)"
               elif $noncapacity_skip then "\($reason); gate=\($implement_gate)" else $reason end),
       alert_key:$alert_key,alert_reason:$alert_reason,implement_gate:$implement_gate,blocker:$blocker,
       pipeline_system:$pipeline_system,on_hold:$held,upstream:$upstream}
  )) as $tickets
  | ($issues[0] | map(. as $issue | select(
      any($issue.labels[]?.name; . as $name | ($states | index($name)) != null
        or ($lane_labels | index($name)) != null)
      or ($events_by_issue | has($issue.number|tostring))
    )) | length) as $expected_ticket_count
  | ($issues[0] | map(select(any(.labels[]?.name; . as $name | ($lane_labels | index($name)) != null))) | length) as $pipeline_system_open_count
  | ([$tickets[] | select(.pipeline_system)] | length) as $pipeline_system_evaluated_count
  | ([$tickets[] | select(.stage == "on-hold")] | length) as $on_hold_ticket_count
  | ([$tickets[] | select(.stage == "on-hold" and .verdict == "WAITING")] | length) as $on_hold_excluded_count
  | [$tickets[] | select(.verdict == "STUCK")] as $abnormal
  | ($abnormal | group_by(.alert_key) | map(
      . as $group
      | $group[0] as $first
      | {alert_key:$first.alert_key,
         issue_ids:($group | map(.issue) | sort_by(tonumber)),
         stage:$first.stage,
         age:($group | map(.stage_age_minutes) | max),
         reason:$first.alert_reason,
         new:($prior | has($first.alert_key) | not),
         episode:($prior[$first.alert_key].episode //
           (if $first.alert_key == $first.issue then
              "ticket-progress issue=#\($first.issue) episode=\($now)"
            elif ($first.alert_key | startswith("blocker:")) then
              "ticket-progress blocker=#\($first.alert_key | ltrimstr("blocker:")) episode=\($now)"
            else
              "ticket-progress gate=\($first.alert_key | ltrimstr("gate:")) episode=\($now)"
            end))}
    )) as $alerts
  | ($alerts | map({key:.alert_key,value:{episode:.episode}}) | from_entries) as $episodes
  | ($abnormal | sort_by(-.stage_age_minutes) | .[0:3]
      | map("#\(.issue) \(.stage) age=\(.stage_age_minutes)m reason=\(.reason)") | join("; ")) as $worst
  | {sampled_at:$now_iso,expected_ticket_count:$expected_ticket_count,
     evaluated_ticket_count:($tickets|length),
     pipeline_system_open_count:$pipeline_system_open_count,
     pipeline_system_evaluated_count:$pipeline_system_evaluated_count,
     on_hold_ticket_count:$on_hold_ticket_count,on_hold_excluded_count:$on_hold_excluded_count,
     open_issue_snapshot_count:($issues[0]|length),
     verdict:(if ($abnormal|length)>0 then "STUCK" else "OK" end),
     detail:(if ($abnormal|length)>0 then "\($abnormal|length) abnormal; \($worst)"
             else "0 abnormal; tickets=\($tickets|length) on-hold-excluded=\([$tickets[] | select(.stage == "on-hold")] | length)" end),
     tickets:($tickets | map({key:.issue,value:del(.issue,.upstream)} ) | from_entries),
     alerts:$alerts,episodes:$episodes}
')"
rm -f -- "$decisions_file" "$umbrellas_file"

sink_failed=0
while IFS=$'\t' read -r alert_key episode stage age reason issue_ids; do
  [ -n "$alert_key" ] || continue
  message="$episode stage=$stage age=${age}m reason=$reason"
  if [[ "$alert_key" == blocker:* || "$alert_key" == gate:* ]]; then
    message="$episode stage=$stage age=${age}m tickets=$issue_ids reason=$reason"
  fi
  supervisor_inbox_append_once "$episode" "$message" || sink_failed=1
done < <(jq -r '.alerts[] | select(.new) | [.alert_key,.episode,.stage,(.age|tostring),.reason,(.issue_ids|map("#" + .)|join(","))] | @tsv' <<< "$result")

if [ "$sink_failed" = 1 ]; then
  result="$(jq '.verdict="BROKEN" | .detail += "; supervisor inbox write failed"' <<< "$result")"
else
  episode_tmp="$(mktemp "$STATE_DIR/.ticket-progress-episodes.XXXXXX")"
  jq -n --argjson episodes "$(jq -c '.episodes' <<< "$result")" '{episodes:$episodes}' > "$episode_tmp"
  mv "$episode_tmp" "$episodes_file"
fi

status_tmp="$(mktemp "$STATE_DIR/.ticket-stage-status.XXXXXX")"
jq '{sampled_at,expected_ticket_count,evaluated_ticket_count,pipeline_system_open_count,
     pipeline_system_evaluated_count,on_hold_ticket_count,on_hold_excluded_count,
     open_issue_snapshot_count,tickets}' <<< "$result" > "$status_tmp"
mv "$status_tmp" "$status_file"
jq -r '"progress " + .verdict + " " + .detail' <<< "$result"
