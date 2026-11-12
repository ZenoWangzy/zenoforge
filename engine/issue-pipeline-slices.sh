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
#   anything else          only this slice failed: write a bell-visible note,
#                          file one incident per stage+status through #166,
#                          then keep the other slices and tick post-steps running
# 2026-11-03: 75 used to fall into "anything else", so one advisor claim miss
# refused the whole tick, every tick, while the queue starved behind it.
ZF_SLICE_DEFER_STATUS=75

# run-tick's refusal gate must stay ahead of the scheduler handoff when the
# dedicated checkout cannot be trusted. These are the exact checkout-integrity
# refusal tags used by run-tick.sh; slice failures never enter this set.
ZF_TICK_CHECKOUT_INTEGRITY_REFUSAL_TAGS='checkout-restore-failed wrong-branch fetch-starved fetch-timeout fetch-failed diverged'
tick_checkout_integrity_refusal_tag() { # run-tick refusal tag -> 0 only for checkout-integrity gates
  case " $ZF_TICK_CHECKOUT_INTEGRITY_REFUSAL_TAGS " in
    *" $1 "*) return 0 ;;
    *) return 1 ;;
  esac
}

# A skipped tick must leave a trace: on 2026-11-07 a 29 minute release stage held the tick lock and every tick
# exited 0 unseen. Same counter and once-per-episode alert as run-tick's refuse(), same supervisor channel.
ZF_LOCK_SKIP_ALERT_THRESHOLD=3
pipeline_lock_skipped() { # holder lock-file
  local count_file="$AGENT_HOME/pipeline-lock-skip-count" alerted_file="$AGENT_HOME/pipeline-lock-skip-alerted" count
  count=$(( $(cat "$count_file" 2>/dev/null || echo 0) + 1 ))
  echo "issue-pipeline: tick skipped, lock busy holder=$1 file=$2 consecutive=$count" >&2
  echo "$count" > "$count_file" 2>/dev/null || true
  if [ "$count" -ge "$ZF_LOCK_SKIP_ALERT_THRESHOLD" ] && [ ! -f "$alerted_file" ]; then
    supervisor_inbox_append tick-outage "cause=pipeline-lock-busy skips=$count file=$2" 2>/dev/null || true
    touch "$alerted_file" 2>/dev/null || true
  fi
}
pipeline_lock_acquired() { # a tick that got the lock ends the episode
  local alerted_file="$AGENT_HOME/pipeline-lock-skip-alerted"
  if [ -f "$alerted_file" ]; then
    supervisor_inbox_append tick-recovery "" 2>/dev/null || true
    rm -f -- "$alerted_file"
  fi
  rm -f -- "$AGENT_HOME/pipeline-lock-skip-count"
}

# The stage's lock, taken once before any decision. Tick stages share LOCK_FILE (a slice inherits its parent's
# fd 9); the delegated release slice excludes only another release run, via RELEASE_STAGE_LOCK_FILE.
pipeline_acquire_lock() {
  local RELEASE_STAGE_LOCK_FILE="${RELEASE_STAGE_LOCK_FILE:-$AGENT_HOME/release-stage.lock}"
  if [ "$PIPELINE_STAGE" = release ] && [ "${ZF_RELEASE_TRAIN_DELEGATE:-0}" = 1 ]; then
    exec {RELEASE_LOCK_FD}>"$RELEASE_STAGE_LOCK_FILE" # not fd 9: a slice's inherited tick lock stays open
    # A bare -n attempt exited 0 silently and the train logged "delegated" (2026-10-22).
    flock -w "${ZF_RELEASE_DELEGATE_LOCK_WAIT_SECONDS:-600}" "$RELEASE_LOCK_FD" || {
      echo "issue-pipeline: release delegate found the release lock busy ($RELEASE_STAGE_LOCK_FILE); the next train retries" >&2
      exit 75
    }
    return 0
  fi
  if [ -z "${ZF_PIPELINE_SLICE_TICK:-}" ]; then exec 9>"$LOCK_FILE"; fi
  if flock -n 9; then
    [ -n "${ZF_PIPELINE_SLICE_TICK:-}" ] || pipeline_lock_acquired
  elif [ "${EVENT_REFILL:-0}" != 0 ]; then
    echo "issue-pipeline: refill skipped, lock busy file=$LOCK_FILE" >&2
    exit 75
  else
    pipeline_lock_skipped "stage-${PIPELINE_STAGE:-none}" "$LOCK_FILE"
    exit 0
  fi
}

# Best-effort durable note for the bell scanner (mac-autopilot/bell.sh reads
# this log; the slice's own stderr goes only to the unit journal, which bell
# never scans). Never fatal: a slice failure must not prevent later work.
pipeline_slice_failure_note() { # tick stage status
  local runtime_dir="${MAC_AUTOPILOT_RUNTIME_DIR:-${REPO_DIR:+$REPO_DIR/.scratch-supervisor/autopi}}"
  [ -n "$runtime_dir" ] || return 0
  mkdir -p -- "$runtime_dir" 2>/dev/null || return 0
  printf '[%s] issue-pipeline: slice-failed tick=%s stage=%s status=%s\n' \
    "$(date -u +%FT%TZ)" "$1" "$2" "$3" >> "$runtime_dir/scheduler.log" 2>/dev/null || true
}

maintenance_step_mark() {
  [ "${DRY_RUN:-0}" = 1 ] && return 0
  printf '%s\n' "$1" > "$AGENT_HOME/night/maintenance-current-step"
}

maintenance_resume_cursor() {
  local resume_file="$1" current_step_file="$2" resume_name="$3" prefix_name="$4" suffix_name="$5" suffix_flag_name="$6"
  local current_step="" resume="" i matched=0
  local -n resume_out="$resume_name" prefix_start_out="$prefix_name" suffix_start_out="$suffix_name" resume_suffix_out="$suffix_flag_name"
  local -n prefix_steps_ref="$7" suffix_steps_ref="$8"
  IFS= read -r resume 2>/dev/null < "$resume_file" || resume=""
  IFS= read -r current_step 2>/dev/null < "$current_step_file" || current_step=""
  resume_out="$resume"
  if [ "${DRY_RUN:-0}" != 1 ] && [ -n "$current_step" ] && [ "$resume" = "$current_step" ]; then
    for i in "${!prefix_steps_ref[@]}"; do
      if [ "${prefix_steps_ref[$i]}" = "$current_step" ]; then
        prefix_start_out=$((i + 1))
        if (( prefix_start_out >= ${#prefix_steps_ref[@]} )); then
          prefix_start_out="${#prefix_steps_ref[@]}"; suffix_start_out=0; resume_suffix_out=1
        fi
        matched=1; break
      fi
    done
    if [ "$matched" != 1 ]; then
      for i in "${!suffix_steps_ref[@]}"; do
        if [ "${suffix_steps_ref[$i]}" = "$current_step" ]; then
          if (( i + 1 < ${#suffix_steps_ref[@]} )); then
            suffix_start_out=$((i + 1)); resume_suffix_out=1
          else
            prefix_start_out=0; suffix_start_out=0; resume_suffix_out=0
          fi
          matched=1; break
        fi
      done
    fi
    if [ "$matched" = 1 ]; then
      echo "issue-pipeline: maintenance skipped killed step=$current_step; resuming after it" >&2
      rm -f -- "$current_step_file"
      return 0
    fi
  fi
  for i in "${!prefix_steps_ref[@]}"; do
    if [ "${prefix_steps_ref[$i]}" = "$resume" ]; then prefix_start_out="$i"; fi
  done
  for i in "${!suffix_steps_ref[@]}"; do
    if [ "${suffix_steps_ref[$i]}" = "$resume" ]; then suffix_start_out="$i"; resume_suffix_out=1; fi
  done
}

pipeline_slice_overrun_note() { # stage
  local stage="$1" current_step=""
  if [ "$stage" = maintenance ]; then
    IFS= read -r current_step 2>/dev/null < "$AGENT_HOME/night/maintenance-current-step" || current_step=""
    if [ -n "$current_step" ]; then
      echo "issue-pipeline: slice overrun stage=maintenance step=$current_step; continuing other stages" >&2
      printf '%s\n' "$current_step" > "$AGENT_HOME/night/maintenance-resume" \
        || echo "issue-pipeline: could not persist maintenance resume step=$current_step" >&2
      return 0
    fi
  fi
  echo "issue-pipeline: slice overrun stage=$stage; continuing other stages" >&2
}

run_pipeline_slices() {
  local scheduler="$1" mode stage budget status=0 started tick="" deadline night
  exec 9>"$LOCK_FILE"
  flock -n 9 || { pipeline_lock_skipped slice-runner "$LOCK_FILE"; return 0; }
  pipeline_lock_acquired
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
      recut) budget=60 ;; release) budget=120 ;; maintenance) budget=150 ;;
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
      0) [ "$stage" != maintenance ] || rm -f -- "$AGENT_HOME/night/maintenance-current-step" ;;
      "$ZF_SLICE_DEFER_STATUS") [ "$stage" != maintenance ] || rm -f -- "$AGENT_HOME/night/maintenance-current-step"; echo "issue-pipeline: slice deferred stage=$stage status=$status (claim/admission said not-now); continuing other stages" >&2 ;;
      124|137) pipeline_slice_overrun_note "$stage" ;;
      *)
        [ "$stage" != maintenance ] || rm -f -- "$AGENT_HOME/night/maintenance-current-step"
        echo "issue-pipeline: slice failed stage=$stage status=$status; isolating this slice and continuing other stages" >&2
        pipeline_slice_failure_note "$tick" "$stage" "$status"
        ;;
    esac
  done
  echo "issue-pipeline: slice-summary tick=$tick status=0 completed=1" >&2
  return 0
}
