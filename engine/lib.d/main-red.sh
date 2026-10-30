_AGENT_LIB_DIR="${_AGENT_LIB_DIR:-$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)}" # a module sourced without lib.sh (land snapshot) still finds the lib dir

# Open main-red quarantine records only paths proved by the failing run. A
# pre-scope or unparseable episode remains a full implement block.
main_ci_red_episode_file() {
  echo "$QUARANTINE_DIR/main-ci-red-episodes.jsonl"
}


# A main-red quarantine lifts only after a complete CI run for the exact main
# tip has produced both Postsubmit and static-guard evidence. A green run on
# an older main SHA does not cover the current candidate.
main_ci_red_quarantine_probe() {
  local sha="${1:-}" main_ref history="${2:-}" run run_id jobs
  if [[ ! "$sha" =~ ^[0-9a-f]{40}$ ]]; then
    main_ref="$(timeout -k 1 8 gh api "repos/$REPO/git/ref/heads/main" -H 'Cache-Control: no-cache')" || return 2
    sha="$(jq -er '.object.sha | select(test("^[0-9a-f]{40}$"))' <<< "$main_ref")" || return 2
  fi
  if [ -z "$history" ]; then
    if history="$(ci_main_postsubmit_run_history_for_sha "$sha")"; then :; else return $?; fi
  fi
  jq -e 'type == "array" or (type == "object" and (.workflow_runs | type == "array"))' \
    <<< "$history" >/dev/null 2>&1 || return 2
  run="$(jq -c --arg sha "$sha" '
    (if type == "array" then . else .workflow_runs end) as $runs
    | [$runs[] | select(.head_branch == "main" and .head_sha == $sha
      and .path == ".github/workflows/ci.yml"
      and (.event == "push" or .event == "workflow_dispatch"))]
    | sort_by([.created_at // "", .id // 0, .run_attempt // 0]) | last // empty
  ' <<< "$history")" || return 2
  [ -n "$run" ] && [ "$run" != null ] || return 1
  jq -e '.status == "completed" and .conclusion == "success"' <<< "$run" >/dev/null 2>&1 || return 1
  run_id="$(jq -er '.id | select(type == "number" and . > 0)' <<< "$run")" || return 2
  jobs="$(timeout -k 1 8 gh api "repos/$REPO/actions/runs/$run_id/jobs?per_page=100&page=1" \
    -H 'Cache-Control: no-cache' -H 'Pragma: no-cache')" || return 2
  jq -e 'type == "object" and (.jobs | type == "array")' <<< "$jobs" >/dev/null 2>&1 || return 2
  jq -e 'any(.jobs[]; .name == "Postsubmit validate" and .status == "completed" and .conclusion == "success")
    and any(.jobs[]; .name == "NUL bytes & lone negative assertions"
      and .status == "completed" and .conclusion == "success")' <<< "$jobs" >/dev/null 2>&1 || return 1
  printf '%s\n' "$run"
}


main_ci_red_episode_has_open() {
  local episode_id="$1" file
  file="$(main_ci_red_episode_file)"
  [ -f "$file" ] && jq -s -e --arg id "$episode_id" 'any(.[]; .event == "open" and .episode_id == $id)' "$file" >/dev/null 2>&1
}


main_ci_red_episode_has_lift() {
  local episode_id="$1" file
  file="$(main_ci_red_episode_file)"
  [ -f "$file" ] && jq -s -e --arg id "$episode_id" 'any(.[]; .event == "lift" and .episode_id == $id)' "$file" >/dev/null 2>&1
}


main_ci_red_episode_append_open() {
  local record_file="$1" snapshot="$2" file
  file="$(main_ci_red_episode_file)"
  mkdir -p "$QUARANTINE_DIR" || return 1
  jq -cn --slurpfile r "$record_file" --argjson snapshot "$snapshot" '
    $r[0] as $r
    | {event:"open", episode_id:$r.episode_id, opened_at:$r.since,
       recorded_at:($snapshot.captured_at // $r.since), quarantine_signature:$r.signature,
       detail:$r.detail, failed_run_ids:[$r.main_run_ids[]? | select(. != 0)],
       failed_signatures:($r.failed_test_ids // []), blocked_paths:($r.blocked_paths // []),
       blocked_epics:($r.blocked_epics // []), scope_known:($r.scope_known == true),
       full_block:($r.full_block == true), candidate_snapshot:$snapshot}
  ' >> "$file"
}


main_ci_red_episode_append_scope() {
  local record_file="$1" detail="$2" now="$3" event="${4:-extend}" file detail_file status
  file="$(main_ci_red_episode_file)"
  detail_file="$(jq_arg_file "$detail")" || return 1
  jq -cn --slurpfile r "$record_file" --rawfile detail "$detail_file" --arg event "$event" --argjson now "$now" '
    $r[0] as $r
    | {event:$event, episode_id:$r.episode_id, recorded_at:$now, detail:$detail,
       failed_run_ids:[$r.main_run_ids[]? | select(. != 0)],
       failed_signatures:($r.failed_test_ids // []), blocked_paths:($r.blocked_paths // []),
       blocked_epics:($r.blocked_epics // []), scope_known:($r.scope_known == true),
       full_block:($r.full_block == true)}
  ' >> "$file"
  status=$?
  rm -f "$detail_file"
  return "$status"
}


main_ci_red_episode_append_lift() {
  local record_file="$1" episode_id="$2" why="$3" now="$4" file tmp status
  main_ci_red_episode_has_lift "$episode_id" && return 0
  file="$(main_ci_red_episode_file)"
  tmp="$(jq_arg_file "$why")" || return 1
  jq -cn --slurpfile r "$record_file" --rawfile reason "$tmp" --arg id "$episode_id" --argjson now "$now" '
    $r[0] as $r
    | {event:"lift", episode_id:$id, lifted_at:$now, reason:$reason,
       failed_run_ids:[$r.main_run_ids[]? | select(. != 0)],
       failed_signatures:($r.failed_test_ids // [])}
  ' >> "$file"
  status=$?
  rm -f "$tmp"
  return "$status"
}


# Legacy active quarantines predate the episode ledger. Preserve their known
# open/lift edge, but never invent the candidate snapshot they did not retain.
main_ci_red_episode_ensure_open_event() {
  local record_file="$1" record episode_id since run_id tmp
  record="$(cat -- "$record_file")" || return 1
  episode_id="$(jq -r '.episode_id // empty' <<< "$record")"
  if [ -z "$episode_id" ]; then
    since="$(jq -r '.since // 0' <<< "$record")"
    run_id="$(jq -r '[.main_run_ids[]? | select(. != 0)][0] // empty' <<< "$record")"
    if [ -z "$run_id" ]; then
      run_id="$(sed -nE 's/.*main ci\.yml push run ([1-9][0-9]*).*/\1/p' <<< "$(jq -r '.detail // ""' <<< "$record")" | head -n 1)"
    fi
    [ -n "$run_id" ] || run_id=unknown
    episode_id="main-ci-red-$since-$run_id"
    tmp="$record_file.tmp.$$"
    jq --arg id "$episode_id" '.episode_id = $id' "$record_file" > "$tmp" \
      && mv -f "$tmp" "$record_file" || { rm -f "$tmp"; return 1; }
  fi
  if ! main_ci_red_episode_has_open "$episode_id"; then
    main_ci_red_episode_append_open "$record_file" \
      '{"status":"unknown","captured_at":null,"candidates":[]}' || return 1
  fi
  printf '%s\n' "$episode_id"
}


main_ci_red_candidate_snapshot() {
  local issues roadmap_flat='' snapshot_status=complete rows_file issue issue_id state body labels surface
  local expected_paths expected_packages package_labels epic scope_known
  if ! issues="$(gh issue list --repo "$REPO" --limit 1000 --label ready-for-agent --state open \
    --json number,body,labels 2>/dev/null)" \
    || ! jq -e 'type == "array" and all(.[]; (.number | type) == "number" and (.labels | type) == "array")' \
      >/dev/null 2>&1 <<< "$issues"; then
    jq -cn '{status:"unknown",captured_at:null,candidates:[]}'
    return 0
  fi
  [ "$(jq 'length' <<< "$issues")" -lt 1000 ] || snapshot_status=truncated
  if [ -n "${ZF_ROADMAP_TREE_CACHE_FILE:-}" ] && [ -r "$ZF_ROADMAP_TREE_CACHE_FILE" ]; then
    roadmap_flat="$(roadmap_flatten "$(cat -- "$ZF_ROADMAP_TREE_CACHE_FILE")" 2>/dev/null || true)"
  fi
  rows_file="$(mktemp)" || { jq -cn '{status:"unknown",captured_at:null,candidates:[]}'; return 0; }
  while IFS= read -r issue; do
    issue_id="$(jq -r '.number' <<< "$issue")"
    [[ "$issue_id" =~ ^[1-9][0-9]*$ ]] || { snapshot_status=unknown; continue; }
    state="$(state_read "$issue_id" 2>/dev/null || echo '{}')"
    body="$(jq -r '.body // ""' <<< "$issue")"
    labels="$(jq -c '.labels // []' <<< "$issue")"
    surface="$(issue_change_surface_json "$state" "$body" "$labels" 2>/dev/null || echo '[]')"
    expected_paths="$(jq -c 'if (.expected_paths | type) == "array" then .expected_paths else "UNKNOWN" end' <<< "$state" 2>/dev/null || echo '"UNKNOWN"')"
    expected_packages="$(jq -c 'if (.expected_packages | type) == "array" then .expected_packages else "UNKNOWN" end' <<< "$state" 2>/dev/null || echo '"UNKNOWN"')"
    package_labels="$(jq -c '[.[]?.name | select(startswith("pkg:") or startswith("package:"))] | unique' <<< "$labels" 2>/dev/null || echo '[]')"
    epic=UNKNOWN
    if [ -n "$roadmap_flat" ]; then
      epic="$(jq -r --argjson n "$issue_id" '
        . as $nodes
        | [$nodes[] | select(.number == $n)][0] as $ticket
        | if $ticket == null then "NONE"
          else ([ $nodes[] | select(.number == $ticket.parent and .depth == 2 and (.labels | index("roadmap-epic") != null)) ][0].number // "NONE" | tostring)
          end
      ' <<< "$roadmap_flat" 2>/dev/null || echo UNKNOWN)"
    fi
    scope_known=false
    if jq -e 'type == "array" and length > 0 and all(.[]; type == "string" and length > 0 and (startswith("/") | not) and ((split("/") | index("..")) == null))' \
      >/dev/null 2>&1 <<< "$surface"; then scope_known=true; fi
    jq -cn --argjson issue_id "$issue_id" --argjson expected_paths "$expected_paths" \
      --argjson expected_packages "$expected_packages" --argjson package_labels "$package_labels" \
      --argjson surface "$surface" --argjson scope_known "$scope_known" --arg epic "$epic" '
      {issue_id:$issue_id,expected_paths:$expected_paths,expected_packages:$expected_packages,
       package_labels:$package_labels,roadmap_epic:(if $epic == "UNKNOWN" then "UNKNOWN" elif $epic == "NONE" then null else ($epic | tonumber) end),
       surface:$surface,scope_known:$scope_known}
    ' >> "$rows_file" || snapshot_status=unknown
  done < <(jq -c '.[]' <<< "$issues")
  jq -sc --arg status "$snapshot_status" --argjson captured_at "$(date +%s)" \
    '{status:$status,captured_at:$captured_at,candidates:.}' "$rows_file"
  local status=$?
  rm -f "$rows_file"
  return "$status"
}


main_ci_red_scope_extend() {
  local run_id="$1" paths_json="$2" test_ids_json="$3" candidate_surface="$4" epic="${5:-}" detail="$6" upgrade="${7:-false}"
  local f had_record known lock_fd tmp detail_file candidate_snapshot episode_id prior_episode_id prior_scope current_scope
  local had_delta=0 wrote_open=0 episode_since episode_run
  f="$(quarantine_file implement)"
  had_record=0
  [ -f "$f" ] && had_record=1
  [ "$upgrade" != true ] || [ "$had_record" = 1 ] || return 1
  quarantine_open implement env:main-ci-red "$detail" 1 || return 1
  candidate_snapshot='{"status":"unknown","captured_at":null,"candidates":[]}'
  if [ "$had_record" = 0 ] && [ "$upgrade" != true ]; then
    candidate_snapshot="$(main_ci_red_candidate_snapshot)" || candidate_snapshot='{"status":"unknown","captured_at":null,"candidates":[]}'
  fi
  if ! jq -e 'type == "array" and all(.[]; type == "string")' <<< "$test_ids_json" >/dev/null 2>&1; then test_ids_json='[]'; fi
  if jq -e 'type == "array" and length > 0 and all(.[]; type == "string" and length > 0 and (startswith("/") | not) and ((split("/") | index("..")) == null))' \
    <<< "$paths_json" >/dev/null 2>&1 \
    && jq -e 'type == "array" and length > 0 and all(.[]; type == "string" and length > 0)' <<< "$test_ids_json" >/dev/null 2>&1; then
    known=true
  else
    known=false
    paths_json='[]'
    test_ids_json='[]'
  fi
  if ! jq -e 'type == "array" and all(.[]; type == "string")' <<< "$candidate_surface" >/dev/null 2>&1; then candidate_surface='[]'; fi
  mkdir -p "$AGENT_HOME/locks" || return 1
  exec {lock_fd}>"$AGENT_HOME/locks/main-ci-red.lock" || return 1
  flock -x "$lock_fd" || { exec {lock_fd}>&-; return 1; }
  prior_episode_id="$(jq -r '.episode_id // empty' "$f" 2>/dev/null || true)"
  prior_scope="$(jq -c '{scope_known:(.scope_known // null),full_block:(.full_block // false),blocked_paths:(.blocked_paths // []),blocked_epics:(.blocked_epics // []),failed_test_ids:(.failed_test_ids // []),main_run_ids:(.main_run_ids // [])}' "$f")"
  episode_id="$prior_episode_id"
  if [ -z "$episode_id" ]; then
    episode_since="$(jq -r '.since // 0' "$f")"
    episode_run="$(jq -r --argjson run "$run_id" '[.main_run_ids[]? | select(. != 0)][0] // $run' "$f")"
    [[ "$episode_run" =~ ^[1-9][0-9]*$ ]] || episode_run=unknown
    episode_id="main-ci-red-$episode_since-$episode_run"
  fi
  tmp="$f.tmp.$$"
  detail_file="$(jq_arg_file "$detail")" || { unlock_fd "$lock_fd"; return 1; }
  if ! jq --argjson new "$((1 - had_record))" --argjson known "$known" \
    --argjson paths "$paths_json" --argjson tests "$test_ids_json" \
    --argjson run "$run_id" --arg epic "$epic" --rawfile detail "$detail_file" \
    --argjson surface "$candidate_surface" --argjson upgrade "$upgrade" --arg episode "$episode_id" '
    def overlaps($left; $right):
      any($left[]; . as $a | any($right[]; . as $b |
        $a == $b or ($a | startswith($b + "/")) or ($b | startswith($a + "/"))));
    if $upgrade and .detail != $detail then error("main-red quarantine changed during scope upgrade") else . end
    | . as $record
    | ($record.blocked_paths // []) as $old_paths
    | (($old_paths + $paths) | unique) as $all_paths
    | (if ($epic | test("^[1-9][0-9]*$")) and $known and overlaps($all_paths; $surface)
       then ((($record.blocked_epics // []) + [$epic]) | unique)
       else ($record.blocked_epics // []) end) as $epics
    | .scope_known = (if $upgrade and $known then true elif has("scope_known") then (.scope_known == true and $known) else ($new == 1 and $known) end)
    | .full_block = ((.full_block // false) or ($known | not) or ($new == 0 and ($record.scope_known? == null) and ($upgrade | not)))
    | .blocked_paths = $all_paths
    | .failed_test_ids = ((.failed_test_ids // []) + $tests | unique)
    | .main_run_ids = ((.main_run_ids // []) + [$run] | unique)
    | .blocked_epics = $epics
    | .episode_id = (.episode_id // $episode)
  ' "$f" > "$tmp"; then
    rm -f "$tmp"
    rm -f "$detail_file"
    unlock_fd "$lock_fd"
    return 1
  fi
  rm -f "$detail_file"
  if ! mv -f "$tmp" "$f"; then
    rm -f "$tmp"
    unlock_fd "$lock_fd"
    return 1
  fi
  current_scope="$(jq -c '{scope_known:(.scope_known // null),full_block:(.full_block // false),blocked_paths:(.blocked_paths // []),blocked_epics:(.blocked_epics // []),failed_test_ids:(.failed_test_ids // []),main_run_ids:(.main_run_ids // [])}' "$f")"
  [ "$current_scope" = "$prior_scope" ] || had_delta=1
  episode_id="$(jq -r '.episode_id' "$f")"
  if ! main_ci_red_episode_has_open "$episode_id"; then
    main_ci_red_episode_append_open "$f" "$candidate_snapshot" || { unlock_fd "$lock_fd"; return 1; }
    wrote_open=1
  fi
  if [ "$wrote_open" = 0 ] && [ "$had_delta" = 1 ]; then
    main_ci_red_episode_append_scope "$f" "$detail" "$(date +%s)" || { unlock_fd "$lock_fd"; return 1; }
  fi
  unlock_fd "$lock_fd"
}


# Upgrade old main-red records once from their recorded failed run. Any missing
# log, issue surface, or test path leaves the legacy full-lane block in place.
main_ci_red_hydrate_scope() {
  local f detail run_id fault_file issue log test_ids paths issue_json surface flat epic
  f="$(quarantine_file implement)"
  [ -f "$f" ] || return 1
  detail="$(jq -r 'select(.signature == "env:main-ci-red" and .scope_known == null and (.full_block // false) != true) | .detail // empty' "$f" 2>/dev/null)"
  [ -n "$detail" ] || return 1
  run_id="$(sed -nE 's/.*main ci\.yml push run ([0-9]+).*/\1/p' <<< "$detail" | head -n 1)"
  [[ "$run_id" =~ ^[1-9][0-9]*$ ]] || {
    main_ci_red_scope_extend 0 '[]' '[]' '[]' '' "$detail" || true
    return 1
  }
  fault_file="$ENV_FAULT_DIR/$(env_fault_key env:main-ci-red).log"
  issue="$(awk -F '\t' -v d="$detail" '$4 == "env:main-ci-red" && $5 == d { number=$3 } END { print number }' "$fault_file" 2>/dev/null)"
  if [[ ! "$issue" =~ ^[1-9][0-9]*$ ]] \
    || ! log="$(gh run view "$run_id" --repo "$REPO" --log-failed 2>/dev/null)" \
    || ! issue_json="$(gh issue view "$issue" --repo "$REPO" --json body,labels 2>/dev/null)"; then
    main_ci_red_scope_extend "$run_id" '[]' '[]' '[]' '' "$detail" || true
    return 1
  fi
  test_ids="$(ci_failed_test_ids "$log" | cut -f2- | jq -Rsc 'split("\n") | map(select(length > 0)) | unique')"
  paths="$(ci_failed_test_scope_from_log "$log")"
  surface="$(issue_change_surface_json "$(state_read "$issue")" \
    "$(jq -r '.body // ""' <<< "$issue_json")" "$(jq -c '.labels // []' <<< "$issue_json")")"
  epic=""
  if [ -n "${ZF_ROADMAP_TREE_CACHE_FILE:-}" ] && [ -r "$ZF_ROADMAP_TREE_CACHE_FILE" ]; then
    flat="$(roadmap_flatten "$(cat -- "$ZF_ROADMAP_TREE_CACHE_FILE")" 2>/dev/null || echo '[]')"
    epic="$(jq -r --argjson n "$issue" '
      . as $nodes | ($nodes[] | select(.number == $n)) as $ticket
      | [$nodes[] | select(.number == $ticket.parent and .depth == 2 and (.labels | index("roadmap-epic") != null))][0].number // empty
    ' <<< "$flat" 2>/dev/null || true)"
  fi
  main_ci_red_scope_extend "$run_id" "$paths" "$test_ids" "$surface" "$epic" "$detail" true
}


# main_ci_red_candidate_allowed <surface-json> [roadmap-epic] -> 0 only when
# both sides have known scope and neither paths/packages nor epic overlap.
main_ci_red_candidate_allowed() {
  local surface="${1:-[]}" epic="${2:-}" f
  f="$(quarantine_file implement)"
  [ -f "$f" ] || return 0
  [ "$(jq -r '.signature // empty' "$f" 2>/dev/null)" = env:main-ci-red ] || return 0
  if jq -e '.scope_known == null and (.full_block // false) != true' "$f" >/dev/null 2>&1; then
    main_ci_red_hydrate_scope || return 1
  fi
  f="$(quarantine_file implement)"
  jq -e --argjson surface "$surface" --arg epic "$epic" '
    def safe_path:
      type == "string" and length > 0 and (startswith("/") | not)
      and ((split("/") | index("..")) == null);
    def overlaps($left; $right):
      any($left[]; . as $a | any($right[]; . as $b |
        $a == $b or ($a | startswith($b + "/")) or ($b | startswith($a + "/"))));
    .scope_known == true
    and (.full_block // false) != true
    and (.blocked_paths | type == "array" and length > 0 and all(.[]; safe_path))
    and ($surface | type == "array" and length > 0 and all(.[]; safe_path))
    and ((.blocked_epics // []) | if length == 0 then true else ($epic != "" and index($epic) == null) end)
    and (overlaps(.blocked_paths; $surface) | not)
  ' "$f" >/dev/null 2>&1
}


# Count distinct tickets actually started during scoped main-red quarantine.
# Failed PRs count only when they later repeat a test id recorded at dispatch.
main_ci_red_record_dispatch() {
  local issue="$1" surface="${2:-[]}" epic="${3:-}" f lock_fd tmp
  f="$(quarantine_file implement)"
  [ -f "$f" ] || return 0
  [ "$(jq -r '.signature // empty' "$f" 2>/dev/null)" = env:main-ci-red ] || return 0
  if ! main_ci_red_candidate_allowed "$surface" "$epic"; then
    STAGE_DISPATCH_BLOCKING_SCOPES=implement
    return 1
  fi
  mkdir -p "$AGENT_HOME/locks" || return 1
  exec {lock_fd}>"$AGENT_HOME/locks/main-ci-red.lock" || return 1
  flock -x "$lock_fd" || { exec {lock_fd}>&-; return 1; }
  tmp="$f.tmp.$$"
  if ! jq --arg issue "$issue" --argjson surface "$surface" --arg epic "$epic" '
    def overlaps($left; $right):
      any($left[]; . as $a | any($right[]; . as $b |
        $a == $b or ($a | startswith($b + "/")) or ($b | startswith($a + "/"))));
    select(.scope_known == true and (.full_block // false) != true
      and (.blocked_paths | type == "array" and length > 0)
      and ($surface | type == "array" and length > 0)
      and ((.blocked_epics // []) | if length == 0 then true else ($epic != "" and index($epic) == null) end)
      and (overlaps(.blocked_paths; $surface) | not))
    | (.failed_test_ids // []) as $tests
    | .scoped_dispatches = ((.scoped_dispatches // []) | if any(.[]; .issue == $issue)
      then map(if .issue == $issue then .test_ids = (((.test_ids // []) + $tests) | unique) else . end)
      else . + [{issue:$issue,test_ids:$tests}] end)
  ' "$f" > "$tmp"; then
    rm -f "$tmp"
    unlock_fd "$lock_fd"
    return 1
  fi
  if ! mv -f "$tmp" "$f"; then
    rm -f "$tmp"
    unlock_fd "$lock_fd"
    return 1
  fi
  unlock_fd "$lock_fd"
}


main_ci_red_record_same_signature_failure() {
  local issue="$1" test_id="$2" f lock_fd tmp prior_full_block current_full_block episode_id
  f="$(quarantine_file implement)"
  [ -f "$f" ] || return 0
  [ "$(jq -r '.signature // empty' "$f" 2>/dev/null)" = env:main-ci-red ] || return 0
  mkdir -p "$AGENT_HOME/locks" || return 1
  exec {lock_fd}>"$AGENT_HOME/locks/main-ci-red.lock" || return 1
  flock -x "$lock_fd" || { exec {lock_fd}>&-; return 1; }
  prior_full_block="$(jq -r '.full_block // false' "$f")"
  tmp="$f.tmp.$$"
  if ! jq --arg issue "$issue" --arg test "$test_id" '
    if any(.scoped_dispatches[]?; .issue == $issue and ((.test_ids // []) | index($test) != null)) then
      .same_signature_failures = (((.same_signature_failures // []) + [$issue]) | unique)
    else . end
    | ((.scoped_dispatches // []) | map(.issue) | unique | length) as $runs
    | ((.same_signature_failures // []) | length) as $failures
    # One repeat at the five-ticket minimum is 20%; it triggers quickly without
    # letting a single low-sample miss trip the global fallback.
    | if $runs >= 5 and ($failures / $runs) > 0.10 then .full_block = true else . end
  ' "$f" > "$tmp"; then
    rm -f "$tmp"
    unlock_fd "$lock_fd"
    return 1
  fi
  if ! mv -f "$tmp" "$f"; then
    rm -f "$tmp"
    unlock_fd "$lock_fd"
    return 1
  fi
  current_full_block="$(jq -r '.full_block // false' "$f")"
  if [ "$prior_full_block" != true ] && [ "$current_full_block" = true ]; then
    episode_id="$(jq -r '.episode_id // empty' "$f")"
    if [ -n "$episode_id" ]; then
      main_ci_red_episode_append_scope "$f" 'same-signature failure threshold tripped' "$(date +%s)" fallback \
        || { unlock_fd "$lock_fd"; return 1; }
    fi
  fi
  unlock_fd "$lock_fd"
}


# Defect (d), 2026-09-12: a failed deploy must never auto-retry its own SHA.
# True (blocked) if $1 (a would-be deploy target SHA) equals the recorded
# failed SHA in $DEPLOY_BLOCKED_FILE — exact equality only. Since the
# 2026-10-26 fix-forward ruling a descendant is the fix-forward commit and
# MAY release; the previous descendant-blocking (and the culprit-revert
# escape hatch) required a manual marker clear for every fix (release 4061,
# seven attempts for one batch). $2 (marker file) defaults to the real one
# and exists only so lib.test.sh can point this at a throwaway path instead.
# No function clears the marker.
# Defect 2, 2026-09-13: run-release.sh's fresh-install bootstrap for
# $OLD_DEPLOYED_SHA (no production Deployment record yet) must diff from THIS
# release's own triggering merge commit's parent, never from current
# origin/main HEAD's parent -- the two are only the same SHA at the instant
# this PR's own merge lands. The moment any other commit reaches main after
# that (another queued issue, an unrelated [skip ci] commit), $DEPLOYED_SHA
# (origin/main HEAD) and $MERGE_SHA (the PR actually being released) diverge,
# and diffing from $DEPLOYED_SHA^ silently excludes the triggering PR's own
# commit from the range changed-images.mjs computes -- reproduced live for
# issue #1098: the buggy range printed no changed images at all and the
# script took the "nothing to deploy" exit, when the correct range printed
# example-admin. Pure (one git call, no state): given $1 = the merge SHA
# being released (never current HEAD), prints its parent. $2 defaults to the
# real $REPO_DIR so lib.test.sh can point this at a throwaway repo instead.
bootstrap_old_deployed_sha() {
  local merge_sha="$1" dir="${2:-$REPO_DIR}"
  git -C "$dir" rev-parse "$merge_sha^"
}


deploy_is_blocked() {
  local candidate_sha="$1" marker_file="${2:-$DEPLOY_BLOCKED_FILE}" blocked_sha
  # 2026-10-26 maintainer ruling (fix-forward, no resident users): the marker
  # blocks ONLY the exact SHA that failed. A descendant is the fix-forward
  # commit and may release; the ancestor semantics below used to block every
  # descendant, so each fix needed a manual marker clear (release 4061, seven
  # attempts). The recorded culprit-revert escape hatch is gone with them.
  [ -f "$marker_file" ] || return 1
  read -r blocked_sha < "$marker_file" || [ -n "${blocked_sha:-}" ] || return 1
  [ -n "$blocked_sha" ] || return 1
  [ "$blocked_sha" = "$candidate_sha" ]
}


main_red_session_file() {
  local sha="$1"
  [[ "$sha" =~ ^[0-9a-f]{40}$ ]] || return 1
  printf '%s/%s.json\n' "$MAIN_RED_DIR" "$sha"
}


main_red_session_read_for_file() {
  local file="$1"
  jq -ce 'select(type == "object"
    and (.red_sha | type == "string" and test("^[0-9a-f]{40}$"))
    and (.status | IN("rerun-requested", "bisecting", "culprit-found", "revert-open", "reverted", "flaky", "unattributed")))' \
    "$file" 2>/dev/null
}


main_red_session_read() {
  local sha="$1" file
  file="$(main_red_session_file "$sha")" || return 1
  jq -ce --arg sha "$sha" 'select(type == "object" and .red_sha == $sha
    and (.status | IN("rerun-requested", "bisecting", "culprit-found", "revert-open", "reverted", "flaky", "unattributed")))' \
    "$file" 2>/dev/null
}


# Persist one session transition atomically. The filter is an internal jq
# update supplied by the state machine; the session identity and status are
# always overwritten from validated arguments.
main_red_session_write() {
  local sha="$1" status="$2" update file tmp now filter
  if [ "$#" -ge 3 ]; then update="$3"; else update="."; fi
  [[ "$sha" =~ ^[0-9a-f]{40}$ ]] || return 1
  case "$status" in
    rerun-requested|bisecting|culprit-found|revert-open|reverted|flaky|unattributed) ;;
    *) return 1 ;;
  esac
  file="$(main_red_session_file "$sha")" || return 1
  mkdir -p "$MAIN_RED_DIR" || return 1
  tmp="$(mktemp "$MAIN_RED_DIR/.${sha}.XXXXXX")" || return 1
  now="$(date -u +%Y-%m-%dT%H:%M:%SZ)" || { rm -f -- "$tmp"; return 1; }
  filter="$update | .red_sha = \$sha | .status = \$status | .updated_at = \$now"
  if [ -e "$file" ]; then
    jq --arg sha "$sha" --arg status "$status" --arg now "$now" \
      'if type != "object" or .red_sha != $sha then error("main-red session SHA mismatch") else . end
       | '"$filter" \
      "$file" > "$tmp" || { rm -f -- "$tmp"; return 1; }
  else
    jq -n --arg sha "$sha" --arg status "$status" --arg now "$now" \
      '{red_sha:$sha,status:$status,created_at:$now,updated_at:$now}' \
      | jq --arg sha "$sha" --arg status "$status" --arg now "$now" "$filter" \
      > "$tmp" || { rm -f -- "$tmp"; return 1; }
  fi
  chmod 600 "$tmp" && mv -f -- "$tmp" "$file"
}


# Admit merges when the latest usable completed main verdict is green or no
# completed verdict exists. A GitHub read failure is different from an empty
# history and remains fail-closed. Preserve a red run for the sanctioned
# fix-forward assessor.
main_merge_clear() {
  local runs run conclusion
  MAIN_RELEASE_RUN_JSON='{}'
  MAIN_MERGE_CLEAR_REASON=""
  if ! runs="$(ci_main_completed_push_runs)"; then
    MAIN_MERGE_CLEAR_REASON="could not read completed main Postsubmit runs"
    echo "$MAIN_MERGE_CLEAR_REASON" >&2
    return 1
  fi
  if ! run="$(ci_main_latest_completed_push_run "$runs")"; then
    if jq -e '[.workflow_runs[]? | select(.status == "completed"
        and (.conclusion | type == "string" and length > 0)
        and .conclusion != "cancelled" and .conclusion != "skipped")] | length == 0' \
      <<< "$runs" >/dev/null 2>&1; then
      MAIN_MERGE_CLEAR_REASON="no completed main Postsubmit verdict"
      return 0
    fi
    MAIN_MERGE_CLEAR_REASON="could not select the latest completed main Postsubmit verdict"
    echo "$MAIN_MERGE_CLEAR_REASON" >&2
    return 1
  fi
  MAIN_RELEASE_RUN_JSON="$run"
  conclusion="$(jq -r '.conclusion // empty' <<< "$run" 2>/dev/null)" || conclusion=""
  if [ "$conclusion" = success ]; then return 0; fi
  MAIN_MERGE_CLEAR_REASON="latest completed push-triggered run on main concluded $conclusion"
  echo "$MAIN_MERGE_CLEAR_REASON" >&2
  return 1
}


main_red_log() {
  mkdir -p "$LOG_DIR" 2>/dev/null || true
  printf '%s %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*" >> "$LOG_DIR/main-red.log" 2>/dev/null || true
}


# Latest completed, non-cancelled verdict for one SHA across main push runs
# and workflow_dispatch probes, in the workflow the red session is running
# (a suites red is probed with Pipeline suites, not Postsubmit).
# Echoes "success" | "failure" | "pending" (a newer non-completed run exists
# for the SHA) | "none" (no usable verdict). rc 2 on an unreadable answer.
main_red_probe_verdict() {
  local sha="$1" workflow="${2:-ci.yml}" focus_head="${3:-}" cache_window_start runs
  [[ "$sha" =~ ^[0-9a-f]{40}$ ]] || return 2
  case "$workflow" in ci.yml|pipeline-suites.yml) ;; *) return 2 ;; esac
  cache_window_start="$(ci_main_actions_cache_window_start)" || return 2
  if [[ "$workflow" == pipeline-suites.yml \
      && ( "$focus_head" =~ ^[0-9a-f]{40}$ || "$focus_head" == "__rerun__" ) ]]; then
    runs="$(main_gh api "repos/$REPO/actions/workflows/pipeline-suites.yml/runs?branch=main&per_page=100&page=1&created=%3E%3D${cache_window_start}" \
      -H 'Cache-Control: no-cache' -H 'Pragma: no-cache' 2>/dev/null)" || return 2
    jq -r --arg sha "$sha" --arg focus_head "$focus_head" '
      [.workflow_runs[]?
        | select(.head_branch == "main" and .path == ".github/workflows/pipeline-suites.yml"
          and (.event == "push" or .event == "workflow_dispatch")
          and (if $focus_head == "__rerun__" then
                ((.display_title // "") | test("^Pipeline suites post-land " + $sha + " ([0-9a-f]{40}|legacy)$"))
              else .display_title == ("Pipeline suites post-land probe " + $sha + " " + $focus_head)
              end))]
      | sort_by([.created_at // "", .id // 0, .run_attempt // 0]) as $all
      | if ($all | length) == 0 then "none"
        elif ($all | last | .status) != "completed" then "pending"
        else ([$all[] | select(.status == "completed" and .conclusion != "cancelled" and .conclusion != "skipped")]
          | last | .conclusion // "none")
        end' <<< "$runs" 2>/dev/null || return 2
    return 0
  fi
  runs="$(main_gh api "repos/$REPO/actions/runs?head_sha=$sha&per_page=100&page=1&created=%3E%3D${cache_window_start}" \
    -H 'Cache-Control: no-cache' -H 'Pragma: no-cache' 2>/dev/null)" || return 2
  jq -r --arg sha "$sha" --arg path ".github/workflows/$workflow" --arg focus_head "$focus_head" '
    [.workflow_runs[]?
      | select(.head_sha == $sha and .path == $path
        and (.event == "push" or .event == "workflow_dispatch")
        and ($focus_head != "__full__" or (((.display_title // "") | startswith("Pipeline suites post-land ")) | not)))]
    | sort_by([.created_at // "", .id // 0, .run_attempt // 0]) as $all
    | if ($all | length) == 0 then "none"
      elif ($all | last | .status) != "completed" then "pending"
      else ([$all[] | select(.status == "completed" and .conclusion != "cancelled" and .conclusion != "skipped")]
        | last | .conclusion // "none")
      end' <<< "$runs" 2>/dev/null || return 2
}


# Push a train ref at the midpoint. Postsubmit probes run on that ref because
# ci.yml requires source_sha to equal it; focused Pipeline suites probes use
# the current main workflow definition, carry the train ref only as their
# concurrency key, and check out the exact probe SHA in the test job.
main_red_dispatch_probe() {
  local mid_sha="$1" red_sha="$2" workflow="${3:-ci.yml}" focused_base="${4:-}" focused_head="${5:-}" branch="train/bisect-${2:0:12}"
  if ! guarded_write git -C "$REPO_DIR" push -q origin "+${mid_sha}:refs/heads/$branch"; then
    return 1
  fi
  if [ "$workflow" = pipeline-suites.yml ]; then
    if [[ "$focused_base" =~ ^[0-9a-f]{40}$ && "$focused_head" =~ ^[0-9a-f]{40}$ ]]; then
      guarded_write gh workflow run pipeline-suites.yml --repo "$REPO" --ref main \
        -f "post_land_base_sha=$focused_base" -f "post_land_head_sha=$focused_head" \
        -f "post_land_probe_sha=$mid_sha" -f "post_land_probe_ref=$branch" || return 1
    else
      guarded_write gh workflow run pipeline-suites.yml --repo "$REPO" --ref "$branch" || return 1
    fi
  elif ! guarded_write gh workflow run ci.yml --repo "$REPO" --ref "$branch" -f "source_sha=$mid_sha"; then
    return 1
  fi
  main_red_log "probe dispatched sha=${mid_sha:0:12} workflow=$workflow branch=$branch red=${red_sha:0:12}"
}


main_red_supervisor_event() {
  local red_sha="$1" detail="$2"
  supervisor_inbox_append main-red-bisect "red=${red_sha:0:12} $detail" >/dev/null 2>&1 \
    || echo "main-red-bisect: supervisor event unwritten: red=${red_sha:0:12} $detail" >&2
}


# Reopen the culprit's ticket with the bisect evidence and route it back to
# implementation. state_requeue resets attempts and labels; a ticket the
# merge had already closed is reopened first so the lane transition lands on
# an open issue.
main_red_direct_landing_request() {
  local sha="$1" request_dir="${ZF_LAND_QUEUE_DIR:-$AGENT_HOME/land-queue}/requests" request base landed
  local -a matches=()
  [[ "$sha" =~ ^[0-9a-f]{40}$ && -d "$request_dir" ]] || return 1
  for request in "$request_dir"/*.json; do
    [[ -r "$request" ]] || continue
    jq -e '.direct_landing == true and .state == "landed"' "$request" >/dev/null 2>&1 || continue
    base="$(jq -r '.base_sha // empty' "$request")" || continue
    landed="$(jq -r '.landed_sha // empty' "$request")" || continue
    [[ "$base" =~ ^[0-9a-f]{40}$ && "$landed" =~ ^[0-9a-f]{40}$ ]] || continue
    git -C "$REPO_DIR" merge-base --is-ancestor "$base" "$sha" 2>/dev/null || continue
    git -C "$REPO_DIR" merge-base --is-ancestor "$sha" "$landed" 2>/dev/null || continue
    matches+=("$request")
  done
  if ((${#matches[@]} == 0)); then return 1; fi
  ((${#matches[@]} == 1)) || return 2
  printf '%s\n' "${matches[0]}"
}


main_red_direct_landing_issue() {
  local request="$1" owned
  local -a issues=()
  [[ -r "$request" ]] || return 1
  owned="$(jq -r '.owned_issues // empty' "$request")" || return 1
  read -r -a issues <<< "$owned"
  ((${#issues[@]} == 1)) && [[ "${issues[0]}" =~ ^[1-9][0-9]*$ ]] || return 1
  printf '%s\n' "${issues[0]}"
}


main_red_reopen_ticket() {
  local issue="$1" culprit="$2" red_sha="$3" run_id="$4" revert_ref="$5" state
  state="$(gh issue view "$issue" --repo "$REPO" --json state -q .state 2>/dev/null)" || return 1
  if [ "$state" = "CLOSED" ]; then
    guarded_write gh issue reopen "$issue" --repo "$REPO" || return 1
  fi
  guarded_issue_comment "$issue" "$BOT_DISCLAIMER

main 的自动化验证变红，二分定位到本 ticket 的合入提交是罪魁，已自动回滚。

- 罪魁提交：$culprit
- 首红 SHA：${red_sha}（run ${run_id}，同一 SHA 重跑一次仍红，排除 flaky）
- 回滚：$revert_ref
- 证据：engine 的 main-red 会话（$AGENT_HOME/main-red/）

请基于回滚合入后的 origin/main 重新应用改动并修复根因，先让对应主线验证通过再重新交付。" || return 1
  state_requeue "$issue" "" "main-red-revert" || return 1
  main_red_log "ticket #$issue reopened after culprit ${culprit:0:12}"
}


# The dedicated revert PR for a bisected culprit uses the shared deploy
# rollback helper, pushed from a throwaway worktree so the live checkout is
# never touched. The returned head is pinned in the red session before the
# sweeper may admit that PR through the red gate.
main_red_open_revert_pr() {
  local issue="$1" culprit="$2" red_sha="$3" run_id="$4" branch url pr head lib_dir
  [ "$DRY_RUN" != 1 ] || return 1
  branch="agent/revert-main-$issue-${culprit:0:12}"
  lib_dir="$(cd "$(dirname "$_AGENT_LIB_DIR/lib.sh")" && pwd)"
  declare -F open_deploy_revert_pr >/dev/null 2>&1 || source "$lib_dir/deploy-culprit.sh"
  url="$(open_deploy_revert_pr "$issue" "$culprit" "$red_sha" main "$run_id")" || return 1
  pr="$(grep -oE '/pull/[0-9]+' <<< "$url" | grep -oE '[0-9]+$' | tail -1)"
  [[ "$pr" =~ ^[1-9][0-9]*$ ]] || return 1
  git_fetch_bounded "$REPO_DIR" main "$branch" >/dev/null 2>&1 || return 1
  head="$(git -C "$REPO_DIR" rev-parse "origin/$branch" 2>/dev/null)" || return 1
  [[ "$head" =~ ^[0-9a-f]{40}$ ]] || return 1
  main_red_session_write "$red_sha" culprit-found ".revert_head = \"$head\"" || return 1
  printf '%s\n' "$pr"
}


main_red_open_direct_revert() {
  local issue="$1" culprit="$2" red_sha="$3" run_id="$4" lib_dir revert_sha
  [ "$DRY_RUN" != 1 ] || return 1
  lib_dir="$(cd "$(dirname "$_AGENT_LIB_DIR/lib.sh")" && pwd)"
  declare -F open_direct_main_revert >/dev/null 2>&1 || source "$lib_dir/deploy-culprit.sh"
  revert_sha="$(open_direct_main_revert "$issue" "$culprit" "$red_sha" "$run_id")" || return 1
  [[ "$revert_sha" =~ ^[0-9a-f]{40}$ ]] || return 1
  printf '%s\n' "$revert_sha"
}
