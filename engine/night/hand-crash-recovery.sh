#!/usr/bin/env bash
# Recovery is driven by explicit terminal acknowledgement, never report presence.
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)/land-queue-state.sh"
hand_crash_report_terminal() {
  local report="$1" started_at="${2:-0}" owner="${3:-}" worktree="${4:-}" report_mtime report_at=0 header ticket=""
  [[ -f "$report" ]] || return 1
  report_mtime="$(stat -c %y -- "$report" 2>/dev/null || true)"
  report_at="$(date -d "$report_mtime" +%s%N 2>/dev/null || echo 0)"
  [[ "$started_at" =~ ^[0-9]+$ ]] || started_at=0
  (( started_at == 0 || report_at >= started_at )) || return 1
  header="$(sed -n '1p' "$report")"
  case "$header" in
    'STATUS: DONE'|'STATUS: DONE '*|'STATUS: FAILED'|'STATUS: FAILED '*|'STATUS: NEEDS-DECISION'|'STATUS: NEEDS-DECISION '*|'STATUS: NEEDS-RELEASE'|'STATUS: NEEDS-RELEASE '*|'STATUS: NEEDS-ACCESS'|'STATUS: NEEDS-ACCESS '*|'STATUS: FOLLOWUP('*|'STATUS: BLOCKED-ON '*|'STATUS: LANDED'|'STATUS: LANDED '*) return 0 ;;
    'STATUS: LANDING-QUEUED'|'STATUS: LANDING-QUEUED '*)
      [[ "$header" == 'STATUS: LANDING-QUEUED' ]] || ticket="${header#STATUS: LANDING-QUEUED }"
      land_queue_owner_ticket "$owner" "$worktree" "$report" "$ticket" >/dev/null; return $? ;;
    'STATUS: LANDING'|'STATUS: LANDING '*) grep -Eq '^LANDED [0-9a-f]{40}([[:space:]]|$)' "$report"; return $? ;;
  esac
  return 1
}

hand_provider_recovery_notice() {
  local name="$1" role="$2" episode="$3" stage="$4" kind="$5" model="$6" worktree="$7" report="$8" key
  key="hand-provider-recovery:$name:$episode:$stage"
  AGENT_HOME="${AGENT_HOME:-${H:-}}" supervisor_inbox_append_once "$key" \
    "hand-agent-provider-recovery name=$name role=$role stage=$stage kind=$kind model=$model worktree=$worktree report=$report"
}

hand_provider_recovery_claim() {
  local name="$1" episode="$2" stage="$3" next_stage="$4" state="$NIGHT/crash-recovery/provider-$name-$episode.stage"
  local stored lock_fd tmp
  mkdir -p -- "${state%/*}" || return 1
  exec {lock_fd}>"$state.lock" || return 1
  flock -x "$lock_fd" || { exec {lock_fd}>&-; return 1; }
  stored="$(cat -- "$state" 2>/dev/null || printf '%s' "$stage")"
  [[ "$stored" =~ ^[0-9]+$ ]] || stored="$stage"
  if (( stored > stage )); then
    flock -u "$lock_fd" || true
    exec {lock_fd}>&-
    return 2
  fi
  tmp="$(mktemp "${state}.XXXXXX")" || { flock -u "$lock_fd" || true; exec {lock_fd}>&-; return 1; }
  if ! printf '%s\n' "$next_stage" > "$tmp" || ! mv -f -- "$tmp" "$state"; then
    rm -f -- "$tmp"
    flock -u "$lock_fd" || true
    exec {lock_fd}>&-
    return 1
  fi
  flock -u "$lock_fd" || true
  exec {lock_fd}>&-
}

hand_provider_recovery_failed() {
  local name="$1" role="$2" episode="$3" stage="$4" kind="$5" model="$6" worktree="$7" report="$8" reason="$9" key tmp first
  if hand_crash_report_terminal "$report" "$episode" "$name" "$worktree"; then return 0; fi
  key="hand-provider-recovery:$name:$episode:failed"
  AGENT_HOME="${AGENT_HOME:-${H:-}}" supervisor_inbox_append_once "$key" \
    "hand-agent-provider-recovery-failed name=$name role=$role stage=$stage kind=$kind model=$model reason=$reason worktree=$worktree report=$report" || true
  mkdir -p -- "${report%/*}" || return 1
  tmp="$(mktemp "${report}.provider-recovery.XXXXXX")" || return 1
  {
    printf 'STATUS: FAILED\nReason: Codex provider recovery stopped after stage %s (%s): %s.\n' "$stage" "$kind" "$reason"
    if [ -f "$report" ]; then
      first="$(sed -n '1p' "$report")"
      if [[ "$first" == STATUS:* ]]; then tail -n +2 -- "$report"; else cat -- "$report"; fi
    fi
  } > "$tmp" || { rm -f -- "$tmp"; return 1; }
  mv -f -- "$tmp" "$report"
}

# Dispatch and crash recovery share this path so one run gets one original-model
# retry and one role-configured fallback, with the same report and inbox key.
hand_provider_recover() {
  local name="$1" worktree="$2" brief="$3" role="$4" report="$5" attempt="$6" note="$7"
  local stage="$8" episode="$9" kind="${10}" started_at="${11}"
  local next_stage identity provider model effort status
  [[ "$stage" =~ ^[0-9]+$ ]] || stage=0
  [[ "$episode" =~ ^[0-9]+$ ]] || episode="$started_at"
  if hand_crash_report_terminal "$report" "$episode" "$name" "$worktree"; then return 0; fi
  if (( stage >= 2 )); then
    hand_provider_recovery_failed "$name" "$role" "$episode" "$stage" "$kind" "exhausted" "$worktree" "$report" 'both configured model attempts failed' || true
    return 1
  fi
  next_stage=$((stage + 1))
  if (( next_stage == 1 )); then
    identity="$(model_policy identity "$role" 2>/dev/null || true)"
  else
    identity="$(model_policy fallback-identity "$role" 2>/dev/null || true)"
    if [ -z "$identity" ]; then
      hand_provider_recovery_failed "$name" "$role" "$episode" "$stage" "$kind" 'unconfigured' "$worktree" "$report" 'role has no valid fallback_model' || true
      return 1
    fi
  fi
  IFS=: read -r provider model effort <<< "$identity"
  if [ "$provider" != codex ] || [ -z "$model" ] || [ -z "$effort" ]; then
    hand_provider_recovery_failed "$name" "$role" "$episode" "$stage" "$kind" 'unconfigured' "$worktree" "$report" 'role identity is not a valid Codex model' || true
    return 1
  fi
  if hand_provider_recovery_claim "$name" "$episode" "$stage" "$next_stage"; then
    :
  else
    status=$?
    [ "$status" = 2 ] && return 0
    hand_provider_recovery_failed "$name" "$role" "$episode" "$stage" "$kind" "$model" "$worktree" "$report" 'provider retry claim failed' || true
    return 1
  fi
  if ! hand_provider_recovery_notice "$name" "$role" "$episode" "$next_stage" "$kind" "$model" "$worktree" "$report"; then
    hand_provider_recovery_failed "$name" "$role" "$episode" "$stage" "$kind" "$model" "$worktree" "$report" 'supervisor inbox write failed' || true
    return 1
  fi
  sleep "${HAND_PROVIDER_RECOVERY_BACKOFF_SECONDS:-15}"
  if hand_crash_report_terminal "$report" "$episode" "$name" "$worktree"; then return 0; fi
  if HAND_ISSUES="${HAND_ISSUES:-}" HAND_NODES="${HAND_NODES:-}" \
    bash "$REPO_DIR/engine/night/dispatch.sh" \
      "$worktree" "$brief" "$name" "$role" "$report" "$attempt" "$note" "$next_stage" "$episode"; then
    return 0
  else
    status=$?
  fi
  if hand_crash_report_terminal "$report" "$episode" "$name" "$worktree"; then return "$status"; fi
  hand_provider_recovery_failed "$name" "$role" "$episode" "$stage" "$kind" "$model" "$worktree" "$report" "retry dispatch failed (exit $status)" || true
  return "$status"
}
