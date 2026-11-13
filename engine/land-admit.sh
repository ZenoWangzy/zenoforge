# Shared admission checks for every landing entry point.
# Each function returns 0 to admit and 1 to refuse.
land_receipt_green() {
  local receipt="${1-}" reason
  if [[ ! -f "$receipt" ]]; then
    printf 'refuse:receipt:missing\n' >&2
    return 1
  fi
  if [[ ! -s "$receipt" ]]; then
    printf 'refuse:receipt:empty\n' >&2
    return 1
  fi
  if awk -F'\t' 'NF >= 2 && $1 ~ /^[0-9]+$/ { last[$2] = $1; n++ } END { bad = (n == 0); for (c in last) if (last[c] + 0 != 0) bad = 1; exit bad }' \
    "$receipt"; then
    return 0
  fi
  reason="$(awk -F'\t' '
    NF >= 2 && $1 ~ /^[0-9]+$/ { last[$2] = $1; n++ }
    END {
      if (n == 0) {
        print "no-valid-lines"
        exit
      }
      for (c in last) if (last[c] + 0 != 0) {
        print "failed:" c
        exit
      }
    }
  ' "$receipt")"
  printf 'refuse:receipt:%s\n' "$reason" >&2
  return 1
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
  merge_args=(pr merge "$pr" --squash --match-head-commit "$head_sha")
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
  if gh "${merge_args[@]}"; then
    return 0
  else
    gh_rc=$?
  fi
  [[ "${LAND_MERGE_REST_FALLBACK:-}" == 1 ]] || return "$gh_rc"
  view_args=(pr view "$pr")
  view_args+=("${repo_args[@]}" --json headRefName)
  head_json="$(gh "${view_args[@]}" 2>/dev/null)" || return 1
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
    printf 'refuse:merge:head-moved:%s is no longer the head, not merged\n' "$head_sha" >&2
  fi
  return 1
}
