gh_key_cache_root() {
  if [[ -n "${GH_KEY_CACHE_DIR:-}" ]]; then
    printf '%s\n' "$GH_KEY_CACHE_DIR"
  elif [[ -n "${AGENT_HOME:-}" ]]; then
    printf '%s/state/gh-key-cache\n' "${AGENT_HOME%/}"
  else
    return 1
  fi
}

gh_key_cache_repo() {
  local repo="${GH_KEY_CACHE_REPO:-${REPO:-${GH_REPO:-${ZF_REPO:-}}}}" root="${ROOT:-${REPO_DIR:-$PWD}}" remote
  if [[ -z "$repo" ]]; then
    remote="$(git -C "$root" remote get-url origin 2>/dev/null || true)"
    repo="$(sed -E 's#^(git@[^:]+:|[a-z+]+://([^/@]+@)?[^/]+/)##; s#\.git$##' <<<"$remote")"
  fi
  printf '%s\n' "${repo:-$root}"
}

gh_key_cache_file() {
  local key="$1" repo root digest
  repo="$(gh_key_cache_repo)" || return 1
  root="$(gh_key_cache_root)" || return 1
  digest="$(printf '%s\0%s' "$repo" "$key" | sha256sum)" || return 1
  digest="${digest%% *}"
  [[ "$digest" =~ ^[[:xdigit:]]{64}$ ]] || return 1
  printf '%s/%s.json\n' "${root%/}" "$digest"
}

gh_key_cache_json_valid() {
  jq -e . >/dev/null 2>&1
}

gh_key_cache_array_valid() {
  jq -e 'type == "array"' >/dev/null 2>&1
}

gh_key_cache_pages_valid() {
  jq -se 'length > 0 and all(.[]; type == "array")' >/dev/null 2>&1
}

gh_pr_files_fetch() {
  gh api --paginate "repos/{owner}/{repo}/pulls/$2/files?per_page=100"
}

gh_pr_files_cached() {
  gh_key_cache_get "pr-files:$1:$2:$3" forever gh_key_cache_pages_valid gh_pr_files_fetch "$@"
}

gh_pr_files_fetch_for_repo() {
  gh api --paginate "repos/$1/pulls/$2/files?per_page=100"
}

gh_pr_files_cached_for_repo() {
  local repo="$1" pr="$2" sha="$3"
  GH_KEY_CACHE_REPO="$repo" gh_key_cache_get "pr-files:$repo:$pr:$sha" forever gh_key_cache_pages_valid gh_pr_files_fetch_for_repo "$repo" "$pr"
}

gh_pr_commits_fetch() {
  gh api --paginate "repos/{owner}/{repo}/pulls/$2/commits?per_page=100"
}

gh_pr_commits_cached() {
  gh_key_cache_get "pr-commits:$1:$2:$3" forever gh_key_cache_pages_valid gh_pr_commits_fetch "$@"
}

gh_issue_subissues_fetch() {
  local repo="$1" issue="$2" pages
  pages="$(gh api "repos/$repo/issues/$issue/sub_issues?per_page=100" --paginate)" || return 1
  jq -cs 'add // []' <<<"$pages"
}

gh_issue_subissues_cached() {
  local repo="$1" issue="$2"
  gh_key_cache_get "sub-issues:$repo:$issue" 600 gh_key_cache_array_valid gh_issue_subissues_fetch "$repo" "$issue"
}

gh_issue_subissues_invalidate() {
  local repo="$1" issue="$2"
  gh_key_cache_invalidate "sub-issues:$repo:$issue"
  if declare -p NATIVE_PARENT_SUBISSUES_CACHE >/dev/null 2>&1; then unset 'NATIVE_PARENT_SUBISSUES_CACHE[$issue]'; fi
  if declare -p DEP_NATIVE_KIDS >/dev/null 2>&1; then unset 'DEP_NATIVE_KIDS[$issue]'; fi
}

gh_issue_blocked_by_fetch() {
  gh api "repos/$1/issues/$2/dependencies/blocked_by"
}

gh_issue_blocked_by_cached() {
  local repo="$1" issue="$2"
  gh_key_cache_get "blocked-by:$repo:$issue" 600 gh_key_cache_array_valid gh_issue_blocked_by_fetch "$repo" "$issue"
}

gh_runner_pages_fetch() {
  gh api --paginate "repos/$1/actions/runners?per_page=100"
}

gh_runner_pages_valid() {
  jq -se 'length > 0 and all(.[]; type == "object" and (.runners | type == "array"))' >/dev/null 2>&1
}

gh_runners_cached() {
  local repo="${1:-}" endpoint_repo
  if [[ -n "$repo" ]]; then endpoint_repo="$repo"; else repo="$(gh_key_cache_repo)"; endpoint_repo='{owner}/{repo}'; fi
  GH_KEY_CACHE_REPO="$repo" gh_key_cache_get "runners:$repo" 300 gh_runner_pages_valid gh_runner_pages_fetch "$endpoint_repo"
}

gh_commit_check_runs_fetch() {
  local sha="$1" endpoint_repo="${2:-}" first count rows row_count page=1 extra page_rows
  [[ -n "$endpoint_repo" ]] || endpoint_repo='{owner}/{repo}'
  first="$(gh api "repos/$endpoint_repo/commits/$sha/check-runs?per_page=100" 2>/dev/null)" || return 1
  jq -e 'type == "object" and (.check_runs | type == "array")' <<<"$first" >/dev/null 2>&1 || return 1
  count="$(jq -er '.total_count | numbers' <<<"$first" 2>/dev/null)" || { printf '%s' "$first"; return 0; }
  rows="$(jq -c '.check_runs' <<<"$first")" || return 1
  row_count="$(jq -er 'length' <<<"$rows")" || return 1
  while (( row_count < count )); do
    (( page < 50 )) || return 1
    page=$((page + 1))
    extra="$(gh api "repos/$endpoint_repo/commits/$sha/check-runs?per_page=100&page=$page" 2>/dev/null)" || return 1
    page_rows="$(jq -ce 'select(type == "object" and (.check_runs | type == "array")) | .check_runs' <<<"$extra")" || return 1
    rows="$(jq -cn --argjson left "$rows" --argjson right "$page_rows" '$left + $right')" || return 1
    row_count="$(jq -er 'length' <<<"$rows")" || return 1
  done
  jq -cn --argjson total "$count" --argjson runs "$rows" '{total_count:$total,check_runs:$runs}'
}

gh_commit_check_runs_complete() {
  jq -e 'type == "object" and (.check_runs | type == "array")
    and ((.total_count // (.check_runs | length)) <= (.check_runs | length))
    and all(.check_runs[]; ((.status // "") | ascii_downcase) == "completed")' >/dev/null 2>&1
}

gh_actions_runs_for_sha_fetch() {
  gh api --paginate "repos/{owner}/{repo}/actions/runs?head_sha=$1&per_page=100"
}

gh_actions_runs_pages_valid() {
  jq -se 'length > 0 and all(.[]; type == "object" and (.workflow_runs | type == "array"))' >/dev/null 2>&1
}

gh_actions_runs_for_sha_cached() {
  local sha="$1" repo
  repo="$(gh_key_cache_repo)" || { gh_actions_runs_for_sha_fetch "$sha"; return $?; }
  gh_key_cache_get "workflow-runs:$repo:$sha" 15 gh_actions_runs_pages_valid gh_actions_runs_for_sha_fetch "$sha"
}

gh_workflow_runs_page_fetch() {
  gh api "$1"
}

gh_workflow_runs_page_valid() {
  jq -e 'type == "object" and (.workflow_runs | type == "array")' >/dev/null 2>&1
}

gh_workflow_runs_page_cached_for_repo() {
  local repo="$1" key="$2" endpoint="$3" ttl="${4:-15}"
  GH_KEY_CACHE_REPO="$repo" gh_key_cache_get "workflow-runs-page:$repo:$key" "$ttl" gh_workflow_runs_page_valid gh_workflow_runs_page_fetch "$endpoint"
}

gh_workflow_runs_slurped_fetch() {
  gh api "$1" --paginate --slurp
}

gh_workflow_runs_slurped_valid() {
  jq -e 'type == "array" and length > 0 and all(.[]; type == "object" and (.workflow_runs | type == "array"))' >/dev/null 2>&1
}

gh_workflow_runs_slurped_cached_for_repo() {
  local repo="$1" key="$2" endpoint="$3" ttl="${4:-15}"
  GH_KEY_CACHE_REPO="$repo" gh_key_cache_get "workflow-runs-pages:$repo:$key" "$ttl" gh_workflow_runs_slurped_valid gh_workflow_runs_slurped_fetch "$endpoint"
}

gh_run_view_fetch_for_repo() {
  if [[ "$3" == latest ]]; then
    gh run view "$2" --repo "$1" --json headSha,attempt,status,conclusion,jobs
  else
    gh run view "$2" --repo "$1" --attempt "$3" --json headSha,attempt,status,conclusion,jobs
  fi
}

gh_run_view_valid() {
  jq -e 'type == "object" and (.headSha | type == "string") and (.attempt | numbers) and (.jobs | type == "array")' >/dev/null 2>&1
}

gh_run_view_complete() {
  jq -e 'type == "object" and (.headSha | type == "string") and (.attempt | numbers)
    and ((.status // "") | ascii_downcase == "completed") and (.jobs | type == "array")
    and all(.jobs[]; ((.status // "") | ascii_downcase) == "completed")' >/dev/null 2>&1
}

gh_run_view_cached_for_repo() {
  local repo="$1" run_id="$2" attempt="$3" completed="${4:-false}" ttl=15 predicate=gh_run_view_valid
  if [[ "$completed" == true && "$attempt" != latest ]]; then ttl=forever; predicate=gh_run_view_complete; fi
  GH_KEY_CACHE_REPO="$repo" gh_key_cache_get "workflow-run:$repo:$run_id:$attempt" "$ttl" "$predicate" gh_run_view_fetch_for_repo "$repo" "$run_id" "$attempt"
}

gh_commit_check_runs_persisted() {
  local sha="$1" repo="${2:-}"
  if [[ -n "$repo" ]]; then
    GH_KEY_CACHE_REPO="$repo" gh_key_cache_get "check-runs:$repo:$sha" 600 gh_commit_check_runs_complete gh_commit_check_runs_fetch "$sha" "$repo"
    return $?
  fi
  repo="$(gh_key_cache_repo)" || { gh_commit_check_runs_fetch "$sha"; return $?; }
  gh_key_cache_get "check-runs:$repo:$sha" 600 gh_commit_check_runs_complete gh_commit_check_runs_fetch "$sha"
}

gh_commit_check_runs_invalidate() {
  local sha="$1" repo
  [[ "$sha" =~ ^[0-9a-f]{40,64}$ ]] || return 0
  repo="$(gh_key_cache_repo)" || return 0
  gh_key_cache_invalidate "check-runs:$repo:$sha"
  [[ -z "${GH_TICK_CACHE_DIR:-}" ]] || rm -f -- "$GH_TICK_CACHE_DIR/check-runs-$sha.json"
  if declare -p TICK_PR_CHECK_RUNS >/dev/null 2>&1; then unset "TICK_PR_CHECK_RUNS[$sha]"; fi
  if declare -p CI_MAIN_RED_CHECKS_CACHE >/dev/null 2>&1; then unset "CI_MAIN_RED_CHECKS_CACHE[$sha]"; fi
}

gh_key_cache_invalidate() {
  local cache="$1" file lock_fd
  file="$(gh_key_cache_file "$cache")" || return 0
  mkdir -p -- "${file%/*}" 2>/dev/null || return 0
  exec {lock_fd}>>"$file.lock" || return 0
  flock -x "$lock_fd" || { exec {lock_fd}>&-; return 0; }
  rm -f -- "$file"
  flock -u "$lock_fd" || :
  exec {lock_fd}>&-
}

gh_issue_blocked_by_invalidate() {
  local repo="$1" issue="$2"
  gh_key_cache_invalidate "blocked-by:$repo:$issue"
  if declare -p OPEN_BLOCKER_SNAPSHOT_STATE >/dev/null 2>&1; then
    unset 'OPEN_BLOCKER_SNAPSHOT_STATE[$issue]' 'OPEN_BLOCKER_SNAPSHOT_IDS[$issue]'
  fi
  if declare -F supervisor_hold_invalidate_open_blocker >/dev/null 2>&1; then
    supervisor_hold_invalidate_open_blocker "$issue"
  fi
}

gh_key_cache_get() {
  local key="$1" ttl="$2" predicate="$3" fetch="$4" file lock_fd now fetched data rc=0 tmp
  shift 4
  [[ "$ttl" == forever || "$ttl" =~ ^[0-9]+$ ]] || return 64
  file="$(gh_key_cache_file "$key")" || { "$fetch" "$@"; return $?; }
  mkdir -p -- "${file%/*}" 2>/dev/null || { "$fetch" "$@"; return $?; }
  exec {lock_fd}>>"$file.lock" || { "$fetch" "$@"; return $?; }
  flock -x "$lock_fd" || { exec {lock_fd}>&-; return 1; }
  if [[ -s "$file" ]]; then
    fetched="$(head -n1 "$file")"
    now="$(date +%s)"
    if [[ "$fetched" =~ ^[0-9]+$ ]] && [[ "$ttl" == forever || ( "$now" =~ ^[0-9]+$ && "$now" -ge "$fetched" && $((now - fetched)) -lt "$ttl" ) ]]; then
      data="$(tail -n +2 "$file")"
      if printf '%s' "$data" | "$predicate"; then
        flock -u "$lock_fd" || :
        exec {lock_fd}>&-
        printf '%s' "$data"
        return 0
      fi
    fi
  fi
  data="$("$fetch" "$@")" || rc=$?
  if (( rc == 0 )) && printf '%s' "$data" | "$predicate"; then
    tmp="$(mktemp "$file.XXXXXX" 2>/dev/null)" || tmp=""
    if [[ -n "$tmp" ]]; then
      if { date +%s && printf '%s' "$data"; } >"$tmp" && mv -f -- "$tmp" "$file"; then :; else rm -f -- "$tmp"; fi
    fi
  fi
  flock -u "$lock_fd" || :
  exec {lock_fd}>&-
  (( rc == 0 )) || return "$rc"
  printf '%s' "$data"
}
