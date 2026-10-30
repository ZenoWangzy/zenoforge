_AGENT_LIB_DIR="${_AGENT_LIB_DIR:-$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)}" # a module sourced without lib.sh (land snapshot) still finds the lib dir

supervisor_alert_daily_budget() {
  case "$1" in
    health-check) printf '0\n' ;;
    ticket-progress) printf '20\n' ;;
    repeat-dispatch) printf '16\n' ;;
    label-churn) printf '10\n' ;;
    node-stuck-30min) printf '%s\n' -1 ;; # Uncapped; node-health already limits alerts to once per episode/30 minutes.
    # Uncapped: one line per failed landing or blocked handoff episode. 2026-10-07 >20 failures exhausted the default
    # budget and landings 236/242/243/245 failed silently while their agents had already exited.
    landing-failed|ops-acceptance-after-release|handoff-pr-ambiguous|handoff-preserved-clone) printf '%s\n' -1 ;;
    # Uncapped (#4728): one line per real episode — finished worker round, harvested
    # unit, landing batch, changed alert file. The 20/day default would hide worker
    # exits at the observed factory rate (84 finished rounds in 26h), which is the
    # silence the head supervisor polled manually to escape.
    worker-exit|unit-harvest|landing|alert-file) printf '%s\n' -1 ;;
    # Uncapped: one line per exited hand owner and unresolved step (hand-exit-handoff.sh ledger), never a loop.
    hand-exit-handoff) printf '%s\n' -1 ;;
    prod-anomaly) printf '%s\n' -1 ;; # Every new signature, rate spike, restart, or OOM wakes the supervisor.
    efficiency-regression) printf '%s\n' -1 ;; # The metric evaluator owns the six-hour per-metric cadence.
    efficiency-anomaly|efficiency-inbox-unread) printf '%s\n' -1 ;; # Durable per-day markers own duplicate suppression.
    *) printf '20\n' ;;
  esac
}


supervisor_inbox_append() {
  (($# == 2 || $# == 3)) || return 2
  local kind="$1" text="$2" inbox_file="${3:-$AGENT_HOME/supervisor-inbox}"
  case "$inbox_file" in
    "$AGENT_HOME/supervisor-inbox"|"$AGENT_HOME/night/efficiency-inbox") ;;
    *) return 2 ;;
  esac
  agent_pipeline_write_guard supervisor_inbox_append "$inbox_file" || return 1
  local at day suffix="" wake_suffix="" budget wake_count inbox_lock
  local issue_ids="" node="" targets='[]' alert_state="" alert_decision="wake" lock_fd duplicate=1 id
  local collapse_key="" loop_signal=0
  local event_file seen_file wake_file row policy_file
  [[ "$kind" =~ ^[[:alnum:]][[:alnum:]._:-]*$ ]] || return 2
  at="$(date -u +%Y-%m-%dT%H:%M:%SZ)" || return 1
  [[ "$at" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$ ]] || return 1
  day="${at%%T*}"
  budget="$(supervisor_alert_daily_budget "$kind")"
  [ -d "$AGENT_HOME/logs" ] || mkdir -p "$AGENT_HOME/logs" || return 1
  mkdir -p "${inbox_file%/*}" || return 1
  event_file="$AGENT_HOME/logs/supervisor-alerts-$day.jsonl"
  if [ "$budget" -eq 0 ]; then
    # ponytail: one append-only write per report-only candidate; add a lock if rows become multi-write.
    printf '{"at":"%s","kind":"%s","targets":[],"state":"","decision":"report-only"}\n' \
      "$at" "$kind" >> "$event_file"
    return $?
  fi
  text="$(printf '%s' "$text" | tr '\r\n\t' '   ')" || return 1
  issue_ids="$(grep -oE '(issue|tickets)=#[0-9,]+' <<< "$text" | grep -oE '[0-9]+' | LC_ALL=C sort -u | paste -sd, - || true)"
  if [ -z "$issue_ids" ]; then
    if [[ "$kind" == node-stuck-30min || "$kind" == node-signature-repeat || "$kind" == node-escalation ]]; then
      node="${text%% *}"
    elif [[ "$text" =~ (^|[[:space:]])node=([^[:space:];]+) ]]; then
      node="${BASH_REMATCH[2]}"
    elif [ "$kind" = health-check ] && [[ "$text" =~ ^(BROKEN|SLOW|STUCK)[[:space:]]+([^[:space:]]+) ]]; then
      node="${BASH_REMATCH[2]}"
    fi
  fi
  if [ -n "$issue_ids" ]; then
    targets="$(jq -cn --arg ids "$issue_ids" '$ids | split(",") | map({type:"issue",id:.})')" || return 1
  elif [ -n "$node" ]; then
    targets="$(jq -cn --arg node "$node" '[{type:"node",id:$node}]')" || return 1
  fi
  if [[ "$text" =~ (^|[[:space:]])(BROKEN|STUCK|SLOW|OK|UNKNOWN|NONE|WAITING)([[:space:]]|$) ]]; then
    alert_state="${BASH_REMATCH[2]}"
  elif [[ "$text" =~ status=([[:alnum:]_-]+) ]]; then
    alert_state="${BASH_REMATCH[1]}"
  fi
  if [[ "$kind" == repeat-dispatch && "$text" =~ (^|[[:space:]])run=([0-9]+)([[:space:]]|$) ]] &&
    (( ${BASH_REMATCH[2]} >= 4 )); then
    loop_signal=1
  fi
  seen_file="$AGENT_HOME/logs/supervisor-alert-seen-$day.tsv"
  wake_file="$AGENT_HOME/logs/supervisor-wakes.log"
  inbox_lock="$event_file.lock"
  [[ "$inbox_file" == "$AGENT_HOME/supervisor-inbox" ]] || inbox_lock="$inbox_file.lock"
  exec {lock_fd}>>"$inbox_lock" || return 1
  flock -x "$lock_fd" || { exec {lock_fd}>&-; return 1; }

  if [[ "$kind" == node-stuck-30min || "$kind" == efficiency-regression ]]; then
    duplicate=0
  elif [[ "$kind" == ticket-progress || "$kind" == repeat-dispatch ]] && [ -n "$issue_ids" ]; then
    duplicate=1
    for id in ${issue_ids//,/ }; do
      if ! grep -Fqx -- "$kind"$'\t'"issue:$id" "$seen_file" 2>/dev/null; then duplicate=0; fi
    done
  else
    duplicate=0
    if [ "$targets" != '[]' ]; then
      # Collapse only a repeat of the target's last state: BROKEN -> OK -> BROKEN on one day wakes three times (2026-10-03).
      collapse_key="$kind"$'\t'"targets:$targets"$'\t'"state:$alert_state"
      [ "$(grep -F -- "$kind"$'\t'"targets:$targets"$'\t' "$seen_file" 2>/dev/null | tail -n 1)" = "$collapse_key" ] && duplicate=1
    else
      collapse_key="$kind"$'\t'"text:$text"
      grep -Fqx -- "$collapse_key" "$seen_file" 2>/dev/null && duplicate=1
    fi
  fi
  if [ "$loop_signal" = 1 ]; then duplicate=0; fi
  policy_file="$AGENT_HOME/night/supervisor-alert-policy.json"
  if [[ "$kind" == external-deliverable ]]; then
    alert_decision=informational
  elif [ "$duplicate" = 1 ]; then
    alert_decision=collapsed
  elif [ "$kind" != node-stuck-30min ] && [ "$kind" != efficiency-regression ] && [ "$kind" != ops-acceptance-after-release ] && [ "$kind" != handoff-pr-ambiguous ] && [ "$kind" != handoff-preserved-clone ] && [ "$loop_signal" != 1 ] && jq -e --arg day "$day" --arg kind "$kind" \
    '.date == $day and ((.demoted_classes // []) | index($kind) != null)' \
    "$policy_file" >/dev/null 2>&1; then
    alert_decision=action-rate
  else
    if [ -r "$wake_file" ]; then
      if [ "$kind" = repeat-dispatch ]; then
        # Forced loop signals wake but do not spend the ordinary class budget.
        wake_count="$(awk -F '\t' -v day="$day" '
          $1 >= day "T00:00:00Z" && $1 < day "T24:00:00Z" && $2 == "repeat-dispatch" {
            if (match($3, /run=[0-9]+/)) {
              run = substr($3, RSTART + 4, RLENGTH - 4)
              if (run + 0 >= 4) next
            }
            count++
          }
          END { print count + 0 }
        ' "$wake_file")" || { flock -u "$lock_fd"; exec {lock_fd}>&-; return 1; }
      else
        wake_count="$(awk -F '\t' -v day="$day" -v kind="$kind" \
          '$1 >= day "T00:00:00Z" && $1 < day "T24:00:00Z" && $2 == kind { count++ } END { print count + 0 }' \
          "$wake_file")" || { flock -u "$lock_fd"; exec {lock_fd}>&-; return 1; }
      fi
    else
      wake_count=0
    fi
    if (( budget >= 0 && wake_count >= budget )) && [ "$loop_signal" != 1 ]; then alert_decision=budget; fi
  fi
  row="$(jq -cn --arg at "$at" --arg kind "$kind" --argjson targets "$targets" \
    --arg state "$alert_state" --arg decision "$alert_decision" \
    '{at:$at,kind:$kind,targets:$targets,state:$state,decision:$decision}')" || {
      flock -u "$lock_fd"; exec {lock_fd}>&-; return 1;
    }
  printf '%s\n' "$row" >> "$event_file" || {
    flock -u "$lock_fd"; exec {lock_fd}>&-; return 1;
  }
  # Do not record the deduplication key before the corresponding inbox write.
  if [ "$alert_decision" = informational ]; then
    printf '%s %s %s\n' "$at" "$kind" "$text" >> "$inbox_file" || {
      flock -u "$lock_fd"; exec {lock_fd}>&-; return 1;
    }
  elif [ "$alert_decision" = wake ]; then
    if [ -n "$text" ]; then suffix=" $text"; wake_suffix=$'\t'"$text"; fi
    printf '%s %s%s\n' "$at" "$kind" "$suffix" >> "$inbox_file" || {
      flock -u "$lock_fd"; exec {lock_fd}>&-; return 1;
    }
  fi
  if [[ "$kind" == node-stuck-30min || "$kind" == efficiency-regression ]]; then
    :
  elif [[ "$kind" == ticket-progress || "$kind" == repeat-dispatch ]] && [ -n "$issue_ids" ]; then
    for id in ${issue_ids//,/ }; do printf '%s\tissue:%s\n' "$kind" "$id" >> "$seen_file" || {
      flock -u "$lock_fd"; exec {lock_fd}>&-; return 1;
    }; done
  else
    printf '%s\n' "$collapse_key" >> "$seen_file" || {
      flock -u "$lock_fd"; exec {lock_fd}>&-; return 1;
    }
  fi

  if [ "$alert_decision" != wake ]; then
    flock -u "$lock_fd"
    exec {lock_fd}>&-
    return 0
  fi
  printf '%s\t%s%s\n' "$at" "$kind" "$wake_suffix" >> "$wake_file"
  local status=$?
  flock -u "$lock_fd"
  exec {lock_fd}>&-
  return "$status"
}


# loop_break_check <n> <label_a> <label_b> -- shared by inline route paths
# and detect-label-churn.sh. A per-issue lock makes episode check-and-freeze
# single-writer even when the timer and pipeline tick overlap.
#
# An active loop is frozen on-hold. Callers receive LOOP_BREAK_ESCALATED=1
# and stop before applying the route that would continue the flip.
#
# The latest transition timestamp keys one episode. The state marker,
# supervisor inbox key and episode-specific comment suppress duplicate writes;
# a later transition starts a new episode.
loop_break_check() {
  local n="$1" lock_fd="" status
  LOOP_BREAK_ESCALATED=0
  if ! try_lock_nonblocking "$AGENT_HOME/locks/label-churn-$n.lock" lock_fd; then
    echo "loop_break_check: #$n issue lock busy or unavailable; suppressing route until next tick" >&2
    LOOP_BREAK_ESCALATED=1
    return 0
  fi
  loop_break_check_locked "$@" || status=$?
  status="${status:-0}"
  unlock_fd "$lock_fd" || return 1
  return "$status"
}


loop_break_check_locked() {
  local n="$1" label_a="$2" label_b="$3" since events count latest recency_cutoff trajectory comment_bodies previous_episode episode_marker lifted_at writer_since writers transition_file dispatched_at cutoff
  since="$(date -u -d "-${LOOP_BREAK_WINDOW_HOURS} hours" +%Y-%m-%dT%H:%M:%SZ)"
  events="$(label_transition_events "$n" "$label_a" "$label_b" "$since")"
  count="$(printf '%s\n' "$events" | grep -c . || true)"
  [ "${count:-0}" -ge "$LOOP_BREAK_THRESHOLD" ] || return 0
  # Lifting on-hold or reopening a concluded ticket starts a new episode:
  # earlier transitions belong to a loop that was frozen and fixed (issue 1943
  # was re-frozen 27 min after a supervisor lift) or to a finished lifecycle
  # (issue 3050 was frozen after one advisor round trip post-reopen). Read only
  # past the threshold, so scans stay cheap.
  lifted_at="$(gh api "repos/$REPO/issues/$n/timeline" --paginate \
    --jq '.[] | select(.event=="unlabeled" and (.label.name=="on-hold" or .label.name=="concluded")) | .created_at' 2>/dev/null | sort | tail -n1 || true)"
  writer_since="$since"
  if [[ -n "$lifted_at" && "$lifted_at" > "$since" ]]; then
    # Rebuild alternations at the new episode boundary; the first post-lift
    # label is a baseline, not a flip from the prior lifecycle.
    events="$(label_transition_events "$n" "$label_a" "$label_b" "$lifted_at")"
    count="$(printf '%s\n' "$events" | grep -c . || true)"
    [ "${count:-0}" -ge "$LOOP_BREAK_THRESHOLD" ] || return 0
    writer_since="$lifted_at"
  fi

  # Same reason as detect-label-churn.sh's own former RECENCY_MINUTES: count
  # alone cannot tell a ticket still actively looping right now from one
  # that churned in a settled historical burst earlier in the same window.
  latest="$(printf '%s\n' "$events" | tail -n1)"
  recency_cutoff="$(date -u -d "-${LOOP_BREAK_RECENCY_MINUTES} minutes" +%Y-%m-%dT%H:%M:%SZ)"
  [[ "$latest" < "$recency_cutoff" ]] && return 0
  transition_file="$AGENT_HOME/state/ticket-transitions.jsonl"
  writers=""
  if [ -r "$transition_file" ]; then
    writers="$(jq -sr --argjson issue "$n" --arg label_a "$label_a" --arg label_b "$label_b" \
      --arg since "$writer_since" '
      [.[]
        | select(.issue == $issue and .kind == "flip")
        | select(.ts >= $since)
        | select((.from_stage == $label_a and .to_stage == $label_b)
          or (.from_stage == $label_b and .to_stage == $label_a))
        | .writer | select(type == "string" and length > 0)]
      | unique | join(",")
    ' "$transition_file" 2>/dev/null)" || writers=""
  fi
  [ -n "$writers" ] || writers=unknown

  previous_episode="$(state_read "$n" | jq -r '.loop_escalated_episode // empty')"
  if [ "$previous_episode" = "$latest" ]; then
    LOOP_BREAK_ESCALATED=1
    return 0
  fi
  comment_bodies="$(gh api "repos/$REPO/issues/$n/comments" --paginate \
      --jq '.[] | select(.created_at >= "'"$since"'") | .body' 2>/dev/null || true)"
  episode_marker="<!-- vecta-loop-episode=$latest -->"
  echo "loop_break_check: #$n crossed $LOOP_BREAK_THRESHOLD transitions between $label_a/$label_b in the last ${LOOP_BREAK_WINDOW_HOURS}h (latest $latest) -- freezing on-hold" >&2
  trajectory="$(printf '%s\n' "$events" | nl -ba -s'. ' -w1)"
  supervisor_inbox_append_once \
    "label-churn issue=#$n episode=$latest" \
    "label-churn issue=#$n episode=$latest action=on-hold writers=$writers" || return 1
  if ! grep -qF "$episode_marker" <<< "$comment_bodies"; then
      guarded_write gh issue comment "$n" --repo "$REPO" --body "$BOT_DISCLAIMER
$LOOP_ESCALATION_MARKER
这是循环保护：这张票在 \`$label_a\`/\`$label_b\` 之间切换 $count 次，最近一次是 ${latest}。已加上 \`on-hold\`，停止本轮自动派发。
$episode_marker
本轮观测到的标签写入者：\`writers=$writers\`。" || return 1
  fi
  hold_issue "$n" --holder detect-label-churn \
    --release 'label churn is reviewed; expiry resumes the ticket at its prior stage' \
    --expires 24h --kind label-churn \
    --remove-label "$label_a" --remove-label "$label_b" || return 1
  state_merge "$n" ". + {loop_escalated_at: (now | todate), loop_escalated_episode: $(jq -Rn --arg episode "$latest" '$episode'), loop_trajectory_md: $(jq -Rs . <<<"$trajectory")}" \
    || echo "loop_break_check: state_merge failed for #$n -- on-hold and inbox notice already applied" >&2
  LOOP_BREAK_ESCALATED=1
  dispatched_at="$(state_read "$n" | jq -r '.loop_hand_dispatch_at // empty')" || return 1
  cutoff="$(date -u -d '24 hours ago' +%Y-%m-%dT%H:%M:%SZ)" || return 1
  if [[ -n "$dispatched_at" && "$dispatched_at" > "$cutoff" ]]; then
    supervisor_inbox_append_once "loop-hold-hand-repeat issue=#$n" \
      "loop-hold-hand-repeat issue=#$n status=held reason=previous-scheduler-handoff-within-24h"
    return $?
  fi
  [ "${DRY_RUN:-0}" != 1 ] || return 0
  scheduler_requeue_issue "$n" "label churn requires a repair of the recorded trajectory" "" "" "$latest" pipeline-requeue \
    '.loop_hand_dispatch_at = (now | todate)'
}


# The supervisor empties the inbox after reading it, so the inbox alone
# forgets what was already sent; supervisor-inbox.once remembers each key
# for 24 hours (the same trace re-alerted after every wake, 2026-09-29).
supervisor_inbox_append_once() {
  agent_pipeline_write_guard supervisor_inbox_append_once "$AGENT_HOME/supervisor-inbox" "$AGENT_HOME/supervisor-inbox.once" || return 1
  local key="$1" message="$2" inbox="$AGENT_HOME/supervisor-inbox" lock_fd status=0 now cutoff
  local once="$AGENT_HOME/supervisor-inbox.once"
  local kind
  message="${message//$'\n'/ }"
  message="${message//$'\r'/ }"
  message="${message//$'\t'/ }"
  if [ "$DRY_RUN" = 1 ]; then
    echo "[dry-run] supervisor inbox: $message" >&2
    return 0
  fi
  mkdir -p "$(dirname "$inbox")" || return 1
  exec {lock_fd}>>"$inbox.lock" || return 1
  flock -x "$lock_fd" || { exec {lock_fd}>&-; return 1; }
  now="$(date +%s)"
  cutoff=$((now - 86400))
  if ! grep -Fq -- "$key" "$inbox" 2>/dev/null \
    && ! awk -F '\t' -v c="$cutoff" -v k="$key" '$1 >= c && $2 == k { found = 1 } END { exit !found }' "$once" 2>/dev/null; then
    kind="${message%% *}"
    if supervisor_inbox_append "$kind" "$message"; then
      { awk -F '\t' -v c="$cutoff" '$1 >= c' "$once" 2>/dev/null; printf '%s\t%s\n' "$now" "$key"; } > "$once.tmp" \
        && mv -f -- "$once.tmp" "$once" || status=$?
    else
      status=$?
    fi
  fi
  flock -u "$lock_fd"
  exec {lock_fd}>&-
  return "$status"
}


supervisor_hand_owner_status() {
  (($# == 2)) || return 2
  local name="$1" worktree="$2" roster="$AGENT_HOME/night/agents.txt"
  local codex_pid lib_dir row row_name row_worktree ticket
  SUPERVISOR_HAND_OWNER_DETAIL=""
  SUPERVISOR_HAND_OWNER_ERROR=""

  if declare -F land_queue_owner_ticket >/dev/null && ticket="$(land_queue_owner_ticket "$name" "$worktree")"; then
    SUPERVISOR_HAND_OWNER_DETAIL="land queue owns ticket $ticket"
    return 0
  fi

  if [[ -e "$roster" && ! -r "$roster" ]]; then
    SUPERVISOR_HAND_OWNER_ERROR="cannot read running-agent roster $roster"
    return 2
  fi

  if ! declare -F hand_agent_worktree_pid >/dev/null; then
    lib_dir="$(cd -- "$(dirname -- "$_AGENT_LIB_DIR/lib.sh")" && pwd -P)" || return 2
    source "$lib_dir/night/hand-agent-watchdog.sh" || return 2
  fi
  if codex_pid="$(hand_agent_worktree_pid "$worktree")"; then
    SUPERVISOR_HAND_OWNER_DETAIL="live Codex process $codex_pid on $worktree"
    return 0
  fi
  if [ -r "$roster" ]; then
    while IFS= read -r row || [ -n "$row" ]; do
      IFS=$'\t' read -r _ row_name _ _ row_worktree _ <<< "$row"
      [[ "$row_name" == "$name" && -n "$row_worktree" && "$row_worktree" != "$worktree" ]] || continue
      if codex_pid="$(hand_agent_worktree_pid "$row_worktree")"; then
        SUPERVISOR_HAND_OWNER_DETAIL="live Codex process $codex_pid on $row_worktree"
        return 0
      fi
    done < "$roster"
  fi
  return 1
}


supervisor_hand_read_failure_is_transient() {
  grep -Fq 'gh: transient read failed after bounded retry:' "$1" 2>/dev/null
}


supervisor_hand_issue_findings() {
  local state="$1" brief brief_file status=0
  brief="$(advisor_current_brief_md "$state" | jq -r '.brief_md // ""')" || return 1
  brief_file="$(jq_arg_file "$brief")" || return 1
  jq -r --rawfile brief "$brief_file" '
    def section($heading; $value):
      ($value // "" | tostring) as $text
      | select($text != "")
      | "### \($heading)\n\($text)";
    [
      section("Current triage and root-cause brief"; $brief),
      section("Latest pipeline failure or root cause"; .last_failure_reason),
      section("Latest review evidence"; .last_failure_tail),
      section("Repeated review findings"; .run.evidence.review_repeat_recut),
      section("Latest advisor finding"; (.advisor_last_verdict.material // .pending_advisor_verdict.result // .advisor_decision // .model_policy.advisor_decision)),
      section("Advisor merge conditions"; .merge_conditions_md),
      section("Hold release condition"; .hold.release_condition),
      section("External deliverable"; .external_deliverable),
      section("Ops acceptance after release"; .ops_acceptance_after_release),
      section("Latest recut finding"; .recut_refused_reason)
    ] | join("\n\n")
  ' <<< "$state" || status=$?
  rm -f "$brief_file"
  return "$status"
}


# An ops acceptance must verify the deployed SHA and stays held for the supervisor.
supervisor_ops_acceptance_handoff() (
  local n="$1" state="$2" reason="$3" expected_hold="${4:-}" sha location condition lock_fd f
  if [ -n "$expected_hold" ]; then
    f="$(state_file "$n")" || return 1
    exec {lock_fd}>"$f.lock" || return 1
    flock -x "$lock_fd" || return 1
    state="$(state_read "$n")" || return 1
    jq -e --argjson expected "$expected_hold" '.state == "on-hold" and (.hold | del(.aging_window)) == ($expected | del(.aging_window))' <<< "$state" >/dev/null || return 1
  fi
  sha="$(jq -r '.deployed_sha // .ops_acceptance_after_release.release_sha // "unknown"' <<< "$state")" || return 1
  location="$(jq -r '.ops_acceptance_after_release.location // "unknown"' <<< "$state")" || return 1
  condition="$(jq -r '.hold.release_condition // "verify deployed SHA"' <<< "$state")" || return 1
  supervisor_inbox_append_once "ops-acceptance-after-release issue=#$n sha=$sha" \
    "ops-acceptance-after-release issue=#$n status=sha-$sha deployed_sha=$sha location=$location condition=$condition reason=$reason"
)


# Count issue-local loop escalations for supervisor HEALTH records.
count_recent_loop_escalations() {
  local cutoff f n=0
  cutoff="$(date -u -d '-24 hours' +%Y-%m-%dT%H:%M:%SZ)"
  [ -d "$STATE_DIR" ] || { echo 0; return; }
  for f in "$STATE_DIR"/*.json; do
    [ -f "$f" ] || continue
    if jq -e --arg c "$cutoff" '(.loop_escalated_at // "") >= $c' "$f" >/dev/null 2>&1; then
      n=$((n + 1))
    fi
  done
  echo "$n"
}
