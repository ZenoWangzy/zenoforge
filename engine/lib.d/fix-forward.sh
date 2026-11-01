_AGENT_LIB_DIR="${_AGENT_LIB_DIR:-$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)}" # a module sourced without lib.sh (land snapshot) still finds the lib dir

# Moving ten-year bound defeats the observed TLS-proxy cache; a century bound
# hid real runs. Use the same supported window for every mutable Actions list.
ci_main_actions_cache_window_start() {
  date -u -d '10 years ago' '+%Y-%m-%dT%H:%M:%SZ'
}


# Exact-tip Postsubmit evidence is shared by build admission and HEALTH. The
# completed-run history can lag, so resolve current main and the CI run through
# their SHA-scoped Actions endpoints instead of borrowing a prior verdict.
ci_main_current_commit() {
  local timeout="${1:-}" response
  response="$(
    if [ -n "$timeout" ]; then
      main_gh() { gh_timeout -k 1 "$timeout" "$@"; }
    fi
    main_gh api "repos/$REPO/commits/main" \
      -H 'Cache-Control: no-cache' -H 'Pragma: no-cache' 2>/dev/null
  )" || return 1
  jq -e 'type == "object" and (.sha | type == "string" and test("^[0-9a-f]{40}$"))
    and (.commit.committer.date | type == "string")' <<< "$response" >/dev/null 2>&1 || return 1
  printf '%s\n' "$response"
}


ci_main_commit_for_sha() {
  local sha="$1" timeout="${2:-}" response
  [[ "$sha" =~ ^[0-9a-f]{40}$ ]] || return 1
  response="$(
    if [ -n "$timeout" ]; then
      main_gh() { gh_timeout -k 1 "$timeout" "$@"; }
    fi
    main_gh api "repos/$REPO/commits/$sha" 2>/dev/null
  )" || return 1
  jq -e --arg sha "$sha" 'type == "object" and .sha == $sha
    and (.commit.message | type == "string")' <<< "$response" >/dev/null 2>&1 || return 1
  printf '%s\n' "$response"
}


postsubmit_request_recovery_dir() {
  if [[ -n "${RELEASE_RECOVERY_DIR:-}" ]]; then
    printf '%s\n' "$RELEASE_RECOVERY_DIR"
  else
    local agent_home="${AGENT_HOME:-${ZF_HOME:-${HOME:?HOME is not set}/.zenoforge}}"
    printf '%s/release-recovery\n' "$agent_home"
  fi
}


postsubmit_request_record_file() {
  local sha="$1" recovery_dir
  [[ "$sha" =~ ^[0-9a-f]{40}$ ]] || return 1
  recovery_dir="$(postsubmit_request_recovery_dir)" || return 1
  printf '%s/postsubmit/%s.json\n' "$recovery_dir" "$sha"
}


postsubmit_request_record_state() {
  local sha="$1" record
  record="$(postsubmit_request_record_file "$sha")" || return 2
  [ -e "$record" ] || return 1
  [ -r "$record" ] || return 2
  jq -er --arg sha "$sha" '
    if type == "object" and .source_sha == $sha and
      (.status | IN("dispatching", "requested", "queued", "in_progress", "completed", "dispatch-failed"))
    then .status else error("invalid Postsubmit request record") end' \
    "$record" 2>/dev/null || return 2
}


_postsubmit_request_record_write_locked() {
  local sha="$1" status="$2" run_id="$3" conclusion="$4" record tmp now
  record="$(postsubmit_request_record_file "$sha")" || return 1
  mkdir -p "${record%/*}" || return 1
  tmp="$record.tmp.$BASHPID"
  now="$(date -u +%Y-%m-%dT%H:%M:%SZ)" || return 1
  if [ -e "$record" ]; then
    jq --arg sha "$sha" --arg status "$status" --arg run_id "$run_id" \
      --arg conclusion "$conclusion" --arg now "$now" \
      'if type != "object" or .source_sha != $sha then error("Postsubmit request source SHA mismatch") else . end
       | .status=$status | .run_id=$run_id | .conclusion=$conclusion | .updated_at=$now
       | if $status == "dispatching" then
           (.dispatch_attempts // 0) as $attempts
           | if ($attempts | type) == "number" and $attempts >= 0 and $attempts == ($attempts | floor)
             then .dispatch_attempts=$attempts+1 else error("invalid Postsubmit dispatch attempt count") end
         else . end' \
      "$record" > "$tmp" || { rm -f -- "$tmp"; return 1; }
  else
    jq -n --arg sha "$sha" --arg status "$status" --arg run_id "$run_id" \
      --arg conclusion "$conclusion" --arg now "$now" \
      '{source_sha:$sha, status:$status, run_id:$run_id, conclusion:$conclusion,
        dispatch_attempts:(if $status == "dispatching" then 1 else 0 end),
        dispatched_at:$now, updated_at:$now}' > "$tmp" || { rm -f -- "$tmp"; return 1; }
  fi
  mv -f -- "$tmp" "$record"
}


postsubmit_request_record_write() (
  local sha="$1" status="$2" run_id="$3" conclusion="$4" recovery_dir lock_file lock_fd
  [[ "$sha" =~ ^[0-9a-f]{40}$ ]] || return 1
  recovery_dir="$(postsubmit_request_recovery_dir)" || return 1
  lock_file="$recovery_dir/postsubmit/.locks/$sha.lock"
  mkdir -p "${lock_file%/*}" || return 1
  exec {lock_fd}> "$lock_file" || return 1
  flock -x "$lock_fd" || return 1
  _postsubmit_request_record_write_locked "$sha" "$status" "$run_id" "$conclusion"
)


# Claim a per-SHA Postsubmit dispatch across every entry point before calling
# GitHub. Return 0 for the winner, 1 when another request owns the SHA or its
# retry window/cap has not opened, and 2 when the durable record is invalid.
postsubmit_request_dispatch_claim() (
  local sha="$1" retry_delay_seconds="${2:-600}" max_attempts="${3:-3}"
  local allow_requested_retry="${4:-0}" recovery_dir record lock_file lock_fd
  local state attempts updated_at updated_epoch now_epoch age
  [[ "$sha" =~ ^[0-9a-f]{40}$ ]] || return 2
  [[ "$retry_delay_seconds" =~ ^[0-9]+$ && "$max_attempts" =~ ^[1-9][0-9]*$ ]] || return 2
  [[ "$allow_requested_retry" == 0 || "$allow_requested_retry" == 1 ]] || return 2
  recovery_dir="$(postsubmit_request_recovery_dir)" || return 2
  record="$(postsubmit_request_record_file "$sha")" || return 2
  lock_file="$recovery_dir/postsubmit/.locks/$sha.lock"
  mkdir -p "${lock_file%/*}" "${record%/*}" || return 2
  exec {lock_fd}> "$lock_file" || return 2
  flock -x "$lock_fd" || return 2
  if [ -e "$record" ]; then
    if ! jq -e --arg sha "$sha" 'type == "object" and .source_sha == $sha
      and (.status | IN("dispatching", "requested", "queued", "in_progress", "completed", "dispatch-failed"))' \
      "$record" >/dev/null 2>&1; then
      return 2
    fi
    state="$(jq -r '.status' "$record")" || return 2
    case "$state" in
      dispatch-failed|dispatching) ;;
      requested)
        [ "$allow_requested_retry" = 1 ] || return 1
        ;;
      *) return 1 ;;
    esac
    attempts="$(jq -er '(.dispatch_attempts // 0) as $n
      | if ($n | type) == "number" and $n >= 0 and $n == ($n | floor)
        then $n else error("invalid Postsubmit dispatch attempt count") end' "$record" 2>/dev/null)" || return 2
    if [ "$attempts" -ge "$max_attempts" ]; then return 1; fi
    updated_at="$(jq -er '.updated_at | select(type == "string" and length > 0)' "$record" 2>/dev/null)" || return 2
    updated_epoch="$(date -u -d "$updated_at" +%s 2>/dev/null)" || return 2
    now_epoch="$(date -u +%s)" || return 2
    age=$((now_epoch - updated_epoch))
    if [ "$age" -lt "$retry_delay_seconds" ]; then return 1; fi
  fi
  _postsubmit_request_record_write_locked "$sha" dispatching "" "" || return 2
)


ci_main_postsubmit_run_history_for_sha() {
  local sha="$1" timeout="${2:-}" runs selected cache_window_start
  [[ "$sha" =~ ^[0-9a-f]{40}$ ]] || return 2
  cache_window_start="$(ci_main_actions_cache_window_start)" || return 2
  runs="$(
    if [ -n "$timeout" ]; then
      main_gh() { gh_timeout -k 1 "$timeout" "$@"; }
    fi
    main_gh api "repos/$REPO/actions/runs?head_sha=$sha&per_page=100&page=1&created=%3E%3D${cache_window_start}" \
      -H 'Cache-Control: no-cache' -H 'Pragma: no-cache' 2>/dev/null
  )" || return 2
  jq -e 'type == "object" and (.workflow_runs | type == "array")' <<< "$runs" >/dev/null 2>&1 || return 2
  selected="$(jq -c --arg sha "$sha" '
    [.workflow_runs[]?
      | select(.head_branch == "main" and .head_sha == $sha
        and (.event == "push" or .event == "workflow_dispatch")
        and .path == ".github/workflows/ci.yml")]
    | sort_by([.created_at // "", .id // 0, .run_attempt // 0])' <<< "$runs")" || return 2
  [ "$selected" != "[]" ] || return 1
  printf '%s\n' "$selected"
}


ci_main_postsubmit_run_for_sha() {
  local sha="$1" timeout="${2:-}" runs
  if runs="$(ci_main_postsubmit_run_history_for_sha "$sha" "$timeout")"; then :; else
    return $?
  fi
  jq -c 'last' <<< "$runs"
}


ci_main_postsubmit_job_for_run() {
  local run_id="$1" timeout="${2:-}" jobs selected
  [[ "$run_id" =~ ^[0-9]+$ ]] || return 2
  jobs="$(
    if [ -n "$timeout" ]; then
      main_gh() { gh_timeout -k 1 "$timeout" "$@"; }
    fi
    main_gh api "repos/$REPO/actions/runs/$run_id/jobs?per_page=100&page=1" \
      -H 'Cache-Control: no-cache' -H 'Pragma: no-cache' 2>/dev/null
  )" || return 2
  jq -e 'type == "object" and (.jobs | type == "array")' <<< "$jobs" >/dev/null 2>&1 || return 2
  selected="$(jq -c '[.jobs[]? | select(.name == "Postsubmit validate")]
    | sort_by(.id // 0) | last // {status:"missing",conclusion:"missing"}' <<< "$jobs")" || return 2
  printf '%s\n' "$selected"
}


ci_main_postsubmit_green_run_for_sha() {
  local sha="$1" history="${2:-}" latest run_id jobs
  [[ "$sha" =~ ^[0-9a-f]{40}$ ]] || return 2
  if [ -z "$history" ]; then
    if history="$(ci_main_postsubmit_run_history_for_sha "$sha")"; then :; else return $?; fi
  fi
  jq -e 'type == "array"' <<< "$history" >/dev/null 2>&1 || return 2
  latest="$(jq -c --arg sha "$sha" '
    [.[]
      | select(.head_branch == "main" and .head_sha == $sha
        and (.event == "push" or .event == "workflow_dispatch")
        and .path == ".github/workflows/ci.yml")]
    | sort_by([.created_at // "", .id // 0, .run_attempt // 0])
    | last // empty' <<< "$history")" || return 2
  [ -n "$latest" ] || return 1
  jq -e '.status == "completed" and .conclusion == "success"' <<< "$latest" >/dev/null 2>&1 || return 1
  run_id="$(jq -r '.id // empty' <<< "$latest")"
  [[ "$run_id" =~ ^[0-9]+$ ]] || return 2
  jobs="$(ci_main_postsubmit_job_for_run "$run_id")" || return 2
  if jq -e '.status == "completed" and .conclusion == "success"' <<< "$jobs" >/dev/null 2>&1; then
    printf '%s\n' "$latest"
    return 0
  fi
  return 1
}


ci_main_postsubmit_green_for_sha() {
  local sha="$1" history="${2:-}" green_run
  if green_run="$(ci_main_postsubmit_green_run_for_sha "$sha" "$history")"; then
    return 0
  else
    return $?
  fi
}


main_fix_forward_carried_capacity_check() {
  local checks_json="$1" expected_head="$2" link link_path run_id job_id run_json check_name
  local aggregate="Required CI gates"
  [[ "$expected_head" =~ ^[0-9a-f]{40}$ ]] || return 1
  checks_json="$(pr_latest_check_rows "$checks_json")" || return 1
  jq -e --arg touched "Touched packages PR gate" --arg aggregate "$aggregate" '
    type == "array"
    and all(.[]; (.name | type == "string") and (.bucket | type == "string"))
    and ([.[] | select(.bucket == "pending" or .bucket == "cancel")] | length == 0)
    and ([.[] | select(.name == $touched)] | length == 1)
    and ([.[] | select(.name == $aggregate and .bucket == "fail")] | length == 1)
    and ([.[] | select(.bucket == "fail") | .name] | sort) == ([$aggregate, $touched] | sort)
    and ([.[] | select(.bucket == "fail")][0].link | type == "string" and length > 0)
  ' <<< "$checks_json" >/dev/null 2>&1 || return 1

  # "Required CI gates" is a pure rollup whose needs include "Touched packages PR gate":
  # when Touched's failure is the accepted capacity exception, the aggregate's red is that
  # same failure counted twice, so it is exempted alongside Touched here. Everything else
  # in the shared required definition (delivery policy, Required contract gates) must pass.
  for check_name in "${REQUIRED_PR_CHECKS[@]}"; do
    [[ "$check_name" == "Touched packages PR gate" || "$check_name" == "$aggregate" ]] && continue
    jq -e --arg name "$check_name" 'any(.[]; .name == $name and .bucket == "pass")' <<< "$checks_json" >/dev/null 2>&1 || return 1
  done
  # The aggregate is red when Touched is red, so this narrow exception must inspect its other
  # children: the carried-capacity exception is valid only when the remaining CI gates passed.
  for check_name in "NUL bytes & lone negative assertions" "$ZF_PACK_PR_GATE" "Repo-path regression PR gate"; do
    jq -e --arg name "$check_name" 'any(.[]; .name == $name and .bucket == "pass")' <<< "$checks_json" >/dev/null 2>&1 || return 1
  done

  link="$(jq -r '[.[] | select(.name == "Touched packages PR gate" and .bucket == "fail")][0].link // empty' <<< "$checks_json")" || return 1
  [[ "$link" == "https://github.com/$REPO/actions/runs/"* ]] || return 1
  link_path="${link#https://github.com/$REPO/actions/runs/}"
  [[ "$link_path" =~ ^([1-9][0-9]*)/job/([1-9][0-9]*)$ ]] || return 1
  run_id="${BASH_REMATCH[1]}"
  job_id="${BASH_REMATCH[2]}"
  run_json="$(main_gh run view "$run_id" --repo "$REPO" --json headSha,status,conclusion,jobs -q '{headSha,status,conclusion,jobs}' 2>/dev/null)" || return 1
  jq -e --arg head "$expected_head" --argjson job_id "$job_id" --arg hook_step "$ZF_PACK_HOOK_STEP" '
    .headSha == $head and .status == "completed" and .conclusion == "failure"
    and ([.jobs[]? | select(.databaseId == $job_id)] | length == 1)
    and ([.jobs[]? | select(.databaseId == $job_id)][0] as $job
      | $job.conclusion == "failure"
      and ([$job.steps[]? | select(.conclusion == "failure")] as $failed
        | ($failed | length) == 1
          and $failed[0].name == "Ensure CI runner has capacity before dependency install")
      and ([$job.steps[]? | select(.name == "Run touched package gates in Dagger"
          or .name == "Run touched Postsubmit integration gates in Dagger"
          or .name == "Run changed integration tests in Dagger"
          or .name == $hook_step)] as $source
        | ($source | length) > 0 and all($source[]; .conclusion == "skipped")))
    and all(.jobs[]?; .conclusion != "failure" or .databaseId == $job_id)
  ' <<< "$run_json" >/dev/null 2>&1
}


main_fix_forward_carried_pr_registered() {
  local pr_number="$1" registry_path remote_command registry result release_runner helper
  [[ "$pr_number" =~ ^[1-9][0-9]*$ && -n "${DEPLOY_HOST:-}" ]] || return 2
  release_runner="$(zf_release_runner)" || return 2
  helper="$(dirname -- "$release_runner")/release-drift-carried.sh"
  [[ -r "$helper" ]] || return 2
  registry_path="${DEPLOY_DIR:-$ZF_DEPLOY_DIR}/release-drift-carried.tsv"
  printf -v remote_command 'path=%q; if [ ! -e "$path" ] && [ ! -L "$path" ]; then exit 0; fi; [ -r "$path" ] || exit 44; cat -- "$path"' "$registry_path"
  registry="$(ssh -o BatchMode=yes -o ConnectTimeout=15 "$DEPLOY_HOST" "$remote_command")" || return 2
  result="$(bash "$helper" --contains-pr "$pr_number" <<< "$registry")" || return 2
  jq -e '.unknown == false and .approved == true' <<< "$result" >/dev/null 2>&1
}


main_fix_forward_carried_checks_still_valid() {
  main_fix_forward_carried_capacity_check "$2" "$3" && main_fix_forward_carried_pr_registered "$1"
}


main_fix_forward_carried_exception_for_pr() {
  local pr_number="$1"
  main_merge_clear >/dev/null 2>&1 && return 1
  main_fix_forward_prepare_for_pr "$pr_number" || return 1
  [[ "$MAIN_FIX_FORWARD_REASON" == carried-hotpatch:* ]]
}


main_release_jobs_for_fix_forward() {
  local run_id="$1" jobs
  [[ "$run_id" =~ ^[1-9][0-9]*$ ]] || return 1
  jobs="$(main_gh api "repos/$REPO/actions/runs/$run_id/jobs?per_page=100" \
    -q '{total_count, jobs:[.jobs[] | {name, conclusion}]}')" || return 1
  jq -e 'type == "object" and (.total_count | type == "number")
    and (.jobs | type == "array") and (.total_count == (.jobs | length))
    and all(.jobs[]; (.name | type == "string" and length > 0)
      and (.conclusion == "success" or .conclusion == "skipped" or .conclusion == "failure"))' \
    <<< "$jobs" >/dev/null 2>&1 || return 1
  printf '%s\n' "$jobs"
}


main_current_sha() {
  local cache_window_start sha
  cache_window_start="$(date -u -d '10 years ago' '+%Y-%m-%dT%H:%M:%SZ')" || return 1
  sha="$(main_gh api -H 'Cache-Control: no-cache' -H 'Pragma: no-cache' \
    "repos/$REPO/commits?sha=main&per_page=1&since=$cache_window_start" -q '.[0].sha')" || return 1
  [[ "$sha" =~ ^[0-9a-f]{40}$ ]] || return 1
  printf '%s\n' "$sha"
}


main_fix_forward_assess() {
  local run_json="$1" jobs_json="$2" main_sha="$3" base_sha="$4"
  local checks_json="$5" reserved_run_id="$6" run_id job_name check_name
  local main_jobs pr_jobs refuse="" carried_capacity_exception=0
  local -a failed_jobs=() covered_checks=()

  if ! jq -e 'type == "object" and (.id | tostring | test("^[1-9][0-9]*$"))
    and .status == "completed" and .conclusion == "failure"' <<< "$run_json" >/dev/null 2>&1; then
    refuse="latest completed main verdict is not a failure"
  else
    run_id="$(jq -r '.id | tostring' <<< "$run_json")"
    if [[ "$reserved_run_id" == "$run_id" ]]; then
      refuse="fix-forward already used for main run $run_id"
    elif ! [[ "$main_sha" =~ ^[0-9a-f]{40}$ && "$base_sha" =~ ^[0-9a-f]{40}$ ]] \
      || [[ "$base_sha" != "$main_sha" ]]; then
      refuse="PR base is not the current main tip"
    elif [[ "$(pr_checks_outcome "$checks_json")" != pass ]]; then
      if [[ "${7:-0}" == 1 && "${8:-0}" == 1 ]] && jq -e '.total_count == (.jobs | length) and [.jobs[] | select(.conclusion == "failure") | .name] == ["Postsubmit validate"]' <<< "$jobs_json" >/dev/null 2>&1; then
        carried_capacity_exception=1
      else
        refuse="PR required checks are not all green"
      fi
    elif ! jq -e 'type == "object" and (.total_count | type == "number")
      and (.jobs | type == "array") and (.total_count == (.jobs | length))
      and (.jobs | length > 0)
      and all(.jobs[]; (.name | type == "string" and length > 0)
        and (.conclusion == "success" or .conclusion == "skipped" or .conclusion == "failure"))
      and any(.jobs[]; .conclusion == "failure")' <<< "$jobs_json" >/dev/null 2>&1; then
      refuse="main failure jobs are unreadable or incomplete"
    else
      mapfile -t failed_jobs < <(jq -r '.jobs[] | select(.conclusion == "failure") | .name' <<< "$jobs_json")
      for job_name in "${failed_jobs[@]}"; do
        if [[ "$job_name" == "Postsubmit validate" ]]; then
          if [[ "$carried_capacity_exception" == 1 ]]; then
            continue
          fi
          if ! jq -e 'any(.[]; .name == "Touched packages PR gate" and .bucket == "pass")' \
            <<< "$checks_json" >/dev/null 2>&1; then
            refuse="main red on $job_name is not covered by passing PR checks"
            break
          fi
          covered_checks+=("Touched packages PR gate")
          # The aggregate already proved the regression gates green-or-legitimately-skipped
          # (#4484); covering a Postsubmit-validate failure now means Touched + Required CI gates.
          if jq -e --arg name "Required CI gates" \
            'any(.[]; .name == $name and .bucket == "pass")' <<< "$checks_json" >/dev/null 2>&1; then
            covered_checks+=("Required CI gates")
          else
            refuse="main red on $job_name lacks a passing repository regression gate"
            break
          fi
        elif jq -e --arg name "$job_name" \
          'any(.[]; .name == $name and .bucket == "pass")' <<< "$checks_json" >/dev/null 2>&1; then
          covered_checks+=("$job_name")
        else
          refuse="main red on $job_name is not covered by passing PR checks"
          break
        fi
      done
    fi
  fi

  if [[ -n "$refuse" ]]; then
    jq -cn --arg reason "$refuse" '{eligible:false,reason:$reason}'
    return 0
  fi
  main_jobs="$(jq -r '[.jobs[] | select(.conclusion == "failure") | .name]
    | reduce .[] as $name ([]; if index($name) then . else . + [$name] end) | join(", ")' <<< "$jobs_json")"
  if [[ "$carried_capacity_exception" == 1 ]]; then
    pr_jobs="PR checks green except Touched packages PR gate (shared runner-capacity failure; source validation did not run)"
    jq -cn --arg run_id "$run_id" --arg main_jobs "$main_jobs" --arg pr_jobs "$pr_jobs" '{eligible:true,run_id:$run_id,main_jobs:$main_jobs,pr_jobs:$pr_jobs,reason:("carried-hotpatch: main red on " + $main_jobs + "; " + $pr_jobs)}'
    return 0
  fi
  pr_jobs="$(printf '%s\n' "${covered_checks[@]}" | jq -rRsc 'split("\n") | map(select(length > 0))
    | reduce .[] as $name ([]; if index($name) then . else . + [$name] end) | join(", ")')"
  jq -cn --arg run_id "$run_id" --arg main_jobs "$main_jobs" --arg pr_jobs "$pr_jobs" \
    '{eligible:true,run_id:$run_id,main_jobs:$main_jobs,pr_jobs:$pr_jobs,
      reason:("fix-forward: main red on " + $main_jobs + "; PR checks green on " + $pr_jobs)}'
}


main_fix_forward_reserved_run() {
  local path="$STATE_DIR/merge-fix-forward.json"
  [[ -e "$path" ]] || return 0
  jq -er 'select(type == "object" and (.run_id | type == "string" and test("^[1-9][0-9]*$"))) | .run_id' \
    "$path" 2>/dev/null
}


main_fix_forward_reserve() {
  local run_id="$1" main_sha="$2" pr_number="$3" path="$STATE_DIR/merge-fix-forward.json" tmp
  [[ "$run_id" =~ ^[1-9][0-9]*$ && "$main_sha" =~ ^[0-9a-f]{40}$ \
    && "$pr_number" =~ ^[1-9][0-9]*$ ]] || return 1
  mkdir -p "$STATE_DIR" || return 1
  tmp="$(mktemp "$STATE_DIR/.merge-fix-forward.XXXXXX")" || return 1
  if ! jq -cn --arg run_id "$run_id" --arg main_sha "$main_sha" --arg pr "$pr_number" \
    '{run_id:$run_id,main_sha:$main_sha,pr_number:$pr}' > "$tmp" \
    || ! chmod 600 "$tmp" || ! mv -f -- "$tmp" "$path"; then
    rm -f -- "$tmp"
    return 1
  fi
  return 0
}


main_fix_forward_prepare_for_pr() {
  local pr_number="$1" run_id current_pr checks jobs main_sha reserved assessment
  MAIN_FIX_FORWARD_REASON=""
  MAIN_FIX_FORWARD_RUN_ID=""
  MAIN_FIX_FORWARD_MAIN_SHA=""
  MAIN_FIX_FORWARD_PR_JSON=""
  MAIN_FIX_FORWARD_CHECKS=""
  if ! jq -e '.status == "completed" and .conclusion == "failure"
    and (.id | tostring | test("^[1-9][0-9]*$"))' <<< "$MAIN_RELEASE_RUN_JSON" >/dev/null 2>&1; then
    MAIN_FIX_FORWARD_REASON="latest completed main verdict is not a failure"
    return 1
  fi
  run_id="$(jq -r '.id | tostring' <<< "$MAIN_RELEASE_RUN_JSON")"
  if ! jobs="$(main_release_jobs_for_fix_forward "$run_id")" \
    || ! main_sha="$(main_current_sha)" \
    || ! current_pr="$(gh pr view "$pr_number" --repo "$REPO" \
      --json baseRefOid,headRefOid,mergeable,mergeStateStatus,updatedAt,files,isDraft 2>/dev/null)" \
    || ! checks="$(gh pr checks "$pr_number" --repo "$REPO" --json name,bucket,link 2>/dev/null)" \
    || ! reserved="$(main_fix_forward_reserved_run)"; then
    MAIN_FIX_FORWARD_REASON="could not verify current main, PR checks, or fix-forward reservation"
    return 1
  fi
  assessment="$(main_fix_forward_assess "$MAIN_RELEASE_RUN_JSON" "$jobs" "$main_sha" \
    "$(jq -r '.baseRefOid // empty' <<< "$current_pr")" "$checks" "$reserved")"
  if [[ "$(jq -r '.reason // empty' <<< "$assessment")" == "PR required checks are not all green" ]] \
    && main_fix_forward_carried_capacity_check "$checks" "$(jq -r '.headRefOid // empty' <<< "$current_pr")" \
    && main_fix_forward_carried_pr_registered "$pr_number"; then
    assessment="$(main_fix_forward_assess "$MAIN_RELEASE_RUN_JSON" "$jobs" "$main_sha" "$(jq -r '.baseRefOid // empty' <<< "$current_pr")" "$checks" "$reserved" 1 1)"
  fi
  MAIN_FIX_FORWARD_REASON="$(jq -r '.reason // "fix-forward eligibility unavailable"' <<< "$assessment")"
  if ! jq -e '.eligible == true' <<< "$assessment" >/dev/null 2>&1; then
    return 1
  fi
  MAIN_FIX_FORWARD_RUN_ID="$(jq -r '.run_id' <<< "$assessment")"
  MAIN_FIX_FORWARD_MAIN_SHA="$main_sha"
  MAIN_FIX_FORWARD_PR_JSON="$current_pr"
  MAIN_FIX_FORWARD_CHECKS="$checks"
}
