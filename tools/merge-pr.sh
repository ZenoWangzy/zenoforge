#!/usr/bin/env bash
# Run the CI-equivalent local suites for this exact HEAD, record their exit
# codes under .git, then merge only if GitHub still reports the tested SHA.
set -uo pipefail

MERGE_PR_ENGINE_SHARDS=8
MERGE_PR_MAX_PARALLEL=4

merge_pr_root() {
  git rev-parse --show-toplevel 2>/dev/null
}

merge_pr_result_dir() {
  local repo="$1" git_dir
  git_dir="$(git -C "$repo" rev-parse --git-dir 2>/dev/null)" || return 1
  case "$git_dir" in
    /*) ;;
    *) git_dir="$repo/$git_dir" ;;
  esac
  printf '%s/zenoforge-merge-pr\n' "$git_dir"
}

merge_pr_result_file() {
  local dir
  dir="$(merge_pr_result_dir "$1")" || return 1
  printf '%s/%s.json\n' "$dir" "$2"
}

merge_pr_refuse() {
  printf 'refusing to merge PR #%s: %s\n' "$1" "$2" >&2
  return 1
}

merge_pr_join_checks() {
  local separator='' check_name
  for check_name in "$@"; do
    printf '%s%s' "$separator" "$check_name"
    separator=', '
  done
}

merge_pr_result_is_green() {
  local result_file="$1" sha="$2"
  jq -e --arg sha "$sha" '
    .sha == $sha
    and .green == true
    and .cli_exit_code == 0
    and (.engine_shards | type == "array"
      and length == 8
      and ([.[].shard] | sort == [0,1,2,3,4,5,6,7])
      and all(.[]; .exit_code == 0))
  ' "$result_file" >/dev/null 2>&1
}

# Ruling zenoforge-limited-allow-research-first-2026-11-05: a PR body must cite
# researched prior art. PRs that touch only test files are exempt.
merge_pr_prior_art_ok() {
  local pr="$1" view body section
  if ! view="$(gh pr view "$pr" --json body,files,commits 2>/dev/null)" || ! jq -e '
      (.body | type == "string") and (.files | type == "array"
        and all(.[]; (.path | type) == "string"))' <<<"$view" >/dev/null 2>&1; then
    merge_pr_refuse "$pr" 'could not read the PR body and file list as JSON'
    return 1
  fi
  # A reused branch name can turn a new PR into someone's old commits (#413).
  if jq -e '(.commits[-1].committedDate // null) as $at
      | $at != null and (now - ($at | fromdateiso8601)) > 86400' <<<"$view" >/dev/null 2>&1; then
    merge_pr_refuse "$pr" 'PR head commit is over 24 hours old: check the branch is yours, then rebase it'
    return 1
  fi
  # shortcut: test-file naming is a path heuristic, tighten if a non-test file matches it.
  if jq -e '(.files | length) > 0 and all(.files[].path;
      test("(^|/)(tests?|__tests__|fixtures)/") or test("\\.(test|spec)\\.[^/]+$"))' \
      <<<"$view" >/dev/null; then
    return 0
  fi
  body="$(jq -r '.body' <<<"$view" | tr -d '\r' | tr '[:upper:]' '[:lower:]')"
  section="$(awk '/^##[ \t]+prior-art[ \t]*$/ {on=1; next}
    on && /^##?[ \t]/ {on=0}
    on' <<<"$body")"
  if ! grep -Eq '^##[[:space:]]+prior-art[[:space:]]*$' <<<"$body"; then
    merge_pr_refuse "$pr" 'PR body has no "## prior-art" section (see ruling zenoforge-limited-allow-research-first-2026-11-05)'
    return 1
  fi
  if ! grep -Eq 'https?://[^[:space:])>]+|^no external prior art:[[:space:]]*[^[:space:]]' <<<"$section"; then
    merge_pr_refuse "$pr" '"## prior-art" needs a source URL or a line "no external prior art: <reason>"'
    return 1
  fi
}

merge_pr_checks_and_merge() {
  local pr="${1:-}" checks_json check_name override_name matched
  local -a override_names=() failed_names=() blocked_names=() overridden_names=()
  if [[ $# -ne 1 || ! "$pr" =~ ^[0-9]+$ ]]; then
    printf 'usage: tools/merge-pr.sh <pr-number>\n' >&2
    return 2
  fi

  # gh pr checks exits non-zero when checks are failed or pending. The JSON
  # buckets distinguish those valid results from a command/API error.
  checks_json="$(gh pr checks "$pr" --json bucket,name 2>/dev/null)" || :
  if ! jq -e 'type == "array" and all(.[];
      type == "object" and (.name | type == "string" and length > 0)
      and (.bucket | type == "string"))' <<<"$checks_json" >/dev/null 2>&1; then
    merge_pr_refuse "$pr" 'could not read PR checks as JSON'
    return 1
  fi

  if [[ -n "${ZF_MERGE_OVERRIDE:-}" ]]; then
    case "$ZF_MERGE_OVERRIDE" in
      ,*|*,|*,,*)
        merge_pr_refuse "$pr" 'ZF_MERGE_OVERRIDE must contain comma-separated check names'
        return 1
        ;;
    esac
    IFS=, read -r -a override_names <<<"$ZF_MERGE_OVERRIDE"
    for override_name in "${override_names[@]}"; do
      if [[ -z "$override_name" ]]; then
        merge_pr_refuse "$pr" 'ZF_MERGE_OVERRIDE must contain comma-separated check names'
        return 1
      fi
    done
  fi

  matched=0
  for override_name in "${override_names[@]}"; do
    [[ "$override_name" == prior-art ]] && matched=1
  done
  if (( matched )); then
    printf 'merge-pr: explicit ZF_MERGE_OVERRIDE skips the prior-art check for PR #%s\n' "$pr" >&2
  else
    merge_pr_prior_art_ok "$pr" || return 1
  fi

  while IFS= read -r check_name; do
    [[ -n "$check_name" ]] || continue
    failed_names+=("$check_name")
    matched=0
    for override_name in "${override_names[@]}"; do
      if [[ "$check_name" == "$override_name" ]]; then
        matched=1
        break
      fi
    done
    if (( matched )); then
      overridden_names+=("$check_name")
    else
      blocked_names+=("$check_name")
    fi
  done < <(jq -r '.[] | select(.bucket == "fail") | .name' <<<"$checks_json")

  if ((${#blocked_names[@]})); then
    local failed_csv blocked_csv
    failed_csv="$(merge_pr_join_checks "${failed_names[@]}")"
    blocked_csv="$(merge_pr_join_checks "${blocked_names[@]}")"
    merge_pr_refuse "$pr" "failed checks: $failed_csv; checks without a matching ZF_MERGE_OVERRIDE: $blocked_csv"
    return 1
  fi
  if ((${#overridden_names[@]})); then
    local overridden_csv
    overridden_csv="$(merge_pr_join_checks "${overridden_names[@]}")"
    printf 'merge-pr: explicit ZF_MERGE_OVERRIDE allows failed checks: %s\n' "$overridden_csv" >&2
  fi

  gh pr merge "$pr" --squash --delete-branch
}

merge_pr_gate() {
  local pr="$1" sha="$2" repo="${3:-$(merge_pr_root)}"
  local result_file head_json head_sha
  if [[ ! "$pr" =~ ^[0-9]+$ ]]; then
    merge_pr_refuse "$pr" 'PR number must be numeric'
    return 1
  fi
  if [[ ! "$sha" =~ ^[0-9a-f]{40}$ ]]; then
    merge_pr_refuse "$pr" 'tested SHA is not a full commit ID'
    return 1
  fi
  result_file="$(merge_pr_result_file "$repo" "$sha")" || {
    merge_pr_refuse "$pr" 'cannot locate the repository result directory'
    return 1
  }
  if [[ ! -f "$result_file" ]]; then
    merge_pr_refuse "$pr" "no full-suite result exists for SHA $sha"
    return 1
  fi
  if ! merge_pr_result_is_green "$result_file" "$sha"; then
    if jq -e --arg sha "$sha" '
      .sha == $sha and (.green == false
        or .cli_exit_code != 0
        or any(.engine_shards[]?; .exit_code != 0))
    ' "$result_file" >/dev/null 2>&1; then
      merge_pr_refuse "$pr" "full local suites are red for SHA $sha"
    else
      merge_pr_refuse "$pr" "the full-suite result for SHA $sha is incomplete or invalid"
    fi
    return 1
  fi
  if ! head_json="$(gh pr view "$pr" --json headRefOid 2>&1)"; then
    merge_pr_refuse "$pr" "could not read the PR head: $head_json"
    return 1
  fi
  head_sha="$(jq -er '.headRefOid | select(type == "string")' <<<"$head_json" 2>/dev/null)" || {
    merge_pr_refuse "$pr" 'GitHub did not return a PR head SHA'
    return 1
  }
  if [[ "$head_sha" != "$sha" ]]; then
    merge_pr_refuse "$pr" "PR head $head_sha does not match tested SHA $sha"
    return 1
  fi
  printf 'full local suites are green for %s and PR #%s still points to that SHA; checking PR checks before merge\n' "$sha" "$pr"
  merge_pr_checks_and_merge "$pr"
}

merge_pr_main() {
  local pr="${1:-}" repo sha result_dir log_dir result_file cli_rc rc green current_sha engine_results='[]'
  local shard pid status_file
  local -a pids=()
  if [[ $# -ne 1 || ! "$pr" =~ ^[0-9]+$ ]]; then
    printf 'usage: tools/merge-pr.sh <pr-number>\n' >&2
    return 2
  fi
  repo="$(merge_pr_root)" || {
    merge_pr_refuse "$pr" 'run this helper inside a Git checkout'
    return 1
  }
  cd "$repo" || return 1
  if [[ -n "$(git status --porcelain 2>/dev/null)" ]]; then
    merge_pr_refuse "$pr" 'the working tree must be clean so the tested SHA identifies the source'
    return 1
  fi
  sha="$(git rev-parse HEAD 2>/dev/null)" || {
    merge_pr_refuse "$pr" 'could not read the current HEAD'
    return 1
  }
  result_dir="$(merge_pr_result_dir "$repo")" || {
    merge_pr_refuse "$pr" 'cannot locate the repository result directory'
    return 1
  }
  mkdir -p "$result_dir" || return 1
  result_file="$result_dir/$sha.json"
  log_dir="$result_dir/$sha-logs"
  rm -f "$result_file"
  rm -rf "$log_dir"
  mkdir -p "$log_dir" || return 1

  for ((shard=0; shard<MERGE_PR_ENGINE_SHARDS; shard++)); do
    (
      # The host is shared with production; shards yield to it under load.
      nice -n 10 bash "$repo/tools/run-engine-tests.sh" "$shard" "$MERGE_PR_ENGINE_SHARDS" \
        >"$log_dir/engine-$shard.log" 2>&1
      rc=$?
      printf '%s\n' "$rc" >"$log_dir/engine-$shard.exit"
      exit "$rc"
    ) &
    pids+=("$!")
    if (( ${#pids[@]} >= MERGE_PR_MAX_PARALLEL )); then
      wait "${pids[0]}" || :
      pids=("${pids[@]:1}")
    fi
  done
  for pid in "${pids[@]}"; do wait "$pid" || :; done

  for ((shard=0; shard<MERGE_PR_ENGINE_SHARDS; shard++)); do
    status_file="$log_dir/engine-$shard.exit"
    if [[ -f "$status_file" ]]; then
      rc="$(cat "$status_file")"
      [[ "$rc" =~ ^[0-9]+$ ]] || rc=125
    else
      rc=125
    fi
    engine_results="$(jq -cn --argjson current "$engine_results" --argjson shard "$shard" --argjson rc "$rc" \
      '$current + [{shard:$shard,exit_code:$rc}]')"
  done

  npm test >"$log_dir/cli.log" 2>&1
  cli_rc=$?
  [[ "$cli_rc" =~ ^[0-9]+$ ]] || cli_rc=125
  green=false
  if [[ "$cli_rc" == 0 ]] && jq -e 'all(.[]; .exit_code == 0)' <<<"$engine_results" >/dev/null; then
    green=true
  fi
  jq -n --arg sha "$sha" --argjson engine_shards "$engine_results" \
    --argjson cli_exit_code "$cli_rc" --argjson green "$green" \
    '{sha:$sha,engine_shards:$engine_shards,cli_exit_code:$cli_exit_code,green:$green}' \
    >"$result_file.tmp" && mv -f "$result_file.tmp" "$result_file" || {
      merge_pr_refuse "$pr" "could not record full-suite results for SHA $sha"
      return 1
    }

  for ((shard=0; shard<MERGE_PR_ENGINE_SHARDS; shard++)); do
    rc="$(jq -r --argjson shard "$shard" '.[] | select(.shard==$shard) | .exit_code' <<<"$engine_results")"
    printf 'ENGINE_SHARD=%s/%s EXIT_CODE=%s\n' "$shard" "$MERGE_PR_ENGINE_SHARDS" "$rc"
    tail -n 15 "$log_dir/engine-$shard.log"
  done
  printf 'CLI_TEST=npm test EXIT_CODE=%s\n' "$cli_rc"
  tail -n 15 "$log_dir/cli.log"
  printf 'FULL_SUITE_SHA=%s GREEN=%s RESULT=%s\n' "$sha" "$green" "$result_file"

  current_sha="$(git rev-parse HEAD 2>/dev/null)" || current_sha=''
  if [[ "$current_sha" != "$sha" ]]; then
    merge_pr_refuse "$pr" "local HEAD changed during the suites (tested $sha, now ${current_sha:-unknown})"
    return 1
  fi
  merge_pr_gate "$pr" "$sha" "$repo"
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  if [[ "${ZF_ALLOW_FULL_GATE:-}" == 1 ]]; then
    merge_pr_main "$@"
  else
    # Ruling zenoforge-no-local-gate-2026-11-04: only the focused tests run locally.
    merge_pr_checks_and_merge "$@"
  fi
fi
