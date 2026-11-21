#!/usr/bin/env bash
# One idempotent anomaly scan for the autopilot runtime.
set -o pipefail
shopt -s nullglob

HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
# runtime-env.sh defaults an unset AGENT_HOME to $HOME/.zenoforge; ci_protection must tell an explicit
# setting (a missing state/ then holds cancellation) from that default (used only when its state/ exists).
EXPLICIT_AGENT_HOME="${AGENT_HOME:-}"
source "$HERE/runtime-env.sh"
ROOT="$MAC_AUTOPILOT_ROOT"
ENGINE_DIR="${ZF_ENGINE_DIR:-$ROOT/engine}"
source "$HERE/incident-fingerprint.sh"
source "$ENGINE_DIR/lib.d/transport.sh"
source "$ENGINE_DIR/lib.d/ci-checks.sh"; source "$HERE/pin-lag.sh"; source "$HERE/zf-main-ci.sh"; source "$HERE/bell-guards.sh"; source "$HERE/bell-history.sh"; source "$HERE/live-evidence.sh"
A="${BELL_AUTOPI_DIR:-$MAC_AUTOPILOT_RUNTIME_DIR}"
CHECK_ONLY=0
for arg in "$@"; do
  case "$arg" in
    --check-only) CHECK_ONLY=1 ;;
    *) echo "bell.sh: unknown argument: $arg" >&2; exit 2 ;;
  esac
done
[[ -d "$A" ]] || { echo "bell.sh: autopilot runtime is missing: $A" >&2; exit 1; }

# 不用 `// empty`：jq 的 // 把 false 当缺省，`enabled:false` 会被静默改回默认 true。
cfg() { jq -r "($1) | if . == null then empty else . end" "$A/config.json" 2>/dev/null || true; }
cfg_bool() {
  local value
  value="$(cfg "$1")"
  case "$value" in true|false) ;; *) value="$2" ;; esac
  printf '%s' "$value"
}
ENABLED="$(cfg_bool '.bell.enabled' true)"
DEDUP_MINUTES="$(cfg '.bell.dedup_minutes')"
[[ "$DEDUP_MINUTES" =~ ^[0-9]+$ ]] || DEDUP_MINUTES=30
(( DEDUP_MINUTES > 0 )) || DEDUP_MINUTES=30
DEDUP_SECONDS=$((DEDUP_MINUTES * 60))
FILE_MIN_SEVERITY="$(cfg '.incident.file_min_severity')"
case "$FILE_MIN_SEVERITY" in info|low|medium|high|critical|off) ;; *) FILE_MIN_SEVERITY=medium ;; esac
severity_rank() {
  case "$1" in
    info) printf 0 ;;
    low) printf 1 ;;
    medium) printf 2 ;;
    high) printf 3 ;;
    critical) printf 4 ;;
    off) printf 5 ;;
    *) printf -1 ;;
  esac
}
FILE_MIN_SEVERITY_RANK="$(severity_rank "$FILE_MIN_SEVERITY")"
if [[ "$ENABLED" != true ]]; then
  [[ "$CHECK_ONLY" == 1 ]] && echo "bell check-only: disabled by config"
  exit 0
fi

STATE="$A/bell-state.json"
QUEUE="$A/BELL-QUEUE.md"
LOG="$A/bell.log"
SCAN_LOCK="$A/.bell.lock"
SCAN_PID=""
if [[ -s "$STATE" ]] && jq -e 'type=="object"' "$STATE" >/dev/null 2>&1; then
  STATE_JSON="$(jq -c '. + {monitor_initialized:(.monitor_initialized//false),scheduler_lines:(.scheduler_lines//0),alert_mtimes:(.alert_mtimes//{}),merge_events:(.merge_events//{}),signatures:(.signatures//{}),pending:(.pending//[]),incident_stats:(.incident_stats//{}),incident_filing:(.incident_filing//{}),scheduler_signature_seen:(.scheduler_signature_seen//{}),main_ci_runs_seen:(.main_ci_runs_seen//{}),slow_phase_ticks:(.slow_phase_ticks//{}),network_down:(.network_down//false)}' "$STATE")"
else
  STATE_JSON='{"monitor_initialized":false,"scheduler_lines":0,"alert_mtimes":{},"merge_events":{},"signatures":{},"pending":[],"incident_stats":{},"incident_filing":{},"scheduler_signature_seen":{},"main_ci_runs_seen":{},"slow_phase_ticks":{},"network_down":false}'
fi
MONITOR_INITIALIZED="$(jq -r '.monitor_initialized' <<<"$STATE_JSON")"

save_state() {
  # STATE_JSON 只来自 jq -c 的输出，直接落盘即可；再过一道 jq 会把整个状态重新解析一遍。
  [[ "$CHECK_ONLY" == 1 ]] && return 0
  local tmp="$STATE.tmp.$$"
  printf '%s\n' "$STATE_JSON" > "$tmp" && mv "$tmp" "$STATE"
}
rotate_log_if_large() {
  # bell.log 只追加、只有人会 tail；超过上限保留尾部，避免无界增长拖慢宿主与备份。
  [[ -s "$LOG" ]] || return 0
  local max="${BELL_LOG_MAX_BYTES:-8388608}" size tmp_log
  size="$(wc -c < "$LOG" 2>/dev/null | awk '{print $1}')"
  [[ "$size" =~ ^[0-9]+$ ]] || return 0
  (( size > max )) || return 0
  tmp_log="$LOG.rot.$$"
  # 按字节截断的第一行可能被切一半：不以 [ 开头的行整行丢弃。
  if tail -c $((max / 2)) "$LOG" 2>/dev/null | sed -e '1{/^\[/d;}' > "$tmp_log" && [[ -s "$tmp_log" ]]; then
    printf '[%s] bell.log rotated: kept the last %s bytes (was %s)\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$((max / 2))" "$size" | cat - "$tmp_log" > "$tmp_log.2" 2>/dev/null && mv -f "$tmp_log.2" "$LOG" || mv -f "$tmp_log" "$LOG"
  fi
  rm -f "$tmp_log" "$tmp_log.2" 2>/dev/null || true
}
acquire_lock() {
  if mkdir "$SCAN_LOCK" 2>/dev/null; then
    printf '%s\n' "$$" > "$SCAN_LOCK/pid"
    SCAN_PID="$$"
    return 0
  fi
  local old_pid=""
  [[ -r "$SCAN_LOCK/pid" ]] && old_pid="$(cat "$SCAN_LOCK/pid" 2>/dev/null || true)"
  if [[ "$old_pid" =~ ^[0-9]+$ ]] && kill -0 "$old_pid" 2>/dev/null; then return 1; fi
  rm -f "$SCAN_LOCK/pid" 2>/dev/null || true
  rmdir "$SCAN_LOCK" 2>/dev/null || true
  mkdir "$SCAN_LOCK" 2>/dev/null || return 1
  printf '%s\n' "$$" > "$SCAN_LOCK/pid"
  SCAN_PID="$$"
}
release_lock() {
  [[ "$CHECK_ONLY" == 1 || -z "$SCAN_PID" ]] && return 0
  local pid=""
  [[ -r "$SCAN_LOCK/pid" ]] && pid="$(cat "$SCAN_LOCK/pid" 2>/dev/null || true)"
  if [[ "$pid" == "$SCAN_PID" ]]; then rm -f "$SCAN_LOCK/pid"; rmdir "$SCAN_LOCK" 2>/dev/null || true; fi
}
if [[ "$CHECK_ONLY" != 1 ]]; then
  acquire_lock || { echo "bell.sh: scan already active"; exit 0; }
  trap release_lock EXIT
  rotate_log_if_large
fi

now="$(date +%s)"
stamp="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
SUPERVISOR_DIR="${BELL_SUPERVISOR_DIR:-$MAC_AUTOPILOT_SUPERVISOR_DIR}"
events=()
action_ids=()
action_severities=()
action_sigs=()
action_results=()
event_seq=0
clean() { printf '%s' "$1" | tr '\t\r\n' '   '; }
add_event() { events+=("$1"$'\t'"$(clean "$2")"$'\t'"$(clean "$3")"$'\t'"$(clean "$4")"); }
to_epoch() {
  python3 - "$1" <<'PY'
from datetime import datetime,timezone
import sys
try:
 d=datetime.fromisoformat(sys.argv[1].replace("Z","+00:00"))
 print(int((d if d.tzinfo else d.replace(tzinfo=timezone.utc)).timestamp()))
except Exception: print("")
PY
}
mtime_epoch() {
  python3 - "$1" <<'PY'
import os,sys
print(int(os.stat(sys.argv[1]).st_mtime))
PY
}

scheduler_signature_class() {
  local line="$1" rc fn var
  if [[ "$line" =~ jqf[[:space:]]error[[:space:]]\(rc=([0-9]+)\)[[:space:]]in[[:space:]]([^[:space:]:]+) ]]; then
    rc="${BASH_REMATCH[1]}"; fn="${BASH_REMATCH[2]}"
    fn="$(printf '%s' "$fn" | LC_ALL=C tr '[:upper:]_' '[:lower:]-' | sed -E 's/[^a-z0-9-]+/-/g; s/-+/-/g; s/^-|-$//g')"
    [[ -n "$fn" ]] || fn=unknown
    printf 'sched-jqf-%s-rc%s\n' "$fn" "$rc"
  elif [[ "$line" == *'unbound variable'* ]]; then
    if [[ "$line" =~ ([[:alnum:]_]+):[[:space:]]unbound[[:space:]]variable ]]; then
      var="$(printf '%s' "${BASH_REMATCH[1]}" | LC_ALL=C tr '[:upper:]_' '[:lower:]-' | sed -E 's/[^a-z0-9-]+/-/g; s/-+/-/g; s/^-|-$//g')"
      [[ -n "$var" ]] || var=unknown
      printf 'sched-unbound-%s\n' "$var"
    else
      printf 'sched-unbound-variable\n'
    fi
  elif [[ "$line" == *TICK-TIMEOUT* ]]; then
    printf 'sched-tick-timeout\n'
  elif [[ "$line" == *REFILL-TIMEOUT* ]]; then
    printf 'sched-refill-timeout\n'
  elif [[ "$line" == *"run-tick: refusing to run this tick"* ]]; then
    # 2026-11-03: a refused tick (issue-pipeline exit != 0) used to match no
    # signature anywhere -- the refusal went to the agent unit's journal,
    # which this scanner never reads, so a down pipeline filed no incident.
    # run-tick's refuse() now also appends the line to scheduler.log.
    printf 'sched-run-tick-refused\n'
  elif [[ "$line" =~ issue-pipeline:[[:space:]]slice-failed[[:space:]]tick=[^[:space:]]+[[:space:]]stage=([a-z0-9-]+)[[:space:]]status=([0-9]+) ]]; then
    # #166 files a stable incident for each failed slice+status. Repeated
    # occurrences dedupe in pipeline-issue-upsert; distinct stages/statuses
    # remain independently actionable.
    printf 'sched-slice-failed-%s-%s\n' "${BASH_REMATCH[1]}" "${BASH_REMATCH[2]}"
  elif [[ "$line" == *'advisor provider missing: '* ]]; then
    # The scheduler refuses a unit-advisor launch before Node can emit a
    # MODULE_NOT_FOUND stack; #166 files this stable signature as an incident.
    printf 'sched-advisor-provider-missing\n'
  elif [[ "$line" == *"review-family wait unit="* ]]; then
    # A queued PR cannot obtain an independent verifier. Keep it pending and
    # let the normal bell incident intake own the alert and escalation.
    printf 'sched-review-family-wait\n'
  elif [[ "$line" =~ issue-pipeline:[[:space:]]maintenance[[:space:]]deferred[[:space:]]streak[[:space:]]section=([a-z0-9-]+)[[:space:]]consecutive=([0-9]+) ]]; then
    # Repeated budget deferral means a maintenance section is starving across
    # ticks; keep the warning on the normal #166 incident intake path.
    printf 'sched-maintenance-deferral-%s\n' "${BASH_REMATCH[1]}"
  fi
}

INCIDENT_REPO="${ZF_GH_REPO:-${ZF_REPO:-}}"
if [[ -z "$INCIDENT_REPO" ]]; then
  incident_remote="$(git -C "$ROOT" remote get-url origin 2>/dev/null || true)"
  INCIDENT_REPO="$(printf '%s' "$incident_remote" | sed -E 's#^(git@[^:]+:|[a-z+]+://([^/@]+@)?[^/]+/)##; s#\.git$##')"
fi
# 2026-11-03: an incident whose evidence is engine-owned (scheduler.log lines, engine
# file paths) was filed on the product repo, where a product worker "fixed" it by
# forking an engine file into the product tree. Engine-owned evidence now files on
# the engine repo; the product repo keeps product evidence.
ENGINE_INCIDENT_REPO="${ZF_ENGINE_REPO:-$(cfg '.incident.engine_repo')}"
[[ "$ENGINE_INCIDENT_REPO" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] || ENGINE_INCIDENT_REPO='ZenoWangzy/zenoforge'
# A single slow-phase notice is a timing metric, not an incident; the same phase
# must be slow in N of the last M tick summaries before an incident is filed.
SLOW_PHASE_MIN_TICKS="$(cfg '.incident.slow_phase_min_ticks')"
SLOW_PHASE_WINDOW_TICKS="$(cfg '.incident.slow_phase_window_ticks')"
[[ "$SLOW_PHASE_MIN_TICKS" =~ ^[0-9]+$ ]] || SLOW_PHASE_MIN_TICKS=5
[[ "$SLOW_PHASE_WINDOW_TICKS" =~ ^[0-9]+$ ]] || SLOW_PHASE_WINDOW_TICKS=10
(( SLOW_PHASE_WINDOW_TICKS >= 1 )) || SLOW_PHASE_WINDOW_TICKS=10
(( SLOW_PHASE_MIN_TICKS >= 1 && SLOW_PHASE_MIN_TICKS <= SLOW_PHASE_WINDOW_TICKS )) || SLOW_PHASE_MIN_TICKS=5

incident_target_repo() {
  local text="$1"
  if printf '%s' "$text" | grep -Fq -- 'scheduler.log' \
    || printf '%s' "$text" | grep -Fq -- "$ENGINE_DIR" \
    || printf '%s' "$text" | grep -Eq -- '(^|[^A-Za-z0-9_.-])engine/[A-Za-z0-9_]'; then
    printf '%s\n' "$ENGINE_INCIDENT_REPO"
  else
    printf '%s\n' "$INCIDENT_REPO"
  fi
}

# One tick-summary line (tick done / refill done) carries that tick's per-phase
# timing. Each summary appends one bit per tracked phase (slow or not) to a
# capped window in bell-state; an event fires only when this tick's slow bit
# raises the window to the configured N-of-M threshold. The window lives in the
# SLOW_TICKS mirror and is merged into STATE_JSON once after the line loop:
# 每拍都把整个 2MB 级状态串进 jq 再 fromjson 只为读这一个键，是每拍常数开销的大头。
record_slow_phase_tick() {
  local line="$1" slow_part="" update phase
  [[ "$line" =~ slow:[[:space:]](.*)$ ]] && slow_part="${BASH_REMATCH[1]}"
  update="$(jq -cn --argjson old "$SLOW_TICKS" --arg slow "$slow_part" \
    --argjson n "$SLOW_PHASE_MIN_TICKS" --argjson m "$SLOW_PHASE_WINDOW_TICKS" '
    def ones($s): [$s | scan("1")] | length;
    $old as $old
    | ($slow | [splits(" +") | select(test("^[A-Za-z0-9_-]+=[0-9]+s$")) | sub("=.*$"; "")] | unique) as $slowphases
    | (($old | keys) + $slowphases | unique) as $phases
    | reduce $phases[] as $p ({ticks: {}, fired: []};
        ($old[$p] // "") as $w
        | (if ($slowphases | index($p)) != null then "1" else "0" end) as $bit
        | (($w + $bit) | if length > $m then .[-$m:] else . end) as $nw
        | .ticks[$p] = $nw
        | if $bit == "1" and ones($nw) >= $n and ones($w) == ($n - 1)
          then .fired += [$p] else . end)
  ' 2>/dev/null)" || return 0
  [[ "$update" == *'"ticks"'* ]] || return 0
  SLOW_TICKS="$(jq -c '.ticks' <<<"$update" 2>/dev/null)" || return 0
  [[ -n "$SLOW_TICKS" ]] || return 0
  slow_ticks_dirty=1
  while IFS= read -r phase; do
    [[ -n "$phase" ]] || continue
    add_event medium "slow-phase:$phase" \
      "scheduler.log: phase $phase was slow in $SLOW_PHASE_MIN_TICKS of the last $SLOW_PHASE_WINDOW_TICKS tick summaries: $(clean "$line")" \
      "tail -n 120 '$A/scheduler.log'"
  done < <(jq -r '.fired[]' <<<"$update" 2>/dev/null)
}
advisor_incident_scan() {
  local result_file result recorded cutoff job_id answer_err outcome exit_code code fallback_signature
  local fail_streak=0 saw_consecutive_failure=0
  local advisor_job_dir="${ZF_WEB_ADVISOR_PROVIDER_JOB_DIR:-$AGENT_HOME/web-advisor-provider-jobs}"
  cutoff="$(python3 - "$((now - 86400))" <<'PY'
from datetime import datetime, timezone
import sys
print(datetime.fromtimestamp(int(sys.argv[1]), timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"))
PY
)"
  for result_file in "$AGENT_HOME"/logs/advisor-batch-*.result.json; do
    [[ -r "$result_file" ]] || continue
    result="$(jq -ce 'select(type == "object")' "$result_file" 2>/dev/null || true)"
    [[ -n "$result" ]] || continue
    recorded="$(jq -r '.recorded_at // empty' <<<"$result")"
    [[ "$recorded" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$ \
      && "$recorded" > "$cutoff" && ( "$recorded" < "$stamp" || "$recorded" == "$stamp" ) ]] || continue
    job_id="$(jq -r '.job_id // empty' <<<"$result")"
    [[ "$job_id" =~ ^[A-Za-z0-9._-]{1,128}$ ]] || job_id=""
    answer_err=""
    [[ -z "$job_id" ]] || answer_err="$advisor_job_dir/$job_id/answer.err"
    for code in ADVISOR_MODEL_UNVERIFIED ADVISOR_ANSWER_TIMEOUT ADVISOR_SEND_NOT_CONFIRMED ADVISOR_SESSION_SIGNED_OUT ADVISOR_SESSION_UNREADABLE ADVISOR_WRONG_ACCOUNT; do
      if jq -e --arg code "$code" '(.advisor_error_codes // []) | index($code) != null' \
        <<<"$result" >/dev/null 2>&1 || { [[ -n "$answer_err" && -r "$answer_err" ]] \
          && grep -Fq -- "$code" "$answer_err"; }; then
        add_event high "advisor-error:$code" "advisor batch error signature $code" \
          "redacted advisor diagnostic marker: $code"
      fi
    done
    fallback_signature="$(jq -r '.model_fallback_signature // empty' <<<"$result")"
    if [[ "$fallback_signature" == picker-not-found ]] \
      || [[ "$(jq -r '.advisor_signal // empty' <<<"$result")" == 'ADVISOR_MODEL_FALLBACK picker-not-found' ]]; then
      add_event high "advisor-model-fallback:picker-not-found" \
        'advisor model picker was not found; the batch used its configured fallback' \
        'ADVISOR_MODEL_FALLBACK picker-not-found'
    fi

    outcome="$(jq -r '.outcome // empty' <<<"$result")"
    exit_code="$(jq -r '.exit_code // 0' <<<"$result")"
    [[ "$exit_code" =~ ^-?[0-9]+$ ]] || exit_code=1
    if [[ -n "$job_id" && ( "$outcome" == job-failed || "$outcome" == job-timeout \
        || ( "$exit_code" != 0 && "$outcome" != pending && "$outcome" != dispatched ) ) ]]; then
      if (( fail_streak > 0 )); then saw_consecutive_failure=1; fi
      fail_streak=$((fail_streak + 1))
    elif [[ -n "$job_id" && "$outcome" == completed && "$exit_code" == 0 ]]; then
      fail_streak=0
    fi
  done
  if (( saw_consecutive_failure == 1 )); then
    add_event high advisor-batch-consecutive-failures \
      'two consecutive advisor batch jobs failed' \
      'two consecutive terminal advisor-batch result records failed within 24 hours'
  fi
}

main_ci_incident_scan() {
  local wf runs seen key run run_id sha created conclusion status jobs_json failed_jobs failed_count
  local job job_id check_name failed_log first_failure failed_step run_ok processed snapshot_cutoff
  snapshot_cutoff="$(python3 - "$((now - 86400))" <<'PY'
from datetime import datetime, timezone
import sys
print(datetime.fromtimestamp(int(sys.argv[1]), timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"))
PY
)"
  for wf in CI 'Pipeline suites'; do
    runs="$(pr_run_snapshot_section "$A" ".main_runs[\"$wf\"]" 2>/dev/null || true)"
    jq -e 'type == "array"' <<<"$runs" >/dev/null 2>&1 || continue
    seen="$(jq -c '.main_ci_runs_seen // {}' <<<"$STATE_JSON")"
    while IFS= read -r run; do
      [[ -n "$run" ]] || continue
      run_id="$(jq -r '.databaseId // empty' <<<"$run")"
      sha="$(jq -r '.headSha // empty' <<<"$run")"
      created="$(jq -r '.createdAt // empty' <<<"$run")"
      status="$(jq -r '.status // empty' <<<"$run")"
      conclusion="$(jq -r '.conclusion // empty' <<<"$run")"
      [[ "$run_id" =~ ^[1-9][0-9]*$ && "$sha" =~ ^[0-9a-f]{40}$ \
        && "$created" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$ \
        && "$status" == completed && "$conclusion" == failure && "$created" > "$snapshot_cutoff" ]] || continue
      key="$wf:$run_id"
      [[ "$(jq -r --arg k "$key" '.main_ci_runs_seen[$k] // false' <<<"$STATE_JSON")" == false ]] || continue
      jobs_json="$(gh_timeout -k 1 8 run view "$run_id" --repo "$INCIDENT_REPO" --json jobs -q '.jobs' 2>/dev/null)" || continue
      jq -e 'type == "array" and all(.[]; type == "object")' <<<"$jobs_json" >/dev/null 2>&1 || continue
      failed_jobs="$(jq -c '[.[] | select(.conclusion == "failure")]' <<<"$jobs_json")"
      failed_count="$(jq 'length' <<<"$failed_jobs")"
      if (( failed_count == 0 )); then
        add_event high "main-ci:$wf:workflow:unreported" \
          "main CI red commit=$sha check=$wf first_failure=unreported" \
          "commit=$sha workflow=$wf failed without a failed job record"
        STATE_JSON="$(jq -c --arg k "$key" --argjson now "$now" '.main_ci_runs_seen[$k]=$now' <<<"$STATE_JSON")"
        continue
      fi
      run_ok=1
      processed=0
      while IFS= read -r job; do
        [[ -n "$job" ]] || continue
        job_id="$(jq -r '.databaseId // .id // empty' <<<"$job")"
        check_name="$(jq -r '.name // .displayTitle // "unnamed check"' <<<"$job")"
        [[ "$job_id" =~ ^[1-9][0-9]*$ ]] || { run_ok=0; continue; }
        if ! failed_log="$(gh_timeout -k 1 8 run view "$run_id" --job "$job_id" --repo "$INCIDENT_REPO" --log-failed 2>/dev/null)"; then
          run_ok=0
          continue
        fi
        first_failure="$(ci_first_failed_test_id "$failed_log" 2>/dev/null || true)"
        if [[ -z "$first_failure" ]]; then
          failed_step="$(jq -r '[.steps[]? | select(.conclusion == "failure") | .name][0] // empty' <<<"$job")"
          first_failure="${failed_step:-unreported-test-output}"
        fi
        add_event high "main-ci:$check_name:$first_failure" \
          "main CI red commit=$sha check=$check_name first_failure=$first_failure" \
          "commit=$sha workflow=$wf check=$check_name first_failure=$first_failure"
        processed=$((processed + 1))
      done < <(jq -c '.[] | select(.conclusion == "failure")' <<<"$failed_jobs")
      if (( run_ok == 1 && processed == failed_count )); then
        STATE_JSON="$(jq -c --arg k "$key" --argjson now "$now" '.main_ci_runs_seen[$k]=$now' <<<"$STATE_JSON")"
      fi
    done < <(jq -c --arg cutoff "$snapshot_cutoff" --arg wf "$wf" --argjson seen "$seen" '
      [.[] | select(.status == "completed" and .conclusion == "failure"
        and (.createdAt // "") >= $cutoff and (.createdAt // "") <= (now | todateiso8601)
        and (.databaseId | type == "number") and (.headSha // "" | test("^[0-9a-f]{40}$"))
        and ($seen[($wf + ":" + (.databaseId | tostring))] // false) == false)]
      | sort_by([.createdAt, .databaseId]) | reverse | .[:5][]' <<<"$runs")
  done
  STATE_JSON="$(jq -c --argjson now "$now" '.main_ci_runs_seen |= with_entries(select((.value // 0) > ($now - 604800)))' <<<"$STATE_JSON")"
}

file_incident_issue() {
  local class="$1" severity="$2" summary="$3" evidence="$4" first_seen="$5" count="$6"
  local engine_dir upsert body_file title target
  engine_dir="${ZF_ENGINE_DIR:-$ROOT/engine}"
  upsert="$engine_dir/pipeline-issue-upsert.sh"
  [[ -r "$upsert" ]] || { echo "bell.sh: incident upsert helper is missing: $upsert" >&2; return 1; }
  target="$(incident_target_repo "$summary $evidence")"
  body_file="$(mktemp "$A/.bell-incident.XXXXXX")" || return 1
  title="Incident: ${summary:0:180}"
  {
    printf '# Detected incident\n\n'
    printf -- '- Class: `%s`\n- Severity: %s\n- First seen: %s\n- Occurrence count: %s\n- Latest seen: %s\n\n' \
      "$class" "$severity" "$first_seen" "$count" "$stamp"
    printf '## Observation\n\n%s\n\n## Evidence lines\n\n%s\n' "$summary" "$evidence"
  } > "$body_file"
  local output status
  if output="$(ZF_GH_REPO="$INCIDENT_REPO" ZF_REPO="$INCIDENT_REPO" ZF_REPO_DIR="$ROOT" ZF_ENGINE_DIR="$engine_dir" \
    bash "$upsert" --class "$class" --title "$title" --body-file "$body_file" --lane pipeline-system \
    --label incident --repo "$target" 2>&1)"; then
    [[ -z "$output" ]] || printf '%s\n' "$output" >> "$LOG"
    rm -f -- "$body_file"
    return 0
  else
    status=$?
    printf '[%s] incident upsert failed class=%s: %s\n' "$stamp" "$class" "$(clean "$output")" >> "$LOG"
    rm -f -- "$body_file"
    return "$status"
  fi
}

queue_incident_filing() {
  local severity="$1" raw="$2" summary="$3" evidence="$4"
  local class first_seen occurrence_count stats
  (( $(severity_rank "$severity") >= FILE_MIN_SEVERITY_RANK )) || return 0
  class="$(incident_class "$(incident_fingerprint "$raw")")"
  # 一次读取 first_seen/count；逐字段读会把整个（MB 级）状态各解析一遍。
  stats="$(jq -r --arg c "$class" '(.incident_stats[$c] // {}) as $s | [($s.first_seen // ""), ($s.count // 0 | tostring)] | @tsv' <<<"$STATE_JSON" 2>/dev/null || true)"
  IFS=$'\t' read -r first_seen occurrence_count <<<"$stats"
  [[ "$occurrence_count" =~ ^[0-9]+$ ]] || occurrence_count=0
  [[ -n "$first_seen" ]] || first_seen="$stamp"
  occurrence_count=$((occurrence_count + 1))
  STATE_JSON="$(jq -c --arg c "$class" --arg first "$first_seen" --arg latest "$stamp" \
    --arg severity "$severity" --arg summary "$summary" --arg evidence "$evidence" \
    --argjson count "$occurrence_count" \
    '.incident_stats[$c]={first_seen:$first,count:$count,last_seen:$latest}
     |.incident_filing[$c]={class:$c,severity:$severity,summary:$summary,evidence:$evidence,first_seen:$first,count:$count}' \
    <<<"$STATE_JSON")"
}

# Read the candidate identities retained by the scheduler and both publishers.
# release.json is only a human checklist; without an authoritative publisher
# ledger, pending work cannot prove that an older CI run is disposable.
ci_protection() {
  local agent_home="$EXPLICIT_AGENT_HOME"
  [[ -n "$agent_home" || ! -d "${AGENT_HOME:-}/state" ]] || agent_home="$AGENT_HOME"
  python3 - "$A" "$agent_home" <<'PY'
import glob,json,os,re,sys
a,agent_home=sys.argv[1:]
shas=set(); runs=set()
def read(path):
 with open(path,encoding="utf-8") as f: value=json.load(f)
 if not isinstance(value,dict): raise ValueError("state must be an object")
 return value
def sha(value,required=False):
 if value in (None,"") and not required: return
 if not isinstance(value,str) or not re.fullmatch(r"[0-9a-f]{40}",value):
  raise ValueError("active candidate SHA is missing or invalid")
 shas.add(value)
try:
 units=read(os.path.join(a,"units.json")).get("units")
 if not isinstance(units,list): raise ValueError("units array is missing")
 try: # 退休进 units-archive.json 的终态单元仍要参与 shape 校验
  archived=read(os.path.join(a,"units-archive.json")).get("units")
  if isinstance(archived,list): units=units+archived
 except OSError: pass
 for unit in units:
  if not isinstance(unit,dict) or not isinstance(unit.get("stage"),str):
   raise ValueError("unit stage is missing or invalid")
 train_path=os.path.join(a,"release-train.json")
 has_train=os.path.lexists(train_path)
 if has_train:
  train=read(train_path)
  status=train.get("status")
  # release_train.sh retains old released_sha/build_run fields when it starts
  # another attempt. Only current status/candidate identify pending work.
  if status in ("building","deploying","held","blocked-credentials","deferred-busy"):
   sha(train.get("candidate"),required=True)
  # delegated: run-release.sh owns the candidate; its state/*.json release_candidate is read below.
  elif status not in ("released","failed","built","no-image-change","delegated"):
   raise ValueError("release train status is missing or unknown")
  # build_run belongs to example-infra; it is not a the product source CI run identity.
 if agent_home:
  state_dir=os.path.join(agent_home,"state")
  if not os.path.isdir(state_dir) or not os.access(state_dir,os.R_OK|os.X_OK):
   raise ValueError("configured run-release state directory is unavailable")
  for path in sorted(glob.glob(os.path.join(state_dir,"*.json"))):
   candidate=read(path).get("release_candidate")
   if candidate is None: continue
   if not isinstance(candidate,dict): raise ValueError("release candidate is invalid")
   status=candidate.get("status")
   if status == "invalidated": continue
   if status not in ("waiting","selected"): raise ValueError("release candidate status is unknown")
   sha(candidate.get("sha") or candidate.get("head_sha"),required=True)
   sha(candidate.get("head_sha"))
 elif not has_train:
  steps=read(os.path.join(a,"release.json")).get("steps")
  if not isinstance(steps,list): raise ValueError("release checklist is missing")
  if any(not isinstance(step,dict) or step.get("status") != "done" for step in steps):
   raise ValueError("unfinished release has no authoritative candidate ledger")
 print(json.dumps({"shas":sorted(shas),"run_ids":sorted(runs)}))
except (OSError,ValueError,TypeError) as exc:
 print(str(exc),file=sys.stderr)
 sys.exit(1)
PY
}
# 2026-11-04（--argjson 事故复发防护）：heredoc 临时文件创建失败（/tmp 写满）时 python 静默退出 0 且无输出，
# ci_protection 的"成功"输出成了空串，直接喂给 --argjson 产生 "invalid JSON text"。成功路径同样必须验形状。
ci_protection_valid() {
  jq -en --argjson p "$1" \
    '($p | type) == "object" and (($p.shas // []) | type) == "array" and (($p.run_ids // []) | type) == "array"' \
    >/dev/null 2>&1
}

# Probe GitHub's main ref on every beat. Keep the last known outage in state so
# recovery is emitted once, even when the probe remains green on later beats.
network_down="$(jq -r '.network_down // false' <<<"$STATE_JSON")"
probe_error=""
if probe_error="$(cd "$ROOT" && timeout 8 git ls-remote origin refs/heads/main 2>&1 >/dev/null)"; then
  if [[ "$network_down" == true ]]; then
    add_event info "network-recovered" "network-recovered: GitHub probe is green again" "network probe recovered after an outage"
    STATE_JSON="$(jq -c '.network_down=false' <<<"$STATE_JSON")"
  fi
else
  probe_status=$?
  if (( probe_status != 0 )) && printf '%s' "$probe_error" | grep -Eiq '502|timed out|Connection'; then
    add_event high "network-down" "network-down: suites 裁决在此期间可能假阴性；网络恢复后应重跑在跑的失败 run" "timeout 8 git ls-remote origin refs/heads/main failed: $probe_error"
    STATE_JSON="$(jq -c '.network_down=true' <<<"$STATE_JSON")"
  fi
fi

lines=0
[[ -s "$A/scheduler.log" ]] && lines="$(wc -l < "$A/scheduler.log" | awk '{print $1}')"
# 每个告警文件一次 python stat 是 7 次进程创建；一次批量 stat 输出同样的 {rel: mtime_ns} 映射。
alerts='{}'
if [[ -d "$A/alerts" ]]; then
  alerts="$(python3 - "$A/alerts" <<'PY'
import json,os,sys
out={}
try:
  for name in sorted(os.listdir(sys.argv[1])):
    if name.startswith('.') or not name.endswith('.md'): continue
    path=os.path.join(sys.argv[1],name)
    if not os.path.isfile(path): continue
    try: out['alerts/'+name]=os.stat(path).st_mtime_ns
    except OSError: out['alerts/'+name]=0
except OSError: pass
print(json.dumps(out))
PY
)"
  jq -e 'type=="object"' <<<"$alerts" >/dev/null 2>&1 || alerts='{}'
fi
# 退休进 units-archive.json 的终态单元也是台账历史（merge-reverted 监控按单元 history 扫描）。
bell_units_history() {
  if [[ -r "$A/units-archive.json" ]]; then
    jq -s --slurpfile arch "$A/units-archive.json" '{units: ((.[0].units // []) + ($arch[0].units // []))}' "$A/units.json" 2>/dev/null || cat "$A/units.json"
  else
    cat "$A/units.json"
  fi
}
# units.json 有 8MB：一次解析出 merge-reverted 行，事件循环与状态合并共用；逐行重读是每拍双倍的解析开销。
merges='{}'
merge_rows=""
if [[ -r "$A/units.json" ]]; then
  merge_rows="$(jq -r '.units[]? as $u|($u.history//[])|to_entries[]?|select(.value.stage=="merge-reverted")|[$u.id,(.key|tostring),(.value.at//""),(.value.result//"")]|@tsv' <(bell_units_history) 2>/dev/null || true)"
fi

if [[ "$MONITOR_INITIALIZED" == true ]]; then
  old_lines="$(jq -r '.scheduler_lines' <<<"$STATE_JSON")"
  [[ "$old_lines" =~ ^[0-9]+$ ]] || old_lines=0
  (( lines < old_lines )) && old_lines=0
  if (( lines > old_lines )); then
    line_num="$old_lines"
    SLOW_TICKS="$(jq -c '.slow_phase_ticks // {}' <<<"$STATE_JSON" 2>/dev/null || echo '{}')"
    slow_ticks_dirty=0
    while IFS= read -r line; do
      line_num=$((line_num + 1))
      [[ -n "$line" ]] || continue
      # tick/refill done 行只是每拍汇总；它的阶段计时含 release_dependency_blocks，会被 BLOCK 误判成 high（2026-10-20 32 条）。
      # 单次 slow: 阶段也只是计时指标，不排队不立项（2026-11-03 一次 slow 就开了事故单）；
      # 只有同一阶段在最近 M 拍汇总里慢了 N 次才升级为 slow-phase 事件。
      if [[ "$line" == *"] tick done "* || "$line" == *"] refill done "* ]]; then
        record_slow_phase_tick "$line"
        continue
      fi
      event_class="$(scheduler_signature_class "$line")"
      if [[ -n "$event_class" ]]; then
        event_stamp=""
        [[ "$line" =~ ^\[([^]]+)\] ]] && event_stamp="${BASH_REMATCH[1]}"
        seen_epoch=0
        if [[ "$event_stamp" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$ ]]; then
          seen_epoch="$(scheduler_signature_last_seen "$event_class" "$line_num" "$event_stamp")"
        fi
        if [[ "$seen_epoch" =~ ^[0-9]+$ ]] && (( now - seen_epoch < 86400 )); then
          STATE_JSON="$(jq -c --arg c "$event_class" --argjson seen "$seen_epoch" '.scheduler_signature_seen[$c]=$seen' <<<"$STATE_JSON")"
          continue
        fi
        add_event high "$event_class" "scheduler signature $event_class: $(clean "$line")" "scheduler.log: $line"
        STATE_JSON="$(jq -c --arg c "$event_class" --argjson seen "$now" '.scheduler_signature_seen[$c]=$seen' <<<"$STATE_JSON")"
        continue
      fi
      # KILL/BLOCK 必须大小写敏感：小写的 blocked/unblocked/no-kill 是常规行，不是事故（#266 #314 #320）。
      printf '%s\n' "$line" | grep -Eiq 'SLOW|orphan-recover|budget|merge-revert|error' || printf '%s\n' "$line" | grep -Eq 'KILL|BLOCK' || continue
      clean_line="$(printf '%s\n' "$line" | sed -E 's/^\[[^]]+\][[:space:]]*//' | tr '\t\r\n' '   ')"
      sev=medium
      { printf '%s\n' "$clean_line" | grep -Eq 'KILL|BLOCK' || printf '%s\n' "$clean_line" | grep -Eiq 'merge-revert|error'; } && sev=high
      if printf '%s\n' "$clean_line" | grep -Eiq 'merge-reverted'; then
        unit="$(printf '%s\n' "$clean_line" | sed -nE 's/.*merge-reverted unit=([^ ]+).*/\1/p')"
        [[ -n "$unit" ]] || unit=unknown
        raw="merge-reverted unit=$unit"; sev=high
      else
        raw="scheduler:$clean_line"
      fi
      add_event "$sev" "$raw" "scheduler.log: $clean_line" "tail -n 120 '$A/scheduler.log'"
    done < <(sed -n "$((old_lines+1)),${lines}p" "$A/scheduler.log" 2>/dev/null)
    if (( slow_ticks_dirty )); then
      STATE_JSON="$(jq -c --argjson u "$SLOW_TICKS" '.slow_phase_ticks=$u' <<<"$STATE_JSON")"
    fi
  fi

  declare -A old_alert_mtimes=()
  while IFS=$'\t' read -r rel mt; do
    [[ -n "$rel" ]] || continue
    old_alert_mtimes["$rel"]="$mt"
  done < <(jq -r '(.alert_mtimes // {}) | to_entries[] | [.key, (.value|tostring)] | @tsv' <<<"$STATE_JSON" 2>/dev/null)
  while IFS=$'\t' read -r rel mt; do
    [[ -n "$rel" ]] || continue
    [[ -n "$mt" && "$mt" != "${old_alert_mtimes[$rel]:-}" ]] || continue
    last="$(tail -n 1 "$A/$rel" 2>/dev/null | tr '\t\r\n' '   ')"
    add_event medium "alerts-mtime:$rel" "alert changed: $rel $last" "tail -n 120 '$A/$rel'"
  done < <(jq -r 'to_entries | sort_by(.key) | .[] | [.key, (.value|tostring)] | @tsv' <<<"$alerts" 2>/dev/null)

  if [[ -n "$merge_rows" ]]; then
    declare -A known_merges=()
    merge_keys=()
    while IFS=$'\t' read -r k _; do
      [[ -n "$k" ]] || continue
      known_merges["$k"]=1
    done < <(jq -r '(.merge_events // {}) | keys[]' <<<"$STATE_JSON" 2>/dev/null)
    while IFS=$'\t' read -r unit idx at result; do
      [[ -n "$unit" ]] || continue
      key="${unit}:${idx}:${at}"
      merge_keys+=("$key")
      [[ -z "${known_merges[$key]:-}" ]] || continue
      add_event high "merge-reverted unit=$unit" "merge-reverted unit=$unit $(clean "$result")" "tail -n 120 '$A/units.json'; tail -n 120 '$A/alerts/merge.md'"
    done <<<"$merge_rows"
    merges="$(printf '%s\n' "${merge_keys[@]}" | jq -Rsc 'split("\n") | map(select(length > 0)) | reduce .[] as $k ({}; .[$k]=true)' 2>/dev/null || echo '{}')"
  fi
fi
tick=""; tick_epoch=""
if [[ -s "$A/scheduler.log" ]]; then
  tick="$(python3 "$HERE/scheduler_tick.py" "$A/scheduler.log" "$now")"
  tick_epoch="$(to_epoch "$tick")"
  # 行首时间是该拍开始的 STAMP：一拍 6 分钟 + sleep 120s 后最后一行看着有 8 分钟旧，其实刚写完。
  # 日志最后写入时刻才是存活信号（2026-10-21 02:07–02:20 连续三次误判重启）。
  log_epoch="$(mtime_epoch "$A/scheduler.log" 2>/dev/null || echo 0)"
  if [[ "$tick_epoch" =~ ^[0-9]+$ && "$log_epoch" =~ ^[0-9]+$ ]] && (( log_epoch > tick_epoch )); then tick_epoch="$log_epoch"; fi
fi
stale=0
if [[ ! "$tick_epoch" =~ ^[0-9]+$ ]] || (( now - tick_epoch > 360 )); then stale=1; fi
# 慢 tick 不是卡死：tick 锁的持有进程还活着且锁不到 30 分钟，就不算 stale。2026-10-20 tick 常要 6–7 分钟，
# bell 每次都判 stale 重启 scheduler 单元，连带杀光在跑的 worker（5 小时 40 个无产出死亡）。
if [[ "$stale" == 1 && -d "$A/.scheduler.lock" ]]; then
  lock_pid="$(cat "$A/.scheduler.lock/pid" 2>/dev/null || true)"
  if [[ "$lock_pid" =~ ^[0-9]+$ ]] && kill -0 "$lock_pid" 2>/dev/null \
      && [[ -z "$(find "$A/.scheduler.lock" -maxdepth 0 -mmin +30 2>/dev/null)" ]]; then
    stale=0
  fi
fi
if [[ "$stale" == 1 ]]; then
  restart="not attempted in check-only mode"
  sev=high
  if [[ "$CHECK_ONLY" != 1 ]] && autopilot_manual_pause_is_valid; then
    restart="paused, not restarting"
  elif [[ "$CHECK_ONLY" != 1 ]] && ! restart_allowed; then restart="restart cap: 3 per hour with backoff, not restarting"; sev=critical
  elif [[ "$CHECK_ONLY" != 1 && -n "${AUTOPILOT_LOOP_UNIT:-}" ]]; then
    # systemd 托管时由 systemd 重启，避免与 Restart=always 叠出第二个 loop。
    if systemctl --user restart "$AUTOPILOT_LOOP_UNIT" 2>/dev/null; then restart="loop restarted via systemd unit $AUTOPILOT_LOOP_UNIT"; else restart="systemd restart of $AUTOPILOT_LOOP_UNIT failed"; sev=critical; fi
  elif [[ "$CHECK_ONLY" != 1 ]]; then
    if [[ -r "$A/loop.pid" ]]; then
      old_pid="$(cat "$A/loop.pid" 2>/dev/null || true)"
      if [[ "$old_pid" =~ ^[0-9]+$ && "$old_pid" != "$$" ]]; then
        old_cmd="$(ps -p "$old_pid" -o command= 2>/dev/null || true)"
        [[ "$old_cmd" == *"loop.sh"* ]] && kill "$old_pid" 2>/dev/null || true
      fi
    fi
    pkill -f 'bash loop[.]sh' 2>/dev/null || true; pkill -f 'autopi-live/loop[.]sh' 2>/dev/null || true
    sleep 1
    (nohup bash "$MAC_AUTOPILOT_SUPERVISOR_DIR/autopi-live/loop.sh" >> "$A/loop.out" 2>&1 < /dev/null) &
    loop_pid=$!
    printf '%s\n' "$loop_pid" > "$A/loop.pid" 2>/dev/null || true
    sleep 1
    if kill -0 "$loop_pid" 2>/dev/null; then restart="loop restarted pid=$loop_pid"; else restart="loop restart failed"; sev=critical; fi
  fi
  add_event "$sev" "scheduler-stale:last_tick=${tick:-missing}" "scheduler tick stale (${tick:-no readable tick}); $restart" "tail -n 120 '$A/scheduler.log'; ps -Ao pid,command"
fi

if [[ -r "$A/workers.json" && -r "$A/units.json" ]]; then
  while IFS=$'\t' read -r pid unit harvested log report; do
    [[ "$pid" =~ ^[0-9]+$ && -n "$unit" ]] || continue
    [[ "$harvested" == true ]] && continue
    kill -0 "$pid" 2>/dev/null || worker_log_fresh "$log" && continue
    # 已交付报告的 worker 是正常结束、等下一拍回收，不是死亡（每次误报都会拉起一次付费调查）。
    [[ "$report" =~ ^[A-Za-z0-9._/-]+$ && "$report" != *".."* && -s "$SUPERVISOR_DIR/$report" ]] && continue
    stage="$(jq -r --arg id "$unit" '.units[]?|select(.id==$id)|.stage//empty' "$A/units.json" 2>/dev/null | head -n 1)"
    [[ -n "$stage" ]] || continue
    case "$stage" in merged|landed|done|wontfix|duplicate) continue ;; esac
    [[ "$log" =~ ^[A-Za-z0-9._/-]+$ && "$log" != *".."* ]] || log="[invalid path]"
    [[ "$report" =~ ^[A-Za-z0-9._/-]+$ && "$report" != *".."* ]] || report="[invalid path]"
    oom_output="$(ap_oom_evidence 5 | head -c 2048 || true)"
    [[ -n "$oom_output" ]] || oom_output="[no matching journal output]"
    evidence="tail -n 120 '$SUPERVISOR_DIR/$log'; tail -n 120 '$SUPERVISOR_DIR/$report'; $(ap_oom_command 5) output (max 2048 bytes): $oom_output"
    add_event high "worker-died unit=$unit" "worker-died unit=$unit pid=$pid stage=$stage log=$log report=$report" "$evidence"
  done < <(jq -r '.workers[]?|[(.pid|tostring),(.unit//""),((.harvested//false)|tostring),(.log//""),(.report//"")]|@tsv' "$A/workers.json" 2>/dev/null)
fi

# Repeated pipeline-suite failures are promoted when the same suite appears in
# either scheduler.log or alerts/gate.md at least twice in the last 24 hours.
suite_failures='{}'
record_suite_failures() {
  local file="$1" line timestamp epoch suite count
  [[ -r "$file" ]] || return 0
  while IFS= read -r line; do
    [[ "$line" =~ ^\[([^]]+)\] ]] || continue
    timestamp="${BASH_REMATCH[1]}"
    epoch="$(to_epoch "$timestamp")"
    [[ "$epoch" =~ ^[0-9]+$ ]] || continue
    (( epoch >= now - 86400 && epoch <= now )) || continue
    [[ "$line" =~ \[pipeline[[:space:]]suites\].*FAILED[[:space:]]suite=([^[:space:]]+) ]] || continue
    suite="${BASH_REMATCH[1]}"
    count="$(jq -r --arg suite "$suite" '.[$suite] // 0' <<<"$suite_failures")"
    suite_failures="$(jq -c --arg suite "$suite" --argjson count "$((count + 1))" '.[$suite]=$count' <<<"$suite_failures")"
  done < <(grep -E '^\[[^]]+\].*\[pipeline[[:space:]]suites\].*FAILED[[:space:]]suite=' "$file" 2>/dev/null)
}
record_suite_failures "$A/scheduler.log"
record_suite_failures "$A/alerts/gate.md"
while IFS= read -r suite; do
  [[ -n "$suite" ]] || continue
  add_event high "suite-flake:$suite" "suite-flake:$suite failed at least twice in 24h; 隔离候选：在 engine/run-ci-suites.sh 的 nightly_suite_paths=(...) 中加入 '$suite'，再运行 bash engine/run-ci-suites.sh --nightly（按 nightly 层运行）" "FAILED suite=$suite repeated in scheduler.log or alerts/gate.md; add '$suite' to nightly_suite_paths, then run bash engine/run-ci-suites.sh --nightly"
done < <(jq -r 'to_entries[] | select(.value >= 2) | .key' <<<"$suite_failures")

# Old advisor verdict files with remaining FIX items stay visible as an
# actionable import queue item; no issue or repository writes happen here.
stale_verdict_files=()
unimported_fix_count=0
for f in "$SUPERVISOR_DIR"/advisor-verdicts-*.json; do
  [[ -f "$f" ]] || continue
  file_mtime="$(mtime_epoch "$f" 2>/dev/null || echo 0)"
  [[ "$file_mtime" =~ ^[0-9]+$ ]] || continue
  (( now - file_mtime > 172800 && file_mtime <= now )) || continue
  fix_count="$(jq '[.[]? | select(type=="object" and .verdict=="FIX")] | length' "$f" 2>/dev/null || echo 0)"
  [[ "$fix_count" =~ ^[0-9]+$ ]] || fix_count=0
  (( fix_count > 0 )) || continue
  stale_verdict_files+=("$(basename "$f"):$fix_count")
  unimported_fix_count=$((unimported_fix_count + fix_count))
done
if (( unimported_fix_count > 0 )); then
  file_list="$(printf '%s, ' "${stale_verdict_files[@]}")"
  file_list="${file_list%, }"
  add_event medium "verdicts-backlog-stale" "verdicts-backlog-stale: $unimported_fix_count unimported FIX item(s) in files older than 48h ($file_list); 批量导入模板：gh issue create --repo ${ZF_REPO:-<owner/name>} --title '<FIX 标题>' --body-file '<issue-body.md>' --label auto-filed --label bug --label needs-triage（建成 issue 后由 auto_triage 接管）" "advisor FIX backlog: $unimported_fix_count unimported item(s) in $file_list; template: gh issue create --repo ${ZF_REPO:-<owner/name>} --title '<FIX 标题>' --body-file '<issue-body.md>' --label auto-filed --label bug --label needs-triage"
fi

# S11 dashboard 心跳(dead man's switch):gen_dashboard 曾静默崩 3268 次
if [[ ! -f "$A/dashboard.data.js" ]]; then
  add_event high "dashboard-data-missing" "dashboard-data-missing: dashboard.data.js 不存在,检查生成器输出目录和最近退出日志" "expected heartbeat file: $A/dashboard.data.js"
else
  dash_mtime="$(ap_mtime_epoch "$A/dashboard.data.js" || true)"
  if [[ ! "$dash_mtime" =~ ^[0-9]+$ ]]; then
    add_event high "dashboard-data-unreadable" "dashboard-data-unreadable: 无法读取 dashboard.data.js 心跳时间" "unable to stat $A/dashboard.data.js"
  else
  dash_age=$(( now - dash_mtime ))
  if (( dash_age > 900 )); then
    add_event high "dashboard-data-stale" "dashboard-data-stale: dashboard.data.js 已 ${dash_age}s 未刷新(gen_dashboard 可能静默崩,查 autopilot.err;bell-loop 与 scheduler tick 每 2 分钟都会触发生成)" "dashboard.data.js mtime age ${dash_age}s > 900s"
  fi
  fi
fi

# The run lists come from the scheduler's per-tick snapshot (pr-run-snapshot.json); a missing or malformed one keeps every queue.
# S12 deduplicates CI and Pipeline suites waiting queues independently. Keep
# in_progress runs, waiting runs with started jobs, and each workflow's newest
# queued/pending/waiting run. GitHub can report queued while a shard is running.
# The replacement run supplies the SHA proof, so a [skip ci] main HEAD is safe.
# Check-only reports plans; candidate identity is re-read before cancellation.
if [[ "${BELL_STALE_CI_DISABLE:-0}" != "1" ]]; then
  cancelled=""
  for wf in CI "Pipeline suites"; do
    if ! ci_runs="$(pr_run_snapshot_section "$A" ".main_runs[\"$wf\"]")" \
      || ! jq -e 'type=="array" and all(.[]; (.databaseId|type)=="number" and (.databaseId>0) and (.databaseId|floor)==.databaseId and (.headSha|type)=="string" and (.headSha|test("^[0-9a-f]{40}$")) and (.status|type)=="string" and (.createdAt|type)=="string" and (.createdAt|test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$")))' <<<"$ci_runs" >/dev/null 2>&1; then
      add_event medium "stale-main-ci-verdict-unknown:$wf" "stale-main-ci-verdict-unknown: 无法读取 $wf 的完整 run 列表,保留该队列" "the scheduler snapshot is missing or its run list is invalid"
      continue
    fi
    waiting_runs="$(jq -c '[.[] | select(.status=="queued" or .status=="pending" or .status=="waiting")] | sort_by(.createdAt,.databaseId)' <<<"$ci_runs")"
    [[ "$(jq 'length' <<<"$waiting_runs")" -gt 1 ]] || continue
    if ! protection="$(ci_protection 2>&1)" || ! ci_protection_valid "$protection"; then
      add_event medium "stale-main-ci-protection-unknown" "stale-main-ci-protection-unknown: 保留所有 CI run; $protection" "candidate identity must be readable before cancellation"
      break
    fi
    replacement_sha="$(jq -r '.[-1].headSha' <<<"$waiting_runs")"
    stale_runs=()
    while IFS=$'\t' read -r rid rsha; do
      [[ -n "$rid" ]] || continue
      git -C "$ROOT" merge-base --is-ancestor "$rsha" "$replacement_sha" >/dev/null 2>&1 || continue
      stale_runs+=("$rid:$rsha")
    done < <(jq -r --argjson protected "$protection" \
        '.[-1].createdAt as $latest | .[:-1][] | select(.createdAt < $latest)
         | select(.headSha as $sha | ($protected.shas|index($sha))==null)
         | select((.databaseId|tostring) as $id | ($protected.run_ids|index($id))==null)
         | "\(.databaseId)\t\(.headSha)"' <<<"$waiting_runs")
    if [[ "$CHECK_ONLY" == 1 ]]; then
      if (( ${#stale_runs[@]} > 0 )); then
        add_event info "stale-main-ci-would-cancel:$wf" "stale-main-ci: check-only would cancel $wf ${stale_runs[*]}" "no CI runs were canceled"
      fi
      continue
    fi
    for sr in "${stale_runs[@]}"; do
      rid="${sr%%:*}"; rsha="${sr#*:}"
      # The queued run may have started after the list response.
      if ! current_run="$(gh run view "$rid" -R "${ZF_REPO:?ZF_REPO is not set}" --json databaseId,headSha,status,jobs 2>/dev/null)" \
        || ! jq -e --argjson id "$rid" --arg sha "$rsha" 'type=="object" and .databaseId==$id and .headSha==$sha and (.status|type)=="string"' <<<"$current_run" >/dev/null 2>&1; then
        add_event medium "stale-main-ci-verdict-unknown:$wf" "stale-main-ci-verdict-unknown: 取消前无法确认 $wf run $rid 的状态,保留剩余队列" "run identity or status changed during scan"
        break
      fi
      jq -e '.status=="queued" or .status=="pending" or .status=="waiting"' <<<"$current_run" >/dev/null || continue
      if ! jq -e '(.jobs|type)=="array" and all(.jobs[]; type=="object" and (.status=="queued" or .status=="pending" or .status=="waiting" or .status=="in_progress" or .status=="completed"))' <<<"$current_run" >/dev/null 2>&1; then
        add_event medium "stale-main-ci-jobs-unknown:$wf" "stale-main-ci-jobs-unknown: 取消前无法确认 $wf run $rid 的 job 状态,保留剩余队列" "missing or unknown jobs cannot prove that no job has started"
        break
      fi
      jq -e 'any(.jobs[]; .status=="in_progress" or .status=="completed")' <<<"$current_run" >/dev/null && continue
      if ! protection="$(ci_protection 2>&1)" || ! ci_protection_valid "$protection"; then
        add_event medium "stale-main-ci-protection-unknown" "stale-main-ci-protection-unknown: 取消前保护信息失效,保留剩余 run; $protection" "candidate protection changed during scan"
        break
      fi
      if jq -e --arg sha "$rsha" --arg id "$rid" \
        '(.shas|index($sha))!=null or (.run_ids|index($id))!=null' <<<"$protection" >/dev/null; then
        continue
      fi
      ZF_CANCEL_REASON="superseded by newer main head" bash "${ZF_ENGINE_DIR:-$ROOT/engine}/night/main-ci-recovery.sh" cancel-run "$rid" >/dev/null 2>&1 && cancelled="$cancelled $rid"
    done
  done
  [[ -n "$cancelled" ]] && add_event medium "stale-main-ci-canceled${cancelled}" "stale-main-ci: 取消被更新等待 run 取代、未被候选引用的祖先 run(在跑的不动):${cancelled}" "audited CI/Pipeline suites queue dedupe after candidate and ancestry checks: ${cancelled}"
fi

live_evidence_scan; advisor_incident_scan; main_ci_incident_scan; auto_pin_scan; zf_main_ci_scan

if [[ "$CHECK_ONLY" == 1 ]]; then
  echo "bell check-only: ${#events[@]} candidate event(s); runtime state and files were not changed"
  for item in "${events[@]}"; do
    IFS=$'\t' read -r sev raw summary evidence <<<"$item"
    h="$(printf '%s' "$raw" | shasum -a 256 | awk '{print $1}')"
    echo "candidate severity=$sev sig=${h:0:16}"
  done
  exit 0
fi

for item in "${events[@]}"; do
  IFS=$'\t' read -r sev raw summary evidence <<<"$item"
  h="$(printf '%s' "$raw" | shasum -a 256 | awk '{print $1}')"
  # prev/count/event_id 一次读出；逐字段读会把整个（MB 级）状态各解析一遍。
  sig_info="$(jq -r --arg h "$h" '(.signatures[$h] // {}) as $s | [($s.last // 0 | tostring), ($s.count // 0 | tostring), ($s.event_id // "")] | @tsv' <<<"$STATE_JSON" 2>/dev/null || true)"
  IFS=$'\t' read -r prev count event_id <<<"$sig_info"
  [[ "$prev" =~ ^[0-9]+$ ]] || prev=0
  [[ "$count" =~ ^[0-9]+$ ]] || count=0
  if [[ "$raw" != network-recovered ]] && (( prev > 0 && now - prev < DEDUP_SECONDS )); then
    count=$((count+1))
    STATE_JSON="$(jq -c --arg h "$h" --argjson now "$now" --argjson n "$count" '.signatures[$h].last=$now|.signatures[$h].count=$n' <<<"$STATE_JSON")"
    queue_incident_filing "$sev" "$raw" "$summary" "$evidence"
    save_state
    continue
  fi

  queue_incident_filing "$sev" "$raw" "$summary" "$evidence"

  event_seq=$((event_seq+1))
  event_id="${now}-$$-${event_seq}"
  STATE_JSON="$(jq -c --arg h "$h" --arg raw "$raw" --arg id "$event_id" --arg sev "$sev" --arg summary "$summary" --arg evidence "$evidence" --argjson now "$now" '.signatures[$h]={last:$now,count:1,event_id:$id}|.pending += [{id:$id,signature:$h,raw_signature:$raw,severity:$sev,summary:$summary,evidence:$evidence,status:"queued"}]' <<<"$STATE_JSON")"
  if ! grep -Fq "event_id=$event_id" "$QUEUE" 2>/dev/null; then
    printf '[%s] %s %s event_id=%s | %s | %s\n' "$stamp" "$sev" "$h" "$event_id" "$summary" "$evidence" >> "$QUEUE" || true
  fi
  action_ids+=("$event_id"); action_severities+=("$sev"); action_sigs+=("$h")
  action_results+=("queue=append")
  save_state
done

# Keep failed writes queued in bell-state and retry them on the next scan. The
# upsert helper is idempotent by class, so a retry cannot open a second issue.
while IFS=$'\t' read -r incident_key incident_severity incident_summary incident_evidence incident_first_seen incident_count; do
  [[ -n "$incident_key" ]] || continue
  if file_incident_issue "$incident_key" "$incident_severity" "$incident_summary" "$incident_evidence" "$incident_first_seen" "$incident_count"; then
    printf '[%s] incident filed class=%s count=%s\n' "$stamp" "$incident_key" "$incident_count" >> "$LOG"
    STATE_JSON="$(jq -c --arg c "$incident_key" 'del(.incident_filing[$c])' <<<"$STATE_JSON")"
    save_state
  else
    printf '[%s] incident filing failed class=%s; will retry\n' "$stamp" "$incident_key" >> "$LOG"
  fi
done < <(jq -r '.incident_filing // {} | to_entries[] | [.key,.value.severity,.value.summary,.value.evidence,.value.first_seen,(.value.count|tostring)] | @tsv' <<<"$STATE_JSON")

if [[ -r "$A/BELL-RESOLUTION.md" ]]; then
  # 2026-11-04：pending 积到 3500+ 条后，逐条 grep BELL-RESOLUTION.md 是每拍 7000 个进程、
  # CPU 的大头。这里改为一次提取全部裁决，再单趟 jq 批量改状态；匹配语义与逐条
  # grep -F "event_id: <id> status: complete|failed" 相同（complete 优先）。
  declare -A res_done=() res_failed=()
  while IFS= read -r entry; do
    id="${entry#event_id: }"
    case "$entry" in
      *" status: complete") res_done["${id% status: complete}"]=1 ;;
      *" status: failed") res_failed["${id% status: failed}"]=1 ;;
    esac
  done < <(grep -oE 'event_id: [^ ]+ status: (complete|failed)' "$A/BELL-RESOLUTION.md" 2>/dev/null)
  if (( ${#res_done[@]} + ${#res_failed[@]} > 0 )); then
    res_done_ids="$(printf '%s\n' "${!res_done[@]}" | jq -Rsc 'split("\n") | map(select(length > 0))' 2>/dev/null || echo '[]')"
    res_failed_ids="$(printf '%s\n' "${!res_failed[@]}" | jq -Rsc 'split("\n") | map(select(length > 0))' 2>/dev/null || echo '[]')"
    STATE_JSON="$(jq -c --argjson d "$res_done_ids" --argjson f "$res_failed_ids" '
      .pending |= map(if (.id as $i | $d | index($i)) != null then .status="done"
                      elif (.id as $i | $f | index($i)) != null then .status="failed" else . end)' <<<"$STATE_JSON")"
  fi
fi

for i in "${!action_ids[@]}"; do
  printf '[%s] %s sig=%s event_id=%s action=%s\n' "$stamp" "${action_severities[$i]}" "${action_sigs[$i]}" "${action_ids[$i]}" "${action_results[$i]}" >> "$LOG"
done
# 状态瘦身:已完结 pending 只留最近 50 条,7 天未再出现的签名淘汰(防 bell-state 无界增长拖慢每拍)。
# 2026-11-04：queued 条目曾只有 auto_supervisor 会清，它关闭时无限堆积(实测 3500+ 条/1.9MB，
# 每拍 jq 都在反复解析它)，故未完结条目也只留最近 BELL_PENDING_KEEP 条。去重走 .signatures，不受影响。
# auto_supervisor 已退役：没有任何进程再清 queued，这个上限是唯一的界。
BELL_PENDING_KEEP="${BELL_PENDING_KEEP:-200}"
STATE_JSON="$(jq -c --argjson now "$now" --argjson keep "$BELL_PENDING_KEEP" '
  .pending |= (([.[] | select(.status != "done" and .status != "failed")] | if length > $keep then .[-$keep:] else . end)
             + ([.[] | select(.status == "done" or .status == "failed")] | .[-50:]))
  | .signatures |= with_entries(select((.value.last // 0) > ($now - 604800)))' <<<"$STATE_JSON")"
if [[ "$MONITOR_INITIALIZED" != true ]]; then
  STATE_JSON="$(jq -c --argjson lines "$lines" --argjson alerts "$alerts" --argjson merges "$merges" '.monitor_initialized=true|.scheduler_lines=$lines|.alert_mtimes=$alerts|.merge_events=$merges' <<<"$STATE_JSON")"
else
  STATE_JSON="$(jq -c --argjson lines "$lines" --argjson alerts "$alerts" --argjson merges "$merges" '.scheduler_lines=$lines|.alert_mtimes=$alerts|.merge_events=((.merge_events//{})+$merges)' <<<"$STATE_JSON")"
fi
save_state
