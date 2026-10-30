
# same_failure_streak <old_reason> <old_tail> <new_reason> <new_tail>
# <old_streak> -> repeat count beyond the first failure. A first failure
# returns 0; the same canonical reason+tail increments. No old reason means
# there is no prior failure to compare. Shared by implement and advisor legs.
same_failure_streak() {
  local old_reason="$1" old_tail="$2" new_reason="$3" new_tail="$4" old_streak="${5:-0}"
  if [ -n "$old_reason" ] \
    && [ "$(failure_fingerprint "$old_reason" "$old_tail")" = "$(failure_fingerprint "$new_reason" "$new_tail")" ]; then
    echo $((old_streak + 1))
  else
    echo 0
  fi
}


# Two-strike rule (maintainer ruling 2026-10-07, pipeline-node-execution-model):
# a ticket that fails the same implement step with the same normalized failure
# class twice in a row must not get a third full attempt. Scope/plan failures
# route to needs-recut, decision/ambiguity failures to the advisor;
# environmental failures (quota, CI/landing-slot timeout, provider outage)
# never count as a strike -- their refund paths requeue the ticket without
# charging an attempt, and this classifier must agree with them.
two_strike_failure_class() {
  local reason="$1" status="${2:-}"
  if [ "$status" = "124" ] || grep -Eiq 'usage limit|quota|rate limit|land-lock|landing slot|preflight[ -]?slot|slot (timeout|wait|timed out)|timed?[ -]?out|provider outage|provider transport|network[ -]?(timeout|error)|BLOCKED-ON land|env:|infrastructure retry' <<< "$reason"; then
    echo environmental
    return 0
  fi
  if grep -Eiq 'scope|blast radius|risk[ _-]?class|autonomy|oversized|too (large|big|broad)|recut|split|超出|范围|拆分' <<< "$reason"; then
    echo scope-plan
    return 0
  fi
  if grep -Eiq 'decision|ambiguit|ambiguous|unclear|clarif|confirm|needs-info|决策|明确|确认' <<< "$reason"; then
    echo decision-ambiguity
    return 0
  fi
  echo unclassified
}


# implement_two_strike_route <n> -> prints "recut" or "advisor" when the last
# two implement-unit failures in .model_policy.failures share a step and a
# normalized reason and the class routes away; prints nothing (nonzero) when
# they do not, when the class is environmental, when the ticket runs in the
# pipeline-system lane (the model-policy loop-breaker owns those), when
# the ticket already carries its own open agent PR (#2796: that failure stays
# in the PR lane, not a fresh advisor/recut episode), or when this exact pair
# was already routed (.two_strike marker -- a human re-arming the ticket
# afterwards is a fresh decision this gate must not veto).
implement_two_strike_route() {
  local n="$1" state pair step normalized second_reason second_status open_pr_status=0
  state="$(state_read "$n" 2>/dev/null)" || return 1
  [ "$(jq -r '.pipeline_system.enabled // false' <<< "$state" 2>/dev/null)" = true ] && return 1
  # issue_own_open_agent_pr: 0 owns an open PR, 1 none, 2 GitHub unreadable.
  # Only 1 may route away; 0 keeps the PR-lane recovery, and 2 keeps the
  # current path (the advisor route is the harm this gate must not risk).
  issue_own_open_agent_pr "$n" || open_pr_status=$?
  [ "$open_pr_status" -eq 1 ] || return 1
  pair="$(jq -c '
    [.model_policy.failures[]? | select(.unit == "implement")] as $f
    | [$f[-2], $f[-1]]
    | select(.[0] != null and .[1] != null)
    | select((.[0].step // "") != "" and (.[0].step // "") == (.[1].step // ""))
    | select(((.[0].normalized_reason // .[0].reason // "") != "") and ((.[0].normalized_reason // .[0].reason) == (.[1].normalized_reason // .[1].reason)))
    | {step: .[0].step, normalized_reason: (.[0].normalized_reason // .[0].reason)}
  ' <<< "$state" 2>/dev/null || true)"
  [ -n "$pair" ] || return 1
  step="$(jq -r '.step' <<< "$pair")"
  normalized="$(jq -r '.normalized_reason' <<< "$pair")"
  if [ "$(jq -r --arg step "$step" --arg reason "$normalized" \
    '(.two_strike.step // "") == $step and (.two_strike.normalized_reason // "") == $reason' <<< "$state")" = true ]; then
    return 1
  fi
  second_reason="$(jq -r '[.model_policy.failures[]? | select(.unit == "implement")][-1].reason // ""' <<< "$state")"
  second_status="$(jq -r '[.model_policy.failures[]? | select(.unit == "implement")][-1].status // ""' <<< "$state")"
  case "$(two_strike_failure_class "$second_reason" "$second_status")" in
    environmental) return 1 ;;
    scope-plan) printf 'recut\n' ;;
    *) printf 'advisor\n' ;;
  esac
  return 0
}


# enforce_implement_two_strike <n> -> 0 when the ticket was routed away from
# another full implement attempt (the caller must not dispatch it), nonzero
# when the ordinary dispatch path continues. Routes first, then records the
# idempotency marker and posts the one comment naming both failures -- a route
# that fails leaves no marker, so the next tick retries the routing instead of
# silently dispatching a third attempt.
enforce_implement_two_strike() {
  local n="$1" route first_reason second_reason class state marker comment_body
  route="$(implement_two_strike_route "$n" 2>/dev/null)" || return 1
  [ -n "$route" ] || return 1
  state="$(state_read "$n")" || return 1
  mapfile -t reasons < <(jq -r '([.model_policy.failures[]? | select(.unit == "implement")][-2:][] | .reason // "")' <<< "$state")
  first_reason="${reasons[0]:0:1200}"
  second_reason="${reasons[1]:0:1200}"
  class="$(two_strike_failure_class "$second_reason" "")"
  if [ "$route" = recut ]; then
    route_to_recut "$n" || return 1
  else
    route_to_advisor "$n" || return 1
  fi
  marker="$(jq -cn \
    --arg route "$route" \
    --arg step "$(jq -r '([.model_policy.failures[]? | select(.unit == "implement")][-2].step // ""' <<< "$state")" \
    --arg reason "$(jq -r '([.model_policy.failures[]? | select(.unit == "implement")][-2].normalized_reason // .reason // ""' <<< "$state")" \
    '{routed_at:(now|todate),route:$route,step:$step,normalized_reason:$reason}' 2>/dev/null || true)"
  if [ -n "$marker" ]; then
    state_merge "$n" ".two_strike = $marker" >/dev/null 2>&1 || true
  fi
  comment_body="$BOT_DISCLAIMER
Two-strike rule (ruling pipeline-node-execution-model): the same implement step failed twice in a row with the same normalized failure class, so no third full attempt is dispatched. Class: ${class}; route: needs-${route}.
Failure 1: ${first_reason}
Failure 2: ${second_reason}"
  guarded_issue_comment "$n" "$comment_body" || echo "two-strike: could not post the two-failure comment for #$n" >&2
  record_run_decision "$n" model-policy "Two identical implement failures at the same step (class ${class}); routed to needs-${route} instead of a third full attempt" 1 || true
  printf 'implement-two-strike issue=#%s class=%s route=%s\n' "$n" "$class" "$route" >&2
  return 0
}


# implement_failure_records <state-json> -- every recorded implement failure,
# oldest first, from the model-policy records (current, appended, and those
# requeue moved into history). Copies of one failure collapse.
implement_failure_records() {
  jq -c '
    ([(.model_policy.history // [])[] | .failure?] + [.model_policy.failure?] + (.model_policy.failures // []))
    | map(select(type == "object" and ((.unit // "implement") == "implement")
        and ((.reason // "") != "") and ((.recorded_at // "") != "")))
    | map({stage: (.stage // "unknown"), reason, recorded_at})
    | unique_by([.recorded_at, .reason]) | sort_by(.recorded_at)
  ' <<< "$1"
}


# implement_failure_class_key <stage> <reason> -- what a failure was about,
# stable across runs: the stage, an environmental category, and the failing
# commands/suites; otherwise the decisive text with paths, SHAs and numbers
# blanked. Model-written summaries vary in wording ("ConnectTimeoutError",
# "Connect Timeout Error"), so environmental causes compare by category.
implement_failure_class_key() {
  local stage="$1" reason="$2" env="" subjects text
  case "${reason,,}" in
    *connecttimeout*|*"connect timeout"*|*"fetch failed"*|*etimedout*|*econnrefused*|*econnreset*|*enotfound*|*eai_again*|*getaddrinfo*|*"could not resolve host"*|*"network is unreachable"*|*"proxy"*) env=network ;;
    *"sandbox"*|*"operation not permitted"*|*"read-only file system"*) env=sandbox ;;
    *"host overloaded"*|*"insufficient memory"*|*"out of memory"*) env=host ;;
  esac
  subjects="$(printf '%s\n' "$reason" | awk '
    {
      line = $0
      # The first backticked span of a line names the blocked command.
      if (match(line, /`[^`]+`/)) print substr(line, RSTART + 1, RLENGTH - 2)
    }
    /^Preflight command failed: / { cmd = $0; sub(/^Preflight command failed: /, "", cmd); sub(/ \(exit=[0-9]+\)$/, "", cmd); print cmd }
    /^Focused suite: [^ ]+ duration_ms=/ { print $3 }
    /^not ok/ { t = $0; sub(/^not ok [0-9]* *-? */, "", t); print "not ok: " t }
  ' | sed -E 's/[0-9]+(\.[0-9]+)?ms//g' | LC_ALL=C sort -u | paste -sd ';' -)"
  if [ -z "$subjects" ]; then
    text="$(printf '%s\n' "$reason" | grep -Ev '^[[:space:]]*($|ok |PROGRESS |CHECKED |To |From |\* |Switched |Cloning |remote: |Falling back|Applied patch .* cleanly)' \
      | sed -E 's#/tmp/[^ ]*#<tmp>#g; s/[0-9a-f]{7,64}/<sha>/g; s/[0-9]+/#/g; s/[[:space:]]+/ /g' | tail -n 3 | paste -sd ' ' -)"
    subjects="${text,,}"
  fi
  printf '%s|%s|%s\n' "$stage" "$env" "${subjects:0:600}"
}


# blind_rerun_failure_paths <reasons> <state-json> -- repo paths that count as
# the failing area: paths named in the failures, the ticket's expected paths,
# and the run-environment carriers above.
blind_rerun_failure_paths() {
  local reasons="$1" state="$2" path
  {
    grep -oE '(^|[^A-Za-z0-9_./-])[A-Za-z0-9_.-]+(/[A-Za-z0-9_.-]+)+\.[A-Za-z0-9]+' <<< "$reasons" | sed -E 's#^[^A-Za-z0-9_.]##'
    jq -r '(.expected_paths // [])[]?' <<< "$state" 2>/dev/null
    tr ' ' '\n' <<< "$BLIND_RERUN_ENV_PATHS"
  } | while IFS= read -r path; do
    [ -n "$path" ] && [[ "$path" != /* ]] && [[ "$path" != *..* ]] && printf '%s\n' "$path"
  done | LC_ALL=C sort -u
}


# implement_rerun_input_change <n> <since> <reasons> <state-json> <comments-json>
# -- prints what changed since the latest failure and returns 0; returns 1
# when nothing did.
implement_rerun_input_change() {
  local n="$1" since="$2" reasons="$3" state="$4" comments="$5" since_epoch env_file env_epoch commit
  local -a paths=()
  if [ "$(jq -r --arg since "$since" '(.hold_released_at // "") > $since' <<< "$state")" = true ]; then
    echo "supervisor released the hold after the failure"
    return 0
  fi
  if [ "$(jq -r --arg since "$since" --arg marker "$BOT_COMMENT_MARKER" \
    '[.[] | select((.created_at // "") > $since and ((.body // "") | contains($marker) | not))] | length' <<< "$comments")" -gt 0 ]; then
    echo "new issue comment after the failure"
    return 0
  fi
  env_file="${ENV_FAULT_ENV_FILE:-$AGENT_HOME/env}"
  since_epoch="$(agent_epoch "$since" 2>/dev/null || echo 0)"
  env_epoch="$(stat -c %Y "$env_file" 2>/dev/null || echo 0)"
  if [[ "$since_epoch" =~ ^[0-9]+$ && "$env_epoch" =~ ^[0-9]+$ ]] && (( since_epoch > 0 && env_epoch > since_epoch )); then
    echo "run environment file changed after the failure"
    return 0
  fi
  mapfile -t paths < <(blind_rerun_failure_paths "$reasons" "$state")
  if ((${#paths[@]} > 0)); then
    commit="$(git -C "$REPO_DIR" log -1 --format=%h --since="$since" origin/main -- "${paths[@]}" 2>/dev/null || true)"
    if [ -n "$commit" ]; then
      echo "main commit $commit touched the failing area or run environment"
      return 0
    fi
  fi
  return 1
}


# implement_blind_rerun_gate <n> -> 0 when this dispatch must not run (the
# ticket is parked, or its input history could not be read this tick); 1 when
# dispatch continues. BLIND_RERUN_DECISION carries the reason for the caller's
# tick decision record.
implement_blind_rerun_gate() {
  local n="$1" state records count first second stage1 stage2 reason1 reason2 since key1 key2 change comments
  local decisive marker inbox_key paths_note
  BLIND_RERUN_DECISION=""
  state="$(state_read "$n" 2>/dev/null)" || return 1
  # A landing retry replays the rescued commit without a model call.
  [ -z "$(jq -r '.pipeline_system.landing_retry_sha // empty' <<< "$state")" ] || return 1
  records="$(implement_failure_records "$state" 2>/dev/null)" || return 1
  count="$(jq 'length' <<< "$records")"
  [ "${count:-0}" -ge 2 ] || return 1
  first="$(jq -c '.[-2]' <<< "$records")"
  second="$(jq -c '.[-1]' <<< "$records")"
  stage1="$(jq -r '.stage' <<< "$first")"; stage2="$(jq -r '.stage' <<< "$second")"
  [ "$stage1" = "$stage2" ] || return 1
  reason1="$(jq -r '.reason' <<< "$first")"; reason2="$(jq -r '.reason' <<< "$second")"
  key1="$(implement_failure_class_key "$stage1" "$reason1")"
  key2="$(implement_failure_class_key "$stage2" "$reason2")"
  [ "$key1" = "$key2" ] || return 1
  # Where two-strike routing (recut/advisor) owns the pair, it decides.
  if declare -F implement_two_strike_route >/dev/null 2>&1 && implement_two_strike_route "$n" >/dev/null 2>&1; then
    return 1
  fi
  since="$(jq -r '.recorded_at' <<< "$second")"
  if ! comments="$(gh api "repos/$REPO/issues/$n/comments" --paginate --jq '.[] | {created_at, body}' 2>/dev/null | jq -s '.' 2>/dev/null)"; then
    BLIND_RERUN_DECISION="同类失败已连续两次，但无法读取 issue 评论以确认输入是否变化，本 tick 暂缓派发"
    return 0
  fi
  if change="$(implement_rerun_input_change "$n" "$since" "$reason1"$'\n'"$reason2" "$state" "$comments")"; then
    printf 'blind-rerun-gate issue=#%s rerun allowed: %s\n' "$n" "$change" >&2
    return 1
  fi
  decisive="$(grep -Ev '^[[:space:]]*$' <<< "$reason2" | head -n 6 | cut -c1-300)"
  paths_note="$(blind_rerun_failure_paths "$reason1"$'\n'"$reason2" "$state" | head -n 8 | paste -sd ' ' -)"
  BLIND_RERUN_DECISION="最近两次 implement 在 $stage2 以同一类原因失败，之后没有任何输入变化；不再盲目重跑，已挂起并通知 supervisor"
  inbox_key="blind-rerun issue=#$n failure=$since"
  supervisor_inbox_append_once "$inbox_key" \
    "blind-rerun issue=#$n stage=$stage2 failures=2 since=$since reason=$(tr '\n' ' ' <<< "$decisive" | cut -c1-500) unblock=land-a-fix-touching[$paths_note]|comment-on-issue|change-env" \
    || echo "blind-rerun-gate: supervisor inbox write failed for #$n" >&2
  marker="<!-- vecta-blind-rerun issue=#$n failure=$since -->"
  if ! jq -e --arg marker "$marker" 'any(.[]; (.body // "") | contains($marker))' <<< "$comments" >/dev/null 2>&1; then
    guarded_issue_comment "$n" "$BOT_DISCLAIMER
Blind-rerun gate: the last two implement runs failed at \`$stage2\` for the same reason, and nothing changed since (no main commit touching the failing area or run environment, no new issue comment, no environment change). Another run would repeat the failure, so this ticket is parked instead of redispatched.

Decisive reason:
\`\`\`
$decisive
\`\`\`
To rerun: land a fix touching the failing area or environment (${paths_note:-the paths named above}), add an issue comment with the new input, or release the hold with \`state_requeue $n release-hold\`.
$marker" || echo "blind-rerun-gate: comment failed for #$n" >&2
  fi
  hold_issue "$n" --holder blind-rerun-gate \
    --release 'an input changed: a main commit touching the failing area or run environment, a new issue comment, or a supervisor hold release' \
    --expires 72h --kind blind-rerun \
    || echo "blind-rerun-gate: on-hold write failed for #$n; candidate stays skipped and the hold retries next tick" >&2
  printf 'blind-rerun-gate issue=#%s parked stage=%s since=%s\n' "$n" "$stage2" "$since" >&2
  return 0
}


# One tick's latest decision lives beside the issue state; every invocation
# also emits a structured-enough journal line. state_merge keeps this
# bookkeeping from refreshing state_changed_at, so a stuck ticket stays stale.
# --- implement dispatch streak (2026-10-08) ----------------------------------
# One line in $AGENT_HOME/night/implement-dispatch-streak:
#   ticks=<K> open=<tick|none> gate=<last gate>
# K counts consecutive scheduler ticks that reached implement with a free slot
# and ready candidates but dispatched nothing. A tick opens the streak before
# any implement work, so a tick killed before its summary (02:24Z and 02:44Z
# on 2026-10-08, TimeoutStartSec) still counts; the next open names that kill.
implement_dispatch_streak_file() {
  printf '%s\n' "${IMPLEMENT_DISPATCH_STREAK_FILE:-$AGENT_HOME/night/implement-dispatch-streak}"
}


implement_dispatch_streak_read() {
  local file line ticks=0 open=none gate=none field
  file="$(implement_dispatch_streak_file)"
  IFS= read -r line 2>/dev/null < "$file" || line=""
  for field in $line; do
    case "$field" in
      ticks=*) ticks="${field#ticks=}" ;;
      open=*) open="${field#open=}" ;;
      gate=*) gate="${field#gate=}" ;;
    esac
  done
  [[ "$ticks" =~ ^[0-9]+$ ]] || ticks=0
  printf '%s %s %s\n' "$ticks" "${open:-none}" "${gate:-none}"
}


implement_dispatch_streak_write() {
  local file tmp
  file="$(implement_dispatch_streak_file)"
  mkdir -p "${file%/*}" || return 1
  tmp="$file.tmp.$$"
  printf 'ticks=%s open=%s gate=%s\n' "$1" "$2" "$3" > "$tmp" && mv -f -- "$tmp" "$file"
}


# implement_dispatch_streak_open <tick>
implement_dispatch_streak_open() {
  local tick="$1" ticks open gate
  read -r ticks open gate <<< "$(implement_dispatch_streak_read)"
  [ "$open" = none ] || gate=tick-ended-before-implement-summary
  implement_dispatch_streak_write "$((ticks + 1))" "$tick" "$gate"
}


# implement_dispatch_streak_close <dispatched> <free slots at start> <candidates> <top gate>
implement_dispatch_streak_close() {
  local dispatched="$1" slots="$2" candidates="$3" gate="${4:-none}" ticks open old_gate
  read -r ticks open old_gate <<< "$(implement_dispatch_streak_read)"
  [ "$open" != none ] || ticks=$((ticks + 1))
  if [ "${dispatched:-0}" -gt 0 ] || [ "${slots:-0}" -le 0 ] || [ "${candidates:-0}" -le 0 ]; then
    ticks=0
  fi
  implement_dispatch_streak_write "$ticks" none "${gate// /_}"
}


# implement_dispatch_stall_detail <active> <cap> <ready>: prints the STUCK
# detail and returns 0 when implement has free slots and ready work but has not
# dispatched for IMPLEMENT_NO_DISPATCH_STUCK_TICKS ticks; returns 1 otherwise.
implement_dispatch_stall_detail() {
  local active="$1" cap="$2" ready="$3" ticks open gate
  [[ "$active" =~ ^[0-9]+$ && "$cap" =~ ^[0-9]+$ && "$ready" =~ ^[0-9]+$ ]] || return 1
  (( ready > 0 && active < cap )) || return 1
  read -r ticks open gate <<< "$(implement_dispatch_streak_read)"
  (( ticks >= IMPLEMENT_NO_DISPATCH_STUCK_TICKS )) || return 1
  printf 'no implement dispatch for %s ticks with %s/%s active and %s ready; gate=%s\n' \
    "$ticks" "$active" "$cap" "$ready" "$gate"
}


record_implement_tick_decision() {
  local n="$1" tick="$2" outcome="$3" gate="$4" reason="$5" object="$6" record reason_file
  reason_file="$(jq_arg_file "$reason")"
  record="$(jq -cn --arg tick "$tick" --arg outcome "$outcome" --arg gate "$gate" \
    --rawfile reason "$reason_file" --arg object "$object" \
    '{tick:$tick, outcome:$outcome, gate:$gate, reason:$reason, object:$object, recorded_at:(now | todate)}')"
  rm -f "$reason_file"
  state_merge "$n" ".implement_tick_decision = $record" || return 1
  printf 'issue-pipeline: implement-decision tick=%s issue=#%s outcome=%s gate=%s object=%s reason=%s\n' \
    "$tick" "$n" "$outcome" "$gate" "$object" "$reason" >&2
}


record_advisor_tick_decision() {
  local n="$1" tick="$2" outcome="$3" gate="$4" reason="$5" object="$6" record reason_file
  reason_file="$(jq_arg_file "$reason")"
  record="$(jq -cn --arg tick "$tick" --arg outcome "$outcome" --arg gate "$gate" \
    --rawfile reason "$reason_file" --arg object "$object" \
    '{tick:$tick, outcome:$outcome, gate:$gate, reason:$reason, object:$object, recorded_at:(now | todate)}')"
  rm -f "$reason_file"
  state_merge "$n" ".advisor_tick_decision = $record" || return 1
  printf 'issue-pipeline: advisor-decision tick=%s issue=#%s outcome=%s gate=%s object=%s reason=%s\n' \
    "$tick" "$n" "$outcome" "$gate" "$object" "$reason" >&2
}


record_triage_tick_decision() {
  local n="$1" tick="$2" outcome="$3" gate="$4" reason="$5" object="$6" record reason_file
  reason_file="$(jq_arg_file "$reason")"
  record="$(jq -cn --arg tick "$tick" --arg outcome "$outcome" --arg gate "$gate" \
    --rawfile reason "$reason_file" --arg object "$object" \
    '{tick:$tick, outcome:$outcome, gate:$gate, reason:$reason, object:$object, recorded_at:(now | todate)}')"
  rm -f "$reason_file"
  state_merge "$n" ".triage_tick_decision = $record" || return 1
  printf 'issue-pipeline: triage-decision tick=%s issue=#%s outcome=%s gate=%s object=%s reason=%s\n' \
    "$tick" "$n" "$outcome" "$gate" "$object" "$reason" >&2
}


# Strip run-specific noise before comparing implement failures. Keep this a
# readable canonical string, not a digest: logs remain inspectable in state.
failure_fingerprint() {
  local text="${1:-}"
  [ "$#" -lt 2 ] || text+=$'\n'"$2"
  printf '%s' "$text" | LC_ALL=C sed -E \
    -e 's#(/tmp|/var/tmp)/[^/[:space:]]+#<tmp-dir>#g' \
    -e 's/[0-9]{4}-[0-9]{2}-[0-9]{2}[T ][0-9]{2}:[0-9]{2}:[0-9]{2}([.][0-9]+)?(Z|[+-][0-9]{2}:?[0-9]{2})?/<timestamp>/Ig' \
    -e 's/[0-9]{8}T[0-9]{6}Z?/<timestamp>/Ig' \
    -e 's/((timestamp|sampled[-_]at|recorded[-_]at|created[-_]at|time)[[:space:]_=-]+)[0-9]{10,13}/\1<timestamp>/Ig' \
    -e 's/(^|[^[:alnum:]_])[[:xdigit:]]{7,40}([^[:alnum:]_]|$)/\1<hash>\2/g' \
    -e 's/(elapsed|duration([_-]?(sec|ms))?|took)([[:space:]_=:.-]+)[0-9]+([.][0-9]+)?[[:space:]]*(milliseconds?|msecs?|ms|seconds?|secs?|s|minutes?|mins?|m|hours?|hrs?|h)?/\1=<duration>/Ig' \
    -e 's/[0-9]+([.][0-9]+)?[[:space:]]*(milliseconds?|msecs?|ms|seconds?|secs?|s|minutes?|mins?|m|hours?|hrs?|h)/<duration>/Ig' \
    -e 's/(issue[[:space:]]+)#[0-9]+/\1#<issue>/Ig' \
    -e 's/[[:space:]]+/ /g; s/^ //; s/ $//'
}

record_implement_failure() {
  local n="$1" reason="$2" evidence="$3" status="${4:-}" stage="${5:-implement}" reset_streak="${6:-0}"
  local prior old_reason old_evidence old_streak fingerprint reason_file evidence_file fingerprint_file reason_json evidence_json record_json
  prior="$(state_read "$n")" || return 1
  old_reason="$(jq -r '.last_failure_reason // ""' <<< "$prior")"
  old_evidence="$(jq -r '.last_failure_tail // ""' <<< "$prior")"
  old_streak="$(jq -r '.same_failure_streak // 0' <<< "$prior")"
  IMPLEMENT_FAILURE_STREAK="$(same_failure_streak "$old_reason" "$old_evidence" "$reason" "$evidence" "$old_streak")" || return 1
  [ "$reset_streak" != 1 ] || IMPLEMENT_FAILURE_STREAK=0
  fingerprint="$(failure_fingerprint "$reason" "$evidence")" || return 1
  reason_file="$(jq_arg_file "$reason")" || return 1
  evidence_file="$(jq_arg_file "$evidence")" || { rm -f -- "$reason_file"; return 1; }
  fingerprint_file="$(jq_arg_file "$fingerprint")" || { rm -f -- "$reason_file" "$evidence_file"; return 1; }
  reason_json="$(jq -n --rawfile value "$reason_file" '$value')" || { rm -f -- "$reason_file" "$evidence_file" "$fingerprint_file"; return 1; }
  evidence_json="$(jq -n --rawfile value "$evidence_file" '$value')" || { rm -f -- "$reason_file" "$evidence_file" "$fingerprint_file"; return 1; }
  record_json="$(jq -nc --arg stage "$stage" --arg status "$status" \
    --argjson streak "$IMPLEMENT_FAILURE_STREAK" --rawfile reason "$reason_file" \
    --rawfile evidence "$evidence_file" --rawfile fingerprint "$fingerprint_file" \
    '{stage:$stage,status:(if ($status|test("^-?[0-9]+$")) then ($status|tonumber) else null end),reason:$reason,evidence:$evidence,fingerprint:$fingerprint,same_failure_streak:$streak,recorded_at:(now|todate)}')" \
    || { rm -f -- "$reason_file" "$evidence_file" "$fingerprint_file"; return 1; }
  rm -f -- "$reason_file" "$evidence_file" "$fingerprint_file"
  state_merge "$n" ".implement_failure = $record_json | .last_failure_reason = $reason_json | .last_failure_tail = $evidence_json | .last_failure_attempt = (.attempts // 0) | .same_failure_streak = $IMPLEMENT_FAILURE_STREAK | del(.model_policy.active)"
}
