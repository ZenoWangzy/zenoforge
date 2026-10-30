#!/usr/bin/env bash
# Each serial decision stage owns a hard slice; an overrun cannot eat the tail.
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
      0) ;; 124|137) echo "issue-pipeline: slice overrun stage=$stage; continuing other stages" >&2 ;;
      *) failed=1 ;;
    esac
  done
  echo "issue-pipeline: slice-summary tick=$tick status=$failed completed=1" >&2
  return "$failed"
}
