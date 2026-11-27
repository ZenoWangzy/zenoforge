merge_pr_view() {
  local pr="$1" fields="$2" out meta files commits head_sha body repo
  case "$fields" in
    body,files,commits)
      if out="$(gh pr view "$pr" --json body,headRefOid 2>/dev/null)" && [[ -n "$out" ]]; then
        head_sha="$(jq -er '.headRefOid | select(type == "string" and test("^[0-9a-f]{40,64}$"))' <<<"$out")" || return 1
        body="$(jq -r '.body // ""' <<<"$out")" || return 1
      else
        meta="$(gh api "repos/{owner}/{repo}/pulls/$pr" 2>/dev/null)" || return 1
        head_sha="$(jq -er '.head.sha | select(type == "string" and test("^[0-9a-f]{40,64}$"))' <<<"$meta")" || return 1
        body="$(jq -r '.body // ""' <<<"$meta")" || return 1
      fi
      repo="$(gh_key_cache_repo)" || return 1
      files="$(gh_pr_files_cached "$repo" "$pr" "$head_sha")" || return 1
      commits="$(gh_pr_commits_cached "$repo" "$pr" "$head_sha")" || return 1
      files="$(jq -cs '[.[][] | {path: .filename}]' <<<"$files")" || return 1
      commits="$(jq -cs '[.[][] | {oid: .sha, messageHeadline: (.commit.message | split("\n")[0]), committedDate: .commit.committer.date}]' <<<"$commits")" || return 1
      jq -cn --arg body "$body" --argjson f "$files" --argjson c "$commits" '{body:$body,files:$f,commits:$c}'
      ;;
    headRefName)
      if out="$(gh pr view "$pr" --json "$fields" 2>/dev/null)" && [[ -n "$out" ]]; then
        printf '%s\n' "$out"
      else
        meta="$(gh api "repos/{owner}/{repo}/pulls/$pr" 2>/dev/null)" || return 1
        jq -ce '{headRefName: .head.ref}' <<<"$meta"
      fi
      ;;
    *) return 1 ;;
  esac
}
