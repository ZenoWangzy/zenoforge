
# quarantine_scope <stage> [package_dir] -> "implement" or "implement@packages/foo"
quarantine_scope() {
  local stage="$1" pkg="${2:-}"
  if [ -n "$pkg" ]; then echo "$stage@$pkg"; else echo "$stage"; fi
}


quarantine_file() { echo "$QUARANTINE_DIR/$(env_fault_key "$1").json"; }


# quarantine_notification_should_send <scope> <edge> <now> -- allow one
# quarantine edge notification per scope/window, retaining edge count locally.
quarantine_notification_should_send() {
  agent_pipeline_write_guard quarantine_notification_should_send "$AGENT_HOME" "$QUARANTINE_NOTIFICATION_DIR" || return 1
  local scope="$1" edge="$2" now="$3" f since edges
  f="$QUARANTINE_NOTIFICATION_DIR/$(env_fault_key "quarantine:$scope").json"
  if [ -f "$f" ]; then
    since="$(jq -r '.since // 0' "$f" 2>/dev/null || echo 0)"
    case "$since" in ''|*[!0-9]*) since=0 ;; esac
    if [ "$since" -gt 0 ] && [ $((now - since)) -lt "$QUARANTINE_NOTIFICATION_WINDOW_SECONDS" ]; then
      edges="$(jq -r '.edges // 0' "$f" 2>/dev/null || echo 0)"
      case "$edges" in ''|*[!0-9]*) edges=0 ;; esac
      if ! jq --arg edge "$edge" --argjson edges "$((edges + 1))" --argjson now "$now" \
        '.edges = $edges | .last_edge = $edge | .last_edge_at = $now' "$f" > "$f.tmp" || ! mv "$f.tmp" "$f"; then
        rm -f "$f.tmp"
        echo "quarantine_notification_should_send: could not update $f -- suppressing repeat notification" >&2
      fi
      return 1
    fi
  fi
  mkdir -p "$QUARANTINE_NOTIFICATION_DIR"
  if ! jq -n --arg scope "$scope" --arg edge "$edge" --argjson now "$now" \
    '{scope: $scope, since: $now, edges: 1, last_edge: $edge, last_edge_at: $now}' > "$f.tmp" || ! mv "$f.tmp" "$f"; then
    rm -f "$f.tmp"
    echo "quarantine_notification_should_send: could not create $f -- suppressing notification" >&2
    return 1
  fi
  return 0
}


# quarantine_supervisor_notice <scope> <edge> <detail> -- records one internal
# quarantine notice. Quarantine is pipeline state, never maintainer mail.
quarantine_supervisor_notice() {
  local scope="$1" edge="$2" detail="$3"
  if ! supervisor_inbox_append pipeline-quarantine "scope=$scope edge=$edge detail=$detail"; then
    echo "quarantine_supervisor_notice: could not queue notice in $AGENT_HOME/supervisor-inbox" >&2
    return 1
  fi
}


# quarantine_open <scope> <signature> <detail> <hit_count> [now] -- creates
# the quarantine (no-op if one is already open for the scope) and queues one
# supervisor notice per scope/window, not one for every open/lift edge.
quarantine_open() {
  local scope="$1" signature="$2" detail="$3" hits="$4" now="${5:-$(date +%s)}" f
  agent_pipeline_write_guard quarantine_open "$AGENT_HOME" "$QUARANTINE_DIR" || return 1
  f="$(quarantine_file "$scope")"
  [ -f "$f" ] && return 0
  if [ "$DRY_RUN" = "1" ]; then
    echo "[dry-run] quarantine_open scope=$scope signature=$signature hits=$hits" >&2
    return 0
  fi
  mkdir -p "$QUARANTINE_DIR"
  # $detail can carry a gate log tail (run-implement.sh's record_env_fault
  # calls, up to 80 lines of build/test output) -- jq_arg_file(), not --arg.
  local detail_file
  detail_file="$(jq_arg_file "$detail")"
  jq -n --arg s "$scope" --arg sig "$signature" --rawfile d "$detail_file" --argjson now "$now" --argjson hits "$hits" \
    --argjson first "$QUARANTINE_CANARY_INITIAL_SECONDS" \
    '{scope: $s, signature: $sig, detail: $d, since: $now, hits: $hits, canaries: 0, next_canary_at: ($now + $first), last_canary_at: null, repair_tried: false}' \
    > "$f.tmp" && mv "$f.tmp" "$f"
  rm -f "$detail_file"
  quarantine_notification_should_send "$scope" open "$now" || return 0
  quarantine_supervisor_notice "$scope" open "$signature hits=$hits $detail" || return 0
}


# quarantine_lift <scope> <why> [now]
quarantine_lift() {
  local scope="$1" why="$2" now="${3:-$(date +%s)}" f signature lock_fd episode_id
  agent_pipeline_write_guard quarantine_lift "$AGENT_HOME" "$QUARANTINE_DIR" || return 1
  f="$(quarantine_file "$scope")"
  [ -f "$f" ] || return 0
  if [ "$DRY_RUN" = "1" ]; then
    echo "[dry-run] quarantine_lift scope=$scope why=$why" >&2
    return 0
  fi
  signature="$(jq -r '.signature // empty' "$f" 2>/dev/null || true)"
  if [ "$signature" = env:main-ci-red ]; then
    mkdir -p "$AGENT_HOME/locks" || return 1
    exec {lock_fd}>"$AGENT_HOME/locks/main-ci-red.lock" || return 1
    flock -x "$lock_fd" || { exec {lock_fd}>&-; return 1; }
    [ -f "$f" ] || { unlock_fd "$lock_fd"; return 0; }
    episode_id="$(main_ci_red_episode_ensure_open_event "$f")" || { unlock_fd "$lock_fd"; return 1; }
    main_ci_red_episode_append_lift "$f" "$episode_id" "$why" "$now" || { unlock_fd "$lock_fd"; return 1; }
    rm -f "$f" || { unlock_fd "$lock_fd"; return 1; }
    unlock_fd "$lock_fd"
  else
    rm -f "$f"
  fi
  quarantine_notification_should_send "$scope" lift "$now" || return 0
  quarantine_supervisor_notice "$scope" lift "$why" || return 0
}


# quarantine_decision <scope> [now] -> "clear" (no quarantine), "canary"
# (quarantined, but a probe dispatch is due now), "open" (blocked).
quarantine_decision() {
  local scope="$1" now="${2:-$(date +%s)}" f next signature
  f="$(quarantine_file "$scope")"
  [ -f "$f" ] || { echo clear; return 0; }
  signature="$(jq -r '.signature // empty' "$f" 2>/dev/null)"
  # Capacity gates and operator pauses (ops:*) lift on their own condition, never
  # on a timed probe: the 2026-10-02 advisor pause would have re-sent answered
  # tickets to the web advisor at its first canary.
  case "$signature" in
    env:ci-runner-capacity|env:build-capacity|env:main-ci-red|ops:*) echo open; return 0 ;;
  esac
  next="$(jq -r '.next_canary_at // 0' "$f" 2>/dev/null || echo 0)"
  if [ "$now" -ge "$next" ]; then echo canary; else echo open; fi
}


# quarantine_mark_canary <scope> [now] -- one dispatch was let through;
# the next canary is due after an exponentially longer wait (capped), so a
# second candidate this same tick already sees "open".
quarantine_mark_canary() {
  local scope="$1" now="${2:-$(date +%s)}" f canaries wait
  agent_pipeline_write_guard quarantine_mark_canary "$AGENT_HOME" "$QUARANTINE_DIR" || return 1
  f="$(quarantine_file "$scope")"
  [ -f "$f" ] || return 0
  [ "$DRY_RUN" = "1" ] && { echo "[dry-run] quarantine_mark_canary scope=$scope" >&2; return 0; }
  canaries="$(jq -r '.canaries // 0' "$f")"
  wait=$((QUARANTINE_CANARY_INITIAL_SECONDS * (1 << (canaries + 1))))
  [ "$wait" -gt "$QUARANTINE_CANARY_MAX_SECONDS" ] && wait="$QUARANTINE_CANARY_MAX_SECONDS"
  jq --argjson now "$now" --argjson wait "$wait" \
    '.canaries = ((.canaries // 0) + 1) | .last_canary_at = $now | .next_canary_at = ($now + $wait)' \
    "$f" > "$f.tmp" && mv "$f.tmp" "$f"
}


# quarantine_scopes_for <stage> <expected_packages_json> -> every quarantine
# scope that would block this dispatch: the stage-wide one, plus any
# package-scoped one whose package the candidate's expected_packages touch
# (same prefix rule as gate 4, via path_in_expected_packages).
quarantine_scopes_for() {
  local stage="$1" expected_json="${2:-[]}" f scope pkg
  echo "$stage"
  [ -d "$QUARANTINE_DIR" ] || return 0
  for f in "$QUARANTINE_DIR"/*.json; do
    [ -f "$f" ] || continue
    scope="$(jq -r '.scope // empty' "$f" 2>/dev/null)"
    case "$scope" in
      "$stage@"*) pkg="${scope#*@}" ;;
      *) continue ;;
    esac
    path_in_expected_packages "$expected_json" "$pkg" && echo "$scope"
  done
}


# stage_dispatch_allowed <stage> [expected_packages_json] [now] [red_surface_json] [roadmap_epic] -> 0 if the
# scheduler may dispatch this candidate now (marking a canary when that is
# what lets it through), 1 if a quarantine blocks it. Logs once per
# blocked candidate.
stage_dispatch_allowed() {
  local stage="$1" expected_json="${2:-[]}" now="${3:-$(date +%s)}" red_surface="${4:-${2:-[]}}" epic="${5:-}" scope decision blocked=0
  local -a canary_scopes=()
  STAGE_DISPATCH_BLOCKING_SCOPES=""
  while IFS= read -r scope; do
    [ -z "$scope" ] && continue
    if [ "$stage" = implement ] && [ "$scope" = implement ] \
      && [ "$(jq -r '.signature // empty' "$(quarantine_file implement)" 2>/dev/null)" = env:main-ci-red ]; then
      if main_ci_red_candidate_allowed "$red_surface" "$epic"; then
        continue
      fi
      blocked=1
      STAGE_DISPATCH_BLOCKING_SCOPES="${STAGE_DISPATCH_BLOCKING_SCOPES:+${STAGE_DISPATCH_BLOCKING_SCOPES}、}$scope"
      continue
    fi
    decision="$(quarantine_decision "$scope" "$now")"
    case "$decision" in
      clear) ;;
      canary) canary_scopes+=("$scope") ;;
      open)
        blocked=1
        STAGE_DISPATCH_BLOCKING_SCOPES="${STAGE_DISPATCH_BLOCKING_SCOPES:+${STAGE_DISPATCH_BLOCKING_SCOPES}、}$scope" ;;
    esac
  done < <(quarantine_scopes_for "$stage" "$expected_json")
  if [ "$blocked" = "1" ]; then
    echo "issue-pipeline: $stage dispatch blocked by an open quarantine (env fault); see $QUARANTINE_DIR" >&2
    return 1
  fi
  for scope in "${canary_scopes[@]:-}"; do
    [ -z "$scope" ] && continue
    echo "issue-pipeline: $stage dispatch let through as a canary for quarantine $scope" >&2
    quarantine_mark_canary "$scope" "$now"
  done
  return 0
}


# legs_executable_check -- once per tick, before reconcile_quarantines: is
# every leg's wrapper actually executable in the checkout this tick runs
# from? 2026-09-15 01:06:32, zf-advisor-1131.service: the advisor leg's
# first-ever automatic dispatch died at `status=203/EXEC` -- run-advisor.sh
# had been committed without its executable bit, so systemd could not spawn
# it, before a line of its logic ran; every needs-advisor ticket would have
# failed identically every tick, and a failed unit looks the same whether
# the leg refused the ticket or never ran. A leg that cannot execute is an
# OUTAGE: it opens a stage quarantine under a signature with a probe (the
# mode bit itself), which lifts on the tick after the fix lands, and records
# the fault locally -- distinguishable from a verdict by construction.
legs_executable_check() {
  local stage script
  for stage in triage advisor recut release; do
    script="$ZF_ENGINE_DIR/run-$stage.sh"
    # release is a pack leg: a deployment that ships no run-release.sh has no such leg (a present, non-executable one is still an outage).
    [ "$stage" = release ] && [ ! -e "$script" ] && continue
    [ -x "$script" ] && continue
    echo "issue-pipeline: leg $stage cannot execute -- $script is not executable (git mode bit); this is an outage, not a verdict" >&2
    quarantine_open "$stage" "env:leg-not-executable:$stage" "$script is not executable in the checkout this tick runs from (the file's git mode bit is missing)" 1
  done
}


# reconcile_quarantines [now] -- once per tick, before any dispatch:
#   (a) open a quarantine for every signature that turned systemic since
#       its scope was last quarantined (or was never);
#   (b) for every open quarantine: probe -> lift; else repair once ->
#       re-probe -> lift; else if a canary went through and no new fault
#       followed within the grace period -> lift ("canary survived"). An
#       advisor canary is asynchronous: its pending web-advisor-provider job must be
#       polled before silence can count as survival.
reconcile_quarantines() {
  local now="${1:-$(date +%s)}" f signature scope hits detail last_canary repair_tried newer probe_rc repair_rc recovery_rc
  MAIN_CI_RED_RECONCILIATION_DONE=0
  MAIN_CI_RED_RECOVERY_HELD=0
  if [ -d "$ENV_FAULT_DIR" ]; then
    for f in "$ENV_FAULT_DIR"/*.log; do
      [ -f "$f" ] || continue
      signature="$(tail -n 1 "$f" | cut -f4)"
      [ -n "$signature" ] || continue
      # These signatures are opened at the observed gate and lifted by their
      # live probe. Generic history replay would reopen a recovered episode.
      case "$signature" in
        env:model-config:*|env:ci-runner-capacity|env:build-capacity|env:main-ci-red|env:provider-outage|env:unit-memory-cap|env:ci-checkout|env:docker-hub-dns) continue ;;
      esac
      env_fault_is_systemic "$signature" "$now" || continue
      if [ "$signature" = "env:network-timeout" ]; then
        # Require both repeated ticket failures and a current API probe
        # failure. A successful or unavailable probe keeps the timeout at
        # per-call scope; unknown is not evidence for blocking a whole stage.
        probe_rc=0
        env_fault_probe "$signature" || probe_rc=$?
        [ "$probe_rc" -eq 1 ] || continue
      fi
      scope="$(env_fault_latest_scope "$signature")"
      [ -n "$scope" ] || continue
      hits="$(env_fault_lines_since "$signature" "$((now - ENV_FAULT_WINDOW_SECONDS))" | wc -l)"
      detail="$(tail -n 1 "$f" | cut -f5)"
      quarantine_open "$scope" "$signature" "$detail" "$hits" "$now"
    done
  fi
  [ -d "$QUARANTINE_DIR" ] || return 0
  for f in "$QUARANTINE_DIR"/*.json; do
    [ -f "$f" ] || continue
    scope="$(jq -r '.scope // empty' "$f")"
    signature="$(jq -r '.signature // empty' "$f")"
    last_canary="$(jq -r '.last_canary_at // empty' "$f")"
    repair_tried="$(jq -r '.repair_tried // false' "$f")"
    [ -n "$scope" ] && [ -n "$signature" ] || continue
    # `|| probe_rc=$?` on purpose: the callers run under `set -e`, and a
    # bare probe returning 1 ("still broken", the common case) would
    # otherwise abort the whole tick.
    probe_rc=0
    env_fault_probe "$signature" || probe_rc=$?
    if [ "$signature" = env:main-ci-red ]; then
      MAIN_CI_RED_RECONCILIATION_DONE=1
      # Main CI red is lifted only by an exact-current-main green CI run with
      # Postsubmit and static-guard evidence. Silence after a canary, a failed
      # dispatch, or an unreadable GitHub result is not validation evidence.
      if [ "$probe_rc" = 0 ]; then
        quarantine_lift "$scope" "exact main CI validation passed on current main (Postsubmit and static guards)" "$now"
      elif [ "$probe_rc" = 1 ] && [ "${DRY_RUN:-0}" != 1 ]; then
        recovery_rc=0
        ZF_REPO_DIR="$REPO_DIR" bash "${ZF_ENGINE_DIR:-$REPO_DIR/engine}/night/main-ci-recovery.sh" reconcile-red || recovery_rc=$?
        case "$recovery_rc" in
          0) ;;
          10|11|12) MAIN_CI_RED_RECOVERY_HELD=1 ;;
          *)
            MAIN_CI_RED_RECOVERY_HELD=1
            echo "quarantine: main-CI recovery reconciliation failed (exit $recovery_rc); keeping quarantine" >&2
            ;;
        esac
      else
        MAIN_CI_RED_RECOVERY_HELD=1
      fi
      continue
    fi
    case "$probe_rc" in
      0) quarantine_lift "$scope" "探测通过（$signature 已不再出现）" "$now"; continue ;;
      1)
        if [ "$repair_tried" != "true" ]; then
          repair_rc=0
          env_fault_repair "$signature" || repair_rc=$?
          if [ "$repair_rc" -ne 75 ]; then
            jq '.repair_tried = true' "$f" > "$f.tmp" && mv "$f.tmp" "$f"
          fi
          if [ "$repair_rc" = "0" ]; then
            probe_rc=0
            env_fault_probe "$signature" || probe_rc=$?
            if [ "$probe_rc" = "0" ]; then
              quarantine_lift "$scope" "机器自动修复后探测通过（${signature}）" "$now"
              continue
            fi
          fi
        fi
        ;;
      *) ;;
    esac
    if [ -n "$last_canary" ] && [ "$((now - last_canary))" -ge "$QUARANTINE_CANARY_GRACE_SECONDS" ]; then
      # A dispatched advisor web job has not tested recovery until its own
      # result is consumed. The scheduler admits that poll independently of
      # this quarantine; until then, silence only means nobody has learned
      # whether the canary passed.
      if [ "$scope" = "advisor" ] && [ -n "$(web_advisor_provider_job_candidates)" ]; then
        continue
      fi
      newer="$(env_fault_lines_since "$signature" "$last_canary" | wc -l)"
      if [ "$newer" -eq 0 ]; then
        quarantine_lift "$scope" "试探派发后 $((QUARANTINE_CANARY_GRACE_SECONDS / 60)) 分钟内没有再出现同一故障（${signature}）" "$now"
        continue
      fi
    fi
  done
}
