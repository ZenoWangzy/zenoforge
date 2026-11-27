TRIAGE_PR_CENSUS=''

triage_pr_census_load() {
  local cutoff="$1" repo="${2:-${REPO:-}}" issue_numbers="${3:-}" open_pages closed_pages page_json page=1 page_count=0 oldest tmp issue_id
  [[ "$cutoff" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T ]] || return 2
  [[ "$repo" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] || return 2
  [[ -n "$issue_numbers" ]] || return 2
  for issue_id in $issue_numbers; do [[ "$issue_id" =~ ^[1-9][0-9]*$ ]] || return 2; done
  open_pages="$(gh api --paginate --slurp "repos/$repo/pulls?state=open&per_page=100")" || return 1
  jq -e 'type == "array" and all(.[]; type == "array")' <<<"$open_pages" >/dev/null || return 1
  tmp="$(mktemp)" || return 1
  while (( page <= 50 )); do
    page_json="$(gh api "repos/$repo/pulls?state=closed&sort=updated&direction=desc&per_page=100&page=$page")" || { rm -f -- "$tmp"; return 1; }
    jq -e 'type == "array" and all(.[]; type == "object" and (.number | type == "number") and (.updated_at | type == "string") and (.head.ref | type == "string") and (.base.ref | type == "string"))' <<<"$page_json" >/dev/null || { rm -f -- "$tmp"; return 1; }
    page_json="$(jq -c '[.[] | {number, state, draft, head:{ref:.head.ref}, base:{ref:.base.ref}, title, body, merge_commit_sha, merged_at, updated_at}]' <<<"$page_json")" || { rm -f -- "$tmp"; return 1; }
    printf '%s\n' "$page_json" >>"$tmp" || { rm -f -- "$tmp"; return 1; }
    page_count="$(jq 'length' <<<"$page_json")" || { rm -f -- "$tmp"; return 1; }
    oldest="$(jq -r '[.[].updated_at] | min // ""' <<<"$page_json")" || { rm -f -- "$tmp"; return 1; }
    if (( page_count < 100 )) || [[ "$oldest" < "$cutoff" ]]; then break; fi
    (( page < 50 )) || { rm -f -- "$tmp"; return 1; }
    page=$((page + 1))
  done
  closed_pages="$(jq -cs 'add' "$tmp")" || { rm -f -- "$tmp"; return 1; }
  rm -f -- "$tmp"
  TRIAGE_PR_CENSUS="$(jq -c --argjson closed "$closed_pages" --arg cutoff "$cutoff" --arg issues "$issue_numbers" '
    def matches_issue($n): .head.ref == ("agent/issue-" + $n)
      or (((.title // "") + "\n" + (.body // "")) | test("(^|[^A-Za-z0-9_])#" + $n + "([^0-9]|$)"; "i"));
    (add | map({number, state:"OPEN", draft:(.draft // false), head:.head, base:.base,
      title, body, merge_commit_sha, merged_at, updated_at})) as $open
    | ($closed | map(select(.updated_at >= $cutoff and .merged_at != null)) | map({number,
      state:(if .merged_at != null then "MERGED" else "CLOSED" end), draft:(.draft // false), head:.head, base:.base,
      title, body, merge_commit_sha, merged_at, updated_at})) as $closed
    | ($issues | split(" ")) as $numbers
    | ($open + $closed) | map(select(. as $pr | any($numbers[]; . as $number | $pr | matches_issue($number))))
  ' <<<"$open_pages")" || { TRIAGE_PR_CENSUS=''; return 1; }
  jq -e 'type == "array" and all(.[]; (.number | type == "number") and (.head.ref | type == "string") and (.base.ref | type == "string"))' \
    <<<"$TRIAGE_PR_CENSUS" >/dev/null || { TRIAGE_PR_CENSUS=''; return 1; }
}

triage_pr_census_for_issue() {
  local n="$1" census="${TRIAGE_PR_CENSUS:-}"
  if [[ -z "$census" ]]; then
    [[ -n "${TRIAGE_PR_CENSUS_FILE:-}" && -r "$TRIAGE_PR_CENSUS_FILE" ]] || return 1
    census="$(cat -- "$TRIAGE_PR_CENSUS_FILE")" || return 1
  fi
  [[ "$n" =~ ^[1-9][0-9]*$ ]] && jq -ce --argjson n "$n" '
    ($n | tostring) as $number
    | .
    | map(select(.head.ref == ("agent/issue-" + $number)
        or (((.title // "") + "\n" + (.body // ""))
          | test("(^|[^A-Za-z0-9_])#" + $number + "([^0-9]|$)"; "i"))))
    | map({number, state, isDraft:(.draft // false), headRefName:.head.ref, baseRefName:.base.ref,
      mergeCommit:(if .merge_commit_sha == null then null else {oid:.merge_commit_sha} end), mergedAt:.merged_at})
    | unique_by(.number)
  ' <<<"$census"
}
