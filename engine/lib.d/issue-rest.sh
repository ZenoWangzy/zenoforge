# REST reads of one issue for the paths that decide a hold, a requeue, a recut or a ruling (#1038).
# `gh issue view --json` goes through GraphQL, whose secondary rate limit refused these reads and
# stalled the scheduler; REST has its own budget. The output keeps the shape `gh issue view --json`
# gave (state OPEN/CLOSED, labels [{name}], comments [{id,body,createdAt,url,author}]) so a caller
# keeps its own comparisons.
#
# issue_rest_view <issue> [repo] [comments]
#   stdout: one JSON object {number,title,body,state,stateReason,closedAt,labels[,comments]}.
#   `comments` is emitted only when asked for: an absent key can never read as "no comments".
#   Nonzero with no stdout when the number is not a positive integer, the repo is unknown, either
#   API call fails, the number is a pull request (gh issue view refused those too), or the answer is
#   not a well-formed issue. A caller must treat that as unreadable and must not pick a branch from it.
issue_rest_view() {
  local n="${1:-}" repo="${2:-${REPO:-}}" want_comments="${3:-}" issue comments='[]'
  [[ "$n" =~ ^[1-9][0-9]*$ && -n "$repo" ]] || return 2
  issue="$(gh api "repos/$repo/issues/$n" 2>/dev/null)" || return 1
  if [[ "$want_comments" == comments ]]; then
    comments="$(gh api --paginate --slurp "repos/$repo/issues/$n/comments?per_page=100" 2>/dev/null)" || return 1
  fi
  jq -ce --argjson comments "$comments" --argjson n "$n" --argjson with_comments "$([[ "$want_comments" == comments ]] && echo true || echo false)" '
    select(type == "object" and .number == $n and (.pull_request | not)
      and (.state | IN("open", "closed")) and (.labels | type == "array") and all(.labels[]; type == "object" and (.name | type == "string"))
      and ($comments | type == "array") and all($comments[]; type == "array" or type == "object"))
    | {number, title, body: (.body // ""), state: (.state | ascii_upcase),
       stateReason: (.state_reason | if type == "string" then ascii_upcase else null end),
       closedAt: .closed_at, labels: [.labels[] | {name}]}
      + (if $with_comments then {comments: [$comments | flatten[] | {id: .node_id, body: (.body // ""), createdAt: .created_at, url: .html_url, author: {login: .user.login}}]} else {} end)
  ' <<< "$issue"
}

# issue_rest_state <issue> [repo] -- prints OPEN or CLOSED; nonzero and silent when unreadable.
issue_rest_state() {
  local view
  view="$(issue_rest_view "$@")" || return 1
  jq -r '.state' <<< "$view"
}

# issue_rest_list <label> [state=open] [repo] -- every issue with the label as one JSON array of
# {number,title,body,state,createdAt,author,labels}, the fields `gh issue list --json` gave, via
# REST (pull requests dropped, every page read). Nonzero with no stdout when the call fails on any
# page or the answer is not a list of issues: a caller must treat that as "could not list", never as
# an empty queue.
issue_rest_list() {
  local label="${1:-}" state="${2:-open}" repo="${3:-${REPO:-}}" pages
  [[ -n "$label" && "$state" =~ ^(open|closed|all)$ && -n "$repo" ]] || return 2
  pages="$(gh api --paginate --slurp "repos/$repo/issues?labels=$(jq -rn --arg l "$label" '$l | @uri')&state=$state&per_page=100" 2>/dev/null)" || return 1
  jq -ce '
    select(type == "array" and all(.[]; type == "array")
      and all(.[][]; type == "object" and ((.pull_request | type) == "object"
        or ((.number | type) == "number" and (.state | IN("open", "closed")) and (.labels | type == "array")))))
    | [.[][] | select((.pull_request | type) != "object")
       | {number, title, body: (.body // ""), state: (.state | ascii_upcase), createdAt: .created_at,
          author: {login: .user.login}, labels: [.labels[] | {name}]}]
  ' <<< "$pages"
}
