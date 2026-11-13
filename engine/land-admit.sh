# Shared admission checks for every landing entry point.
# Each function returns 0 to admit and 1 to refuse.
land_receipt_green() {
  local receipt="${1-}"
  if [[ ! -f "$receipt" ]]; then
    printf 'refuse:receipt:missing\n' >&2
    return 1
  fi
  if [[ ! -s "$receipt" ]]; then
    printf 'refuse:receipt:empty\n' >&2
    return 1
  fi
  awk -F'\t' -v strict="${LAND_RECEIPT_STRICT:-0}" '
    {
      if (strict == 1) {
        tab = index($0, "\t")
        rc = substr($0, 1, tab - 1)
        cmd = substr($0, tab + 1)
        if (tab == 0 || rc !~ /^[0-9]+$/ || cmd == "") {
          print "malformed receipt line " NR
          bad = 1
          next
        }
      } else {
        if (NF < 2 || $1 !~ /^[0-9]+$/) next
        rc = $1
        cmd = $2
      }
      last[cmd] = rc
      n++
    }
    END {
      if (strict == 1) {
        for (cmd in last) if (last[cmd] + 0 != 0) {
          print cmd " (exit " last[cmd] ")"
          bad = 1
        }
        exit bad
      }
      if (n == 0) {
        print "refuse:receipt:no-valid-lines"
        exit 1
      }
      for (c in last) if (last[c] + 0 != 0) {
        print "refuse:receipt:failed:" c
        exit 1
      }
    }
  ' "$receipt" >&2
}

land_receipt_file() {
  local clone="${1-}" head_sha="${2-}" git_common_dir
  git_common_dir="$(git -C "$clone" rev-parse --git-common-dir 2>/dev/null)" || return 1
  case "$git_common_dir" in /*) ;; *) git_common_dir="${clone%/}/$git_common_dir" ;; esac
  printf '%s/zf-test-receipts/%s\n' "${git_common_dir%/}" "$head_sha"
}

land_merge_pr() {
  local pr="${1-}" head_sha="${2-}" repo="" gh_rc head_json head_ref out
  local -a merge_args=() repo_args=() view_args=() api_args=()
  if [[ ! "$pr" =~ ^[0-9]+$ || ! "$pr" =~ [1-9] ]]; then
    printf 'refuse:merge:bad-pr\n' >&2
    return 64
  fi
  if [[ ! "$head_sha" =~ ^[0-9a-f]{40}$ ]]; then
    printf 'refuse:merge:bad-head\n' >&2
    return 64
  fi
  shift 2
  merge_args=(pr merge "$pr" --squash)
  while (($#)); do
    case "$1" in
      --repo|--subject|--body)
        if (($# < 2)); then
          printf 'refuse:merge:bad-option\n' >&2
          return 64
        fi
        merge_args+=("$1" "$2")
        if [[ "$1" == --repo ]]; then
          repo="$2"
          repo_args=(--repo "$repo")
        fi
        shift 2
        ;;
      --delete-branch)
        merge_args+=("$1")
        shift
        ;;
      *)
        printf 'refuse:merge:bad-option\n' >&2
        return 64
        ;;
    esac
  done
  merge_args+=(--match-head-commit "$head_sha")
  if gh "${merge_args[@]}"; then
    return 0
  else
    gh_rc=$?
  fi
  [[ "${LAND_MERGE_REST_FALLBACK:-}" == 1 ]] || return "$gh_rc"
  view_args=(pr view "$pr")
  view_args+=("${repo_args[@]}" --json headRefName)
  if ! head_json="$(gh "${view_args[@]}" 2>/dev/null)" || [[ -z "$head_json" ]]; then
    api_args=(api)
    api_args+=("${repo_args[@]}" "repos/{owner}/{repo}/pulls/$pr")
    head_json="$(gh "${api_args[@]}" 2>/dev/null)" || return 1
    head_json="$(jq -ce '{headRefName: .head.ref}' <<<"$head_json" 2>/dev/null)" || return 1
  fi
  head_ref="$(jq -er '.headRefName | select(type == "string" and length > 0)' <<<"$head_json")" || return 1
  api_args=(api)
  api_args+=("${repo_args[@]}" -X PUT "repos/{owner}/{repo}/pulls/$pr/merge" -f merge_method=squash -f "sha=$head_sha")
  if out="$(gh "${api_args[@]}" 2>&1)"; then
    api_args=(api)
    api_args+=("${repo_args[@]}" -X DELETE "repos/{owner}/{repo}/git/refs/heads/$head_ref")
    if gh "${api_args[@]}" >/dev/null 2>&1; then
      :
    fi
    return 0
  fi
  if [[ "$out" == *409* ]]; then
    if [[ "${LAND_MERGE_PR_REFUSAL:-}" == 1 ]]; then
      printf 'refusing to merge PR #%s: head moved after the gate: %s is no longer the head, not merged\n' "$pr" "$head_sha" >&2
    else
      printf 'refuse:merge:head-moved:%s is no longer the head, not merged\n' "$head_sha" >&2
    fi
  fi
  return 1
}
