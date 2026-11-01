#!/usr/bin/env bash
# Bounded-concurrency scheduler. Runs on a systemd user timer (systemd/
# zenoforge-agent.timer, firing every 5 minutes) and, per tick, fills each
# stage's cap (below) with `systemd-run --user` dispatches of the wrapper
# scripts, then returns promptly:
#   needs-triage -> triage -> ready-for-agent/needs-info/needs-advisor
#   ready-for-agent -> implement -> merge (owned by the autopilot scheduler,
#     not by this script)
#   merged PR -> release -> production + acceptance checklist on the issue
#   pipeline-system labels -> lightweight classification -> direct-main
#     implement -> close once the commit is live in this checkout
#
# AGENT_PIPELINE=implement and release behave as triage; the release slice runs
# only when the autopilot's release train delegates to it. Every stage's actual work happens in its own dispatched systemd
# unit, not in this process — this script only ever decides, it never
# blocks on an agent model call, a CI poll, or a deploy.
#
# 2026-09-12 redesign, from a strictly-serial poller: the previous version
# picked exactly one action per tick and ran the wrapper INLINE, which held
# this tick's own process — and the flock below — for up to the wrapper's
# own multi-hour runtime. That made "concurrency 1" true by construction,
# not by choice: `Type=oneshot` with `KillMode=control-group` (systemd/
# zenoforge-agent.service) means anything this process backgrounds with `&`
# dies the instant the tick exits, so running a wrapper inline (or
# backgrounding it) were the only two options, and only the first survived
# the tick. `systemd-run --user --collect` — a transient unit outside this
# process's control group — is the dispatch primitive that does: probed
# 2026-09-12, a `nohup sleep &` inside a oneshot was gone 2s after the unit
# finished; a `systemd-run --user --unit ... --collect` was still active.
#
# All `gh` calls in the decision section below still live only here and in
# the wrapper scripts, never inside an agent prompt (the agent process
# never runs gh/git push/docker/ssh/curl itself — that's the injection
# containment for a bot with production reach).
set -euo pipefail
IMPLEMENT_RECENT_SKIP_SECONDS=600

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=./lib.sh
source "$SCRIPT_DIR/lib.sh"
source "$SCRIPT_DIR/issue-pipeline-slices.sh"
source "$SCRIPT_DIR/hand-completion-refill.sh"
PIPELINE_CLAIM_KEY=""
PIPELINE_CLAIM_OWNER=""
PIPELINE_CLAIM_UNIT=""
PIPELINE_CLAIM_STAGE=""
pipeline_claim_clear() {
  PIPELINE_CLAIM_KEY=""
  PIPELINE_CLAIM_OWNER=""
  PIPELINE_CLAIM_UNIT=""
  PIPELINE_CLAIM_STAGE=""
}
pipeline_live_worker_check() {
  local runtime_dir="${MAC_AUTOPILOT_RUNTIME_DIR:-$REPO_DIR/.scratch-supervisor/autopi}"
  coord_issue_live_worker "$1" "$runtime_dir"
}
pipeline_claim_begin() { # issue stage systemd-unit -> 0 acquired / 1 held / 3 unknown
  local issue="$1" stage="$2" unit="$3" key owner status
  if [[ "$issue" =~ ^[1-9][0-9]*$ ]]; then
    if pipeline_live_worker_check "$issue"; then return 1; else status=$?; (( status == 1 )) || return 3; fi
  fi
  if [[ "$issue" =~ ^[1-9][0-9]*$ ]]; then
    key="$(coord_issue_key "$issue")" || return 2
  else
    key="$(coord_unit_key "$unit")" || return 2
  fi
  owner="$(coord_new_owner)"
  if coord_acquire "$key" "$owner" systemd-worker "$issue" "$unit" "$stage"; then
    PIPELINE_CLAIM_KEY="$key"
    PIPELINE_CLAIM_OWNER="$owner"
    PIPELINE_CLAIM_UNIT="$unit"
    PIPELINE_CLAIM_STAGE="$stage"
  else
    status=$?
    return "$status"
  fi
  if [[ "$issue" =~ ^[1-9][0-9]*$ ]]; then
    if pipeline_live_worker_check "$issue"; then pipeline_claim_drop; return 1; else status=$?; (( status == 1 )) || { pipeline_claim_drop; return 3; }; fi
  fi
}
pipeline_claim_drop() {
  if [[ -n "$PIPELINE_CLAIM_KEY" && -n "$PIPELINE_CLAIM_OWNER" ]]; then
    coord_release "$PIPELINE_CLAIM_KEY" "$PIPELINE_CLAIM_OWNER" >/dev/null 2>&1 || :
  fi
  pipeline_claim_clear
}
pipeline_claim_keep() { # launched unit owns the lease until a later tick sees it inactive
  local unit="$PIPELINE_CLAIM_UNIT"
  if ! coord_renew "$PIPELINE_CLAIM_KEY" "$PIPELINE_CLAIM_OWNER"; then
    echo "issue-pipeline: claim renewal failed after dispatch; stopping $unit" >&2
    systemctl --user stop "$unit" >/dev/null 2>&1 || :
    pipeline_claim_clear
    return 1
  fi
  echo "issue-pipeline: dispatch claim=owned unit=$unit" >&2
  pipeline_claim_clear
}
pipeline_batch_claim_acquire() { # owner stage unit issue...; atomically reserve every member before launch
  local owner="$1" stage="$2" unit="$3" issue key status
  shift 3
  for issue in "$@"; do
    if pipeline_live_worker_check "$issue"; then return 1; else status=$?; (( status == 1 )) || return 3; fi
  done
  if coord_acquire_many "$owner" systemd-worker "$unit" "$stage" "$@"; then
    for issue in "$@"; do
      key="$(coord_issue_key "$issue")" || { coord_release_many "$owner" "$@" >/dev/null 2>&1 || :; return 2; }
      if ! coord_assert_owned "$key" "$owner" >/dev/null; then
        coord_release_many "$owner" "$@" >/dev/null 2>&1 || :
        return 3
      fi
      if pipeline_live_worker_check "$issue"; then
        coord_release_many "$owner" "$@" >/dev/null 2>&1 || :
        return 1
      else
        status=$?
        if (( status != 1 )); then coord_release_many "$owner" "$@" >/dev/null 2>&1 || :; return 3; fi
      fi
    done
    return 0
  else
    status=$?
    return "$status"
  fi
}
pipeline_batch_claim_drop() {
  local owner="$1"; shift
  coord_release_many "$owner" "$@" >/dev/null 2>&1 || :
}
pipeline_batch_claim_keep() { # renew every member after the batch transient unit starts
  local owner="$1" unit="$2" issue key; shift 2
  for issue in "$@"; do
    key="$(coord_issue_key "$issue")" || return 2
    if ! coord_renew "$key" "$owner"; then
      echo "issue-pipeline: batch claim renewal failed; stopping $unit" >&2
      systemctl --user stop "$unit" >/dev/null 2>&1 || :
      pipeline_batch_claim_drop "$owner" "$@"
      return 1
    fi
  done
  echo "issue-pipeline: batch claim=owned unit=$unit issues=${*}" >&2
  return 0
}
PIPELINE_STAGE=""
EVENT_REFILL=0
EVENT_REFILL_STATUS=0
if [ "$#" = 0 ]; then
  run_pipeline_slices "$0"
  exit $?
fi
if [ "$#" = 2 ] && [ "$1" = --stage ]; then
  case "$2" in
    ready-refill) PIPELINE_STAGE=implement; EVENT_REFILL=1 ;;
    fastlane|triage|advisor|recut|implement|release|maintenance) PIPELINE_STAGE="$2" ;;
    *) echo 'issue-pipeline: invalid stage' >&2; exit 2 ;; esac
else
  echo 'issue-pipeline: expected --stage <stage>' >&2; exit 2
fi
if [ "$EVENT_REFILL" = 1 ] && ! python3 "$SCRIPT_DIR/execution-admission.py" inherited; then
  exec python3 "$SCRIPT_DIR/execution-admission.py" run -- bash "$0" "$@"
fi
# One tick is one item; no exec while heartbeat/lock/child work is active.
if declare -F agent_reload_init >/dev/null; then agent_reload_init "$0" "$@"; agent_reload_restore; fi
if ! codex_dispatch_preflight issue-pipeline; then
  echo "issue-pipeline: Codex runtime unavailable; no tickets consumed; dispatch paused" >&2
  [ "${EVENT_REFILL:-0}" = 0 ] || exit 1
  exit 0
fi
coord_reap_expired || echo "issue-pipeline: claim expiry sweep incomplete; dispatch remains fail-closed" >&2
coord_reconcile_systemd_workers || echo "issue-pipeline: worker claim reconciliation incomplete; dispatch remains fail-closed" >&2
NIGHT="${ZF_NIGHT_DIR:-$AGENT_HOME/night}"
INFRA="$ZF_INFRA_REPO"
PIPELINE_ROADMAP_TICK_ID="$(date -u +%Y%m%dT%H%M%SZ)-$$"
ZF_OPEN_ISSUES_CACHE_FILE="${ZF_OPEN_ISSUES_CACHE_FILE:-$NIGHT/.open-issues-pipeline-$PIPELINE_ROADMAP_TICK_ID.json}"
ZF_ROADMAP_TREE_CACHE_FILE="${ZF_ROADMAP_TREE_CACHE_FILE:-$(roadmap_cache_path "$ZF_OPEN_ISSUES_CACHE_FILE")}"
export ZF_OPEN_ISSUES_CACHE_FILE ZF_ROADMAP_TREE_CACHE_FILE
ROADMAP_ORDER_ENABLED="${ZF_PIPELINE_ROADMAP_SWITCH:-$(roadmap_switch_value)}"
ROADMAP_TREE_READY=0
ROADMAP_TREE_JSON=""
ROADMAP_ISSUE_EPICS_JSON='{}'
if [ "$ROADMAP_ORDER_ENABLED" = true ]; then
  mkdir -p -- "$NIGHT"
  find "$NIGHT" -maxdepth 1 -type f -name '.open-issues-pipeline-*.json*' -mmin +720 -delete 2>/dev/null || true
  if [ "${ZF_PIPELINE_ROADMAP_READY:-}" = 1 ]; then
    ROADMAP_TREE_JSON="$(cat -- "$ZF_ROADMAP_TREE_CACHE_FILE")"
    ROADMAP_TREE_READY=1
    ROADMAP_TREE_STALE="${ZF_PIPELINE_ROADMAP_STALE:-0}"
    ROADMAP_SNAPSHOT_AGE_SECONDS="${ZF_PIPELINE_ROADMAP_AGE:-0}"
  elif [ "${ZF_PIPELINE_ROADMAP_READY:-}" = 0 ]; then
    echo "issue-pipeline: roadmap tree read failed; roadmap candidates held this tick" >&2
  elif roadmap_fetch_for_admission "$ZF_ROADMAP_TREE_CACHE_FILE" "$REPO"; then
    ROADMAP_TREE_JSON="$(cat -- "$ZF_ROADMAP_TREE_CACHE_FILE")"
    ROADMAP_TREE_READY=1
  else
    rm -f -- "$ZF_ROADMAP_TREE_CACHE_FILE" "$ZF_ROADMAP_TREE_CACHE_FILE.placed"
    echo "issue-pipeline: roadmap tree read failed; roadmap candidates held this tick" >&2
  fi
fi
if [ "$ROADMAP_TREE_READY" = 1 ]; then
  roadmap_flat="$(roadmap_flatten "$ROADMAP_TREE_JSON")" || roadmap_flat='[]'
  ROADMAP_ISSUE_EPICS_JSON="$(jq -c '
    . as $nodes
    | [$nodes[] as $issue
       | select($issue.depth == 3)
       | $nodes[]
       | select(.number == $issue.parent and .depth == 2 and (.labels | index("roadmap-epic") != null))
       | {key:($issue.number | tostring),value:(.number | tostring)}
      ] | from_entries
  ' <<< "$roadmap_flat" 2>/dev/null)" || ROADMAP_ISSUE_EPICS_JSON='{}'
fi
source "$SCRIPT_DIR/night/hand-agent-watchdog.sh"
# GitNexus is optional context. Triage/advisor units refresh it themselves;
# the scheduler never drains implement for an index refresh (2026-10-08).

PIPELINE_SYSTEM_LABELS_JSON="$(pipeline_system_issue_labels_json)" || {
  echo "issue-pipeline: non-product lane labels are missing or invalid in rulings.json; refusing to run" >&2
  exit 1
}

report_on_hold_query_failures() {
  local exit_status=$?
  [ "$ON_HOLD_QUERY_FAILURE_COUNT" -gt 0 ] || return "$exit_status"
  echo "issue-pipeline: on-hold status could not be verified for $ON_HOLD_QUERY_FAILURE_COUNT read(s) across issue(s) $ON_HOLD_QUERY_FAILURE_ISSUES; fail-closed skipped those candidates, and next tick will retry" >&2
  return "$exit_status"
}
trap report_on_hold_query_failures EXIT

# Concurrency caps, one per stage. The transient units ARE the ledger (see
# lib.sh's stage_unit_active()/stage_unit_count()): no PID files, no lease
# files, no stale-PID reaper — a unit's registration is released however its
# process dies, and `--collect` (every dispatch below) drops it from
# `systemctl --user list-units` output the instant it exits.
#
# Up to AGENT_TRIAGE_CAP triage issues per batch (default 8), configured in
# ~/.zenoforge/env. Keep the operator cap within host memory headroom.
TRIAGE_CAP="${AGENT_TRIAGE_CAP:-8}"
# Implement dispatch moved to mac-autopilot/scheduler.sh; the tick keeps no
# implement cap of its own (the scheduler's implement_cap plus its file-scope
# footprint mutex govern every lane, including pipeline-system).
# Releases are batches, so this cap counts deploy units, not tickets. The
# host capacity file is the single tuning source; default remains one deploy.
RELEASE_CAP="${AGENT_RELEASE_CAP:-1}"
# advisor=2: the wrapper units can prepare/poll two tickets independently,
# but every actual transport call takes the one web-session lease. Keep the
# cap for async bookkeeping; do not infer concurrent session control from it.
ADVISOR_CAP=2
# Every fresh advisor question uses one batch dialogue, including a one-ticket
# queue. Existing single jobs are polled separately; no fresh single fallback.
ADVISOR_BATCH_MIN=1
# recut=1: one parent-state mutation at a time. Its author's
# own caveat (run-recut.sh's header) is that it has been run for real exactly
# once and proven to refuse well, not yet proven to produce a dispatchable
# child — a low cap costs little while that's still true.
RECUT_CAP=1

# 2026-09-12 review, item 2: with a fixed cap per stage, one hung dispatched
# unit permanently consumes a slot and nothing notices — none of the three
# wrappers' own internal deadlines cover EVERY step (a wedged `git worktree
# add`, a `gh` call that hangs despite the proxy, ...), and even the steps
# that now have their own timeout/deadline (this same review added most of
# them) still leave the systemd unit itself with no outer backstop. Each
# limit below is the wrapper's own internal deadlines/timeouts summed
# worst-case, plus headroom for the untimed steps in between (worktree setup,
# pnpm install, git/gh calls) — so RuntimeMaxSec can never fire before an
# internal deadline already would produce a labeled issue and local health
# record; it only catches a hang no internal timeout covers.
#
# triage (run-triage.sh): one Codex call, timeout 45m. +15m headroom.
TRIAGE_RUNTIME_MAX_SEC=$((60 * 60))
# implement (run-implement.sh): implementation (120m) + one code review
# (30m, this review added its timeout) + one repair pass (30m) + one
# re-review (30m) + the CI poll deadline (DEADLINE_SECONDS, 90m) + the
# merge-lock wait (MERGE_LOCK_WAIT_SECONDS, 70m, this review's lib.sh fix) =
# 370m of accounted-for internal deadlines (the 60m merge-queue Postsubmit
# wait left this list with #4356's optimistic merge gate). +60m headroom for
# worktree setup, pnpm install, and the package test/typecheck loop, none of
# which carry their own timeout. Rounded up to 9h.
IMPLEMENT_RUNTIME_MAX_SEC=$((9 * 60 * 60))
# One concrete collision is enough to prioritize its owner when checks fail;
# stale pending PRs become recoverable after the bounded hold below.
BLOCKING_PR_CANDIDATE_THRESHOLD=1
# Failed PRs are recovered at the pressure threshold. Pending or unreadable
# PRs get one hour before owner recovery; operators can tune this bound.
BLOCKING_PR_STALE_SECONDS="${BLOCKING_PR_STALE_SECONDS:-3600}"
IMPLEMENT_PACKAGE_SCOPE_CAP="${IMPLEMENT_PACKAGE_SCOPE_CAP:-2}"
# release (run-release.sh): the Postsubmit wait (DEADLINE_SECONDS, 60m) + the
# build-run-discovery wait (5m) + the image-build completion wait (250m) =
# 315m of accounted-for internal deadlines. +60m headroom for the deploy
# phase itself (now-bounded ssh calls, docker compose, post-deploy-smoke.sh —
# none of these carry a deadline of their own, only a per-call hang bound
# from this review's ssh options). Rounded up to 7h.
#
# ponytail: a RuntimeMaxSec kill on triage/release (unlike implement) is not
# accounted for by state_bump_attempts at dispatch time the way implement's
# is (see the (c) loop below) — a killed triage/release run's own attempts
# bump never runs, so give-up-after-3 can't see it. Narrow, pre-existing gap
# (the same one a plain `systemctl stop` already had); upgrade if a
# RuntimeMaxSec kill on those two stages is ever observed live, not
# speculatively here.
RELEASE_RUNTIME_MAX_SEC=$((7 * 60 * 60))
# advisor (run-advisor.sh) is a detached web-advisor-provider job plus short wrapper work;
# keep its existing one-hour systemd backstop. Recut has one bounded Codex call.
ADVISOR_RUNTIME_MAX_SEC=$((60 * 60))
RECUT_RUNTIME_MAX_SEC=$((60 * 60))

# Every dispatch below shares this shape: a transient unit named
# zf-<stage>-<N>, env needed for `gh`/`git`/network to work under a
# systemd --user unit (see systemd/zenoforge-agent.service's own comment for why
# each of these is there — PATH, the proxy vars, and GH_TOKEN via
# EnvironmentFile), running that stage's wrapper against issue <N>.
# guarded_write is what makes AGENT_DRY_RUN=1 a safe way to exercise this
# scheduler's decisions end to end: under dry-run, dispatch itself is a
# no-op print, so nothing --collect'd ever actually runs.
# Any arguments after <stage> <n> are extra `systemd-run` options placed
# before the unit's command. Model identity comes only from lib.sh's
# persistent model policy; scheduler dispatch never injects model overrides.
#
# 2026-10-08 (issue 2695, run 3): Node 22's built-in fetch ignores the proxy
# vars every unit below imports unless NODE_USE_ENV_PROXY=1 is also set —
# an implement unit died polling raw.githubusercontent.com with
# ConnectTimeoutError while curl through the same proxy worked (run-release.sh
# hit the same wall first and documented it at its preflight). Default it
# once here, before any dispatch, so `-E NODE_USE_ENV_PROXY` below always has
# a value to import; NO_PROXY joins the same imports so loopback/private
# destinations (local test servers) stay direct once Node starts honoring the
# proxy env.
export NODE_USE_ENV_PROXY="${NODE_USE_ENV_PROXY:-1}"

# Consume only systemd's explicit MemoryMax OOM result. Other unit failures
# stay on their existing model-policy path and do not get a resource retry.
consume_unit_memory_oom() {
  local n="$1" stage="$2" state result prior_ooms current_cap retry_cap filter unit_name
  case "$stage" in implement|triage|recut) ;; *) return 2 ;; esac
  [ "${DRY_RUN:-0}" != 1 ] || return 1
  state="$(state_read "$n")" || return 2
  result="$(jq -r --arg stage "$stage" '.unit_results[$stage].result // empty' <<< "$state")" || return 2
  [ "$result" = oom-kill ] || return 1

  prior_ooms="$(jq -r --arg stage "$stage" '.unit_memory_ooms[$stage] // 0' <<< "$state")" || return 2
  unit_name="$(jq -r --arg stage "$stage" '.unit_results[$stage].unit // empty' <<< "$state")" || return 2
  unit_name="${unit_name:-${UNIT_PREFIX_TRANSIENT}-$stage-$n.service}"
  current_cap="${AGENT_UNIT_MEMORY_MAX:-4G}"
  [ "$prior_ooms" -le 0 ] || current_cap="${AGENT_UNIT_MEMORY_RETRY_MAX:-6G}"
  retry_cap="${AGENT_UNIT_MEMORY_RETRY_MAX:-6G}"
  record_env_fault env:unit-memory-cap infrastructure "$n" \
    "$unit_name Result=oom-kill; per-unit memory cap=$current_cap retry cap=$retry_cap" "" "" 0 || true
  record_run_decision "$n" wrapper \
    "$unit_name Result=oom-kill; killed by the per-unit memory cap ($current_cap). Capacity retry uses $retry_cap and does not consume a ticket attempt." 1 \
    || return 2

  filter=".unit_memory_ooms.$stage = ((.unit_memory_ooms.$stage // 0) + 1) | del(.unit_results.$stage) | if .model_policy.active.unit == \"$stage\" then del(.model_policy.active) else . end"
  if [ "$stage" = implement ]; then
    filter+=' | .attempts = (if (.attempts // 0) > 0 then .attempts - 1 else 0 end)'
    state_merge_attempt_transition "$n" "$filter" || return 2
  else
    state_merge "$n" "$filter" || return 2
  fi
}

# Recover stale policy markers before dispatch admission or attempt-cap checks.
# A unit result plus its saved model-policy outcome identify interruption vs
# an accounted code failure; missing evidence stays explicitly unknown.
recover_stale_policy_unit() {
  local n="$1" queue_label="$2" prior active active_unit active_step started result exit_status reason evidence refund_attempt=0 consume_status recorded_failure
  prior="$(state_read "$n")"
  active="$(jq -c '.model_policy.active // {}' <<< "$prior")"
  active_unit="$(jq -r '.unit // empty' <<< "$active")"
  [ -n "$active_unit" ] || return 1
  if stage_unit_active "$active_unit" "$n"; then return 2; fi
  case "$active_unit" in
    implement|triage|recut)
      if consume_unit_memory_oom "$n" "$active_unit"; then return 0; else
        consume_status=$?
        [ "$consume_status" -eq 1 ] || return "$consume_status"
      fi
      ;;
  esac
  active_step="$(jq -r '.step // empty' <<< "$active")"
  started="$(jq -r '.model_started // false' <<< "$active")"
  recorded_failure="$(jq -r --arg dispatched_at "$(jq -r '.dispatched_at // ""' <<< "$active")" '
    if $dispatched_at == "" then empty else
      [(.model_policy.failure // null), ((.model_policy.failures // [])[-1] // null)]
      | map(select(type == "object" and (.reason // "") != "" and (.recorded_at // "") >= $dispatched_at))
      | sort_by(.recorded_at // "") | last // empty | .reason // empty
    end
  ' <<< "$prior")"
  if [ -n "$recorded_failure" ]; then
    state_merge "$n" 'del(.model_policy.active)' || return 1
    echo "issue-pipeline: #$n $active_unit had a saved failure record after dispatch; preserved charged attempt and cleared stale active marker" >&2
    return 0
  fi
  result="$(jq -r --arg unit "$active_unit" '.unit_results[$unit].result // empty' <<< "$prior")"
  exit_status="$(jq -r --arg unit "$active_unit" '.unit_results[$unit].exit_status // empty' <<< "$prior")"
  # A previous boot's unit result cannot describe this unfinished dispatch.
  if [ -n "$(jq -r '.boot_id // empty' <<< "$active")" ] \
    && [ "$(jq -r '.boot_id' <<< "$active")" != "$(cat /proc/sys/kernel/random/boot_id)" ]; then
    result=signal
    exit_status=143
  fi
  if [ -n "$result" ]; then
    reason="Previous $active_unit unit ended with systemd Result=$result${exit_status:+, exit_status=$exit_status} before clearing its active marker; retrying the same policy step"
    evidence="unit=$active_unit; systemd_result=$result; exit_status=$exit_status; model_started=$started; step=$active_step; dispatch=$active"
  else
    reason="Previous $active_unit unit has no persisted systemd Result or terminal model-policy outcome; retrying the same policy step"
    evidence="unit=$active_unit; systemd_result=unavailable; model_started=$started; step=$active_step; dispatch=$active"
  fi
  # A killed or vanished unit is refunded. A unit that exited with an error
  # after the model started is charged: refunding it let issues 1365, 1799
  # and 1825 rerun 50 to 88 times in 72 hours with the attempt cap never met.
  if [ "$active_unit" = implement ] && ! { [ "$result" = exit-code ] && [ "$started" = true ] && [ "$exit_status" != 143 ]; }; then
    refund_attempt=1
  fi
  model_policy_record_failure "$n" "$active_step" "$active_unit" \
    "$reason" "$evidence" "$([ "$exit_status" = 143 ] && echo 143 || echo 124)" "$queue_label" "$active_unit" "$refund_attempt" || return 1
  return 0
}

# Summarize durable evidence when the wrapper, rather than the unit, reaches
# the attempt cap. Never infer a kill from a completed/missing unit result.
unit_attempt_cap_reason() {
  local n="$1" state record stage reason result exit_status unit_note
  state="$(state_read "$n")"
  record="$(jq -c '
    # Attempt failures are recorded on .model_policy.history[].failure; reading only the older fields
    # printed "no reason persisted" for issues 1992 and 2002 although history held one (2026-10-03).
    [(.model_policy.failure // null), ((.model_policy.failures // [])[-1] // null), (.model_policy.retry_note // null),
     ([(.model_policy.history // [])[] | .failure? | select(type == "object")] | last // null)]
    | map(select(type == "object" and (.reason // "") != ""))
    | sort_by(.recorded_at // "") | last // {}
  ' <<< "$state")"
  stage="$(jq -r '.stage // "unknown"' <<< "$record")"
  reason="$(jq -r '.reason // empty' <<< "$record")"
  result="$(jq -r '.unit_results.implement.result // empty' <<< "$state")"
  exit_status="$(jq -r '.unit_results.implement.exit_status // empty' <<< "$state")"
  if [ -n "$result" ]; then
    unit_note="systemd Result=$result${exit_status:+, exit_status=$exit_status}"
  else
    unit_note="no persisted systemd Result for the latest implement unit"
  fi
  if [ -n "$reason" ]; then
    printf 'latest policy record %s: %s; latest implement unit: %s' "$stage" "$reason" "$unit_note"
  else
    printf '%s; no model-policy attempt reason is persisted' "$unit_note"
  fi
}

# Count implement logs in the rolling 72-hour window, starting at the latest
# supervisor removal of on-hold or reopen of a concluded ticket, so a reviewed
# lift or a new lifecycle opens a fresh episode.
implement_runs_since_last_hold_lift() {
  local n="$1" lifted_at="" run_lines="" latest
  local -a find_args=(-maxdepth 1 -type f -name "implement-$n-*.log" -mmin -4320) run_logs=()
  IMPLEMENT_REPEAT_RUN_COUNT=0
  IMPLEMENT_REPEAT_RUN_EPISODE=""
  [ -n "${LOG_DIR:-}" ] && [ -d "$LOG_DIR" ] || return 0
  run_lines="$(find "$LOG_DIR" "${find_args[@]}" -printf '%T@ %f\n' 2>/dev/null | sort -n)" || return 1
  [ -n "$run_lines" ] || return 0
  lifted_at="$(gh api "repos/$REPO/issues/$n/timeline" --paginate \
    --jq '.[] | select(.event=="unlabeled" and (.label.name=="on-hold" or .label.name=="concluded")) | .created_at' 2>/dev/null)" || return 1
  lifted_at="$(sort <<< "$lifted_at" | tail -n1)"
  if [ -n "$lifted_at" ]; then
    run_lines="$(find "$LOG_DIR" "${find_args[@]}" -newermt "$lifted_at" \
      -printf '%T@ %f\n' 2>/dev/null | sort -n)" || return 1
  fi
  [ -n "$run_lines" ] || return 0
  # A run whose agent binary could not start (exit 127) never reached a model; it is an
  # environment fault, not an attempt. The 2026-10-05 codex outage pushed requeued tickets
  # over the cap with such runs (1425).
  local line kept=""
  while IFS= read -r line; do
    grep -q 'model_call_exit_status=127' "$LOG_DIR/${line#* }" 2>/dev/null && continue
    kept+="$line"$'\n'
  done <<< "$run_lines"
  run_lines="${kept%$'\n'}"
  run_lines="$(printf '%s\n' "$run_lines" | AGENT_HOME="$AGENT_HOME" node "$SCRIPT_DIR/night/attempt-terminal.mjs" charged-runs "$n")" || return 1
  [ -n "$run_lines" ] || return 0
  mapfile -t run_logs <<< "$run_lines"
  IMPLEMENT_REPEAT_RUN_COUNT="${#run_logs[@]}"
  latest="${run_logs[$(( ${#run_logs[@]} - 1 ))]}"
  IMPLEMENT_REPEAT_RUN_EPISODE="${latest#* }"
}

ensure_issue_roadmap_parent_for_dispatch() {
  local n="$1" stage="$2" issue_json="${3:-}"
  [[ "${ROADMAP_ORDER_ENABLED:-false}" == true ]] || return 0
  roadmap_stage_requires_parent "$stage" || return 0
  # Negative cache: a placement that failed is not retried for 30 min (a missing
  # 待归类 epic fails identically every tick; SRE book "Addressing Cascading
  # Failures": do not retry deterministic failures every cycle). Success clears it.
  local mark="${AGENT_HOME:-/nonexistent}/night/roadmap-placement-failed-$n"
  if [ -n "$(find "$mark" -mmin -30 2>/dev/null)" ]; then return 1; fi
  if ! roadmap_ensure_issue_parent "$n" "$stage" "$issue_json"; then
    echo "issue-pipeline: roadmap parent placement failed for #$n before $stage dispatch" >&2
    mkdir -p -- "${mark%/*}" 2>/dev/null && : > "$mark" 2>/dev/null
    return 1
  fi
  rm -f -- "$mark" 2>/dev/null
  return 0
}

dispatch() {
  local stage="$1" n="$2" runtime_max script memory_max oom_count consume_status claim_status claim_unit claim_key dispatch_status
  shift 2
  # Belt and braces with legs_executable_check() (lib.sh) at the top of the
  # tick: never hand systemd a script it cannot spawn -- that ends as a
  # 203/EXEC unit failure indistinguishable from a leg that ran and refused.
  script="$ZF_ENGINE_DIR/run-$stage.sh"
  if [ ! -x "$script" ]; then
    echo "issue-pipeline: leg $stage cannot execute ($script is not executable) -- not dispatching #$n; recorded as an environment fault, not a verdict" >&2
    record_env_fault "env:leg-not-executable:$stage" "$stage" "$n" "$script is not executable (git mode bit)"
    pipeline_claim_drop
    return 0
  fi
  case "$stage" in
    triage) runtime_max="$TRIAGE_RUNTIME_MAX_SEC" ;;
    implement) runtime_max="$IMPLEMENT_RUNTIME_MAX_SEC" ;;
    release) runtime_max="$RELEASE_RUNTIME_MAX_SEC" ;;
    advisor) runtime_max="$ADVISOR_RUNTIME_MAX_SEC" ;;
    recut) runtime_max="$RECUT_RUNTIME_MAX_SEC" ;;
  esac
  # 2026-09-26: an implement unit's headless E2E Chrome grew to 5 GB (unit
  # MemoryPeak 6.5 GB) and pushed the box below 1.6 GB MemAvailable. A cap
  # makes the OOM kill land inside that unit, not on the whole WSL box.
  # Release is exempt: an OOM kill mid-deploy would leave production half-rolled.
  local -a memory_args=() result_args=()
  case "$stage" in
    implement|triage|recut)
      if consume_unit_memory_oom "$n" "$stage"; then
        :
      else
        consume_status=$?
        [ "$consume_status" -eq 1 ] || { pipeline_claim_drop; return "$consume_status"; }
      fi
      oom_count="$(state_read "$n" | jq -r --arg stage "$stage" '.unit_memory_ooms[$stage] // 0')"
      memory_max="${AGENT_UNIT_MEMORY_MAX:-4G}"
      [ "$oom_count" -le 0 ] || memory_max="${AGENT_UNIT_MEMORY_RETRY_MAX:-6G}"
      memory_args=(-p "MemoryMax=$memory_max")
      result_args=(-p "ExecStopPost=$SCRIPT_DIR/record-unit-result.sh $stage $n")
      ;;
  esac
  # A launch error records a fault and stops the scheduler tick. Admission's
  # status 75 instead leaves the work queued without treating it as a fault.
  # No EnvironmentFile for the agent env file: every line in it is shell `export X=...`, which systemd rejects
  # and logs value-included into the user journal (25k lines on 2026-10-22, a GitHub token among them) while
  # loading nothing. Stages read credentials through with-credentials.sh, which sources the file as shell.
  if [[ "$stage" != release ]]; then
    claim_unit="${UNIT_PREFIX_TRANSIENT}-$stage-$n"
    claim_key="$(if [[ "$n" =~ ^[1-9][0-9]*$ ]]; then coord_issue_key "$n"; else coord_unit_key "$claim_unit"; fi)" || return 1
    if [[ "$PIPELINE_CLAIM_KEY" == "$claim_key" && "$PIPELINE_CLAIM_UNIT" == "$claim_unit" \
        && "$PIPELINE_CLAIM_STAGE" == "$stage" && -n "$PIPELINE_CLAIM_OWNER" ]]; then
      : # dispatch_policy_unit acquired before recording the attempt
    else
      if [[ -n "$PIPELINE_CLAIM_KEY" ]]; then
        echo "issue-pipeline: stale in-process claim before $stage dispatch; refusing #$n" >&2
        pipeline_claim_drop
        return 1
      fi
      if pipeline_claim_begin "$n" "$stage" "$claim_unit"; then
        :
      else
        claim_status=$?
        echo "issue-pipeline: $stage #$n claim unavailable status=$claim_status; leaving it queued" >&2
        return 0
      fi
    fi
    if ! coord_assert_owned "$PIPELINE_CLAIM_KEY" "$PIPELINE_CLAIM_OWNER" >/dev/null; then
      echo "issue-pipeline: $stage #$n claim lost before launch; leaving it queued" >&2
      pipeline_claim_drop
      return 0
    fi
  fi
  if guarded_write systemd-run --user --unit "${UNIT_PREFIX_TRANSIENT}-$stage-$n" --collect \
    -E PATH -E https_proxy -E HTTPS_PROXY -E http_proxy -E HTTP_PROXY -E no_proxy -E NO_PROXY -E NODE_USE_ENV_PROXY -E ZF_ROADMAP_TREE_CACHE_FILE \
    -p "RuntimeMaxSec=$runtime_max" \
    "${memory_args[@]}" "${result_args[@]}" \
    "$@" \
    "$ZF_ENGINE_DIR/run-$stage.sh" "$n"; then
    :
  else
    dispatch_status=$?
    if [ "$dispatch_status" -eq 75 ]; then
      echo "issue-pipeline: $stage #$n admission deferred; leaving it queued" >&2
      pipeline_claim_drop
      return 75
    fi
    echo "issue-pipeline: systemd-run dispatch failed for ${UNIT_PREFIX_TRANSIENT}-$stage-$n -- no unit was created; refusing to count #$n as dispatched" >&2
    record_env_fault "env:systemd-run-dispatch-failed:$stage" "$stage" "$n" "systemd-run --user --unit ${UNIT_PREFIX_TRANSIENT}-$stage-$n failed; see stderr above"
    pipeline_claim_drop
    return 1
  fi
  [[ "$stage" == release ]] || pipeline_claim_keep || return 1
  # Standing rule: a ticket's second implement dispatch wakes the
  # supervisor, and so does every later one. #1799 ran implement 84 times in
  # three days (recut reset its attempts) before anyone looked.
  if [ "$stage" = implement ]; then
    local prior_runs
    if implement_runs_since_last_hold_lift "$n"; then
      prior_runs="$IMPLEMENT_REPEAT_RUN_COUNT"
    else
      prior_runs="$(find "${LOG_DIR:-}" -maxdepth 1 -type f -name "implement-$n-*.log" -mmin -4320 2>/dev/null | wc -l)" || prior_runs=0
    fi
    if [ "$prior_runs" -ge 1 ]; then
      supervisor_inbox_append repeat-dispatch \
        "issue=#$n unit=implement run=$((prior_runs + 1)) in 72h; last: $(unit_attempt_cap_reason "$n" 2>/dev/null | cut -c1-200)" || true
    fi
  fi
}

dispatch_release_batch() {
  local anchor="$1" batch_sha="$2" script="$(zf_release_runner)"
  local -a runtime_env=()
  [ -z "${MAC_AUTOPILOT_RUNTIME_DIR:-}" ] || runtime_env=(-E "MAC_AUTOPILOT_RUNTIME_DIR=$MAC_AUTOPILOT_RUNTIME_DIR")
  if [ ! -x "$script" ]; then
    echo "issue-pipeline: release batch cannot execute ($script is not executable) -- not dispatching #$anchor" >&2
    record_env_fault "env:leg-not-executable:release-batch" release "$anchor" "$script is not executable (git mode bit)"
    return 0
  fi
  if guarded_write systemd-run --user --unit ${UNIT_PREFIX_TRANSIENT}-release-batch --collect \
    -E PATH -E https_proxy -E HTTPS_PROXY -E http_proxy -E HTTP_PROXY -E no_proxy -E NO_PROXY -E ALL_PROXY -E NODE_USE_ENV_PROXY \
    -E "ZF_ENGINE_DIR=$ZF_ENGINE_DIR" -E "ZF_REPO_DIR=$ZF_REPO_DIR" -E "ZF_CONFIG_ROOT=$ZF_CONFIG_ROOT" \
    -p "RuntimeMaxSec=$RELEASE_RUNTIME_MAX_SEC" \
    "${runtime_env[@]}" \
    "$script" "$anchor" "$batch_sha"; then
    release_batch_cadence_mark
    return 0
  else
    local launch_status=$?
    if [ "$launch_status" -eq 75 ]; then
      echo "issue-pipeline: release batch admission deferred; leaving #$anchor pending" >&2
      return 75
    fi
    echo "issue-pipeline: systemd-run dispatch failed for ${UNIT_PREFIX_TRANSIENT}-release-batch -- no unit was created; refusing batch anchored at #$anchor" >&2
    record_env_fault "env:systemd-run-dispatch-failed:release-batch" release "$anchor" "systemd-run --user --unit ${UNIT_PREFIX_TRANSIENT}-release-batch failed; see stderr above"
    return 1
  fi
}

# A fresh batch receives this tick's filtered issue snapshot; a poll-only
# batch keeps its persisted member list. Unit name still shares the advisor
# capacity ledger.
dispatch_advisor_batch() {
  local script="" poll_only="${1:-0}" n budget_result budget_state budget_calls budget_tokens claim_owner claim_unit claim_status
  local -a issue_ids=()
  if ! script="$(zf_advisor_batch_runner)"; then
    echo "issue-pipeline: advisor batch runner is invalid in advisor.json -- not dispatching" >&2
    record_env_fault "env:invalid-advisor-batch-runner" advisor-batch batch "advisor.json batchRunner must name an executable repository-relative script"
    return 0
  fi
  if [ "$poll_only" != "1" ]; then
    for n in $NEEDS_ADVISOR_IDS; do
      if hand_agent_issue_is_live_owned "$n"; then
        record_hand_owned_decision advisor "$n"
      else
        budget_result="$(issue_spend_budget_status "$n")" || return 1
        IFS=$'\t' read -r budget_state budget_calls budget_tokens <<< "$budget_result"
        if [ "$budget_state" = over ]; then
          route_issue_spend_budget "$n" "$budget_calls" "$budget_tokens" || return 1
        elif [ "$budget_state" = clear ]; then
          ensure_issue_roadmap_parent_for_dispatch "$n" needs-advisor || continue
          issue_ids+=("$n")
        else
          echo "issue-pipeline: #$n spend ledger unreadable; holding advisor dispatch" >&2
        fi
      fi
    done
    [ "${#issue_ids[@]}" -gt 0 ] || return 0
  fi
  agent_memory_floor_allows advisor || return 0
  if [ ! -x "$script" ]; then
    echo "issue-pipeline: batch advisor leg cannot execute ($script) -- not dispatching" >&2
    record_env_fault "env:leg-not-executable:advisor-batch" advisor-batch batch "$script is not executable (git mode bit)"
    return 0
  fi
  if [ "${#issue_ids[@]}" -gt 0 ]; then
    claim_unit="${UNIT_PREFIX_TRANSIENT}-advisor-batch"
    claim_owner="$(coord_new_owner)"
    if pipeline_batch_claim_acquire "$claim_owner" advisor-batch "$claim_unit" "${issue_ids[@]}"; then
      :
    else
      claim_status=$?
      echo "issue-pipeline: advisor batch claim unavailable status=$claim_status; leaving issues queued" >&2
      return 75
    fi
  fi
  if guarded_write systemd-run --user --unit ${UNIT_PREFIX_TRANSIENT}-advisor-batch --collect \
    -E PATH -E https_proxy -E HTTPS_PROXY -E http_proxy -E HTTP_PROXY -E no_proxy -E NO_PROXY -E NODE_USE_ENV_PROXY -E ZF_ROADMAP_TREE_CACHE_FILE \
    -E "ZF_ENGINE_DIR=$ZF_ENGINE_DIR" -E "ZF_REPO_DIR=$ZF_REPO_DIR" -E "ZF_CONFIG_ROOT=$ZF_CONFIG_ROOT" \
    -p "RuntimeMaxSec=$ADVISOR_RUNTIME_MAX_SEC" \
    "$script" --scheduled "${issue_ids[@]}"; then
    if [ "${#issue_ids[@]}" -gt 0 ]; then
      pipeline_batch_claim_keep "$claim_owner" "$claim_unit" "${issue_ids[@]}" || return $?
    fi
    return 0
  else
    local launch_status=$?
    if [ "${#issue_ids[@]}" -gt 0 ]; then
      pipeline_batch_claim_drop "$claim_owner" "${issue_ids[@]}"
    fi
    if [ "$launch_status" -eq 75 ]; then
      echo "issue-pipeline: advisor batch admission deferred; selected jobs remain pending" >&2
      return 0
    fi
    echo "issue-pipeline: systemd-run dispatch failed for ${UNIT_PREFIX_TRANSIENT}-advisor-batch" >&2
    record_env_fault "env:systemd-run-dispatch-failed:advisor-batch" advisor-batch batch "systemd-run --user --unit ${UNIT_PREFIX_TRANSIENT}-advisor-batch failed; see stderr above"
    return 1
  fi
}

# One transient unit carries the selected issue IDs; the batch wrapper owns
# one Codex call and isolates result application per issue.
dispatch_triage_batch() {
  local script="$ZF_ENGINE_DIR/run-triage-batch.sh" active_tmp="" issues_json="" n memory_max oom_count consume_status budget_result budget_state budget_calls budget_tokens claim_owner claim_unit claim_status
  local -a issue_ids=() memory_args=() result_args=()
  for n in "$@"; do
    [[ "$n" =~ ^[0-9]+$ ]] || continue
    budget_result="$(issue_spend_budget_status "$n")" || return 1
    IFS=$'\t' read -r budget_state budget_calls budget_tokens <<< "$budget_result"
    if [ "$budget_state" = over ]; then
      route_issue_spend_budget "$n" "$budget_calls" "$budget_tokens" || return 1
      continue
    fi
    [ "$budget_state" = clear ] || { echo "issue-pipeline: #$n spend ledger unreadable; holding triage dispatch" >&2; continue; }
    issue_ids+=("$n")
  done
  [ "${#issue_ids[@]}" -gt 0 ] || return 0
  if model_config_fault_blocked work "$(model_policy identity work)"; then
    echo "issue-pipeline: triage batch held by work-role model configuration fault" >&2
    return 0
  fi
  if [ ! -x "$script" ]; then
    echo "issue-pipeline: batch triage leg cannot execute ($script) -- not dispatching" >&2
    record_env_fault "env:leg-not-executable:triage-batch" triage-batch batch "$script is not executable (git mode bit)"
    return 0
  fi
  claim_unit="${UNIT_PREFIX_TRANSIENT}-triage-batch"
  claim_owner="$(coord_new_owner)"
  if pipeline_batch_claim_acquire "$claim_owner" triage-batch "$claim_unit" "${issue_ids[@]}"; then
    :
  else
    claim_status=$?
    echo "issue-pipeline: triage batch claim unavailable status=$claim_status; leaving issues queued" >&2
    return 75
  fi
  memory_max="${AGENT_UNIT_MEMORY_MAX:-4G}"
  for n in "${issue_ids[@]}"; do
    if consume_unit_memory_oom "$n" triage; then
      :
    else
      consume_status=$?
      [ "$consume_status" -eq 1 ] || { pipeline_batch_claim_drop "$claim_owner" "${issue_ids[@]}"; return "$consume_status"; }
    fi
    oom_count="$(state_read "$n" | jq -r '.unit_memory_ooms.triage // 0')"
    [ "$oom_count" -le 0 ] || memory_max="${AGENT_UNIT_MEMORY_RETRY_MAX:-6G}"
  done
  memory_args=(-p "MemoryMax=$memory_max")
  result_args=(-p "ExecStopPost=$SCRIPT_DIR/record-unit-result.sh triage-batch ${issue_ids[*]}")
  if [ "$DRY_RUN" != "1" ]; then
    mkdir -p "$AGENT_HOME"
    active_tmp="$AGENT_HOME/triage-batch-active-dispatch-$$.json"
    issues_json="$(printf '%s\n' "${issue_ids[@]}" | jq -Rsc 'split("\n") | map(select(test("^[0-9]+$")) | tonumber)')"
    if ! jq -n --argjson issues "$issues_json" '{issues:$issues}' > "$active_tmp" \
        || ! mv "$active_tmp" "$AGENT_HOME/triage-batch-active.json"; then
      rm -f -- "$active_tmp"
      pipeline_batch_claim_drop "$claim_owner" "${issue_ids[@]}"
      return 1
    fi
  fi
  if guarded_write systemd-run --user --unit ${UNIT_PREFIX_TRANSIENT}-triage-batch --collect \
    -E PATH -E https_proxy -E HTTPS_PROXY -E http_proxy -E HTTP_PROXY -E no_proxy -E NO_PROXY -E NODE_USE_ENV_PROXY -E ZF_ROADMAP_TREE_CACHE_FILE \
    -p "RuntimeMaxSec=$TRIAGE_RUNTIME_MAX_SEC" \
    "${memory_args[@]}" "${result_args[@]}" \
    "$script" --scheduled "${issue_ids[@]}"; then
    pipeline_batch_claim_keep "$claim_owner" "$claim_unit" "${issue_ids[@]}"
  else
    local launch_status=$?
    [ -z "$active_tmp" ] || rm -f "$AGENT_HOME/triage-batch-active.json"
    pipeline_batch_claim_drop "$claim_owner" "${issue_ids[@]}"
    if [ "$launch_status" -eq 75 ]; then
      echo "issue-pipeline: triage batch admission deferred; selected jobs remain pending" >&2
      return 75
    fi
    echo "issue-pipeline: systemd-run dispatch failed for ${UNIT_PREFIX_TRANSIENT}-triage-batch" >&2
    record_env_fault "env:systemd-run-dispatch-failed:triage-batch" triage-batch batch "systemd-run --user --unit ${UNIT_PREFIX_TRANSIENT}-triage-batch failed; see stderr above"
    return 1
  fi
}

# One persisted failure ladder for every issue work unit.
dispatch_policy_unit() {
  local unit="$1" n="$2" queue_label="$3" bump="${4:-0}"
  local prior step role identity provider active_patch dispatch_status backoff_remaining recovery_status skipped_patch budget_result budget_state budget_calls budget_tokens
  shift 3
  [ "$#" -eq 0 ] || shift
  budget_result="$(issue_spend_budget_status "$n")" || return 77
  IFS=$'\t' read -r budget_state budget_calls budget_tokens <<< "$budget_result"
  case "$budget_state" in
    over)
      # The budget route sends oversized tickets to recut; recut runs once per
      # parent, so it must not be held by the budget that routed it (1983, 1703).
      if [ "$unit" != recut ]; then
        route_issue_spend_budget "$n" "$budget_calls" "$budget_tokens" || return 1
        local budget_window_end
        budget_window_end="$(state_read "$n" | jq -r '.issue_spend_budget.window_end // empty')" || return 1
        [ -n "$budget_window_end" ] || return 1
        record_implement_decision "$n" skipped spend-budget \
          "24-hour spend window is active; issue held until $budget_window_end" "$budget_window_end" || return 1
        return 80 # Spend-budget skip; preserve 78 for model-policy transitions.
      fi
      ;;
    unknown)
      echo "issue-pipeline: #$n spend ledger unreadable; holding $unit dispatch" >&2
      return 77
      ;;
  esac
  if recover_stale_policy_unit "$n" "$queue_label"; then return 78; else
    recovery_status=$?
    case "$recovery_status" in
      1) ;;
      2) return 78 ;;
      *) return "$recovery_status" ;;
    esac
  fi
  if [ "$unit" = implement ]; then
    backoff_remaining="$(issue_model_failure_backoff_remaining "$n")"
    [ "$backoff_remaining" -gt 0 ] && return 76
    agent_implement_dispatch_resources_allow || return 75
  fi
  model_policy_begin_unit "$n" "$unit" "$queue_label" || return 1
  prior="$(state_read "$n")"
  step="$(jq -r --arg unit "$unit" 'if .model_policy.unit == $unit then .model_policy.step // empty else empty end' <<< "$prior")"
  step="${step:-$(model_policy initial-step)}"
  case "$step" in
    advisor)
      route_to_advisor "$n" "$queue_label" true || return 1
      return 78
      ;;
    production)
      if ! model_policy step-role production >/dev/null 2>&1; then
        skipped_patch="$(jq -nc '{step:"production",reason:"not present in the active model policy",recorded_at:(now|todate)}')"
        state_merge "$n" ".model_policy.step = \"conclude\" | .model_policy.skipped_steps = ((.model_policy.skipped_steps // []) + [$skipped_patch]) | .model_policy.failure.transition = \"conclude\" | .model_policy.failure.reason = (.model_policy.failure.reason // \"The legacy production step is not present in the active model policy\")" || return 1
        local terminal_reason
        terminal_reason="$(state_read "$n" | jq -r '.model_policy.failure.reason')"
        conclude_run "$n" not-completed "Configured model escalation exhausted: $terminal_reason" || return 1
        return 78
      fi
      ;;
    conclude)
      local terminal_reason
      terminal_reason="$(jq -r 'if .model_policy.failure.early_stop.reason == "same-failure" then
        "Stopped early after repeated same classified failure at \(.model_policy.failure.stage): \(.model_policy.failure.reason)"
      else .model_policy.failure.reason // "Configured model escalation exhausted" end' <<< "$prior")"
      if jq -e '.model_policy.failure.early_stop.reason == "same-failure"' <<< "$prior" >/dev/null; then
        terminal_reason="$terminal_reason. Both failures and diff summary are in model_policy.failure.early_stop."
      else
        terminal_reason="Configured model escalation exhausted: $terminal_reason"
      fi
      conclude_run "$n" not-completed "$terminal_reason" || return 1
      return 78
      ;;
  esac
  role="$(model_policy step-role "$step")" || return 76
  identity="$(model_policy dispatch-identity "$role")" || return 76
  provider="${identity%%:*}"
  [ "$provider" = codex ] || return 76
  if model_config_fault_blocked "$role" "$identity"; then
    echo "issue-pipeline: $unit held by $role/$identity model configuration fault" >&2
    return 77
  fi
  if ! codex_probe_ok; then
    record_env_fault env:codex-sandbox-probe "$unit" "$n" "Codex sandbox probe has not passed; model-policy dispatch held"
    return 77
  fi
  if ! codex_provider_recovery_probe_if_due "$identity"; then
    record_env_fault env:codex-provider-recovery-probe "$unit" "$n" "Codex provider recovery probe did not pass; model-policy dispatch held" "" "" 0
    return 77
  fi
  if codex_quota_exhausted "$identity"; then
    return 77
  fi
  if codex_model_capacity_held "$identity"; then
    echo "issue-pipeline: $role model capacity hold; $unit dispatch deferred before attempt accounting" >&2
    return 74
  fi
  if ! ensure_issue_roadmap_parent_for_dispatch "$n" "$queue_label"; then return 79; fi
  active_patch="$(jq -n --arg u "$unit" --arg q "$queue_label" --arg s "$step" --arg r "$role" --arg i "$identity" --arg boot "$(cat /proc/sys/kernel/random/boot_id)" \
    '{unit:$u,step:$s,role:$r,active:{unit:$u,queue_label:$q,step:$s,role:$r,identity:$i,boot_id:$boot,model_started:false,dispatched_at:(now|todate)}}')"
  if pipeline_claim_begin "$n" "$unit" "${UNIT_PREFIX_TRANSIENT}-$unit-$n"; then
    :
  else
    dispatch_status=$?
    echo "issue-pipeline: #$n $unit claim unavailable status=$dispatch_status; no attempt charged" >&2
    return 78
  fi
  if ! coord_assert_owned "$PIPELINE_CLAIM_KEY" "$PIPELINE_CLAIM_OWNER" >/dev/null; then
    pipeline_claim_drop
    echo "issue-pipeline: #$n $unit claim unknown before attempt accounting; no attempt charged" >&2
    return 78
  fi
  state_merge "$n" ".model_policy = (.model_policy // {}) + $active_patch" || { pipeline_claim_drop; return 1; }
  if [ "$bump" != 0 ]; then state_bump_attempts "$n" || { pipeline_claim_drop; return 1; }; fi
  echo "issue-pipeline: #$n dispatching $unit with model policy step=$step role=$role" >&2
  if dispatch "$unit" "$n" "$@"; then
    return 0
  else
    dispatch_status=$?
    if [ "$dispatch_status" -eq 75 ] && [ "$bump" != 0 ]; then
      state_merge_attempt_transition "$n" 'del(.model_policy.active) | .attempts = (if (.attempts // 0) > 0 then .attempts - 1 else 0 end)' || return 1
    else
      state_merge "$n" 'del(.model_policy.active)' || true
    fi
    return "$dispatch_status"
  fi
}


# Hand agents query the GitNexus index, but only triage and advisor runs
# refresh it: with triage paused it went 46 commits stale (2026-10-09).
# gitnexus_refresh_index_once owns the lock, throttle and memory floor.
dispatch_gitnexus_refresh() {
  gitnexus_index_matches_origin_main "$REPO_DIR" && return 0
  systemctl --user is-active --quiet ${UNIT_PREFIX_TRANSIENT}-gitnexus-refresh && return 0
  local dispatch_status
  if guarded_write systemd-run --user --unit ${UNIT_PREFIX_TRANSIENT}-gitnexus-refresh --collect \
    -E PATH -E https_proxy -E HTTPS_PROXY -E http_proxy -E HTTP_PROXY -E no_proxy -E NO_PROXY -E NODE_USE_ENV_PROXY \
    -p RuntimeMaxSec=2700 \
    bash -c 'source "$2/lib.sh" || exit 1
      gitnexus_refresh_index_once "$1" "$(git -C "$1" rev-parse origin/main)" gitnexus_index_matches_origin_main
      rc=$?; printf "%s\n" "$GITNEXUS_REFRESH_OUTPUT" | tail -20; exit "$rc"' _ "$REPO_DIR" "$ZF_ENGINE_DIR"; then
    :
  else
    dispatch_status=$?
    if [ "$dispatch_status" -eq 75 ]; then
      echo "issue-pipeline: gitnexus refresh admission deferred; leaving it pending" >&2
      return 0
    fi
    echo "issue-pipeline: systemd-run dispatch failed for ${UNIT_PREFIX_TRANSIENT}-gitnexus-refresh -- no unit was created" >&2
    record_env_fault "env:systemd-run-dispatch-failed:gitnexus-refresh" "gitnexus-refresh" "refresh" "systemd-run --user --unit ${UNIT_PREFIX_TRANSIENT}-gitnexus-refresh failed; see stderr above"
    return 1
  fi
}

# Defect 6, 2026-09-13 (#1094): the read side of the ask/read loop (see
# notify.sh's Defect 6 comment for the ask side, run-triage.sh's needs-info
# branch for where a thread id first gets recorded). Pull open needs-info
# threads and still-open threads with an applied default; post each new
# genuine human reply as an issue comment.
#
# The hard boundary: this function may persist thread metadata and processed
# message ids, and may post a comment, but never edits an issue label or calls
# `gh issue edit`, `gh pr merge`, or another GitHub mutation. The existing
# needs-info recovery runs after stage admission and sees the relayed comment
# in the same tick; resulting triage work waits until the next tick. lib.test.sh
# checks this function for those verbs.
#
# Correlates by threadId only, never by parsing "#$n" out of a subject line
# — subjects get edited, forwarded and re-prefixed by mail clients, so a
# state-recorded threadId (Gmail's own opaque id) is the only correlation
# that can't drift. Dedup is by Gmail message id, recorded into each
# issue's own state file (`.processed_gmail_message_ids`) — examined once,
# recorded once, regardless of whether it turned out to be a genuine reply,
# our own outgoing mail, or a message from outside the trust boundary — so
# a reply can never be posted twice across a five-minute tick and this
# function never re-parses the same message on the next one either. A
# fetch failure (network hiccup, a dead credential — see
# check_gmail_credential()) leaves that message id UNrecorded on purpose,
# so it's retried next tick instead of being silently dropped.
read_needs_info_email_replies() {
  local issue_rows issue_row n state needs_info applied_thread thread_id message_ids processed mid raw parsed \
    from_email auto_submitted issue_marker body login trimmed comment_body question_thread sent_at \
    first_mid first_resource first_sent_at_ms first_raw first_parsed first_body default_option metadata_patch

  issue_rows="$(gh issue list --repo "$REPO" --limit 1000 --state open --json number,labels)" || return 0
  while IFS= read -r issue_row; do
    n="$(jq -r '.number // empty' <<< "$issue_row")"
    [[ "$n" =~ ^[0-9]+$ ]] || continue
    state="$(state_read "$n")"
    needs_info="$(jq -r 'any(.labels[]?; .name == "needs-info")' <<< "$issue_row")"
    applied_thread="$(jq -r '.needs_info_default_applied.thread_id // empty' <<< "$state")"
    thread_id="$(jq -r '.needs_info_thread_id // empty' <<< "$state")"
    [ -n "$thread_id" ] || continue
    [ "$needs_info" = true ] || [ "$applied_thread" = "$thread_id" ] || continue
    if [ "$applied_thread" != "$thread_id" ] && is_on_hold "$n"; then continue; fi

    message_ids="$(fetch_gmail_thread_message_ids "$thread_id")"
    [ -n "$message_ids" ] || continue

    question_thread="$(jq -r '.needs_info_question_thread_id // empty' <<< "$state")"
    sent_at="$(jq -r '.needs_info_question_sent_at // empty' <<< "$state")"
    first_mid=""
    first_resource=""
    first_sent_at_ms=""
    first_raw=""
    first_parsed=""
    if [ "$question_thread" != "$thread_id" ] || ! [[ "$sent_at" =~ ^[0-9]+$ ]]; then
      first_mid="${message_ids%%$'\n'*}"
      first_resource="$(fetch_gmail_message_resource_raw "$first_mid")"
      first_raw="$(jq -r '.raw // empty' <<< "$first_resource")"
      if [ -n "$first_raw" ]; then
        first_parsed="$(parse_gmail_message_raw "$first_raw")"
        first_sent_at_ms="$(jq -r '.internal_date_ms // empty' <<< "$first_resource")"
        if [[ "$first_sent_at_ms" =~ ^[0-9]+$ ]]; then
          sent_at=$((first_sent_at_ms / 1000))
        else
          # Gmail normally supplies internalDate; retain RFC822 Date fallback
          # for messages imported without that field.
          sent_at="$(jq -r '.date_epoch // empty' <<< "$first_parsed")"
        fi
        if [[ "$sent_at" =~ ^[0-9]+$ ]]; then
          first_body="$(jq -r '.body // empty' <<< "$first_parsed")"
          default_option="$(needs_info_default_option "$first_body" || true)"
          metadata_patch="$(jq -cn --arg thread "$thread_id" --arg option "$default_option" --argjson sent_at "$sent_at" \
            '{needs_info_question_thread_id:$thread,needs_info_question_sent_at:$sent_at,needs_info_default_option:(if $option == "" then null else $option end)}')"
          state_merge "$n" ". + $metadata_patch" || echo "issue-pipeline: could not record needs-info question date for #$n" >&2
        fi
      fi
    fi

    processed="$(state_read "$n" | jq -c '.processed_gmail_message_ids // []')"
    for mid in $message_ids; do
      gmail_message_id_processed "$mid" "$processed" && continue

      if [ "$mid" = "$first_mid" ] && [ -n "$first_raw" ]; then
        raw="$first_raw"
        parsed="$first_parsed"
      else
        raw="$(fetch_gmail_message_raw "$mid")"
        [ -n "$raw" ] || continue
        parsed="$(parse_gmail_message_raw "$raw")"
        [ -n "$parsed" ] || continue
      fi

      from_email="$(echo "$parsed" | jq -r '.from // empty')"
      auto_submitted="$(echo "$parsed" | jq -r '.auto_submitted // empty')"
      issue_marker="$(echo "$parsed" | jq -r '.issue_marker // empty')"
      body="$(echo "$parsed" | jq -r '.body // empty')"

      if gmail_message_is_human_reply "$from_email" "$auto_submitted" "$issue_marker"; then
        login="$(resolve_login_for_email "$from_email")"
        trimmed="$(trim_quoted_reply "$body")"
        comment_body="> *This reply arrived by email and was relayed here automatically by the the product agent pipeline.* Original sender: @$login. $EMAIL_COMMENT_MARKER

$trimmed"
        guarded_write gh issue comment "$n" --repo "$REPO" --body "$comment_body"
      fi

      processed="$(echo "$processed" | jq -c --arg m "$mid" '. + [$m]')"
    done

    state_merge "$n" ". + $(jq -n --argjson p "$processed" '{processed_gmail_message_ids: $p}')"
  done < <(jq -c '.[]' <<< "$issue_rows")
}

reconcile_needs_info_issues() {
  local n issue_json lane_match_status last_comment_body
  for n in $(gh issue list --repo "$REPO" --limit 1000 --label needs-info --state open --json number -q '.[].number'); do
    is_on_hold "$n" && continue
    if ! issue_json="$(gh issue view "$n" --repo "$REPO" --json number,labels,comments)"; then
      echo "issue-pipeline: could not read #$n labels/comments; leaving needs-info unchanged" >&2
      continue
    fi
    lane_match_status=0
    pipeline_system_issue_matches "$issue_json" || lane_match_status=$?
    case "$lane_match_status" in
      0)
        if stage_unit_active triage "$n" || stage_unit_active advisor "$n"; then continue; fi
        if ! prepare_pipeline_system_issue "$n" "$issue_json" needs-info; then
          echo "issue-pipeline: failed to clean pipeline-system needs-info issue #$n" >&2
        fi
        continue
        ;;
      1) ;;
      *) echo "issue-pipeline: cannot classify #$n; leaving needs-info unchanged" >&2; continue ;;
    esac
    last_comment_body="$(jq -r '.comments[-1].body // ""' <<< "$issue_json")"
    if ! needs_info_timeout_step "$n" "$issue_json" "$(date +%s)"; then
      echo "issue-pipeline: needs-info timeout step failed for #$n; leaving current stage unchanged" >&2
      continue
    fi
    case "$NEEDS_INFO_TIMEOUT_ACTION" in
      advisor-routed|default-applied) continue ;;
    esac
    if [ -n "$last_comment_body" ] && ! comment_is_bot "$last_comment_body"; then
      needs_info_resume_answered_issue "$n" "$issue_json"
    fi
  done
}

run_post_dispatch_maintenance() {
  # Findings here stay queued for the next tick, after triage can run first.
  # zenoforge-agent.service stops the tick at TimeoutStartSec=20min. Tick
  # 20261008T035843Z was killed inside needs-info-unlabeled once maintenance
  # ran last. A sweep starts only while its measured worst case (~210 s) still
  # fits; a deferred sweep is where the next tick resumes, so the cycle keeps
  # its order across ticks and no tail sweep is skipped every tick.
  local stop_at=$(( ${TICK_UNIT_TIMEOUT_SECONDS:-1200} - ${MAINTENANCE_STEP_RESERVE_SECONDS:-240} ))
  local resume_file="$AGENT_HOME/night/maintenance-resume" resume="" step i start=0
  local -a steps=(checks-blocked-sweep hold-sweep supervisor-hold-sweep hand-completion-events founder-outcome-recovery needs-info-email
    needs-info-recovery needs-info-blocker-roots needs-info-unlabeled needs-info-loop main-red-bisect batch-state)
  IFS= read -r resume 2>/dev/null < "$resume_file" || resume=""
  for i in "${!steps[@]}"; do
    [ "${steps[$i]}" != "$resume" ] || start="$i"
  done
  for ((i = 0; i < ${#steps[@]}; i++)); do
    step="${steps[$(((start + i) % ${#steps[@]}))]}"
    if [ "$SECONDS" -ge "$stop_at" ]; then
      [ "$DRY_RUN" = "1" ] || printf '%s\n' "$step" > "$resume_file" || true
      echo "issue-pipeline: maintenance deferred tick=$IMPLEMENT_TICK_ID from=$step elapsed_sec=$SECONDS stop_at=$stop_at" >&2
      return 0
    fi
    profile_mark "$step"
    case "$step" in
      checks-blocked-sweep)
        if [ "$DRY_RUN" != "1" ] && ! checks_blocked_sweep; then
          echo "issue-pipeline: checks-blocked owner sweep failed; parked tickets remain for the next tick" >&2
        fi
        ;;
      hold-sweep)
        if [ "$DRY_RUN" != "1" ] && ! hold_sweep; then
          echo "issue-pipeline: hold expiry sweep failed; leaving failed holds untouched for next tick" >&2
        fi
        ;;
      supervisor-hold-sweep)
        if [ "$DRY_RUN" != "1" ] && ! supervisor_hold_sweep; then
          echo "issue-pipeline: supervisor hold sweep failed; ownerless tickets remain for next tick" >&2
        fi
        ;;
      hand-completion-events)
        if [ "$DRY_RUN" != "1" ] && ! hand_completion_events_run_once "$REPO_DIR"; then
          echo "issue-pipeline: hand completion recovery deferred until next tick" >&2
        fi
        ;;
      founder-outcome-recovery)
        if reconcile_maintainer_outcomes; then
          flush_maintainer_outcome_digest || true
        else
          echo "issue-pipeline: maintainer outcome recovery failed; digest send deferred" >&2
        fi
        ;;
      needs-info-email)
        if ! read_needs_info_email_replies; then
          echo "issue-pipeline: needs-info email poll failed; replies will be retried next tick" >&2
        fi
        ;;
      needs-info-recovery)
        if ! sweep_reopened_issues; then
          echo "issue-pipeline: reopened-issue recovery failed; issues remain queued for the next tick" >&2
        fi
        ;;
      needs-info-blocker-roots)
        if ! sweep_blocking_issue_roots; then
          echo "issue-pipeline: blocker-root recovery failed; current roots unavailable" >&2
        fi
        ;;
      needs-info-unlabeled)
        if ! sweep_unlabeled_issues; then
          echo "issue-pipeline: unlabeled-issue recovery failed; issues remain queued for the next tick" >&2
        fi
        ;;
      needs-info-loop)
        if ! reconcile_needs_info_issues; then
          echo "issue-pipeline: needs-info recovery failed; answers will be retried next tick" >&2
        fi
        ;;
      main-red-bisect)
        # One bounded step of main-red recovery (#4356): flaky rerun,
        # midpoint probes, culprit attribution, revert PR, ticket reopen.
        # Session writes are pipeline state, so this never runs under DRY_RUN.
        # A valid manual PAUSE still permits red discovery at the tick gate,
        # but stops this recovery step (including the delegated release slice).
        if [ "$DRY_RUN" != "1" ] && ! manual_pause_is_valid && ! main_red_bisect_sweep; then
          echo "issue-pipeline: main-red bisect step failed; the red session retries next tick" >&2
        fi
        ;;
      batch-state)
        # 批次 STATE（#4363）→ critical-path / legacy 标签的周期同步；自带每小时节流。
        if [ "$DRY_RUN" != "1" ] && ! sweep_batch_state; then
          echo "issue-pipeline: batch STATE sweep failed; label sync retries next tick" >&2
        fi
        ;;
    esac
  done
  [ "$DRY_RUN" = "1" ] || rm -f -- "$resume_file"
}

# Kill switch: concurrency 1 on the tick's own DECISION section, not on the
# dispatched work anymore. This flock still has to wrap every candidate
# selection below — the caps and the per-issue is-active checks all read
# live `gh`/`systemctl` state and must not race a second tick's own reads of
# the same state — but now that dispatch is fire-and-forget, holding it no
# longer holds up a multi-hour wrapper run; a held lock means another tick's
# own (fast) decision-making is still in progress.
# A slice inherits the parent's lock; manual stage runs acquire their own.
if [ -z "${ZF_PIPELINE_SLICE_TICK:-}" ]; then exec 9>"$LOCK_FILE"; fi
# The release train's delegated release slice waits for a gap between ticks: zenoforge-agent.service holds this
# lock tick after tick, so a bare -n attempt exited 0 silently and the train logged "delegated" (2026-10-22).
# The wait must span a whole tick (250-490 s, gaps 0-64 s on 10-22): a waiter blocked in flock wins the lock
# when the tick ends, but 240 s missed the boundary whenever the tick had longer to run, e.g. 16:05Z.
if [ "${ZF_RELEASE_TRAIN_DELEGATE:-0}" = 1 ]; then
  flock -w "${ZF_RELEASE_DELEGATE_LOCK_WAIT_SECONDS:-600}" 9 || {
    echo "issue-pipeline: release delegate found the pipeline lock busy; the next train retries" >&2
    exit 75
  }
elif ! flock -n 9; then
  [ "${EVENT_REFILL:-0}" = 0 ] || exit 75
  exit 0
fi

# --- tick timing and dispatch metrics ---------------------------------------
# Keep timing markers across early exits and attach candidate/dispatch counts
# to the current tick's local journal.
IMPLEMENT_TICK_ID="${ZF_PIPELINE_SLICE_TICK:-$(date -u +%Y%m%dT%H%M%SZ)}"
TICK_PROFILE_SECTION=preflight
TICK_PROFILE_SINCE=$SECONDS
ZF_CALL_PROFILE_SECTION=preflight
ZF_CALL_PROFILE_STAGE="$PIPELINE_STAGE"
export ZF_CALL_PROFILE_SECTION ZF_CALL_PROFILE_STAGE
profile_mark() {
  local next="$1"
  echo "issue-pipeline: timing tick=$IMPLEMENT_TICK_ID section=$TICK_PROFILE_SECTION elapsed_sec=$((SECONDS - TICK_PROFILE_SINCE))" >&2
  TICK_PROFILE_SECTION="$next"
  ZF_CALL_PROFILE_SECTION="$next"
  export ZF_CALL_PROFILE_SECTION
  TICK_PROFILE_SINCE=$SECONDS
}
profile_finish() {
  echo "issue-pipeline: timing tick=$IMPLEMENT_TICK_ID section=$TICK_PROFILE_SECTION elapsed_sec=$((SECONDS - TICK_PROFILE_SINCE))" >&2
  echo "issue-pipeline: label-reads tick=$IMPLEMENT_TICK_ID batch_lists=$ISSUE_LABEL_BULK_QUERY_COUNT point_views=$ISSUE_LABEL_POINT_QUERY_COUNT" >&2
}
IMPLEMENT_CANDIDATE_COUNT=0
IMPLEMENT_SLOTS_AT_START=0
IMPLEMENT_DISPATCH_COUNT=0
IMPLEMENT_EVALUATED_COUNT=0
IMPLEMENT_METRICS_READY=0
IMPLEMENT_BUDGET_EXHAUSTED=0
IMPLEMENT_BUDGET_UNPROCESSED_COUNT=0
IMPLEMENT_TOP_REASON=""
IMPLEMENT_TOP_OBJECT=""
IMPLEMENT_TOP_OBJECT_COUNT=0
declare -A IMPLEMENT_GATE_COUNTS=()
declare -A IMPLEMENT_GATE_OBJECT_COUNTS=()
declare -A HAND_OWNED_DECISIONS_RECORDED=()

record_implement_decision() {
  local n="$1" outcome="$2" gate="$3" reason="$4" object="$5"
  local object_key gate_count object_count
  if [ "${ROADMAP_TREE_STALE:-0}" = 1 ]; then
    reason="$reason; roadmap_snapshot=stale age_seconds=$ROADMAP_SNAPSHOT_AGE_SECONDS ttl_seconds=${ZF_ROADMAP_SNAPSHOT_TTL_SECONDS:-7200}"
  fi
  # Per-ticket state/metrics writes must leave time for the summary. Keep
  # deferred decisions in the journal and counts; never refresh old state.
  if [ "$outcome" = dispatched ] || (( SECONDS < ${IMPLEMENT_DECISION_WRITE_DEADLINE_SECONDS:-2147483647} )); then
    if [ "$outcome" = skipped ] && [ -n "${IMPLEMENT_DECISION_BATCH_FILE:-}" ]; then
      printf '%s\0' "$n" "$IMPLEMENT_TICK_ID" "$outcome" "$gate" "$reason" "$object" "$EPOCHREALTIME" >> "$IMPLEMENT_DECISION_BATCH_FILE"
      printf 'issue-pipeline: implement-decision tick=%s issue=#%s outcome=%s gate=%s object=%s persistence=batch-pending reason=%s\n' \
        "$IMPLEMENT_TICK_ID" "$n" "$outcome" "$gate" "$object" "$reason" >&2
    else
      record_implement_tick_decision "$n" "$IMPLEMENT_TICK_ID" "$outcome" "$gate" "$reason" "$object"
      if ! efficiency_metrics_record_implement_decision "$n" "$IMPLEMENT_TICK_ID" "$outcome" "$gate" "$reason" "$object"; then
      echo "issue-pipeline: efficiency metrics append failed for #$n gate=$gate" >&2
      fi
    fi
  else
    printf 'issue-pipeline: implement-decision tick=%s issue=#%s outcome=%s gate=%s object=%s persistence=deferred reason=%s\n' \
      "$IMPLEMENT_TICK_ID" "$n" "$outcome" "$gate" "$object" "$reason" >&2
  fi
  [ "$outcome" = "dispatched" ] && return 0
  gate_count=${IMPLEMENT_GATE_COUNTS[$gate]:-0}
  gate_count=$((gate_count + 1))
  IMPLEMENT_GATE_COUNTS[$gate]="$gate_count"
  object_key="$gate"$'\034'"$object"
  object_count=${IMPLEMENT_GATE_OBJECT_COUNTS[$object_key]:-0}
  object_count=$((object_count + 1))
  IMPLEMENT_GATE_OBJECT_COUNTS[$object_key]="$object_count"
  if [ "$object_count" -gt "$IMPLEMENT_TOP_OBJECT_COUNT" ]; then
    IMPLEMENT_TOP_REASON="$reason"
    IMPLEMENT_TOP_OBJECT="$object"
    IMPLEMENT_TOP_OBJECT_COUNT="$object_count"
  fi
}





# A mode-level choice has no single issue state to attach to. Keep it in the
# tick journal with the same outcome/gate/reason/object vocabulary as
# record_implement_decision(), so a skipped batch is an auditable decision,
# not an empty branch.
record_advisor_decision() {
  local outcome="$1" gate="$2" reason="$3" issue_ids="$4" object n
  object="${issue_ids//$'\n'/,}"
  for n in $issue_ids; do
    [ -n "$n" ] || continue
    record_advisor_tick_decision "$n" "$IMPLEMENT_TICK_ID" "$outcome" "$gate" "$reason" "$object" || return 1
  done
}

record_hand_owned_decision() {
  local stage="$1" n="$2" reason='live hand-agent PID and start identity own this issue' key="$1:$2"
  [ -z "${HAND_OWNED_DECISIONS_RECORDED[$key]:-}" ] || return 0
  case "$stage" in
    triage)
      record_triage_tick_decision "$n" "$IMPLEMENT_TICK_ID" skipped hand-owned "$reason" hand-agent || return 1
      ;;
    advisor)
      record_advisor_decision skipped hand-owned "$reason" "$n" || return 1
      ;;
  esac
  HAND_OWNED_DECISIONS_RECORDED[$key]=1
}



prioritize_advisor_blockers() {
  local ids="$1" now="${2:-$(date +%s)}" issue state count index=0
  {
    while IFS= read -r issue; do
      [[ "$issue" =~ ^[0-9]+$ ]] || continue
      state="$(state_read "$issue")"
      count="$(jq -r --argjson now "$now" '
        .implement_blocking_pr as $b
        | if ($b.recorded_at | type) == "number" and ($b.count | type) == "number"
          and $now >= $b.recorded_at and ($now - $b.recorded_at) <= 900
          then $b.count else 0 end
      ' <<< "$state" 2>/dev/null || echo 0)"
      [[ "$count" =~ ^[0-9]+$ ]] || count=0
      printf '%09d\t%09d\t%s\n' "$count" "$index" "$issue"
      index=$((index + 1))
    done <<< "$ids"
  } | sort -t $'\t' -k1,1nr -k2,2n | cut -f3
}




# Defect 7, 2026-09-13: keep mail credential status current even when dispatch
# is paused or off. This single status probe measured 27ms in the dry-run profile.
if [ -z "${ZF_PIPELINE_SLICE_TICK:-}" ]; then check_gmail_credential; fi

# PAUSE is a manual operator stop. Require complete metadata; empty or invalid
# markers are ignored so an automatic model error can never freeze all stages.
# The release train alone may continue its delegated release slice under PAUSE.
if [ -e "$PAUSE_FILE" ]; then
  if manual_pause_is_valid; then
    if ! main_red_paused_discovery; then
      echo "issue-pipeline: main-red discovery during PAUSE failed; it will retry next tick" >&2
    fi
    if [ "$PIPELINE_STAGE" != release ] || [ "${ZF_RELEASE_TRAIN_DELEGATE:-0}" != 1 ]; then
      exit 0
    fi
  else
    echo "issue-pipeline: ignoring invalid PAUSE marker; manual stop requires nonempty JSON metadata" >&2
  fi
fi

# Kill switch: gh variable AGENT_PIPELINE. off|triage|implement|release, each
# mode enabling the previous ones. Unset/unreadable defaults to off.
#
# 2026-09-12 bug: only "off" and "triage" (and "!= release") were ever
# checked against MODE, so a typo, trailing whitespace from `gh variable
# get`, or any other leftover value fell through into the implement
# (auto-merge) branch below instead of stopping. This is the kill switch the
# maintainer reaches for from a phone under pressure — it must fail closed on
# anything it doesn't recognize, validated the same explicit-allowlist way
# AGENT_PHASE already is in run-triage.sh.
MODE="$(gh variable get AGENT_PIPELINE --repo "$REPO" 2>/dev/null || echo off)"
MODE="$(echo "$MODE" | tr -d '[:space:]')"
case "$MODE" in
  off|triage) ;;
  # The scheduler owns implement and release; the retired values behave as triage.
  implement|release) MODE=triage ;;
  *) MODE=off ;;
esac
# The maintainer's standing authorization (2026-10-22) ships migrations and fleet rolls automatically.
# While the autopilot owns implementation (AGENT_PIPELINE=triage), its release train delegates those
# releases to this release slice, so the one release path (run-release.sh) keeps running.
if [ "$MODE" = triage ] && [ "$PIPELINE_STAGE" = release ] && [ "${ZF_RELEASE_TRAIN_DELEGATE:-0}" = 1 ]; then
  MODE=release
fi
echo "issue-pipeline: AGENT_PIPELINE=$MODE" >&2
[ "$MODE" = "off" ] && { echo "issue-pipeline: off, exiting without touching anything" >&2; exit 0; }
# Live AGENT_PHASE read for section (c)'s dispatch-time gate recomputation
# below (2026-09-12 review, item 1) — read_agent_phase() (lib.sh) is the
# exact same fail-closed read run-triage.sh uses for its own per-run PHASE,
# so the two can never disagree on the fallback.
PHASE="$(read_agent_phase)"

# Every issue unit resolves its provider and model from the persistent policy;
# operators cannot switch launchers with per-stage environment overrides.
echo "issue-pipeline: implement model policy loaded" >&2

# The scheduler itself relabels to needs-advisor in section (c) below -- heal
# the labels here too, not only inside the wrappers (lib.sh
# ensure_state_labels(): the 2026-09-15 zf-triage-1203 death).
if [ "$PIPELINE_STAGE" = fastlane ]; then
ensure_state_labels

# Systemic environmental faults (lib.sh, "systemic environmental faults"):
# first the cheapest outage check there is -- can each leg's wrapper even be
# spawned (zf-advisor-1131, 203/EXEC) -- then open a quarantine for any
# signature that turned systemic and probe/repair/canary-lift the open ones.
# Runs before any dispatch decision so every stage_dispatch_allowed() call
# below reads this tick's reconciled state.
legs_executable_check
reconcile_quarantines
fi

if [ "$PIPELINE_STAGE" = fastlane ] || [ "$PIPELINE_STAGE" = release ]; then
ZF_GIT_FETCH_TRANSIENT_RETRIES=1 git_fetch_bounded "$REPO_DIR" main
fi
if [ "$PIPELINE_STAGE" = fastlane ]; then profile_mark fastlane; fi

pipeline_system_factory_infra_paths_valid() {
  jq -e '
    type == "array" and length > 0 and all(.[];
      type == "string" and (
        test("^\\.github/workflows/(build|sync)-cihost-[A-Za-z0-9._-]+\\.yml$") or
        test("^\\.github/workflows/pr-contract-checks\\.yml$") or
        test("^scripts/(build|sync)-cihost-[A-Za-z0-9._-]+\\.(sh|py)$") or
        test("^scripts/verify-nexus-image-digest\\.sh$") or
        test("^scripts/test_[A-Za-z0-9_-]+_contract\\.(py|sh|mjs)$")
      )
    )
  ' <<< "$1" >/dev/null 2>&1
}

pipeline_system_external_pr_check_state() {
  local current_pr="$1"
  current_pr="$(pr_latest_check_rows "$current_pr" 2>/dev/null)" || { echo "unknown"; return 0; }
  jq -r '
    if type != "object" or (.statusCheckRollup | type) != "array" or (.statusCheckRollup | length) == 0 then "unknown"
    else
      [.statusCheckRollup[] | if .__typename == "CheckRun" then
        if .status != "COMPLETED" then "pending"
        elif .conclusion == "SUCCESS" then "success"
        else "red" end
      elif .__typename == "StatusContext" then
        if .state == "SUCCESS" then "success"
        elif .state == "PENDING" or .state == "EXPECTED" then "pending"
        else "red" end
      else "unknown" end] as $checks
      | if any($checks[]; . == "red") then "red"
        elif any($checks[]; . == "unknown") then "unknown"
        elif any($checks[]; . == "pending") then "pending"
        elif any($checks[]; . == "success") then "green"
        else "unknown" end
    end
  ' <<< "$current_pr"
}

pipeline_system_external_pr_to_product() {
  local n="$1" issue_json="$2" pr_number="$3"
  echo "issue-pipeline: external PR #$pr_number for #$n changes product paths; returning issue to product lane" >&2
  pipeline_system_return_to_product "$n" || return 2
  if jq -e 'any(.labels[]?; .name == "on-hold")' <<< "$issue_json" >/dev/null 2>&1; then
    state_requeue "$n" release-hold product-path || return 2
  else
    state_requeue "$n" "" product-path || return 2
  fi
}

pipeline_system_hand_external_pr_conclusion() {
  local n="$1" report="$2" issue_json="$3" default_branch pr_number pr_json pr_state paths_json checks_state merge_sha head_sha merge_status=0
  local -a pr_refs=()
  mapfile -t pr_refs < <(
    {
      grep -Eio "https?://github\.com/$INFRA/pull/[1-9][0-9]*" "$report" 2>/dev/null \
        | grep -Eo '[0-9]+$' || true
      grep -Eio "$INFRA[[:space:]]+PR[[:space:]]*#?[1-9][0-9]*" "$report" 2>/dev/null \
        | grep -Eo '[0-9]+$' || true
    } | sort -un
  )
  ((${#pr_refs[@]} == 0)) && return 1
  ((${#pr_refs[@]} == 1)) || return 2
  pr_number="${pr_refs[0]}"
  default_branch="$(gh repo view "$INFRA" --json defaultBranchRef --jq '.defaultBranchRef.name')" || return 2
  [[ "$default_branch" =~ ^[A-Za-z0-9._/-]+$ ]] || return 2
  pr_json="$(gh pr view "$pr_number" --repo "$INFRA" \
    --json number,state,baseRefName,headRefName,headRefOid,mergeable,mergeStateStatus,isDraft,mergedAt,mergeCommit,body,files,changedFiles,statusCheckRollup)" || return 2
  if ! jq -e --arg pr_number "$pr_number" --arg issue "$n" --arg base "$default_branch" --arg slug "$REPO" '
    . as $pr_json |
    type == "object" and (.number | tostring) == $pr_number and .baseRefName == $base and
    (.headRefName | type == "string" and test("^agent/issue-" + $issue + "($|[-/])")) and
    ((.body // "") | test("(?i)(^|[^[:alnum:]_])" + ($slug | gsub("[.]"; "\\.")) + "#" + $issue + "([^[:alnum:]_]|$)")) and
    .isDraft == false and ((.state == "OPEN") or (.state == "MERGED")) and
    (.headRefOid | type == "string" and test("^[[:xdigit:]]{40,64}$")) and
    (.changedFiles | type == "number" and . > 0) and
    ($pr_json.files | type == "array" and length == $pr_json.changedFiles and all(.[]; (.path | type == "string" and length > 0)))
  ' <<< "$pr_json" >/dev/null 2>&1; then
    return 2
  fi
  paths_json="$(jq -c '[.files[].path]' <<< "$pr_json")" || return 2
  if ! pipeline_system_factory_infra_paths_valid "$paths_json"; then
    pipeline_system_external_pr_to_product "$n" "$issue_json" "$pr_number" || return 2
    return 0
  fi
  head_sha="$(jq -r '.headRefOid' <<< "$pr_json")"
  checks_state="$(pipeline_system_external_pr_check_state "$pr_json")" || return 2
  case "$checks_state" in
    green) ;;
    pending) echo "issue-pipeline: external factory PR #$pr_number for #$n checks pending; leaving hold for next tick" >&2; return 0 ;;
    red) echo "issue-pipeline: external factory PR #$pr_number for #$n has red checks; dispatching hand repair" >&2; return 3 ;;
    *) echo "issue-pipeline: external factory PR #$pr_number for #$n checks unreadable; leaving it open" >&2; return 2 ;;
  esac
  pr_state="$(jq -r '.state' <<< "$pr_json")"
  if [[ "$pr_state" == OPEN ]]; then
    if ! jq -e '.mergeable == "MERGEABLE" and .mergeStateStatus == "CLEAN"' <<< "$pr_json" >/dev/null 2>&1; then
      echo "issue-pipeline: external factory PR #$pr_number for #$n is not cleanly mergeable; dispatching hand repair" >&2
      return 3
    fi
    gh pr merge "$pr_number" --repo "$INFRA" --squash --delete-branch \
      --match-head-commit "$head_sha" || merge_status=$?
    pr_json="$(gh pr view "$pr_number" --repo "$INFRA" \
      --json number,state,baseRefName,headRefName,headRefOid,mergeable,mergeStateStatus,isDraft,mergedAt,mergeCommit,body,files,changedFiles,statusCheckRollup)" || return 2
    if [[ "$(jq -r '.state // empty' <<< "$pr_json")" != MERGED ]]; then
      echo "issue-pipeline: external factory PR #$pr_number for #$n merge not confirmed (status=$merge_status)" >&2
      return 2
    fi
    checks_state="$(pipeline_system_external_pr_check_state "$pr_json")" || return 2
    [[ "$checks_state" == green ]] || return 2
    jq -e --arg issue "$n" --arg base "$default_branch" --arg pr "$pr_number" --arg slug "$REPO" '
      (.number | tostring) == $pr and .baseRefName == $base and
      (.headRefName | test("^agent/issue-" + $issue + "($|[-/])")) and
      ((.body // "") | test("(?i)(^|[^[:alnum:]_])" + ($slug | gsub("[.]"; "\\.")) + "#" + $issue + "([^[:alnum:]_]|$)")) and
      (.mergedAt | type == "string" and length > 0) and
      (.changedFiles | type == "number" and . > 0) and
      (.files | type == "array") and (.files | length) == .changedFiles and
      (.files | all(.[]; (.path | type == "string" and length > 0)))
    ' <<< "$pr_json" >/dev/null 2>&1 || return 2
    paths_json="$(jq -c '[.files[].path]' <<< "$pr_json")" || return 2
    if ! pipeline_system_factory_infra_paths_valid "$paths_json"; then
      pipeline_system_external_pr_to_product "$n" "$issue_json" "$pr_number" || return 2
      return 0
    fi
    jq -e --arg head "$head_sha" '.headRefOid == $head' <<< "$pr_json" >/dev/null 2>&1 || return 2
  fi
  merge_sha="$(jq -r '.mergeCommit.oid // empty' <<< "$pr_json")"
  [[ "$merge_sha" =~ ^[[:xdigit:]]{40,64}$ ]] || return 2
  pipeline_system_finish_external_landing "$REPO_DIR" "$n" "$pr_number" "$merge_sha" || return 2
  echo "issue-pipeline: #$n closed from green factory PR $INFRA#$pr_number at $merge_sha" >&2
  return 0
}

pipeline_system_hand_report_conclusion() {
  local n="$1" issue_json="$2" report status evidence_line evidence_candidate report_sha_scan report_sha_match report_sha_candidate report_sha report_sha_index report_candidate_sha report_commit_message resolved_sha close_sha candidate candidate_sha candidate_close_sha last_main_report_sha last_main_sha_linked_elsewhere=0 external_status=0
  local -a report_sha_candidates=() report_sha_lines=() issue_linked_main_candidates=()
  local issue_status=0 inbox_key="hand-done-no-diff-close issue=$1" note
  # STATUS: DONE is the terminal claim. Do not make its prose a closed
  # vocabulary: collect reported Git IDs, then require a verified origin/main
  # commit and an independently verified issue-linked ancestor before closure.
  local report_sha_pattern='(^|[^[:xdigit:]])([[:xdigit:]]{7,64})([^[:xdigit:]]|$)'
  pipeline_system_issue_matches "$issue_json" || issue_status=$?
  case "$issue_status" in
    0) ;;
    1) return 1 ;;
    *) return 2 ;;
  esac

  report="${NIGHT:-${AGENT_HOME:-$HOME/.zenoforge}/night}/hand-$n.report"
  [[ -r "$report" ]] || return 1
  status="$(pipeline_system_owner_report_status "$report" 2>/dev/null)" || return 1
  case "$status" in 'STATUS: DONE'|'STATUS: DONE '*) ;; *) return 1 ;; esac
  pipeline_system_hand_external_pr_conclusion "$n" "$report" "$issue_json" || external_status=$?
  case "$external_status" in
    0) return 0 ;;
    1) ;;
    2) echo "issue-pipeline: #$n external hand PR evidence is unreadable; leaving hold" >&2; return 2 ;;
    3) return 1 ;;
    *) return 2 ;;
  esac
  evidence_line=""
  report_sha=""
  while IFS= read -r evidence_candidate || [[ -n "${evidence_candidate:-}" ]]; do
    report_sha_scan="$evidence_candidate"
    while [[ "$report_sha_scan" =~ $report_sha_pattern ]]; do
      report_sha_match="${BASH_REMATCH[0]}"
      report_sha_candidate="${BASH_REMATCH[2],,}"
      report_sha_candidates+=("$report_sha_candidate")
      report_sha_lines+=("$evidence_candidate")
      report_sha_scan="${report_sha_scan#*"$report_sha_match"}"
    done
  done < "$report"
  if ! ZF_GIT_FETCH_TRANSIENT_RETRIES=1 git_fetch_bounded "$REPO_DIR" main; then
    note="pipeline-system DONE no-diff report for #$n could not refresh origin/main; report=$report; supervisor must verify evidence before closure"
    supervisor_inbox_append_once "$inbox_key" "$note" || return 2
    echo "issue-pipeline: #$n terminal hand report routed to supervisor; bounded origin/main refresh failed" >&2
    return 0
  fi

  while IFS= read -r candidate; do
    issue_linked_main_candidates+=("$candidate")
  done < <(git -C "$REPO_DIR" log origin/main --format='%H' --extended-regexp --regexp-ignore-case \
    --grep="(^|[^[:alnum:]_])Refs:[[:space:]]*#$n([^[:digit:]]|$)" \
    --grep="(^|[^[:alnum:]_])Refs[[:space:]]+#$n([^[:digit:]]|$)" \
    --grep="(^|[^[:alnum:]_])fix\\(#$n\\)([^[:digit:]]|$)" \
    --grep="(^|[^[:alnum:]_])issue[[:space:]]+#?$n([^[:digit:]]|$)" --max-count=20 2>/dev/null || true)

  resolved_sha=""
  close_sha=""
  last_main_report_sha=""
  for report_sha_index in "${!report_sha_candidates[@]}"; do
    report_sha="${report_sha_candidates[$report_sha_index]}"
    report_candidate_sha="$(git -C "$REPO_DIR" rev-parse --verify "$report_sha^{commit}" 2>/dev/null)" || continue
    git -C "$REPO_DIR" merge-base --is-ancestor "$report_candidate_sha" origin/main 2>/dev/null || continue
    last_main_report_sha="$report_candidate_sha"
    last_main_sha_linked_elsewhere=0
    if ! report_commit_message="$(git -C "$REPO_DIR" show -s --format=%B "$report_candidate_sha" 2>/dev/null)"; then
      continue
    fi
    if grep -Eiq '(^|[^[:alnum:]_])(#|issue[[:space:]]+)[1-9][0-9]*([^[:alnum:]_]|$)' <<< "$report_commit_message" \
      && ! pipeline_system_close_comment_valid "$REPO_DIR" "$n" "结案：hand report reported origin/main SHA $report_candidate_sha"; then
      last_main_sha_linked_elsewhere=1
      continue
    fi

    candidate_close_sha=""
    for candidate in "${issue_linked_main_candidates[@]}"; do
      [[ "$candidate" =~ ^[[:xdigit:]]{40,64}$ ]] || continue
      candidate_sha="$(git -C "$REPO_DIR" rev-parse --verify "$candidate^{commit}" 2>/dev/null)" || continue
      # Each report SHA must include an issue-linked close commit before it can
      # replace an earlier candidate that already had both proofs.
      git -C "$REPO_DIR" merge-base --is-ancestor "$candidate_sha" "$report_candidate_sha" 2>/dev/null || continue
      note="结案：hand report verified no change; already on origin/main at $report_candidate_sha; issue-linked close commit $candidate_sha"
      if pipeline_system_close_comment_valid "$REPO_DIR" "$n" "$note"; then
        candidate_close_sha="$candidate_sha"
        break
      fi
    done
    if [[ -n "$candidate_close_sha" ]]; then
      resolved_sha="$report_candidate_sha"
      close_sha="$candidate_close_sha"
      evidence_line="${report_sha_lines[$report_sha_index]}"
    fi
  done

  if [[ -z "$close_sha" ]]; then
    if [[ -z "$last_main_report_sha" ]]; then
      note="pipeline-system DONE no-diff report for #$n has no verifiable origin/main SHA; report=$report; supervisor must verify evidence before closure"
      echo "issue-pipeline: #$n terminal hand report routed to supervisor; origin/main SHA unavailable" >&2
    elif (( last_main_sha_linked_elsewhere )); then
      note="pipeline-system DONE report for #$n cites origin/main SHA $last_main_report_sha linked to another issue; report=$report; supervisor must verify this ticket's evidence before closure"
      echo "issue-pipeline: #$n reported SHA is linked to another issue; routed to supervisor" >&2
    else
      note="pipeline-system DONE report for #$n verifies origin/main SHA $last_main_report_sha, but no issue-linked close commit is at or before that SHA; report=$report"
      echo "issue-pipeline: #$n report SHA predates its issue-linked close commit or lacks one; routed to supervisor" >&2
    fi
    supervisor_inbox_append_once "$inbox_key" "$note" || return 2
    return 0
  fi

  state_merge "$n" ".pipeline_system.enabled = true | .pipeline_system.commit_sha = \"$close_sha\"" || return 2
  note="Already on origin/main at $resolved_sha per $report; $evidence_line; close evidence commit $close_sha is issue-linked on origin/main."
  conclude_run "$n" pipeline-system "$note" || return 2
  echo "issue-pipeline: #$n closed from verified no-diff hand report at $resolved_sha" >&2
}

route_pipeline_fastlane_issue() {
  local n="$1" issue_json="$2" reason="$3" owner_status=0 report_status=0 issue_context open_prs claim_key claim_owner claim_status active_stage runtime_dir live_status
  pipeline_system_hand_report_conclusion "$n" "$issue_json" || report_status=$?
  case "$report_status" in
    0) return 0 ;;
    1) ;;
    *) echo "issue-pipeline: cannot consume completed hand report for #$n; left for next tick" >&2; return 1 ;;
  esac
  if ! jq -e 'type == "object" and (.labels | type == "array") and all(.labels[]; type == "object" and (.name | type == "string"))' \
    <<< "$issue_json" >/dev/null 2>&1; then
    echo "issue-pipeline: fastlane #$n labels unreadable; skipped" >&2
    return 1
  fi
  if jq -e 'any(.labels[]; .name == "on-hold")' <<< "$issue_json" >/dev/null 2>&1; then
    echo "issue-pipeline: fastlane #$n is on-hold; skipped" >&2
    return 0
  fi
  if hand_agent_issue_is_live_owned "$n"; then
    echo "issue-pipeline: fastlane #$n already has a live hand owner; skipped" >&2
    return 0
  fi
  ensure_issue_roadmap_parent_for_dispatch "$n" needs-triage "$issue_json" || return 1
  if supervisor_hold_owner_state "$n"; then
    case "$SUPERVISOR_HOLD_OWNER_STATE" in
      queued|running|blocked|worktree-live)
        echo "issue-pipeline: fastlane #$n already has owner: $SUPERVISOR_HOLD_OWNER_DETAIL" >&2
        return 0
        ;;
    esac
  else
    owner_status=$?
    if (( owner_status != 1 )); then
      echo "issue-pipeline: fastlane #$n owner state unreadable; skipped" >&2
      return 1
    fi
  fi
  # The feeder and scheduler share this ticket claim. Check GitHub and the
  # local runner immediately before acquiring it; the claim closes the race
  # between this snapshot and another local dispatcher.
  if ! open_prs="$(gh pr list --repo "$REPO" --state open --search "Refs #$n" --limit 1 --json number 2>/dev/null)" \
      || ! jq -e 'type == "array"' <<<"$open_prs" >/dev/null 2>&1; then
    echo "issue-pipeline: fastlane #$n open-PR census unavailable; skipped" >&2
    return 1
  fi
  if jq -e 'length > 0' <<<"$open_prs" >/dev/null 2>&1; then
    echo "issue-pipeline: fastlane #$n already has an open PR; skipped" >&2
    return 0
  fi
  for active_stage in triage implement advisor recut; do
    if stage_unit_active "$active_stage" "$n"; then
      echo "issue-pipeline: fastlane #$n already has active $active_stage work; skipped" >&2
      return 0
    fi
  done
  runtime_dir="${MAC_AUTOPILOT_RUNTIME_DIR:-$REPO_DIR/.scratch-supervisor/autopi}"
  if coord_issue_live_worker "$n" "$runtime_dir"; then
    echo "issue-pipeline: fastlane #$n already has a live scheduler worker; skipped" >&2
    return 0
  else
    live_status=$?
    if (( live_status != 1 )); then
      echo "issue-pipeline: fastlane #$n live-worker census unknown; skipped" >&2
      return 1
    fi
  fi
  claim_key="$(coord_issue_key "$n")" || return 1
  claim_owner="$(coord_new_owner)"
  if coord_acquire "$claim_key" "$claim_owner" feeder "$n" "fastlane-$n" fastlane; then
    :
  else
    claim_status=$?
    echo "issue-pipeline: fastlane #$n atomic claim unavailable status=$claim_status; skipped" >&2
    return 1
  fi
  if coord_issue_live_worker "$n" "$runtime_dir"; then
    coord_release "$claim_key" "$claim_owner" >/dev/null 2>&1 || :
    echo "issue-pipeline: fastlane #$n worker became live during claim; skipped" >&2
    return 1
  else
    live_status=$?
    if (( live_status != 1 )); then
      coord_release "$claim_key" "$claim_owner" >/dev/null 2>&1 || :
      echo "issue-pipeline: fastlane #$n live-worker census unknown after claim; skipped" >&2
      return 1
    fi
  fi
  if ! coord_assert_owned "$claim_key" "$claim_owner" >/dev/null; then
    coord_release "$claim_key" "$claim_owner" >/dev/null 2>&1 || :
    echo "issue-pipeline: fastlane #$n claim unknown before requeue; skipped" >&2
    return 1
  fi
  echo "issue-pipeline: claim=owned issue=#$n lane=fastlane" >&2
  # Path-only non-product tickets need the scheduler's lane label as well as
  # the ready state; the scheduler owns their dispatch and landing.
  issue_context="$(jq -r '(.title // "") + "\n" + (.body // "") + "\n" + ([.comments[]?.body // ""] | join("\n"))' <<< "$issue_json")" \
    || { coord_release "$claim_key" "$claim_owner" >/dev/null 2>&1 || :; return 1; }
  if ! issue_body_mentions_product_scope "$issue_context"; then
    if ! guarded_write gh issue edit "$n" --repo "$REPO" --add-label pipeline-system; then
      coord_release "$claim_key" "$claim_owner" >/dev/null 2>&1 || :
      return 1
    fi
  fi
  if ! coord_assert_owned "$claim_key" "$claim_owner" >/dev/null; then
    coord_release "$claim_key" "$claim_owner" >/dev/null 2>&1 || :
    echo "issue-pipeline: fastlane #$n claim lost before requeue; skipped" >&2
    return 1
  fi
  if ! scheduler_requeue_issue "$n" "$reason" "$issue_json"; then
    coord_release "$claim_key" "$claim_owner" >/dev/null 2>&1 || :
    return 1
  fi
  if ! coord_release "$claim_key" "$claim_owner" >/dev/null; then
    echo "issue-pipeline: fastlane #$n requeued but claim release failed; lease will expire" >&2
    return 1
  fi
}

fastlane_snapshot_candidates() {
  python3 -c '
import json, pathlib, sys
night = pathlib.Path(sys.argv[1])
rows = []
for issue in json.load(sys.stdin):
    summary = issue.get("subIssuesSummary") or {}
    if summary.get("total", 0) > summary.get("completed", 0):
        continue
    if any(b.get("state", "").lower() == "open" for b in (issue.get("blockedBy") or {}).get("nodes", [])):
        continue
    if any(label.get("name") == "on-hold" for label in issue.get("labels", [])):
        try:
            statuses = [s for s in (night / ("hand-" + str(issue["number"]) + ".report")).read_text().splitlines() if s.startswith("STATUS: ")]
        except OSError:
            statuses = []
        if not statuses or not (statuses[-1] == "STATUS: DONE" or statuses[-1].startswith("STATUS: DONE ")):
            continue
    rows.append(issue)
print(json.dumps(rows, ensure_ascii=False))
' "${NIGHT:-$AGENT_HOME/night}" <<< "$1"
}

# Scan position is an admission hint, never gate evidence. Builtins retain it
# even if timeout kills a rich read; the next tick starts at the following leaf.
fastlane_scan_order() {
  local lane="$1" ids="$2" cursor='' n before='' after='' found=0
  if [ -f "$NIGHT/fastlane-$lane.cursor" ]; then
    IFS= read -r cursor < "$NIGHT/fastlane-$lane.cursor" || true
  fi
  for n in $ids; do
    [ "$n" != "$cursor" ] || found=1
    if [ "$found" = 1 ]; then after+="$n "; else before+="$n "; fi
  done
  printf '%s\n' "$after$before"
}

route_nonproduct_path_issue_rows() {
  local issue_rows="$1" issue_json issue_context n lane_status parent_status reason parent_reason
  while IFS= read -r issue_json; do
    n="$(jq -r '.number // empty' <<< "$issue_json")"
    [[ "$n" =~ ^[1-9][0-9]*$ ]] || continue
    lane_status=0
    pipeline_system_issue_matches "$issue_json" || lane_status=$?
    [ "$lane_status" -eq 1 ] || continue
    parent_status=0
    issue_is_parent_tracker "$issue_json" || parent_status=$?
    if ((parent_status == 0)); then
      echo "issue-pipeline: path-only #$n is a parent tracker; leaving it for children" >&2
      continue
    elif ((parent_status != 1)); then
      echo "issue-pipeline: path-only #$n parent state unreadable; leaving it for next tick" >&2
      continue
    fi
    parent_status=0
    parent_reason="$(issue_intake_parent_reason "$n" "$issue_json")" || parent_status=$?
    if ((parent_status == 0)); then
      echo "issue-pipeline: path-only #$n is a parent tracker ($parent_reason); leaving it for children" >&2
      continue
    elif ((parent_status != 1)); then
      echo "issue-pipeline: path-only #$n parent state unreadable; leaving it for next tick" >&2
      continue
    fi
    reason="non-product paths in #$n bypass product queue"
    issue_context="$(jq -r '(.body // "") + "\n" + ([.comments[]?.body // ""] | join("\n"))' <<< "$issue_json")"
    issue_body_is_direct_main_lane "$issue_context" || continue
    route_pipeline_fastlane_issue "$n" "$issue_json" "$reason" \
      || echo "issue-pipeline: non-product path ticket #$n remains for next tick" >&2
  done < <(jq -c '.[] | select((.state | ascii_downcase) == "open")' <<< "$issue_rows")
}

fastlane_read_path_contexts() {
  local rows n context lane_labels ids scan_index=0 cursor_lane="${2:-paths}"
  local -a scan_order=()
  lane_labels="${PIPELINE_SYSTEM_LABELS_JSON:-$(pipeline_system_issue_labels_json)}" || return 1
  rows="$(fastlane_snapshot_candidates "$1")" || return 1
  ids="$(jq -r --argjson lane_labels "$lane_labels" '
    .[] | select(any(.labels[]?; .name as $name | ($lane_labels | index($name)) != null) | not) | .number
  ' <<< "$rows")"
  ids="$(fastlane_scan_order "$cursor_lane" "$ids")"
  read -ra scan_order <<< "$ids"
  mkdir -p "$NIGHT"
  for n in $ids; do
    [[ "$n" =~ ^[1-9][0-9]*$ ]] || continue
    gh_tick_attempt_timeout_sec >/dev/null || break
    scan_index=$(( (scan_index + 1) % ${#scan_order[@]} ))
    printf '%s\n' "${scan_order[$scan_index]}" > "$NIGHT/fastlane-$cursor_lane.cursor"
    context="$(gh issue view "$n" --repo "$REPO" --json number,title,body,comments,labels,state,blockedBy,subIssues,subIssuesSummary)" || continue
    # Establish an owner before reading the next leaf; a slow later read must
    # not consume the slice before already-read candidates can progress.
    route_nonproduct_path_issue_rows "[$context]"
  done
}

route_nonproduct_path_candidates() {
  local state_label issue_rows all_rows='[]'
  if [ "${ROADMAP_ORDER_ENABLED:-false}" = true ]; then
    [ "${ROADMAP_TREE_READY:-0}" = 1 ] || return 0
    for state_label in needs-triage ready-for-agent; do
      gh_tick_attempt_timeout_sec >/dev/null || return 0
      if ! issue_rows="$(gh issue list --repo "$REPO" --limit 1000 --label "$state_label" --state open \
          --json number,title,body,labels,state,blockedBy,subIssuesSummary 2>/dev/null)" \
        || ! jq -e 'type == "array"' <<< "$issue_rows" >/dev/null 2>&1; then
        echo "issue-pipeline: cannot scan $state_label for roadmap-ordered fastlane tickets" >&2
        return 0
      fi
      all_rows="$(printf '%s\n' "$all_rows" "$issue_rows" | jq -sc 'if length == 2 then add | unique_by(.number) else error("invalid issue snapshots") end')" || return 0
    done
    issue_rows="$(roadmap_order_candidate_json "$ROADMAP_TREE_JSON" "$all_rows")" || {
      echo "issue-pipeline: cannot order non-product fastlane tickets by roadmap" >&2
      return 0
    }
    fastlane_read_path_contexts "$issue_rows" "paths-$state_label"
    return
  fi
  for state_label in needs-triage ready-for-agent; do
    gh_tick_attempt_timeout_sec >/dev/null || return 0
    if ! issue_rows="$(gh issue list --repo "$REPO" --limit 1000 --label "$state_label" --state open \
        --json number,title,body,labels,state,blockedBy,subIssuesSummary 2>/dev/null)" \
      || ! jq -e 'type == "array"' <<< "$issue_rows" >/dev/null 2>&1; then
      echo "issue-pipeline: cannot scan $state_label for non-product path tickets" >&2
      continue
    fi
    issue_rows="$(jq -c --arg label "$state_label" \
      '[.[] | select(any(.labels[]?; .name == $label))] | unique_by(.number)' <<< "$issue_rows")" || continue
    fastlane_read_path_contexts "$issue_rows" "paths-$state_label"
  done
}

reconcile_pipeline_system_delivery() {
  local n state pipeline_sha awaiting_sync awaiting_legacy awaiting
  if ! awaiting_sync="$(gh issue list --repo "$REPO" --state all --label awaiting-pipeline-sync \
    --limit 1000 --json number -q '.[].number')" \
    || ! awaiting_legacy="$(gh issue list --repo "$REPO" --state all --label awaiting-pipeline-health \
      --limit 1000 --json number -q '.[].number')"; then
    echo "issue-pipeline: pipeline delivery label query failed; leaving tickets open" >&2
    return 0
  fi
  awaiting="$(printf '%s\n%s\n' "$awaiting_sync" "$awaiting_legacy" | sort -u)"
  while IFS= read -r n; do
    [ -n "$n" ] || continue
    state="$(state_read "$n")"
    pipeline_sha="$(jq -r '.pipeline_system.commit_sha // empty' <<< "$state")"
    [[ "$pipeline_sha" =~ ^[0-9a-f]{40,64}$ ]] || continue
    if ! git -C "$REPO_DIR" merge-base --is-ancestor "$pipeline_sha" HEAD; then
      continue
    fi
    conclude_run "$n" pipeline-system \
      "Commit $pipeline_sha is in the live pipeline checkout." \
      || echo "issue-pipeline: #$n stays open; direct-main commit is not yet recorded live" >&2
  done <<< "$awaiting"
}

if [ "$PIPELINE_STAGE" = fastlane ]; then
  # Closure must precede the roadmap path scan.
  reconcile_pipeline_system_delivery
  route_nonproduct_path_candidates
  profile_finish
  exit 0
fi

# (b) One triage dialogue handles needs-triage issues first, then unmeasured
# ready-for-agent issues. Production bugs keep first rank; founder-test beats
# ordinary features, including priority:top. The batch STATE's delay-cost bands
# (#4363) put critical-path ahead of features and legacy last. Cap leftovers stay queued.
run_intake_dispatch() {
if [ "$PIPELINE_STAGE" = triage ]; then
profile_mark triage
TRIAGE_RETRY_NOW="$(date +%s)"
triage_slots="$(cap_slots_remaining "$TRIAGE_CAP" "$(stage_unit_count triage)")"
declare -a TRIAGE_BATCH_IDS=()
TRIAGE_RETRY_ALONE=0
TRIAGE_DEFERRED_COUNT=0
TRIAGE_BATCH_ACTIVE=0
stage_unit_active triage batch && TRIAGE_BATCH_ACTIVE=1
[ "$TRIAGE_BATCH_ACTIVE" = "1" ] && triage_slots=0
TRIAGE_CANDIDATE_QUERY_FAILED=0
if ! NEEDS_TRIAGE_JSON="$(gh issue list --repo "$REPO" --limit 1000 --label needs-triage --state open \
    --json number,createdAt,labels,author,title,body)"; then
  TRIAGE_CANDIDATE_QUERY_FAILED=1
  echo "issue-pipeline: needs-triage candidate snapshot failed; skipping triage dispatch this tick" >&2
elif ! NEEDS_TRIAGE_JSON="$(label_maintainer_test_candidates "$NEEDS_TRIAGE_JSON")"; then
  TRIAGE_CANDIDATE_QUERY_FAILED=1
  echo "issue-pipeline: founder-test intake failed; skipping triage dispatch this tick" >&2
# `focus` leads legacy queues only; roadmap mode follows tree order with the standing overrides.
elif [ "$ROADMAP_ORDER_ENABLED" = true ] && [ "$ROADMAP_TREE_READY" != 1 ]; then
  TRIAGE_CANDIDATE_QUERY_FAILED=1
  echo "issue-pipeline: roadmap tree unavailable; skipping triage dispatch this tick" >&2
elif [ "$ROADMAP_ORDER_ENABLED" = true ]; then
  ROADMAP_TRIAGE_CANDIDATES="$(jq -c --argjson lane_labels "$PIPELINE_SYSTEM_LABELS_JSON" \
    '[.[] | select((any(.labels[]?; .name as $name | ($lane_labels | index($name)) != null)) | not)]' <<< "$NEEDS_TRIAGE_JSON")"
  NEEDS_TRIAGE_IDS="$(roadmap_order_candidates "$ROADMAP_TREE_JSON" "$ROADMAP_TRIAGE_CANDIDATES")" || {
    TRIAGE_CANDIDATE_QUERY_FAILED=1
    echo "issue-pipeline: could not order needs-triage candidates by roadmap; skipping dispatch" >&2
  }
elif ! NEEDS_TRIAGE_IDS="$(jq -r --argjson lane_labels "$PIPELINE_SYSTEM_LABELS_JSON" '
    sort_by([
      (if any(.labels[]?; .name as $label_name | ($lane_labels | index($label_name)) != null) then 1 else 0 end),
      (if any(.labels[]?; .name == "focus") then 0 else 1 end),
      (if any(.labels[]?; .name == "bug") and any(.labels[]?; .name == "priority:top") then 0 else 1 end),
      (if any(.labels[]?; .name == "founder-test") then 0 else 1 end),
      (if any(.labels[]?; .name == "priority:top") then 0 else 1 end),
      (if any(.labels[]?; .name == "critical-path") then 0 else 1 end),
      (if any(.labels[]?; .name == "legacy") then 1 else 0 end),
      .createdAt
    ])
    | map(select((any(.labels[]?; .name as $label_name | ($lane_labels | index($label_name)) != null)) | not))
    | .[].number
  ' <<< "$NEEDS_TRIAGE_JSON")"; then
  TRIAGE_CANDIDATE_QUERY_FAILED=1
  echo "issue-pipeline: could not order needs-triage candidates; skipping triage dispatch this tick" >&2
fi
if [ "$TRIAGE_CANDIDATE_QUERY_FAILED" = "0" ]; then
  NEEDS_TRIAGE_IDS="$(while IFS= read -r next_triage; do
    [ -n "$next_triage" ] || continue
    if hand_agent_issue_is_live_owned "$next_triage"; then
      record_hand_owned_decision triage "$next_triage"
    else
      printf '%s\n' "$next_triage"
    fi
  done <<< "$NEEDS_TRIAGE_IDS")"
fi
if [ "$TRIAGE_BATCH_ACTIVE" = "0" ] && [ "$TRIAGE_CANDIDATE_QUERY_FAILED" = "0" ]; then
  for next_triage in $NEEDS_TRIAGE_IDS; do
    if hand_agent_issue_is_live_owned "$next_triage"; then
      record_hand_owned_decision triage "$next_triage"
      continue
    fi
    is_on_hold "$next_triage" && continue
    [ "$(issue_model_failure_backoff_remaining "$next_triage" "$TRIAGE_RETRY_NOW")" -gt 0 ] && continue
    if triage_retry_deferred "$next_triage" "$TRIAGE_RETRY_NOW" \
      && ! issue_has_maintainer_test_label "$(jq -c --argjson n "$next_triage" '[.[] | select(.number == $n)][0]' <<< "$NEEDS_TRIAGE_JSON")"; then
      continue
    fi
    # See lib.sh's stage_unit_active(): needs-triage stays on the issue
    # until late in run-triage.sh, so a still-running triage for this same
    # issue would otherwise look selectable to a later tick.
    stage_unit_active triage "$next_triage" && continue
    stage_dispatch_allowed triage || break
    ensure_issue_roadmap_parent_for_dispatch "$next_triage" needs-triage || continue
    if [ "$(state_read "$next_triage" | jq -r '.triage_batch_retry_alone // false')" = "true" ]; then
      TRIAGE_BATCH_IDS=("$next_triage")
      TRIAGE_RETRY_ALONE=1
      break
    fi
    [ "$TRIAGE_RETRY_ALONE" = "1" ] && continue
    if [ "$triage_slots" -le 0 ]; then
      TRIAGE_DEFERRED_COUNT=$((TRIAGE_DEFERRED_COUNT + 1))
      continue
    fi
    TRIAGE_BATCH_IDS+=("$next_triage")
    triage_slots=$((triage_slots - 1))
  done
fi

# (b1) ready-for-agent issues with NO stored classification are measured
# here, under the same triage cap, WITHOUT a label flip. 2026-09-15: section
# (c) used to relabel these needs-triage first ("unmeasured, route to
# triage"), which is precisely the [...] the maintainer saw on the
# 18 tickets he cut with /to-tickets and moved to ready-for-agent from his
# Mac: the label he applied vanished within a tick, the ticket was triaged
# from scratch, and the triage verdict (ready-for-human) replaced his. The
# measurement is still needed -- run-implement.sh needs brief_md and
# expected_packages, the gate needs risk_class/level -- but for a precut
# ticket run-triage.sh now runs measure-only (lib.sh issue_is_precut(),
# ladder_state()) and never changes the state to anything but a rung, and
# for a raw report with a hand-applied ready-for-agent it runs the full
# triage as before; either way the label is untouched until the run's own
# single label edit at the end. The unit ledger (stage_unit_active) keeps
# section (c) from dispatching implement on it mid-measurement.
READY_MEASURE_QUERY_FAILED=0
if ! READY_MEASURE_JSON="$(gh issue list --repo "$REPO" --limit 1000 --label ready-for-agent --state open \
    --json number,createdAt,labels,author,title,body)"; then
  READY_MEASURE_QUERY_FAILED=1
  echo "issue-pipeline: ready-for-agent measurement snapshot failed; skipping triage measurement this tick" >&2
elif ! READY_MEASURE_JSON="$(label_maintainer_test_candidates "$READY_MEASURE_JSON")"; then
  READY_MEASURE_QUERY_FAILED=1
  echo "issue-pipeline: founder-test measurement intake failed; skipping triage measurement this tick" >&2
elif [ "$ROADMAP_ORDER_ENABLED" = true ] && [ "$ROADMAP_TREE_READY" != 1 ]; then
  READY_MEASURE_QUERY_FAILED=1
  echo "issue-pipeline: roadmap tree unavailable; skipping triage measurement this tick" >&2
elif [ "$ROADMAP_ORDER_ENABLED" = true ]; then
  ROADMAP_MEASURE_CANDIDATES="$(jq -c --argjson lane_labels "$PIPELINE_SYSTEM_LABELS_JSON" \
    '[.[] | select((any(.labels[]?; .name as $name | ($lane_labels | index($name)) != null)) | not)]' <<< "$READY_MEASURE_JSON")"
  READY_MEASURE_IDS="$(roadmap_order_candidates "$ROADMAP_TREE_JSON" "$ROADMAP_MEASURE_CANDIDATES")" || {
    READY_MEASURE_QUERY_FAILED=1
    echo "issue-pipeline: could not order ready-for-agent measurement candidates by roadmap" >&2
  }
elif ! READY_MEASURE_IDS="$(jq -r --argjson lane_labels "$PIPELINE_SYSTEM_LABELS_JSON" '
    sort_by([
      (if any(.labels[]?; .name == "focus") then 0 else 1 end),
      (if any(.labels[]?; .name == "bug") and any(.labels[]?; .name == "priority:top") then 0 else 1 end),
      (if any(.labels[]?; .name == "founder-test") then 0 else 1 end),
      (if any(.labels[]?; .name == "priority:top") then 0 else 1 end),
      (if any(.labels[]?; .name == "critical-path") then 0 else 1 end),
      (if any(.labels[]?; .name == "legacy") then 1 else 0 end),
      .createdAt
    ])
    | map(select((any(.labels[]?; .name as $label_name | ($lane_labels | index($label_name)) != null)) | not))
    | .[].number
  ' <<< "$READY_MEASURE_JSON")"; then
  READY_MEASURE_QUERY_FAILED=1
  echo "issue-pipeline: could not order ready-for-agent measurement candidates; skipping triage measurement this tick" >&2
fi
if [ "$READY_MEASURE_QUERY_FAILED" = "0" ]; then
  READY_MEASURE_IDS="$(triage_unmeasured_issue_ids "$READY_MEASURE_IDS")" || return 1
  READY_MEASURE_IDS="$(while IFS= read -r next_measure; do
    [ -n "$next_measure" ] || continue
    if hand_agent_issue_is_live_owned "$next_measure"; then
      record_hand_owned_decision triage "$next_measure"
    else
      printf '%s\n' "$next_measure"
    fi
  done <<< "$READY_MEASURE_IDS")"
fi
if [ "$TRIAGE_BATCH_ACTIVE" = "0" ] && [ "$TRIAGE_RETRY_ALONE" = "0" ] && [ "$READY_MEASURE_QUERY_FAILED" = "0" ]; then
  for next_measure in $READY_MEASURE_IDS; do
    [ "$(triage_classification_status "$(state_file "$next_measure")")" = "unmeasured" ] || continue
    if hand_agent_issue_is_live_owned "$next_measure"; then
      record_hand_owned_decision triage "$next_measure"
      continue
    fi
    is_on_hold "$next_measure" && continue
    [ "$(issue_model_failure_backoff_remaining "$next_measure" "$TRIAGE_RETRY_NOW")" -gt 0 ] && continue
    if triage_retry_deferred "$next_measure" "$TRIAGE_RETRY_NOW" \
      && ! issue_has_maintainer_test_label "$(jq -c --argjson n "$next_measure" '[.[] | select(.number == $n)][0]' <<< "$READY_MEASURE_JSON")"; then
      continue
    fi
    stage_unit_active triage "$next_measure" && continue
    stage_dispatch_allowed triage || break
    ensure_issue_roadmap_parent_for_dispatch "$next_measure" ready-for-agent || continue
    if [ "$(state_read "$next_measure" | jq -r '.triage_batch_retry_alone // false')" = "true" ]; then
      TRIAGE_BATCH_IDS=("$next_measure")
      TRIAGE_RETRY_ALONE=1
      break
    fi
    if [ "$triage_slots" -le 0 ]; then
      TRIAGE_DEFERRED_COUNT=$((TRIAGE_DEFERRED_COUNT + 1))
      continue
    fi
    TRIAGE_BATCH_IDS+=("$next_measure")
    triage_slots=$((triage_slots - 1))
  done
fi
if [ "$TRIAGE_DEFERRED_COUNT" -gt 0 ]; then
  echo "issue-pipeline: triage batch cap deferred $TRIAGE_DEFERRED_COUNT selectable issue(s); they remain queued for a later tick" >&2
fi
if [ "${#TRIAGE_BATCH_IDS[@]}" -gt 0 ]; then
  TRIAGE_DISPATCH_IDS=()
  for next_triage in "${TRIAGE_BATCH_IDS[@]}"; do
    if hand_agent_issue_is_live_owned "$next_triage"; then
      record_hand_owned_decision triage "$next_triage"
    else
      TRIAGE_DISPATCH_IDS+=("$next_triage")
    fi
  done
  if [ "${#TRIAGE_DISPATCH_IDS[@]}" -gt 0 ]; then
    if dispatch_triage_batch "${TRIAGE_DISPATCH_IDS[@]}"; then
      echo "issue-pipeline: dispatched one triage batch for ${#TRIAGE_DISPATCH_IDS[@]} issue(s); retry-alone=$TRIAGE_RETRY_ALONE" >&2
    else
      triage_batch_launch_status=$?
      [ "$triage_batch_launch_status" -eq 75 ] || exit "$triage_batch_launch_status"
      echo "issue-pipeline: triage batch admission deferred; selected issues remain pending" >&2
    fi
  fi
fi
# Not gated on triage: a retry-alone triage batch still runs under the pause
# without refreshing, and the stale index then had no trigger at all (2026-10-09).
dispatch_gitnexus_refresh || true
fi
if [ "$PIPELINE_STAGE" = advisor ]; then
profile_mark advisor

# (b2/b2-orphan) needs-advisor issues, in queue order (priority:top first,
# then oldest), through one batch dialogue -- plus (b2-orphan), local
# ticket state carrying an unresolved pending_advisor_verdict whose GitHub
# label is NOT (or no longer) needs-advisor -- the recovery path for the gap
# 54f148be6/c8d802867 (advisor-core.sh) left open: if a verdict's Apply
# sequence swaps the label away but a LATER step in that same Apply run
# fails before the final atomic completion write, the ticket vanishes from
# the ordinary needs-advisor query below forever, because that query is
# keyed on the very label the verdict already moved.
# advisor_pending_orphan_candidates() (lib.sh) finds these by reading local
# state directly instead of GitHub. Orphans only resume a verdict already
# produced; a changed ticket is returned to needs-advisor for the next batch.
#
# 2026-09-15: the default destination for an issue enforce_autonomy_gate()
# refuses is no longer ready-for-human (a terminal stop), it's the advisor
# (run-advisor.sh, the configured advisor pass) — see docs/agents/
# issue-pipeline.md. Runs even under MODE=triage (before the exit below):
# the advisor never writes code, opens a PR, or touches production, so
# there's no reason to gate it behind AGENT_PIPELINE=implement/release the
# way the actual implement/release legs are gated further down.
#
# Fresh needs-advisor tickets use the batch path below. Single-ticket polling
# handles jobs already sent; stored roadmap-parent verdicts leave the batch
# and resume once without another model call.
ADVISOR_QUEUE_READ_FAILED=0
if ! NEEDS_ADVISOR_IDS="$(gh issue list --repo "$REPO" --limit 1000 --label needs-advisor --state open \
    --json number,createdAt,labels | jq -r --argjson lane_labels "$PIPELINE_SYSTEM_LABELS_JSON" 'sort_by([(if any(.labels[]?; .name == "focus") then 0 else 1 end), (if any(.labels[]?; .name == "priority:top") then 0 else 1 end), .createdAt]) | map(select((any(.labels[]?; .name as $label_name | ($lane_labels | index($label_name)) != null)) | not)) | .[].number')"; then
  ADVISOR_QUEUE_READ_FAILED=1
  NEEDS_ADVISOR_IDS=""
  echo "issue-pipeline: needs-advisor queue could not be read; queue is unknown, so only advisor dispatch is skipped this tick and retried next tick" >&2
fi
NEEDS_ADVISOR_IDS="$(prioritize_advisor_blockers "$NEEDS_ADVISOR_IDS")"
NEEDS_ADVISOR_IDS="$(while IFS= read -r advisor_id; do
  [ -n "$advisor_id" ] || continue
  if issue_is_tracker_parent "$advisor_id"; then continue; fi
  if hand_agent_issue_is_live_owned "$advisor_id"; then
    record_hand_owned_decision advisor "$advisor_id"
    continue
  fi
  if roadmap_issue_is_container "$advisor_id"; then
    if ! issue_state="$(state_read "$advisor_id")" \
      || ! jq -e 'type == "object"' <<< "$issue_state" >/dev/null 2>&1; then
      record_advisor_decision skipped tracker-parent-state \
        "Roadmap parent state could not be verified; preserving advisor state" "$advisor_id"
      continue
    fi
    if is_on_hold "$advisor_id" \
      || jq -e '.state == "on-hold" or (.hold | type == "object")' <<< "$issue_state" >/dev/null 2>&1; then
      continue
    fi
    if jq -e '.pending_advisor_verdict != null' <<< "$issue_state" >/dev/null 2>&1; then
      # Keep the stored ruling out of the fresh batch; the orphan pool below
      # will resume it through run-advisor.sh without another model call.
      continue
    fi
    if retire_tracker_parent "$advisor_id"; then
      record_advisor_decision skipped tracker-parent \
        "Roadmap parent waits on child tickets; advisor candidate retired" "$advisor_id"
    else
      record_advisor_decision skipped tracker-parent-route \
        "Roadmap parent could not be routed to tracker" "$advisor_id"
    fi
    continue
  else
    roadmap_status=$?
  fi
  if [ "$roadmap_status" -ne 1 ]; then
    record_advisor_decision skipped roadmap-parent-query \
      "Roadmap container state could not be verified; advisor dispatch held" "$advisor_id"
    continue
  fi
  [ "$(issue_model_failure_backoff_remaining "$advisor_id")" -gt 0 ] && continue
  printf '%s\n' "$advisor_id"
done <<< "$NEEDS_ADVISOR_IDS")"
advisor_slots="$(cap_slots_remaining "$ADVISOR_CAP" "$(stage_unit_count advisor)")"
ADVISOR_RAW_JOB_IDS="$(web_advisor_provider_job_ids)"
ADVISOR_PENDING_JOB_IDS="$(web_advisor_provider_job_candidates "$NEEDS_ADVISOR_IDS")"
ADVISOR_STALE_PENDING_JOB_IDS="$({
  while IFS= read -r next_job; do
    [ -n "$next_job" ] || continue
    if hand_agent_issue_is_live_owned "$next_job"; then
      record_hand_owned_decision advisor "$next_job"
      continue
    fi
    grep -qx "$next_job" <<< "$ADVISOR_PENDING_JOB_IDS" || printf '%s\n' "$next_job"
  done <<< "$ADVISOR_RAW_JOB_IDS"
} | sort -n)"
ADVISOR_QUEUE_COUNT="$(awk 'NF { n += 1 } END { print n + 0 }' <<< "$NEEDS_ADVISOR_IDS")"
ADVISOR_BATCH_UNIT_ACTIVE=0
if stage_unit_active advisor batch; then
  ADVISOR_BATCH_UNIT_ACTIVE=1
fi

# A web-advisor-provider job was already sent before quarantine closed this stage. Its
# next advisor dispatch only polls that local result; it must not wait for
# another canary window or the grace timer can mistake unobserved work for a
# passing canary. Keep the normal cap/on-hold/active-unit guards -- this is
# not a new web call and does not create extra capacity.
advisor_dispatch_pending_job_pool() {
  for next_poll in $ADVISOR_PENDING_JOB_IDS; do
    if issue_is_tracker_parent "$next_poll"; then continue; fi
    if hand_agent_issue_is_live_owned "$next_poll"; then
      record_hand_owned_decision advisor "$next_poll"
      NEEDS_ADVISOR_IDS="$(grep -vxF "$next_poll" <<< "$NEEDS_ADVISOR_IDS" || true)"
      ADVISOR_PENDING_JOB_IDS="$(grep -vxF "$next_poll" <<< "$ADVISOR_PENDING_JOB_IDS" || true)"
      ADVISOR_QUEUE_COUNT="$(awk 'NF { n += 1 } END { print n + 0 }' <<< "$NEEDS_ADVISOR_IDS")"
      continue
    fi
    [ "$advisor_slots" -le 0 ] && break
    grep -qx "$next_poll" <<< "$NEEDS_ADVISOR_IDS" || continue
    [ "$(issue_model_failure_backoff_remaining "$next_poll")" -gt 0 ] && continue
    is_on_hold "$next_poll" && continue
    state_read "$next_poll" | jq -e 'has("advisor_ruled_at")' >/dev/null 2>&1 && continue
    stage_unit_active advisor "$next_poll" && continue
    ensure_issue_roadmap_parent_for_dispatch "$next_poll" needs-advisor || continue
    agent_memory_floor_allows advisor || break
    if dispatch advisor "$next_poll"; then
      :
    else
      dispatch_status=$?
      if [ "$dispatch_status" -eq 75 ]; then advisor_slots=0; break; fi
      return "$dispatch_status"
    fi
    advisor_slots=$((advisor_slots - 1))
  done
}

# The `grep -qx` dedup against $NEEDS_ADVISOR_IDS (captured above, not a
# fresh query) keeps an orphan recovery candidate from being handled twice if
# it is also back in the batch queue.
advisor_dispatch_orphan_pool() {
  for next_orphan in $(advisor_pending_orphan_candidates); do
    grep -qx "$next_orphan" <<< "$NEEDS_ADVISOR_IDS" && continue
    if issue_is_tracker_parent "$next_orphan"; then continue; fi
    if hand_agent_issue_is_live_owned "$next_orphan"; then
      record_hand_owned_decision advisor "$next_orphan"
      continue
    fi
    [ "$advisor_slots" -le 0 ] && break
    [ "$(issue_model_failure_backoff_remaining "$next_orphan")" -gt 0 ] && continue
    is_on_hold "$next_orphan" && continue
    stage_unit_active advisor "$next_orphan" && continue
    if ! stage_dispatch_allowed advisor; then
      record_advisor_decision skipped quarantine \
        "Advisor rung remains queued because advisor quarantine blocks dispatch: ${STAGE_DISPATCH_BLOCKING_SCOPES:-unknown scope}" "$next_orphan"
      break
    fi
    ensure_issue_roadmap_parent_for_dispatch "$next_orphan" needs-advisor || continue
    agent_memory_floor_allows advisor || break
    if dispatch advisor "$next_orphan" -E ADVISOR_RESUME_ONLY=1; then
      :
    else
      dispatch_status=$?
      if [ "$dispatch_status" -eq 75 ]; then advisor_slots=0; break; fi
      return "$dispatch_status"
    fi
    advisor_slots=$((advisor_slots - 1))
  done
}

advisor_dispatch_roadmap_parent_pending_pool() {
  local next_parent roadmap_status
  for next_parent in $(advisor_pending_orphan_candidates); do
    grep -qx "$next_parent" <<< "$NEEDS_ADVISOR_IDS" && continue
    issue_is_tracker_parent "$next_parent" && continue
    if roadmap_issue_is_container "$next_parent"; then
      :
    else
      roadmap_status=$?
      [ "$roadmap_status" -eq 1 ] && continue
      record_advisor_decision skipped roadmap-parent-query \
        "Stored verdict remains queued because roadmap container state could not be verified" "$next_parent"
      continue
    fi
    [ "$advisor_slots" -gt 0 ] || break
    [ "$(issue_model_failure_backoff_remaining "$next_parent")" -gt 0 ] && continue
    is_on_hold "$next_parent" && continue
    stage_unit_active advisor "$next_parent" && continue
    if ! stage_dispatch_allowed advisor; then
      record_advisor_decision skipped quarantine \
        "Stored roadmap-parent verdict remains queued because advisor quarantine blocks dispatch: ${STAGE_DISPATCH_BLOCKING_SCOPES:-unknown scope}" "$next_parent"
      break
    fi
    agent_memory_floor_allows advisor || break
    if dispatch advisor "$next_parent" -E ADVISOR_RESUME_ONLY=1; then
      :
    else
      dispatch_status=$?
      if [ "$dispatch_status" -eq 75 ]; then advisor_slots=0; break; fi
      return "$dispatch_status"
    fi
    advisor_slots=$((advisor_slots - 1))
  done
}

if [ "$ADVISOR_QUEUE_COUNT" -ge "$ADVISOR_BATCH_MIN" ]; then
  if [ -n "$ADVISOR_STALE_PENDING_JOB_IDS" ]; then
    record_advisor_decision bypassed pending-job-liveness \
      "pending arm bypassed by liveness gate" "$ADVISOR_STALE_PENDING_JOB_IDS"
  fi
  if [ -n "$ADVISOR_PENDING_JOB_IDS" ]; then
    record_advisor_decision skipped batch-pending \
      "batch threshold met but pending single-ticket jobs take priority" "$ADVISOR_PENDING_JOB_IDS"
  fi
fi
# One tick chooses exactly one web-advisor mode. Every fresh question, even a
# one-ticket queue, uses one batch dialogue. Existing single jobs are polled;
# stored orphan verdicts resume without a model call. Deferred batch members
# lead the next batch (one dialogue asks all questions at once).
if [ "$ADVISOR_QUEUE_READ_FAILED" = "1" ]; then
  : # A failed snapshot is not an empty queue; keep unrelated pipeline legs running.
elif [ "$ADVISOR_BATCH_UNIT_ACTIVE" = "1" ]; then
  echo "issue-pipeline: batch advisor wrapper is already active; no new advisor question dispatch this tick" >&2
elif advisor_batch_job_active; then
  if [ "$advisor_slots" -gt 0 ]; then
    dispatch_advisor_batch 1 || exit "$?"
  fi
else
  if [ "$advisor_slots" -gt 0 ]; then
    advisor_dispatch_roadmap_parent_pending_pool
  fi
  if [ -n "$ADVISOR_PENDING_JOB_IDS" ] && [ "$advisor_slots" -gt 0 ]; then
    advisor_dispatch_pending_job_pool
  fi
  if [ "$ADVISOR_QUEUE_COUNT" -ge "$ADVISOR_BATCH_MIN" ]; then
    if [ -n "$ADVISOR_PENDING_JOB_IDS" ]; then
      : # recorded above as batch-pending; the batch starts once they drain
    elif [ "$advisor_slots" -gt 0 ] && web_advisor_provider_dispatch_allowed; then
      echo "issue-pipeline: $ADVISOR_QUEUE_COUNT needs-advisor tickets meet batch threshold $ADVISOR_BATCH_MIN; dispatching one batch job" >&2
      dispatch_advisor_batch || exit "$?"
    elif [ "$advisor_slots" -gt 0 ] && [ -n "${STAGE_DISPATCH_BLOCKING_SCOPES:-}" ]; then
      record_advisor_decision skipped quarantine \
        "Advisor rung remains queued because advisor quarantine blocks dispatch: $STAGE_DISPATCH_BLOCKING_SCOPES" "$NEEDS_ADVISOR_IDS"
    fi
  elif [ "$advisor_slots" -gt 0 ]; then
    advisor_dispatch_orphan_pool
  fi
fi

# Advisor slice ends here; selection replay excludes the outer stage guard.
fi
if [ "$PIPELINE_STAGE" = recut ]; then
profile_mark recut
# (b3) needs-recut issues, in queue order (priority:top first, then oldest),
# up to RECUT_CAP concurrently. Runs
# AFTER the advisor loop above (the advisor decides first, recut executes
# what it labels) and, like the advisor, even under MODE=triage — recut
# never writes code or touches production either, it only ever creates
# needs-triage children.
recut_slots="$(cap_slots_remaining "$RECUT_CAP" "$(stage_unit_count recut)")"
if [ "$recut_slots" -gt 0 ]; then
  for next_recut in $(gh issue list --repo "$REPO" --limit 1000 --label needs-recut --state open \
      --json number,createdAt,labels | jq -r --argjson lane_labels "$PIPELINE_SYSTEM_LABELS_JSON" 'sort_by([(if any(.labels[]?; .name == "focus") then 0 else 1 end), (if any(.labels[]?; .name == "priority:top") then 0 else 1 end), .createdAt]) | map(select((any(.labels[]?; .name as $label_name | ($lane_labels | index($label_name)) != null)) | not)) | .[].number'); do
    [ "$recut_slots" -le 0 ] && break
    is_on_hold "$next_recut" && continue
    [ "$(issue_model_failure_backoff_remaining "$next_recut")" -gt 0 ] && continue
    # Pre-filter for efficiency: run-recut.sh checks its own idempotency
    # markers too (recut_children/recut_refused_at), but there's no reason
    # to spend a worktree + model call dispatching a run whose own first
    # check would just exit 0 immediately.
    state_read "$next_recut" | jq -e 'has("recut_children") or has("recut_refused_at")' >/dev/null 2>&1 && continue
    # Not safe against a triage/advisor run on the SAME parent issue (both
    # would race the parent's own state_merge) -- this is that guard, same
    # shape as stage_unit_active triage "$n" above.
    stage_unit_active recut "$next_recut" && continue
    stage_dispatch_allowed recut || break
    if dispatch_policy_unit recut "$next_recut" needs-recut; then
      recut_slots=$((recut_slots - 1))
    else
      dispatch_status=$?
      case "$dispatch_status" in
        75) break ;;
        78) continue ;;
        79)
          record_implement_decision "$next_recut" skipped roadmap-parent \
            "路线图父级挂接失败；保留在 needs-recut 队列，后续 tick 重试" "#$next_recut"
          continue
          ;;
        74) record_implement_decision "$next_recut" skipped model-capacity-hold \
          "recut role model is at capacity; dispatch deferred without attempt" "$next_recut"; continue ;;
        77) break ;;
        *) record_env_fault env:model-policy-dispatch recut "$next_recut" "recut policy dispatch failed with status $dispatch_status"; break ;;
      esac
    fi
  done
fi
fi
}
if [[ "$PIPELINE_STAGE" == triage || "$PIPELINE_STAGE" == advisor || "$PIPELINE_STAGE" == recut ]]; then
  run_intake_dispatch
  profile_finish
  exit 0
fi
if [ "$PIPELINE_STAGE" = maintenance ]; then
  run_post_dispatch_maintenance
  profile_finish
  exit 0
fi
if [ "$PIPELINE_STAGE" = implement ]; then
  # Implement and ready-refill belong to the autopilot scheduler, not to this script: the
  # stage only services intake and maintenance, and the refill event is a no-op.
  [ "${EVENT_REFILL:-0}" = 0 ] || exit 0
  run_intake_dispatch
  run_post_dispatch_maintenance
  profile_finish
  exit 0
fi
profile_mark release

record_release_decision() {
  local n="$1" outcome="$2" gate="$3" object="$4" reason="$5"
  echo "issue-pipeline: release-decision tick=$IMPLEMENT_TICK_ID issue=#$n outcome=$outcome gate=$gate object=$object reason=$reason" >&2
}

if [ "$MODE" != "release" ]; then
  # Intake reads can consume the whole service deadline. Existing executable
  # tickets get their dispatch and summary first, under the unchanged gates.
  run_intake_dispatch
  run_post_dispatch_maintenance
  profile_finish
  exit 0
fi

# Recheck a recorded infrastructure preflight once per release tick before
# the candidate selector applies deploy_is_blocked(). The wrapper only runs a
# registered read-only preflight; unknown block kinds remain fail-closed.
if [ -s "$DEPLOY_BLOCKED_FILE" ] && [ "$DRY_RUN" != 1 ]; then
  if ! bash "$(zf_release_runner)" --recheck-deploy-block; then
    echo "issue-pipeline: infrastructure deploy-block recheck failed; release remains gated" >&2
  fi
fi

PRODUCTION_DEPLOYMENT_SHA=""
PRODUCTION_DEPLOYMENT_SHA_LOADED=0
latest_production_deployment_sha() {
  if (( PRODUCTION_DEPLOYMENT_SHA_LOADED )); then
    [ -n "$PRODUCTION_DEPLOYMENT_SHA" ] || return 1
    printf '%s' "$PRODUCTION_DEPLOYMENT_SHA"
    return 0
  fi
  PRODUCTION_DEPLOYMENT_SHA_LOADED=1
  local records
  records="$(bash "$SCRIPT_DIR/production-deployment-read.sh" "$REPO")" || return 1
  PRODUCTION_DEPLOYMENT_SHA="$(jq -r '.[0].sha // empty | select(test("^[0-9a-f]{40}$"))' <<<"$records")"
  [ -n "$PRODUCTION_DEPLOYMENT_SHA" ] || return 1
  printf '%s' "$PRODUCTION_DEPLOYMENT_SHA"
}

# Spec #4355 (factory f3): ticket releases batch on a 2h cadence — every window
# dispatches one release from the newest green main SHA, and merging continues
# throughout. The former daily release window is superseded for these batches.
# A persisted fleet-roll continuation is an in-flight release, not a new batch,
# so it does not consume a window.
RELEASE_BATCH_CADENCE_FILE="$AGENT_HOME/release-batch-last-dispatch"
release_batch_cadence_mark() {
  guarded_state_write "$RELEASE_BATCH_CADENCE_FILE" "$(date +%s)" \
    || echo "issue-pipeline: could not record the release-batch cadence marker" >&2
}
release_batch_cadence_open() {
  local last
  last="$(cat "$RELEASE_BATCH_CADENCE_FILE" 2>/dev/null || true)"
  [[ "$last" =~ ^[0-9]+$ ]] || return 0
  [ $(( $(date +%s) - last )) -ge 7200 ]
}

select_release_batch() {
  local release_slots release_issue_numbers release_candidate_sha release_dispatch_block_gate=""
  local n state deploy_state fleet_roll_status pr_number release_pr_row release_pr_number release_merge_sha hl_rc release_wait_sha current_deployed_sha
  local release_batch_anchor="" release_batch_anchor_fleet=0 release_batch_anchor_roll_sha="" fleet_roll_sha=""
  local -a release_batch_issues=()
  local -A release_issue_seen=()

  release_slots="$(cap_slots_remaining "$RELEASE_CAP" "$(stage_unit_count release)")"
  if ! release_issue_numbers="$(gh issue list --repo "$REPO" --state open \
      --label awaiting-release --limit 1000 --json number,labels \
      | jq -r --argjson lane_labels "$PIPELINE_SYSTEM_LABELS_JSON" '
        map(select((any(.labels[]?; .name as $label_name | ($lane_labels | index($label_name)) != null)) | not))
        | .[].number' | sort -n)"; then
    echo "issue-pipeline: could not read awaiting-release issues; refusing release selection" >&2
    return 1
  fi
  # Pin one candidate SHA for the whole cohort. Tickets merged after it wait
  # for the next batch, even if main advances while this selector runs.
  release_candidate_sha="$(git -C "$REPO_DIR" rev-parse origin/main)" || return 1
  while IFS= read -r n; do
    [[ "$n" =~ ^[0-9]+$ ]] || continue
    [ -n "${release_issue_seen[$n]:-}" ] && continue
    release_issue_seen["$n"]=1
    state="$(state_read "$n")"
    if [ "$(jq -r '.pipeline_system.enabled // false' <<< "$state")" = true ]; then
      record_release_decision "$n" skipped pipeline-system state direct-close-path
      continue
    fi
    if [ "$(jq -r '.state // empty' <<< "$state")" != "awaiting-release" ]; then
      record_release_decision "$n" skipped release-state state not-awaiting-release
      continue
    fi
    if [ "$(jq -r '.run.outcome // empty' <<< "$state")" != "merged" ]; then
      record_release_decision "$n" skipped run-outcome state not-merged
      continue
    fi
    deploy_state="$(jq -r '.deploy_state // empty' <<< "$state")"
    if [ "$deploy_state" != "pending" ] && [ "$deploy_state" != "deployed" ]; then
      record_release_decision "$n" skipped deploy-state state not-pending-or-deployed
      continue
    fi
    if [ "$release_slots" -le 0 ]; then
      record_release_decision "$n" skipped capacity RELEASE_CAP slots-exhausted
      continue
    fi
    fleet_roll_status="$(jq -r '.fleet_roll_pending.status // empty' <<< "$state")"
    pr_number="$(jq -r '.run.evidence.pr_number // empty' <<< "$state")"
    if [[ ! "$pr_number" =~ ^[0-9]+$ ]]; then
      record_release_decision "$n" skipped recorded-pr state missing-or-invalid-pr-number
      continue
    fi
    release_pr_row="$(merged_pr_for_issue "$n" || true)"
    if [ -z "$release_pr_row" ]; then
      record_release_decision "$n" skipped recorded-pr "#$pr_number" not-merged-to-main
      continue
    fi
    IFS=$'\t' read -r release_pr_number release_merge_sha <<< "$release_pr_row"
    if ! git -C "$REPO_DIR" merge-base --is-ancestor "$release_merge_sha" "$release_candidate_sha"; then
      record_release_decision "$n" skipped main-ancestry "#$release_pr_number" merge-not-ancestor-of-origin-main
      continue
    fi
    # `on-hold` blocks new issue work, not deploy-time closure after functional E2E.
    # run-release.sh clears the hold when it closes the deployed ticket.
    hl_rc=0; has_label "$n" ready-for-human || hl_rc=$?
    if [ "$hl_rc" -eq 0 ]; then
      record_release_decision "$n" skipped ready-for-human label present
      continue
    fi
    if [ "$hl_rc" -ne 1 ]; then
      record_release_decision "$n" skipped ready-for-human-label label label-unavailable
      continue
    fi
    release_wait_sha="$(jq -r '.release_timing_wait_sha // empty' <<< "$state")"
    if [ -n "$release_wait_sha" ]; then
      latest_production_deployment_sha >/dev/null 2>&1 || true  # load the cache here: the $(...) below runs in a subshell
      current_deployed_sha="$(latest_production_deployment_sha 2>/dev/null || true)"
      if [ "$release_wait_sha" = "$current_deployed_sha" ]; then
        record_release_decision "$n" skipped timing-debt "#1449" already-deployed-waiting-next-deploy
        continue
      fi
    fi
    if [ "$(jq -r '.released // false' <<< "$state")" = "true" ]; then
      record_release_decision "$n" skipped released state already-released
      continue
    fi
    if deploy_is_blocked "$release_candidate_sha"; then
      record_release_decision "$n" skipped deploy-blocked "$release_candidate_sha" exact-failed-sha
      continue
    fi
    if stage_unit_active release batch || stage_unit_active release "$n"; then
      record_release_decision "$n" skipped active-unit ${UNIT_PREFIX_TRANSIENT}-release-batch already-running
      continue
    fi
    if [ -n "$release_dispatch_block_gate" ]; then
      record_release_decision "$n" skipped "$release_dispatch_block_gate" release release-dispatch-blocked
      continue
    fi
    if ! stage_dispatch_allowed release; then
      release_dispatch_block_gate=stage-dispatch
      record_release_decision "$n" skipped stage-dispatch release quarantine-or-policy-block
      continue
    fi
    if ! agent_memory_floor_allows release; then
      release_dispatch_block_gate=memory-floor
      record_release_decision "$n" skipped memory-floor release minimum-memory-unavailable
      continue
    fi
    if ! ensure_issue_roadmap_parent_for_dispatch "$n" awaiting-release; then
      record_release_decision "$n" skipped roadmap-parent release parent-placement-failed
      continue
    fi
    release_batch_issues+=("$n")
    # Several pending rolls: anchor the newest image. It carries every older
    # pending change, and the older pin is already shadowed by the newer pin
    # overlay, so anchoring the oldest failed its pin check on every train
    # (2026-10-22, #1145 behind #4061).
    if [ "$fleet_roll_status" = pending ]; then
      fleet_roll_sha="$(jq -r '.fleet_roll_pending.image_sha // empty' <<< "$state")"
      if [ -z "$release_batch_anchor" ] || { [ "$release_batch_anchor_fleet" -eq 1 ] && [ -n "$fleet_roll_sha" ] \
        && [ "$fleet_roll_sha" != "$release_batch_anchor_roll_sha" ] \
        && git -C "$REPO_DIR" merge-base --is-ancestor "$release_batch_anchor_roll_sha" "$fleet_roll_sha" 2>/dev/null; }; then
        release_batch_anchor="$n"
        release_batch_anchor_fleet=1
        release_batch_anchor_roll_sha="$fleet_roll_sha"
      fi
    fi
  done <<< "$release_issue_numbers"

  [ "${#release_batch_issues[@]}" -gt 0 ] || return 0
  [ -n "$release_batch_anchor" ] || release_batch_anchor="${release_batch_issues[0]}"
  if [ "$release_batch_anchor_fleet" -ne 1 ] && ! release_batch_cadence_open; then
    for n in "${release_batch_issues[@]}"; do
      record_release_decision "$n" skipped release-cadence ${UNIT_PREFIX_TRANSIENT}-release-batch "window-not-elapsed"
    done
    return 0
  fi
  local release_dispatch_status=0
  dispatch_release_batch "$release_batch_anchor" "$release_candidate_sha" || release_dispatch_status=$?
  if [ "$release_dispatch_status" -eq 75 ]; then
    for n in "${release_batch_issues[@]}"; do
      record_release_decision "$n" skipped execution-admission ${UNIT_PREFIX_TRANSIENT}-release-batch temporarily-unavailable
    done
    return 0
  fi
  [ "$release_dispatch_status" -eq 0 ] || return "$release_dispatch_status"
  for n in "${release_batch_issues[@]}"; do
    if [ "$n" = "$release_batch_anchor" ]; then
      if [ "$release_batch_anchor_fleet" -eq 1 ]; then
        record_release_decision "$n" dispatched fleet-roll ${UNIT_PREFIX_TRANSIENT}-release-batch retry-persisted-rollout
      else
        record_release_decision "$n" dispatched release-batch ${UNIT_PREFIX_TRANSIENT}-release-batch "sha=$release_candidate_sha"
      fi
    else
      record_release_decision "$n" batched release-batch ${UNIT_PREFIX_TRANSIENT}-release-batch "shared-sha=$release_candidate_sha anchor=#$release_batch_anchor"
    fi
  done
}

# awaiting-release 状态由合入方在合并当时写入（mac-autopilot 调度器 merge lane 与 delivery-request
# 都直接调 conclude_merged_run，#4515 单一事实源）；release tick 不再从 PR 正文反推补状态。
if [ "$MODE" = release ]; then select_release_batch; fi
profile_finish
