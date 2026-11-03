#!/usr/bin/env bash
# Each serial decision stage owns a hard slice; an overrun cannot eat the tail.

# The stage-exit contract, in ONE place. A stage scheduler
# (bash issue-pipeline.sh --stage X) may exit:
#   0                      completed, including "nothing selected this tick"
#   ZF_SLICE_DEFER_STATUS  defer (sysexits.h EX_TEMPFAIL): admission, a claim,
#                          or the tick lock said "not now". Queues are
#                          unchanged; this is NOT a failure. Producers today:
#                          dispatch_advisor_batch / dispatch_triage_batch
#                          claim-unavailable (issue-pipeline.sh), guarded_write
#                          admission deferrals, the release delegate's lock
#                          wait, the event-refill lock.
#   124 / 137              the slice budget's own timeout killed the stage
#                          (overrun); dispatched units are outside this
#                          process group and survive it
#   anything else          a real failure: failed=1, the tick is refused, and
#                          run-tick's refuse() reports it
# 2026-11-03: 75 used to fall into "anything else", so one advisor claim miss
# refused the whole tick, every tick, while the queue starved behind it.
ZF_SLICE_DEFER_STATUS=75

# Best-effort durable note for the bell scanner (mac-autopilot/bell.sh reads
# this log; the slice's own stderr goes only to the unit journal, which bell
# never scans). Never fatal: a slice failure must still reach refuse().
pipeline_slice_failure_note() { # tick stage status
  local runtime_dir="${MAC_AUTOPILOT_RUNTIME_DIR:-${REPO_DIR:+$REPO_DIR/.scratch-supervisor/autopi}}"
  [ -n "$runtime_dir" ] && [ -d "$runtime_dir" ] || return 0
  printf '[%s] issue-pipeline: slice-failed tick=%s stage=%s status=%s\n' \
    "$(date -u +%FT%TZ)" "$1" "$2" "$3" >> "$runtime_dir/scheduler.log" 2>/dev/null || true
}

run_pipeline_slices() {
  local scheduler="$1" mode stage budget status=0 failed=0 started tick="" deadline night
  exec 9>"$LOCK_FILE"
  flock -n 9 || return 0
  if [ "${ZF_PIPELINE_CALL_PROFILE_ENABLED:-0}" = 1 ]; then
    tick="$(date -u +%Y%m%dT%H%M%SZ)"
    ZF_CALL_PROFILE_TICK_ID="$tick"
    ZF_CALL_PROFILE_STAGE=runner
    ZF_CALL_PROFILE_SECTION=preflight
    export ZF_CALL_PROFILE_TICK_ID ZF_CALL_PROFILE_STAGE ZF_CALL_PROFILE_SECTION
  fi
  check_gmail_credential
  mode="$(gh variable get AGENT_PIPELINE --repo "$REPO" 2>/dev/null || echo off)"
  mode="${mode//[[:space:]]/}"
  case "$mode" in triage|implement|release) mode=triage ;; *) return 0 ;; esac
  manual_pause_is_valid && return 0
  [ -n "$tick" ] || tick="$(date -u +%Y%m%dT%H%M%SZ)"
  echo "issue-pipeline: slice-start tick=$tick mode=$mode" >&2
  # Preserve the original one-roadmap-read-per-tick semantics across slices.
  # The supervisor's admission fallback remains the sole producer.
  night="${ZF_NIGHT_DIR:-$AGENT_HOME/night}"
  ZF_OPEN_ISSUES_CACHE_FILE="${ZF_OPEN_ISSUES_CACHE_FILE:-$night/.open-issues-pipeline-$tick.json}"
  ZF_ROADMAP_TREE_CACHE_FILE="${ZF_ROADMAP_TREE_CACHE_FILE:-$(roadmap_cache_path "$ZF_OPEN_ISSUES_CACHE_FILE")}"
  ZF_PIPELINE_ROADMAP_SWITCH="$(roadmap_switch_value)"
  ZF_PIPELINE_ROADMAP_READY=0
  if [ "$ZF_PIPELINE_ROADMAP_SWITCH" = true ] \
    && roadmap_fetch_for_admission "$ZF_ROADMAP_TREE_CACHE_FILE" "$REPO"; then
    ZF_PIPELINE_ROADMAP_READY=1
  fi
  ZF_PIPELINE_ROADMAP_STALE="${ROADMAP_TREE_STALE:-0}"
  ZF_PIPELINE_ROADMAP_AGE="${ROADMAP_SNAPSHOT_AGE_SECONDS:-0}"
  export ZF_OPEN_ISSUES_CACHE_FILE ZF_ROADMAP_TREE_CACHE_FILE \
    ZF_PIPELINE_ROADMAP_SWITCH ZF_PIPELINE_ROADMAP_READY \
    ZF_PIPELINE_ROADMAP_STALE ZF_PIPELINE_ROADMAP_AGE
  for stage in fastlane triage advisor recut release maintenance; do
    case "$stage:$mode" in release:triage) continue ;; esac
    case "$stage" in
      fastlane) budget=150 ;; triage) budget=120 ;; advisor) budget=150 ;;
      recut) budget=60 ;; release|maintenance) budget=120 ;;
    esac
    if [ "${ZF_PIPELINE_CALL_PROFILE_ENABLED:-0}" = 1 ]; then
      ZF_CALL_PROFILE_STAGE="$stage"
      ZF_CALL_PROFILE_SECTION=preflight
      export ZF_CALL_PROFILE_STAGE ZF_CALL_PROFILE_SECTION
    fi
    started=$SECONDS
    deadline=$(( $(date +%s) * 1000 + (budget - 15) * 1000 ))
    status=0
    # FD 9 keeps the decision lock across children. timeout owns only this child
    # process group; dispatched systemd units are outside it and survive.
    TICK_UNIT_TIMEOUT_SECONDS="$budget" MAINTENANCE_STEP_RESERVE_SECONDS=15 \
      ZF_PIPELINE_SLICE_TICK="$tick" \
      ZF_GH_CALL_DEADLINE_EPOCH_MS="$deadline" \
      timeout --kill-after=5s "${budget}s" bash "$scheduler" --stage "$stage" || status=$?
    echo "issue-pipeline: slice tick=$tick stage=$stage elapsed_sec=$((SECONDS - started)) status=$status" >&2
    case "$status" in
      0) ;;
      "$ZF_SLICE_DEFER_STATUS") echo "issue-pipeline: slice deferred stage=$stage status=$status (claim/admission said not-now); continuing other stages" >&2 ;;
      124|137) echo "issue-pipeline: slice overrun stage=$stage; continuing other stages" >&2 ;;
      *)
        failed=1
        echo "issue-pipeline: slice failed stage=$stage status=$status; refusing this tick" >&2
        pipeline_slice_failure_note "$tick" "$stage" "$status"
        ;;
    esac
  done
  echo "issue-pipeline: slice-summary tick=$tick status=$failed completed=1" >&2
  return "$failed"
}
