
# Start-silent breaker (queue row 935): a worker counts once it is this many minutes old, the newest TRIP silent ones open it,
# and while open one start per PROBE_MINUTES is let through.
WORKER_START_SILENT_MINUTES="${WORKER_START_SILENT_MINUTES:-5}"
WORKER_START_SILENT_TRIP="${WORKER_START_SILENT_TRIP:-3}"
WORKER_START_SILENT_PROBE_MINUTES="${WORKER_START_SILENT_PROBE_MINUTES:-15}"

capture_worker_stdout_report() { # report-path command...
  local report="$1" partial="${1}.partial" status=0
  shift
  "$@" > "$partial" || status=$?
  if (( status != 0 )); then return "$status"; fi
  [[ -s "$partial" ]] || return 1
  if [[ -e "$report" ]]; then
    mv -f -- "$partial" "${report}.final-message"
  else
    # A worker may have written its prompted report while the CLI was running.
    # Never let this final-message capture replace that report, including a
    # report that appears between the existence check and the rename.
    mv -n -- "$partial" "$report" || return 1
    [[ ! -e "$partial" ]] || mv -f -- "$partial" "${report}.final-message"
  fi
}

scheduler_mark_canary_after_worker_start() ( # issue; consume a blocker-route canary reservation after dispatch starts
  local state scope
  state="$(scheduler_issue_state "$1")" || return 1
  scope="$(jqf -r '.run.conclusion.canary_reserved_scopes // empty' <<<"$state")" || return 1
  [[ -n "$scope" ]] || return 0
  REPO_DIR="$ROOT"
  source "$SCHEDULER_AGENT_LIB" || return 1
  state_merge "$1" 'del(.run.conclusion.canary_reserved_scopes)' || return 1
  quarantine_mark_canary_scope_list "$scope"
)
scheduler_clear_canary_after_failed_start() (
  [[ "$1" =~ ^[1-9][0-9]*$ ]] || return 0
  REPO_DIR="$ROOT"
  source "$SCHEDULER_AGENT_LIB" || return 1
  state_merge "$1" 'del(.run.conclusion.canary_reserved_scopes)'
)
dispatch_close_merged_pending_unit() {
  local id="$1" issue="$2" state pr refs_pr refs_status=0 pr_number merged_at ruling_status=0
  [[ "$issue" =~ ^[1-9][0-9]*$ ]] || return 1
  state="$(scheduler_issue_state_readonly "$issue" 2>/dev/null)" || { say "implement-pending unit=$id: issue state unavailable; dispatch held"; return 0; }
  if jqf -e '.state == "ready-for-agent"' <<<"$state" >/dev/null 2>&1; then
    jqf -e '.hold == null' <<<"$state" >/dev/null 2>&1 || { say "implement-pending unit=$id: issue is held; dispatch held"; return 0; }
    refs_pr="$(intake_merged_refs_pr_for_issue "$issue")" || refs_status=$?
    if (( refs_status == 2 )); then
      say "implement-pending unit=$id: merged Refs PR check unavailable; dispatch held"
      return 0
    elif (( refs_status == 0 )); then
      IFS=$'\t' read -r pr_number merged_at <<<"$refs_pr"
      intake_issue_ruling_after_merge "$issue" "$merged_at" || ruling_status=$?
      if (( ruling_status == 1 )); then
        scheduler_conclude_merged_pr "$issue" "$pr_number" \
          || say "implement-pending unit=$id: merged Refs PR #$pr_number could not conclude issue #$issue; dispatch held"
        set_unit "$id" "if .stage == \"implement-pending\" then $(hist merged-refs-delivered "merged Refs PR #$pr_number superseded this implementation") | .stage=\"closed\" | .note=$(js "superseded by merged Refs PR #$pr_number") else . end" \
          || say "implement-pending unit=$id: could not close after merged Refs PR #$pr_number; dispatch held"
        return 0
      elif (( ruling_status != 0 )); then
        say "implement-pending unit=$id: merged Refs ruling state unavailable; dispatch held"
        return 0
      fi
    fi
  fi
  jqf -e '.state == "awaiting-release" and .run.outcome == "merged"' <<<"$state" >/dev/null 2>&1 || return 1
  pr="$(jqf -r '.run.evidence.pr_number // empty' <<<"$state")" || { say "implement-pending unit=$id: merged issue evidence unreadable; dispatch held"; return 0; }
  [[ "$pr" =~ ^[1-9][0-9]*$ ]] || { say "implement-pending unit=$id: merged issue has no PR evidence; dispatch held"; return 0; }
  set_unit "$id" "if .stage == \"implement-pending\" then $(hist merged-delivered "merged PR #$pr moved issue #$issue to awaiting-release") | .stage=\"closed\" | .note=$(js "issue #$issue is awaiting release after merged PR #$pr") else . end" \
    || say "implement-pending unit=$id: could not close the merged issue row; dispatch held"
  return 0
}

# Start-silent breaker: when the TRIP newest implement/repair/supervise workers (started at least MINUTES ago, after the floor)
# all wrote 0 bytes, starts are broken. Hold every start except one probe per PROBE_MINUTES (only a probe shows a fixed build a
# first byte). A new engine build sets a floor, so the old build's workers stop counting. Returns 1 = hold. The signal is read
# once per scheduler process; the state file $A/start-silent-breaker.json carries engine, floor, open time, alert and probe.
start_silent_breaker() { # worker-type
  local type="$1" file="$A/start-silent-breaker.json" now now_iso build stored floor opened alerted last_probe next old tmp cutoff row log started bytes probe_epoch body closed_log="" decide=0
  local -a rows=() fields=()
  now="$(date +%s)"; now_iso="$(date -u -d "@$now" +%Y-%m-%dT%H:%M:%SZ)"
  build="$(readlink -f -- "${ZF_ENGINE_DIR:-$ROOT/engine}" 2>/dev/null)" || build=""
  build="${build:+$(basename -- "$(dirname -- "$build")")}"; build="${build:-unknown}"
  # No state file, no jq call: a jq failure on a missing file would be logged to scheduler.log on every dispatch.
  if [[ -s "$file" ]]; then
    mapfile -t fields < <(jqf -r '.engine // "", .floor // "", .opened_at // "", (.alerted // false), .last_probe // ""' "$file" 2>/dev/null || true)
  fi
  stored="${fields[0]:-}"; floor="${fields[1]:-}"; opened="${fields[2]:-}"; alerted="${fields[3]:-false}"; last_probe="${fields[4]:-}"
  if [[ -n "$stored" && "$stored" != "$build" ]]; then floor="$now_iso"; opened=""; alerted=false; last_probe=""; fi
  if [[ -z "${START_SILENT_DONE:-}" ]]; then
    START_SILENT_DONE=1; START_SILENT_OPEN=false
    cutoff="$(date -u -d "@$((now - WORKER_START_SILENT_MINUTES * 60))" +%Y-%m-%dT%H:%M:%SZ)"
    mapfile -t rows < <(jqf -r --arg cutoff "$cutoff" --arg floor "$floor" --argjson trip "$WORKER_START_SILENT_TRIP" '
      [(.workers // [])[] | select(.type == "implement" or .type == "repair" or .type == "supervise")
        | select((.started // "") <= $cutoff and (.started // "") >= $floor)]
      | sort_by(.started // "") | reverse | .[0:$trip][] | "\(.log // "-")\t\(.started // "-")"' "$WORKERS" 2>/dev/null || true)
    if (( WORKER_START_SILENT_TRIP > 0 && ${#rows[@]} >= WORKER_START_SILENT_TRIP )); then
      START_SILENT_OPEN=true
      for row in "${rows[@]}"; do
        log="${row%%$'\t'*}"
        if ! bytes="$(stat -c %s -- "$SUP/$log" 2>/dev/null)"; then START_SILENT_OPEN=false; break; fi
        if [[ "$bytes" != 0 ]]; then START_SILENT_OPEN=false; closed_log="$log"; break; fi
      done
    fi
    if [[ "$START_SILENT_OPEN" == true ]]; then
      START_SILENT_N=${#rows[@]}; START_SILENT_FIRST="${rows[-1]%%$'\t'*}"; START_SILENT_SINCE="${rows[-1]#*$'\t'}"
    fi
  fi
  if [[ "${START_SILENT_OPEN:-false}" == true ]]; then
    [[ -n "$opened" ]] || opened="$now_iso"
    if [[ "$alerted" != true ]]; then
      body="WORKER-START-SILENT engine=$build silent=$START_SILENT_N first_log=$START_SILENT_FIRST since=$START_SILENT_SINCE dispatch held, probe every $WORKER_START_SILENT_PROBE_MINUTES min"
      mkdir -p -- "$A/alerts"; printf '[%s] %s\n' "$STAMP" "$body" >> "$A/alerts/slo.md"; say "$body"; alerted=true
    fi
    decide=1
    if [[ "$type" == implement || "$type" == repair || "$type" == supervise ]]; then
      probe_epoch="$(date -u -d "$last_probe" +%s 2>/dev/null)" || probe_epoch=0
      if [[ -z "$last_probe" ]] || (( now - probe_epoch >= WORKER_START_SILENT_PROBE_MINUTES * 60 )); then decide=0; last_probe="$now_iso"; fi
    fi
  elif [[ -n "$opened" ]]; then
    if [[ -n "$closed_log" ]]; then say "start-silent-breaker closed: $closed_log has output"; else say "start-silent-breaker closed"; fi
    opened=""; alerted=false; last_probe=""
  fi
  if [[ "${START_SILENT_OPEN:-false}" == true || -n "$floor" ]]; then
    next="$(jqf -cn --arg engine "$build" --arg floor "$floor" --arg opened "$opened" --argjson alerted "$alerted" --arg last_probe "$last_probe" \
      '{engine:$engine,floor:$floor,opened_at:$opened,alerted:$alerted,last_probe:$last_probe}')"
    old=""
    if [[ -s "$file" ]]; then old="$(jqf -c . "$file" 2>/dev/null || true)"; fi
    if [[ "$next" != "$old" ]]; then
      tmp="$(mktemp "$A/.start-silent.XXXXXX")" && printf '%s\n' "$next" > "$tmp" && mv -f -- "$tmp" "$file"
    fi
  else
    rm -f -- "$file"
  fi
  return "$decide"
}

implementation_prompt_version() {
  local worker_docs_version='' project_instructions_version='' product_skills_version='' product_skills_file="${PRODUCT_LANE_SKILLS:-$HERE/product-lane-skills.txt}"
  local -a sources=(
    scheduler.sh
    scheduler.d/dispatch-queue.sh
    scheduler.d/self-check.sh
    scheduler.d/evals-arbiter.sh
    scheduler.d/footprint.sh
    scheduler.d/footprint-memo.sh
    scheduler.d/reports.sh
    scheduler.d/review-rules.sh
    scheduler.d/worker-command.sh
    ../lesson-recurrence-ranking.mjs
  )
  [[ -z "${IMPLEMENTATION_PROMPT_VERSION:-}" ]] || { printf '%s' "$IMPLEMENTATION_PROMPT_VERSION"; return 0; }
  [[ -r "${WORKER_DOCS_FILE:-}" ]] && worker_docs_version="$(sha256sum < "$WORKER_DOCS_FILE" | cut -d' ' -f1)"
  [[ -r "$ROOT/CLAUDE.md" ]] && project_instructions_version="$(sha256sum < "$ROOT/CLAUDE.md" | cut -d' ' -f1)"
  [[ -r "$product_skills_file" ]] && product_skills_version="$(sha256sum < "$product_skills_file" | cut -d' ' -f1)"
  IMPLEMENTATION_PROMPT_VERSION="$(
    {
      cd -- "$HERE" || exit
      sha256sum -- "${sources[@]}"
      printf 'worker-docs %s\nproject-instructions %s\nproduct-skills %s\n' \
        "$worker_docs_version" "$project_instructions_version" "$product_skills_version"
    } | sha256sum | cut -d' ' -f1
  )" || return 1
  [[ "$IMPLEMENTATION_PROMPT_VERSION" =~ ^[0-9a-f]{64}$ ]] || { IMPLEMENTATION_PROMPT_VERSION=""; return 1; }
  printf '%s' "$IMPLEMENTATION_PROMPT_VERSION"
}

dispatch_claim_clear() {
  SCHEDULER_DISPATCH_CLAIM_KEY=""
  SCHEDULER_DISPATCH_CLAIM_OWNER=""
  SCHEDULER_DISPATCH_UNIT_JSON=""
  SCHEDULER_DISPATCH_START_SILENT_CHECKED=false
}
dispatch_claim_release() {
  local key="${1:-${SCHEDULER_DISPATCH_CLAIM_KEY:-}}" owner="${2:-${SCHEDULER_DISPATCH_CLAIM_OWNER:-}}"
  if [[ -n "$key" && -n "$owner" ]]; then
    coord_release "$key" "$owner" >/dev/null 2>&1 || say "dispatch claim release deferred unit=$(jqf -r '.id // empty' <<<"${SCHEDULER_DISPATCH_UNIT_JSON:-{}")"
  fi
  dispatch_claim_clear
}
dispatch_claim_prepare() {
  local unit="$1" unit_json="$2" type="$3" issue claim_key claim_owner claim_status restored original_row restored_row
  dispatch_claim_clear
  SCHEDULER_DISPATCH_UNIT_JSON="$unit_json"
  coord_remote_enabled || return 0
  if declare -F start_silent_breaker >/dev/null; then
    start_silent_breaker "$type" || { say "dispatch held unit=$unit reason=start-silent-breaker"; return 1; }
    SCHEDULER_DISPATCH_START_SILENT_CHECKED=true
  fi
  issue="$(jqf -r '.issue // empty' <<<"$unit_json")" || return 1
  if [[ "$issue" =~ ^[1-9][0-9]*$ ]]; then
    claim_key="$(coord_issue_key "$issue")" || return 1
  else
    claim_key="$(coord_unit_key "$unit")" || return 1
  fi
  claim_owner="$(coord_new_owner)" || return 1
  [[ -n "$claim_owner" ]] || return 1
  if coord_acquire "$claim_key" "$claim_owner" scheduler-worker "$issue" "$unit" "$type"; then
    :
  else
    claim_status=$?
    say "dispatch held unit=$unit reason=$(if (( claim_status == 1 )); then echo claim-owned; else echo claim-unknown; fi)"
    return 1
  fi
  if ! coord_assert_owned "$claim_key" "$claim_owner" >/dev/null; then
    coord_release "$claim_key" "$claim_owner" >/dev/null 2>&1 || :
    say "dispatch held unit=$unit reason=claim-lost-before-size-admission"
    return 1
  fi
  if [[ "${COORD_REMOTE_RESTORE_REQUIRED:-0}" == 1 ]]; then
    restored="$(jqf -c --arg id "$unit" '[.units[] | select(.id == $id)][0] // empty' "$UNITS")" || {
      coord_release "$claim_key" "$claim_owner" >/dev/null 2>&1 || :
      return 1
    }
    original_row="$(jqf -S -c '.' <<<"$unit_json")" || { coord_release "$claim_key" "$claim_owner" >/dev/null 2>&1 || :; return 1; }
    restored_row="$(jqf -S -c '.' <<<"$restored")" || { coord_release "$claim_key" "$claim_owner" >/dev/null 2>&1 || :; return 1; }
    if [[ -z "$restored" || "$original_row" != "$restored_row" ]]; then
      coord_release "$claim_key" "$claim_owner" >/dev/null 2>&1 || :
      say "dispatch held unit=$unit reason=checkpoint-restored"
      return 1
    fi
    SCHEDULER_DISPATCH_UNIT_JSON="$restored"
  fi
  SCHEDULER_DISPATCH_CLAIM_KEY="$claim_key"
  SCHEDULER_DISPATCH_CLAIM_OWNER="$claim_owner"
}

dispatch() { # type model effort unit log report prompt [sha] [workdir] [pr-head] [new-failure] [provider] [hard] [route-reason] [worker-context-json]
  local type="${1:-}" model="${2:-}" effort="${3:-}" unit="${4:-}" log="${5:-}" report="${6:-}" prompt="${7:-}" sha="${8:-}" workdir="${9:-$ROOT}" pr_head="${10:-}" provider="${12:-$(provider_of "${2:-}")}" hard_escalation="${13:-false}" route_reason="${14:-configured}" worker_context="${15:-}" report_only=false expected_session_id="" pid cache_fresh=false cache_until="$LIVE_WORKER_CACHE_UNTIL" started=$SECONDS elapsed issue claim_key claim_owner claim_status pr_census dispatch_pr dispatch_body guard_env_word install_guard_path worker_exit_file worker_prompt="" worker_prompt_stage="" worker_prompt_source="" worker_prompt_version=""
  local -a launcher=() worker_env=() launch_command=()
  case "$type" in
    implement|repair)
      worker_prompt="engine/mac-autopilot/scheduler.d/dispatch-queue.sh"
      worker_prompt_stage="$type"
      implementation_prompt_version >/dev/null 2>&1 || :
      worker_prompt_version="${IMPLEMENTATION_PROMPT_VERSION:-}"
      ;;
    review|rereview)
      worker_prompt="engine/prompts/review-contract.md"
      worker_prompt_stage=review
      worker_prompt_source="${REVIEW_CONTRACT_MD:-}"
      ;;
    *) worker_prompt_source="" ;;
  esac
  if [[ -n "$worker_prompt_source" && -r "$worker_prompt_source" ]]; then
    if worker_prompt_version="$(sha256sum -- "$worker_prompt_source" 2>/dev/null | cut -d' ' -f1)" \
      && [[ "$worker_prompt_version" =~ ^[0-9a-f]{64}$ ]]; then :; else worker_prompt_version=""; fi
  fi
  if [[ -n "$worker_context" ]]; then
    report_only="$(jqf -r '.incident_report_resume // false' <<<"$worker_context")"
    expected_session_id="$(jqf -r '.incident_report_resume_session_id // empty' <<<"$worker_context")"
  fi
  (( SECONDS < LIVE_WORKER_CACHE_UNTIL )) && cache_fresh=true
  # Start-silent breaker (queue row 935): before any claim, guard-file or other state write. Tests that load only this function's text have no breaker.
  if [[ "${SCHEDULER_DISPATCH_START_SILENT_CHECKED:-false}" == true ]]; then
    SCHEDULER_DISPATCH_START_SILENT_CHECKED=false
  else
    ! declare -F start_silent_breaker >/dev/null || start_silent_breaker "$type" || { dispatch_claim_release; say "dispatch held unit=$unit reason=start-silent-breaker"; return 1; }
  fi
  # Same install-guard PATH shim the session workers run behind (bin/zc, bin/luna): every dispatched model
  # worker gets it (queue row 906), whatever the provider, so an unsafe install or a whole-suite test run is
  # refused and a configured test goes to the test host instead of this host. Review workers share it: git has
  # no wrapper, and a read-only node or bash call passes through. Direct-main keeps its harder test blocker first.
  install_guard_path="${ZF_ENGINE_DIR:-$ROOT/engine}/bin/install-guard"
  worker_env=(env "PATH=$install_guard_path:$PATH")
  if [[ "$(unit_field "$unit" '.lane // empty')" == direct-main ]]; then
    rm -f -- "$SUP/$log.guard-refusals"
    worker_env=(env ZF_NON_PRODUCT_UNIT=1 "ZF_PIPELINE_UNIT=$unit" \
      "ZF_NON_PRODUCT_GUARD_FILE=$SUP/$log.guard-refusals" \
      "PATH=${ZF_ENGINE_DIR:-$ROOT/engine}/non-product-test-shim:$install_guard_path:$PATH")
  fi
  # Worker write guard: a node or python write into the deployment checkout fails loudly (2026-11-07).
  while IFS= read -r guard_env_word; do
    [[ -n "$guard_env_word" ]] && worker_env+=("$guard_env_word")
  done < <(worker_write_guard_env "$workdir" || true)
  # setsid：worker 自成进程组，超时可整组终止（含 codex 子进程）。
  command -v setsid >/dev/null 2>&1 && launcher=(setsid)
  build_codex_command "$type" "$model" "$effort" "$unit" "$prompt" "${11-$prompt}" "$workdir" "$provider" "$report_only" "$expected_session_id" || { dispatch_claim_release; return 1; }
  issue="$(unit_field "$unit" '.issue // empty')"
  if [[ "$issue" =~ ^[1-9][0-9]*$ ]]; then
    claim_key="$(coord_issue_key "$issue")"
  else
    claim_key="$(coord_unit_key "$unit")" || { dispatch_claim_release; say "dispatch held unit=$unit reason=invalid-claim-key"; return 1; }
  fi
  if [[ "$type" == implement && "$issue" =~ ^[1-9][0-9]*$ \
      && "$(unit_field "$unit" '.lane // empty')" == direct-main \
      && "${TICK_DISPATCH_LOCAL_REFILL:-false}" != true ]]; then
    pr_census="$(tick_prs)" || { dispatch_claim_release; say "dispatch held unit=$unit reason=open-PR-census-unknown"; return 1; }
    if jqf -e --arg issue "$issue" \
        'any(.[]; (((.title // "") + " " + (.headRefName // "")) | test("(^|[^0-9])#" + $issue + "([^0-9]|$)")))' \
        <<<"$pr_census" >/dev/null; then
      say "dispatch held unit=$unit reason=open-PR-for-issue"
      dispatch_claim_release
      return 1
    fi
    # 标题/分支没提到 issue 才逐个读正文（列表不再携带 body）；一条读不到也按占用来挡，宁可少派不重派
    while IFS= read -r dispatch_pr; do
      [[ "$dispatch_pr" =~ ^[0-9]+$ ]] || continue
      # 本 shell 直接调，缓存才落得下来（$(...) 里每个单元都会把所有 open PR 的正文重读一遍）
      tick_pr_body "$dispatch_pr" >/dev/null 2>&1 \
        || { dispatch_claim_release; say "dispatch held unit=$unit reason=open-PR-for-issue"; return 1; }
      if grep -qE "(^|[^0-9])#$issue([^0-9]|$)" <<<"${TICK_PR_BODY[$dispatch_pr]}"; then
        say "dispatch held unit=$unit reason=open-PR-for-issue"
        dispatch_claim_release
        return 1
      fi
    done < <(jqf -r '[.[].number] | .[]' <<<"$pr_census")
  fi
  if coord_scheduler_live_worker "$unit" "$issue"; then
    say "dispatch held unit=$unit reason=live-worker"
    dispatch_claim_release
    return 1
  fi
  if [[ -n "${SCHEDULER_DISPATCH_CLAIM_KEY:-}" && "$SCHEDULER_DISPATCH_CLAIM_KEY" == "$claim_key" ]]; then
    claim_owner="$SCHEDULER_DISPATCH_CLAIM_OWNER"
  else
    dispatch_claim_release
    claim_owner="$(coord_new_owner)"
    if coord_acquire "$claim_key" "$claim_owner" scheduler-worker "$issue" "$unit" "$type"; then
      :
    else
      claim_status=$?
      say "dispatch held unit=$unit reason=$(if (( claim_status == 1 )); then echo claim-owned; else echo claim-unknown; fi)"
      return 1
    fi
  fi
  if ! coord_assert_owned "$claim_key" "$claim_owner" >/dev/null; then
    dispatch_claim_release "$claim_key" "$claim_owner"
    [[ "$type" != implement || ! "$issue" =~ ^[1-9][0-9]*$ ]] || scheduler_clear_canary_after_failed_start "$issue" || :
    say "dispatch held unit=$unit reason=claim-lost-before-launch"
    return 1
  fi
  dispatch_claim_clear
  if [[ "${WORKER_STDOUT_REPORT:-0}" == 1 ]]; then
    # stdout supplies a missing report, but must not replace a report the worker wrote itself.
    export -f capture_worker_stdout_report
    launch_command=(env GIT_PAGER=cat PAGER=cat bash -c 'capture_worker_stdout_report "$@"' _ "$SUP/$report" \
      "${CODEX_COMMAND[@]}")
  elif [[ "$type" == repair && "$CODEX_MODE" == resume && "$report_only" == true ]]; then
    # Do one strict, read-only continuation of the same session. A startup
    # failure stays a failed report completion; it never falls back to a fresh
    # code-writing repair.
    launch_command=(bash -c 'jq -cn --arg model "$1" "$2" && shift 2 && exec "$@"' autopilot-worker "$model" \
      '{type:"pipeline.execution",mode:"resume",reason:"incident-report-only",model:$model}' "${CODEX_COMMAND[@]}")
  elif [[ "$type" == repair && "$CODEX_MODE" == resume ]]; then
    launch_command=(bash "$CODEX_REPAIR_RUNNER" "$SUP/$log" "$CODEX_SESSION_ID" \
      "${#CODEX_FRESH_COMMAND[@]}" "${CODEX_FRESH_COMMAND[@]}" "${CODEX_COMMAND[@]}")
  else
    launch_command=(bash -c 'jq -cn --arg mode "$1" --arg reason "$2" --arg model "$3" "$4" \
      && shift 4 && exec "$@"' autopilot-worker "$CODEX_MODE" "$CODEX_PATH_REASON" "$model" \
      '{type:"pipeline.execution",mode:$mode,reason:$reason,model:$model}' "${CODEX_COMMAND[@]}")
  fi
  # Keep exit metadata out of the combined provider stream: child processes can finish flushing that log later.
  worker_exit_file="$SUP/$log.pipeline-exit"
  rm -f -- "$worker_exit_file"
  launch_command=(bash -c 'exit_file=$1; shift; rc=0; "$@" || rc=$?; printf "{\"type\":\"pipeline.exit\",\"rc\":%s}\\n" "$rc" > "$exit_file"; exit "$rc"' autopilot-worker "$worker_exit_file" "${launch_command[@]}")
  local worker_pid_file WORKER_PIDFILE WORKER_COST_TAG # not exported: the worker must not inherit them; worker_scope_launch reads them
  local agent_access agent_engine_dir
  agent_access=read
  if [[ "$report_only" != true && ( "$type" == implement || "$type" == repair ) ]]; then agent_access=write; fi
  if [[ "$(unit_field "$unit" '.lane // empty')" == direct-main && "$type" == implement ]]; then agent_access=edit; fi
  agent_engine_dir="${ZF_ENGINE_DIR:-$ROOT/engine}"
  local WORKER_AGENT_PROVIDER="$provider" WORKER_AGENT_ACCESS="$agent_access" WORKER_AGENT_ENGINE_DIR="$agent_engine_dir"
  WORKER_PIDFILE="$(worker_pidfile "$unit")"
  WORKER_COST_TAG="type=$type unit=$unit"
  worker_pid_file="$(mktemp "$A/.worker-start.XXXXXX")" || { coord_release "$claim_key" "$claim_owner" >/dev/null 2>&1 || :; [[ "$type" != implement || ! "$issue" =~ ^[1-9][0-9]*$ ]] || scheduler_clear_canary_after_failed_start "$issue" || :; return 1; }
  rm -f -- "$worker_pid_file"
  local scope_rc=0
  worker_scope_launch "$worker_pid_file" "$workdir" "$SUP/$log" "${launcher[@]}" -- \
    "${worker_env[@]}" "${launch_command[@]}" || scope_rc=$?
  if (( scope_rc != 0 )); then
    rm -f -- "$worker_pid_file"
    if (( scope_rc == 3 )); then say "worker scope start timeout unit=$unit scope=${WORKER_SCOPE_TIMEOUT_SCOPE:-none} waited=${WORKER_SCOPE_WAITED:-0}s"; fi
    coord_release "$claim_key" "$claim_owner" >/dev/null 2>&1 || :
    [[ "$type" != implement || ! "$issue" =~ ^[1-9][0-9]*$ ]] || scheduler_clear_canary_after_failed_start "$issue" || :
    return 1
  fi
  pid="$WORKER_SCOPE_PID"
  rm -f -- "$worker_pid_file"
  local pid_started scope_name
  pid_started="${WORKER_SCOPE_PID_START:-}"
  [[ "$pid_started" =~ ^[0-9]+$ ]] || pid_started="$(coord_process_start_ticks "$pid" 2>/dev/null)" || {
    stuck_worker_stop "$pid" || :
    if ! kill -0 "$pid" 2>/dev/null; then
      coord_release "$claim_key" "$claim_owner" >/dev/null 2>&1 || :
      [[ "$type" != implement || ! "$issue" =~ ^[1-9][0-9]*$ ]] || scheduler_clear_canary_after_failed_start "$issue" || :
    fi
    say "dispatch stopped unit=$unit reason=worker-start-identity-unavailable"
    return 1
  }
  if ! coord_renew "$claim_key" "$claim_owner" "$pid" "$pid_started"; then
    stuck_worker_stop "$pid" || :
    if ! alive "$pid"; then
      coord_release "$claim_key" "$claim_owner" >/dev/null 2>&1 || :
      [[ "$type" != implement || ! "$issue" =~ ^[1-9][0-9]*$ ]] || scheduler_clear_canary_after_failed_start "$issue" || :
    fi
    say "dispatch stopped unit=$unit reason=claim-lost-after-launch"
    return 1
  fi
  if [[ "$type" == implement && "$issue" =~ ^[1-9][0-9]*$ ]] && ! scheduler_mark_canary_after_worker_start "$issue"; then say "dispatch canary mark failed unit=$unit issue=$issue"; fi
  local w; w="$(jqf -cn --argjson pid "${pid:-0}" --argjson pid_start "$pid_started" --arg unit "$unit" --arg type "$type" --arg log "$log" --arg report "$report" --arg at "$STAMP" --arg mode "$CODEX_MODE" --arg session_id "$CODEX_SESSION_ID" --arg sha "$sha" --arg pr_head "$pr_head" --arg workdir "$workdir" --arg model "$model" --arg provider "$provider" --arg effort "$effort" --arg route_reason "$route_reason" --arg prompt "$worker_prompt" --arg prompt_stage "$worker_prompt_stage" --arg prompt_version "$worker_prompt_version" --argjson hard_escalation "$hard_escalation" --arg issue "$issue" --arg claim_key "$claim_key" --arg claim_owner "$claim_owner" --argjson usage_start "$CODEX_USAGE_START" \
    '{pid:$pid,pid_start:$pid_start,unit:$unit,type:$type,log:$log,report:$report,started:$at,mode:$mode,session_id:$session_id,sha:$sha,pr_head:$pr_head,workdir:$workdir,provider:$provider,model:$model,effort:$effort,hard_escalation:$hard_escalation,route_reason:$route_reason,token_usage_start:$usage_start,issue:$issue,claim_key:$claim_key,claim_owner:$claim_owner} + (if ($prompt_version | test("^[0-9a-f]{64}$")) then {prompt:$prompt,prompt_stage:$prompt_stage,prompt_version:$prompt_version} else {} end)')"
  [[ -z "$worker_context" ]] || w="$(jqf --argjson context "$worker_context" '. + $context' <<<"$w")"
  if [[ ( "${WORKER_STDOUT_REPORT:-0}" == 1 || "$provider" == claude ) && ${#launcher[@]} -gt 0 ]]; then
    w="$(jqf --argjson pgid "$pid" '. + {process_group:$pgid}' <<<"$w")"
  fi
  # Harvest stops this scope once the worker is finished (harvest-scope.sh); read it while the leader still lives.
  if [[ "$WORKER_SCOPE_MODE" == scope ]]; then
    scope_name="$(worker_scope_of_pid "$pid")"
    [[ -z "$scope_name" ]] || w="$(jqf --arg scope "$scope_name" '. + {scope:$scope}' <<<"$w")"
  fi
  if ! jqf --argjson w "$w" '.workers += [$w]' "$WORKERS" | write_state "$WORKERS"; then
    stuck_worker_stop "$pid" || :
    if ! alive "$pid"; then coord_release "$claim_key" "$claim_owner" >/dev/null 2>&1 || :; fi
    say "dispatch stopped unit=$unit reason=worker-ledger-write-failed"
    return 1
  fi
  if [[ "$type" == implement || "$type" == repair ]]; then
    say "implement-route unit=$unit provider=$provider reason=$route_reason"
  fi
  if [[ "$cache_fresh" == true ]] && (( SECONDS < cache_until )) && harvest_worker_alive "$w"; then
    LIVE_WORKER_CACHE_TOTAL=$((LIVE_WORKER_CACHE_TOTAL + 1))
    LIVE_WORKER_CACHE_TYPES["$type"]=$((${LIVE_WORKER_CACHE_TYPES[$type]:-0} + 1))
    LIVE_WORKER_CACHE_UNTIL=$((SECONDS + 10))
  fi
  say "dispatch claim=owned issue=${issue:-none} mode=$CODEX_MODE reason=$CODEX_PATH_REASON pid=$pid type=$type unit=$unit"
  elapsed=$((SECONDS - started))
  (( elapsed < 2 )) || say "dispatch detail worker_start unit=$unit secs=${elapsed}s"
}

critical_pending_count() {
  jqf '[.units[] | select(.critical==true) | select(.stage=="implement-pending" or .stage=="review-pending" or .stage=="repair-pending" or .stage=="rereview-pending")] | length' "$UNITS" 2>/dev/null || echo 0
}
