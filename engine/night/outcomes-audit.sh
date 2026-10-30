#!/usr/bin/env bash
# Source-only outcome evidence helpers used by hold and closed-state reconciliation.

outcomes_audit_error() {
  jq -cn --arg detail "$1" '{verdict:"UNKNOWN",detail:$detail}'
  return 2
}

# Keep timeout evidence to fixed stage names: the bounded worker retains this
# marker in its log without exposing issue or API data.
outcomes_stage_mark() {
  if [[ -n "${outcomes_deadline:-}" ]]; then
    local remaining=$((outcomes_deadline - SECONDS - 5))
    ((remaining >= 2)) || return 1
    # Every audit read (including timelines and close comments) reserves both
    # gh_q attempts and time to return a fail-closed verdict.
    local budget_timeout=$((remaining / 2))
    # Ten seconds covers observed normal list latency; the stage still reserves both attempts and return time.
    ((budget_timeout <= 10)) || budget_timeout=10
    ((budget_timeout <= ${OUTCOMES_GH_TIMEOUT_SECONDS:-5})) || budget_timeout="$OUTCOMES_GH_TIMEOUT_SECONDS"
    OUTCOMES_GH_TIMEOUT_SECONDS="$budget_timeout"
  fi
  case "$1" in
    closed-issues-snapshot|awaiting-release-snapshot|open-issues-snapshot|open-prs-snapshot|\
    state-label-refresh|closed-issue-timelines|awaiting-release-timelines|priority-close-comments|\
    merged-pr-search|merged-pr-pagination|merged-issue-state|merged-issue-comments)
      printf 'outcomes-stage=%s\n' "$1" >&2
      ;;
    *) return 1 ;;
  esac
}

# `date -d ""` prints today's local midnight instead of failing, so an empty
# timestamp would pass the numeric check and age from midnight.
outcomes_epoch() { [ -n "$1" ] && date -d "$1" +%s 2>/dev/null; }

outcomes_timelines_json() {
  local repo="$1" issue_ids_json="$2" kind="$3"
  local owner="${repo%%/*}" name="${repo#*/}" item_types selection
  case "$kind" in
    closed)
      item_types=CLOSED_EVENT
      selection='... on ClosedEvent { createdAt closer { __typename ... on Commit { oid } } }'
      ;;
    release)
      item_types='LABELED_EVENT,UNLABELED_EVENT'
      selection='... on LabeledEvent { createdAt label { name } } ... on UnlabeledEvent { createdAt label { name } }'
      ;;
    *) return 1 ;;
  esac
  [[ "$repo" == */* && "$name" != */* && "$owner" =~ ^[A-Za-z0-9_.-]+$ && "$name" =~ ^[A-Za-z0-9_.-]+$ ]] || return 1
  jq -e 'type == "array" and all(.[]; type == "number" and . > 0 and floor == .)' \
    <<< "$issue_ids_json" >/dev/null 2>&1 || return 1

  local -a issue_ids=() batch=()
  mapfile -t issue_ids < <(jq -r '.[]' <<< "$issue_ids_json")
  local timeline_map='{}' nodes_json cursors pending_json page_json query issue cursor after offset=0
  while ((offset < ${#issue_ids[@]})); do
    batch=("${issue_ids[@]:offset:25}")
    pending_json="$(printf '%s\n' "${batch[@]}" | jq -Rn '[inputs | tonumber]')" || return 1
    nodes_json='{}'
    cursors='{}'
    while [ "$(jq 'length' <<< "$pending_json")" -gt 0 ]; do
      query="query { repository(owner:\"$owner\",name:\"$name\") {"
      while IFS= read -r issue; do
        cursor="$(jq -r --arg issue "$issue" '.[$issue] // empty' <<< "$cursors")"
        after=''
        if [ -n "$cursor" ]; then
          after=",after:$(jq -Rn --arg cursor "$cursor" '$cursor')"
        fi
        query+="i$issue: issue(number:$issue) { number timelineItems(first:100,itemTypes:[$item_types]$after) { nodes { __typename $selection } pageInfo { hasNextPage endCursor } } } "
      done < <(jq -r '.[]' <<< "$pending_json")
      query+='} }'
      case "$kind" in
        closed) outcomes_stage_mark closed-issue-timelines || return 1 ;;
        release) outcomes_stage_mark awaiting-release-timelines || return 1 ;;
      esac
      page_json="$(gh_q api graphql -f query="$query")" || return 1
      if ! jq -e --argjson ids "$pending_json" --argjson previous "$cursors" --arg kind "$kind" '
        . as $root |
        ($root.errors // [] | length) == 0 and ($root.data.repository | type) == "object" and
        all($ids[]; . as $id |
          $root.data.repository["i" + ($id | tostring)] as $issue |
          ($issue | type) == "object" and $issue.number == $id and
          ($issue.timelineItems.nodes | type) == "array" and
          ($issue.timelineItems.pageInfo.hasNextPage | type) == "boolean" and
          all($issue.timelineItems.nodes[];
            if $kind == "closed" then
              .__typename == "ClosedEvent" and (.createdAt | type) == "string" and
              (.closer == null or ((.closer.__typename | type) == "string" and
                (.closer.__typename != "Commit" or (.closer.oid | type) == "string")))
            else
              (.__typename == "LabeledEvent" or .__typename == "UnlabeledEvent") and
              (.createdAt | type) == "string" and (.label.name | type) == "string"
            end
          ) and
          (if $issue.timelineItems.pageInfo.hasNextPage then
            ($issue.timelineItems.pageInfo.endCursor) as $next |
            ($next | type) == "string" and $next != "" and $next != ($previous[$id | tostring] // "")
          else true end)
        )
      ' <<< "$page_json" >/dev/null 2>&1; then
        return 1
      fi
      nodes_json="$(printf '%s\n%s\n' "$nodes_json" "$page_json" | jq -cs --argjson ids "$pending_json" '
        .[0] as $all | .[1].data.repository as $page |
        reduce $ids[] as $id ($all;
          .[($id | tostring)] = ((.[($id | tostring)] // []) + $page["i" + ($id | tostring)].timelineItems.nodes)
        )
      ')" || return 1
      cursors="$(jq -c --argjson ids "$pending_json" '
        . as $root |
        reduce $ids[] as $id ({};
          $root.data.repository["i" + ($id | tostring)] as $issue |
          if $issue.timelineItems.pageInfo.hasNextPage then
            .[($id | tostring)] = $issue.timelineItems.pageInfo.endCursor
          else . end
        )
      ' <<< "$page_json")" || return 1
      pending_json="$(jq -c 'keys | map(tonumber)' <<< "$cursors")" || return 1
    done
    nodes_json="$(jq -c --arg kind "$kind" '
      with_entries(.value = (.value | map(
        if $kind == "closed" then
          {event:"closed",created_at:.createdAt,commit_id:(if .closer.__typename == "Commit" then .closer.oid else null end)}
        elif .__typename == "LabeledEvent" then
          {event:"labeled",created_at:.createdAt,label:{name:.label.name}}
        else
          {event:"unlabeled",created_at:.createdAt,label:{name:.label.name}}
        end
      )))
    ' <<< "$nodes_json")" || return 1
    timeline_map="$(printf '%s\n%s\n' "$timeline_map" "$nodes_json" | jq -cs '.[0] * .[1]')" || return 1
    offset=$((offset + 25))
  done
  printf '%s\n' "$timeline_map"
}

# Compare active issues with persisted stage. No state file means the issue has
# not entered the pipeline; tracker/recut parents are unlabeled umbrellas.
# Compare persisted state to live stage labels. Tracker parents intentionally carry no stage label.
outcomes_state_label_drift() {
  local home="$1" issues_json="$2" issue state_file ids_out_name="${3:-}" detail_out_name="${4:-}"
  local state_labels_json state_result detail
  local -a state_labels=("${ALL_STATE_LABELS[@]}" on-hold)
  jq -e 'type == "array" and all(.[]; (.number|type)=="number" and (.labels|type)=="array")' \
    <<< "$issues_json" >/dev/null 2>&1 || return 1
  state_labels_json="$(printf '%s\n' "${state_labels[@]}" | jq -Rsc 'split("\n") | map(select(length > 0))')" || return 1
  local -a state_files=()
  while IFS= read -r issue; do
    state_file="$home/state/$issue.json"
    [ -f "$state_file" ] && state_files+=("$state_file")
  done < <(jq -r 'unique_by(.number)[] | .number' <<< "$issues_json")
  state_result="$(jq -cn --argjson stage_labels "$state_labels_json" '
    input as $issues |
    [inputs | {issue:(input_filename | split("/")[-1] | sub("\\.json$";"")), value:.}] as $state_rows |
    (all($state_rows[]; (.value | type) == "object")) as $valid_state_rows |
    if $valid_state_rows then
      ($state_rows | reduce .[] as $row ({}; .[$row.issue] = $row.value)) as $states |
      [ $issues | unique_by(.number)[] as $row |
        ($row.number | tostring) as $issue |
        ($states[$issue]) as $state_json |
        if $state_json == null then empty else
          ($state_json.state // "") as $state_value |
          (if ($state_value | type) == "string" then ($state_value | sub("\\n+$";"")) else ($state_value | tojson) end) as $state |
          if $state == "" then empty else
            ([ $row.labels[]?.name | select(. as $label | ($stage_labels | index($label)) != null) ] | unique) as $actual |
            any($row.labels[]?; .name == "in-progress") as $in_progress |
            ($state == "needs-recut" and
              ($state_json.tracker_parent == true or ((($state_json.recut_children // []) | type) == "array" and (($state_json.recut_children // []) | length) > 0))) as $stale_recut |
            ($state_json.released == true) as $released |
            ($state == "concluded" and $state_json.run.outcome == "duplicate") as $outcome_duplicate |
            (if $stale_recut then []
             elif $state == "tracker" then []
             elif $state == "concluded" then
               (["concluded"] + (if $released then ["released"] else [] end) +
                 (if $outcome_duplicate then ["duplicate"] else [] end) | unique)
             else [$state]
             end) as $expected |
            ($stale_recut or $actual != $expected or
              ($state != "ready-for-agent" and $in_progress)) as $has_drift |
            if $has_drift then
              (($actual + (if $in_progress then ["in-progress"] else [] end)) | unique | join(",") |
                if length == 0 then "<none>" else . end) as $labels |
              {number:$row.number,text:"#\($issue)(state=\($state) labels=\($labels))"}
            else empty end
          end
        end
      ] as $drift |
      ($drift | map(.number)) as $drift_ids |
      {detail:(if ($drift | length) == 0 then "state-label-drift=0"
        else "state-label-drift=\($drift | length) (\($drift | map(.text) | join(",")))" end),
       ids:$drift_ids,
       ordered_ids:(reduce $issues[] as $row ([];
         if (($drift_ids | index($row.number)) != null and (index($row.number) == null))
         then . + [$row.number] else . end))}
    else error("persisted issue state must be an object") end
  ' <(printf '%s\n' "$issues_json") "${state_files[@]}")" || return 1
  detail="$(jq -r '.detail' <<< "$state_result")" || return 1
  if [[ -n "$ids_out_name" ]]; then
    local -n ids_out_ref="$ids_out_name"
    mapfile -t ids_out_ref < <(jq -r '.ordered_ids[]' <<< "$state_result")
  fi
  if [[ -n "$detail_out_name" ]]; then
    local -n detail_out_ref="$detail_out_name"
    detail_out_ref="$detail"
  fi
  printf '%s' "$detail"
}

# Issue-list snapshots can stay stale after an issue's labels have changed.
# Re-read only rows whose persisted state disagrees with the list before verdict.
outcomes_refresh_state_label_drift() {
  local repo="$1" home="$2" issues_json="$3"
  local candidate_ids_name="${4:-}" candidate_ids_json selected_issues issue_numbers issue_number
  local OUTCOMES_GH_TIMEOUT_SECONDS=5
  local issue row drift owner name query_fields query fresh batch_json fresh_rows offset
  local -a drift_ids=() batch=() checked_drift_ids=() candidate_ids=()
  local -A seen=() candidate_seen=()
  local has_candidate_ids=false

  if (($# >= 4)); then
    [[ -n "$candidate_ids_name" ]] || return 1
    has_candidate_ids=true
    local -n candidate_ids_ref="$candidate_ids_name"
    for issue in "${candidate_ids_ref[@]}"; do
      [[ "$issue" =~ ^[1-9][0-9]*$ ]] || return 1
      [[ -n "${candidate_seen[$issue]:-}" ]] && continue
      candidate_seen["$issue"]=1
      candidate_ids+=("$issue")
    done
  fi

  owner="${repo%%/*}"
  name="${repo#*/}"
  [[ "$repo" == */* && "$name" != */* && "$owner" =~ ^[A-Za-z0-9_.-]+$ && "$name" =~ ^[A-Za-z0-9_.-]+$ ]] || return 1

  if [[ "$has_candidate_ids" == true ]]; then
    issue_numbers="$(jq -r 'if type == "array" and all(.[]; (.number | type) == "number") then .[].number else error("expected numeric issue array") end' \
      <<< "$issues_json")" || return 1
    if [[ -n "$issue_numbers" ]]; then
      while IFS= read -r issue_number; do
        [[ "$issue_number" =~ ^[1-9][0-9]*$ ]] || return 1
      done <<< "$issue_numbers"
    fi
    if ((${#candidate_ids[@]})); then
      candidate_ids_json="$(printf '%s\n' "${candidate_ids[@]}" | jq -Rn '[inputs | tonumber]')" || return 1
      selected_issues="$(jq -ce --argjson ids "$candidate_ids_json" '
        select(type == "array" and all(.[]; (.number | type) == "number")) |
        [.[] | select(.number as $number | ($ids | index($number)) != null)]
      ' <<< "$issues_json")" || return 1
      outcomes_state_label_drift "$home" "$selected_issues" checked_drift_ids >/dev/null || return 1
      drift_ids=("${checked_drift_ids[@]}")
    fi
  else
    # Preserve standalone behavior: without a complete candidate set, scan the
    # issue-list order and refresh every currently observed local mismatch.
    while IFS= read -r row; do
      issue="$(jq -r '.number' <<< "$row")" || return 1
      [[ "$issue" =~ ^[1-9][0-9]*$ ]] || return 1
      [[ -n "${seen[$issue]:-}" ]] && continue
      seen["$issue"]=1
      drift="$(outcomes_state_label_drift "$home" "[$row]")" || return 1
      [[ "$drift" == state-label-drift=0* ]] && continue
      drift_ids+=("$issue")
    done < <(jq -c '.[]' <<< "$issues_json")
  fi

  if ((${#drift_ids[@]} == 0)); then
    printf '%s\n' "$issues_json"
    return 0
  fi
  offset=0
  while ((offset < ${#drift_ids[@]})); do
    batch=("${drift_ids[@]:offset:25}")
    batch_json="$(printf '%s\n' "${batch[@]}" | jq -Rn '[inputs | tonumber]')" || return 1
    query_fields="$(for issue in "${batch[@]}"; do
      printf 'i%s: issue(number:%s){number state labels(first:100){nodes{name} pageInfo{hasNextPage}}} ' "$issue" "$issue"
    done)" || return 1
    query="query { repository(owner:\"$owner\",name:\"$name\") { $query_fields } }"
    outcomes_stage_mark state-label-refresh || return 1
    fresh="$(gh_q api graphql -f query="$query")" || return 1
    jq -e --argjson ids "$batch_json" '
      . as $root |
      ($root | type) == "object" and
      (($root.errors // []) | type) == "array" and (($root.errors // []) | length) == 0 and
      ($root.data.repository | type) == "object" and
      (($root.data.repository | keys | sort) == ($ids | map("i" + tostring) | sort)) and
      all($ids[]; . as $id |
        $root.data.repository["i" + ($id | tostring)] as $issue |
        ($issue | type) == "object" and $issue.number == $id and
        ($issue.state | type) == "string" and ($issue.state | IN("OPEN", "CLOSED")) and
        ($issue.labels.nodes | type) == "array" and
        ($issue.labels.pageInfo.hasNextPage | type) == "boolean" and
        ($issue.labels.pageInfo.hasNextPage == false) and
        all($issue.labels.nodes[]; (.name | type) == "string")
      )
    ' <<< "$fresh" >/dev/null 2>&1 || return 1
    fresh_rows="$(jq -c '[.data.repository[] | {number,state,labels:.labels.nodes}]' <<< "$fresh")" || return 1
    issues_json="$(printf '%s\n%s\n' "$issues_json" "$fresh_rows" | jq -cs '
      .[0] as $issues | .[1] as $fresh |
      reduce $fresh[] as $row ($issues;
        if $row.state == "CLOSED" then
          [.[] | select(.number != $row.number)]
        else
          [.[] | if .number == $row.number then . * $row else . end]
        end
      )
    ')" || return 1
    offset=$((offset + ${#batch[@]}))
  done
  printf '%s\n' "$issues_json"
}

# GitHub UI and PR auto-closes do not pass through conclude_run. Repair only
# tracked tickets from the closed-issue snapshot, through the shared transition.
outcomes_reconcile_closed_states() {
  local home="$1" closed_json="$2" row issue issue_json state_file dry_run="${OUTCOMES_RECONCILE_DRY_RUN:-0}" failure=0
  local mode="${3:-reconcile}" state metadata hold_present held=0
  local -a pending=()
  [[ "$mode" == reconcile || "$mode" == observe ]] || return 1
  [[ "$dry_run" == 0 || "$dry_run" == 1 ]] || return 1
  jq -e 'type == "array" and all(.[];
    (.number | type) == "number" and (.labels | type) == "array" and
    ((.closedAt == null) or (.closedAt | type) == "string") and
    ((.stateReason == null) or (.stateReason | type) == "string"))' \
    <<< "$closed_json" >/dev/null 2>&1 || return 1
  [[ "$mode" == observe || "$dry_run" != 1 ]] || return 0
  while IFS= read -r row; do
    issue="$(jq -r '.number' <<< "$row")" || return 1
    [[ "$issue" =~ ^[1-9][0-9]*$ ]] || return 1
    state_file="$home/state/$issue.json"
    [ -f "$state_file" ] || continue
    if [[ "$mode" == observe ]]; then
      # Preserve the complete local lifecycle/hold record. Report drift rather
      # than publishing a terminal state whose protected hold was not released.
      metadata="$(jq -er 'select(type == "object" and (.state | type == "string" and length > 0))
        | [.state, (.hold != null)] | @tsv' "$state_file")" || return 1
      IFS=$'\t' read -r state hold_present <<< "$metadata"
      if [[ "$hold_present" == true ]]; then held=$((held + 1)); fi
      case "$state" in
        concluded|duplicate|wontfix|released|closed) [[ "$hold_present" == true ]] || continue ;;
      esac
      pending+=("#$issue")
      continue
    fi
    issue_json="$(jq -c '. + {state:"CLOSED"}' <<< "$row")" || return 1
    if ! issue_reconcile_closed_state "$issue" "$issue_json"; then
      echo "outcomes_reconcile_closed_states: could not reconcile closed issue #$issue" >&2
      failure=1
    fi
  done < <(jq -c '.[]' <<< "$closed_json")
  if [[ "$mode" == observe ]]; then
    local issues=none
    if ((${#pending[@]})); then issues="$(IFS=,; printf '%s' "${pending[*]}")"; fi
    printf 'pending=%s issues=%s held=%s' "${#pending[@]}" "$issues" "$held"
  fi
  return "$failure"
}

outcomes_report_merged_pr_ambiguity() {
  local home="$1" issue="$2" prs="$3" reason="$4" marker seen
  marker="merged-pr-association-ambiguous issue=#$issue"
  # The supervisor clears supervisor-inbox once handled, so remember reported
  # (issue, PRs) pairs separately; a new PR set is reported again.
  seen="$home/night/merged-pr-ambiguity-seen"
  grep -Fxq "#$issue $prs" "$seen" 2>/dev/null && return 0
  mkdir -p "$home/night" && printf '#%s %s\n' "$issue" "$prs" >>"$seen"
  AGENT_HOME="$home" supervisor_inbox_append merged-pr-association-ambiguous \
    "issue=#$issue prs=$prs reason=$reason" || return 1
}

# Reuse complete batched comment snapshots; callers skip incomplete items.
outcomes_cached_issue_comments() {
  jq -c '
    .comments | select(.pageInfo.hasPreviousPage == false and (.nodes | type) == "array")
    | select(all(.nodes[]; (.body | type) == "string" and (.createdAt | type) == "string" and
        (.author == null or ((.author.login | type) == "string"))))
    | [.nodes[] | {body,created_at:.createdAt,user:{login:(.author.login // "")}}]
  ' <<< "$1" 2>/dev/null
}

# Two read-only requests may run concurrently; each owns its stdout/stderr files.
outcomes_merged_issue_batch() (
  local owner="$1" name="$2"
  shift 2
  local -a pending_batch=("$@") missing_ids=() remaining=()
  local batch_errors batch_json="" query_fields issue_query issue_id missing_id removed _OUTCOMES_GH_STDERR_FILE
  local attempts=0 remaining_seconds
  local batch_deadline="${worker_deadline:-$((SECONDS + ${ZF_OUTCOMES_SECTION_TIMEOUT_SECONDS:-75} - 5))}"
  batch_errors="$(mktemp)" || return 1
  _OUTCOMES_GH_STDERR_FILE="$batch_errors"
  while ((${#pending_batch[@]})); do
    remaining_seconds=$((batch_deadline - SECONDS - 5))
    ((remaining_seconds >= 2 && attempts < 2)) || break
    # gh_q may retry once; both attempts must fit remaining worker time.
    local OUTCOMES_GH_TIMEOUT_SECONDS=$((remaining_seconds / 2))
    ((OUTCOMES_GH_TIMEOUT_SECONDS <= 5)) || OUTCOMES_GH_TIMEOUT_SECONDS=5
    attempts=$((attempts+1))
    query_fields=""
    for issue_id in "${pending_batch[@]}"; do
      query_fields+="i$issue_id: issueOrPullRequest(number:$issue_id){__typename ... on Issue {number state closedAt stateReason labels(first:100){nodes{name} pageInfo{hasNextPage}} }} "
    done
    issue_query="query { repository(owner:\"$owner\",name:\"$name\") { $query_fields } }"
    outcomes_stage_mark merged-issue-state || return 1
    batch_json="$(gh_q api graphql -f query="$issue_query" 2>"$batch_errors")" || :
    jq -e '(.data.repository | type) == "object"' <<<"$batch_json" >/dev/null 2>&1 && break
    # gh_q discards failed stdout. Remove named missing aliases and reread siblings.
    mapfile -t missing_ids < <(sed -nE 's/.*Could not resolve to an issue or pull request with the number of ([1-9][0-9]*).*/\1/p' "$batch_errors")
    remaining=(); removed=0
    for issue_id in "${pending_batch[@]}"; do
      missing_id=""
      for missing_id in "${missing_ids[@]}"; do [ "$missing_id" != "$issue_id" ] || break; done
      if [ "$missing_id" = "$issue_id" ]; then removed=1; else remaining+=("$issue_id"); fi
    done
    [ "$removed" = 1 ] || break
    pending_batch=("${remaining[@]}")
  done
  rm -f -- "$batch_errors"
  if jq -e '(.data.repository | type) == "object"' <<<"$batch_json" >/dev/null 2>&1; then
    jq -c '
      . as $root | .data.repository |= with_entries(.key as $key |
        select(all($root.errors[]?; .path != null and .path[1] != $key)))
    ' <<<"$batch_json"
  else
    printf '{"data":{"repository":{}}}\n'
  fi
)

# Keep incomplete discovery private: never reconcile a prefix that could hide
# another implementation. Three calls per tick, with durable continuation.
outcomes_merged_pr_search() {
  local home="$1" repo="$2" now="$3"
  shift 3
  local dir="$home/night/outcomes-merged-search" manifest initial connection cursor search pages page_json next calls=0
  local fields='number title headRefName body mergedAt baseRefName'
  local -a searches=("$@") page_files=()
  mkdir -p "$dir" || return 1
  manifest="$dir/manifest.json"
  initial="$dir/initial.json"
  if [ ! -f "$manifest" ]; then
    outcomes_stage_mark merged-pr-search || return 1
    gh_q api graphql -F recent="${searches[0]}" -F boundary="${searches[1]}" \
      -F refs="${searches[2]}" -F implements="${searches[3]}" -F titles="${searches[4]}" \
      -f query='query($recent:String!,$boundary:String!,$refs:String!,$implements:String!,$titles:String!){recent:search(query:$recent,type:ISSUE,first:100){nodes{... on PullRequest{number title headRefName body mergedAt baseRefName}} pageInfo{hasNextPage endCursor}} boundary:search(query:$boundary,type:ISSUE,first:100){nodes{... on PullRequest{number title headRefName body mergedAt baseRefName}} pageInfo{hasNextPage endCursor}} refs:search(query:$refs,type:ISSUE,first:100){nodes{... on PullRequest{number title headRefName body mergedAt baseRefName}} pageInfo{hasNextPage endCursor}} implements:search(query:$implements,type:ISSUE,first:100){nodes{... on PullRequest{number title headRefName body mergedAt baseRefName}} pageInfo{hasNextPage endCursor}} titles:search(query:$titles,type:ISSUE,first:100){nodes{... on PullRequest{number title headRefName body mergedAt baseRefName}} pageInfo{hasNextPage endCursor}}}' \
      > "$initial.tmp" || { rm -f -- "$initial.tmp"; return 1; }
    jq -e '(.errors // [] | length) == 0 and
      all(.data.recent,.data.boundary,.data.refs,.data.implements,.data.titles;
        (.nodes | type) == "array" and (.pageInfo.hasNextPage | type) == "boolean")' \
      "$initial.tmp" >/dev/null || return 1
    mv -f -- "$initial.tmp" "$initial" || return 1
    printf '%s\n' "${searches[@]}" | jq -Rn --slurpfile initial "$initial" --arg repo "$repo" --argjson started "$now" '
      [inputs] as $searches | ["recent","boundary","refs","implements","titles"] as $keys |
      {repo:$repo,started:$started,connections:(reduce range(0;5) as $i ({};
        .[$keys[$i]] = {search:$searches[$i],pages:1,pageInfo:$initial[0].data[$keys[$i]].pageInfo}))}
    ' > "$manifest.tmp" && mv -f -- "$manifest.tmp" "$manifest" || return 1
    calls=1
  fi
  jq -e --arg repo "$repo" ' .repo == $repo and (.started | type) == "number" and
    (.connections | keys) == ["boundary","implements","recent","refs","titles"]' "$manifest" >/dev/null || return 1
  # A continuation older than the recovery horizon cannot prove today's scan.
  if ((now - $(jq -r '.started' "$manifest") > 604800)); then
    rm -f -- "$dir"/*.json "$dir"/*.tmp
    echo 'outcomes_reconcile_merged_issues: expired merged PR scan; restart next tick' >&2
    return 1
  fi
  for connection in recent boundary refs implements titles; do
    while [ "$(jq -r --arg c "$connection" '.connections[$c].pageInfo.hasNextPage' "$manifest")" = true ]; do
      if ((calls >= 3 || SECONDS >= ${ZF_OUTCOMES_SECTION_TIMEOUT_SECONDS:-75} - 25)); then
        echo 'outcomes_reconcile_merged_issues: merged PR scan pending; cursor persisted' >&2
        return 1
      fi
      pages="$(jq -r --arg c "$connection" '.connections[$c].pages' "$manifest")"
      if ((pages >= 10)); then
        echo "outcomes_reconcile_merged_issues: merged PR $connection search reached 1000-record cap" >&2
        return 1
      fi
      cursor="$(jq -r --arg c "$connection" '.connections[$c].pageInfo.endCursor // empty' "$manifest")"
      [ -n "$cursor" ] || { echo "outcomes_reconcile_merged_issues: merged PR $connection search has no page cursor" >&2; return 1; }
      search="$(jq -r --arg c "$connection" '.connections[$c].search' "$manifest")"
      outcomes_stage_mark merged-pr-pagination || return 1
      page_json="$(gh_q api graphql -F q="$search" -F after="$cursor" \
        -f query="query(\$q:String!,\$after:String!){search(query:\$q,type:ISSUE,first:100,after:\$after){nodes{... on PullRequest{$fields}} pageInfo{hasNextPage endCursor}}}")" || return 1
      jq -e --arg previous "$cursor" '(.errors // [] | length) == 0 and
        (.data.search.nodes | type) == "array" and (.data.search.pageInfo.hasNextPage | type) == "boolean" and
        (if .data.search.pageInfo.hasNextPage then .data.search.pageInfo.endCursor as $c |
          ($c | type) == "string" and $c != "" and $c != $previous else true end)' \
        <<< "$page_json" >/dev/null || return 1
      # Page first, cursor second: a crash can replay a page, never skip it.
      next="$dir/$connection-$((pages+1)).json"
      jq -c --arg c "$connection" '{connection:$c,nodes:.data.search.nodes}' <<< "$page_json" > "$next.tmp" &&
        mv -f -- "$next.tmp" "$next" || return 1
      jq --arg c "$connection" --argjson info "$(jq -c '.data.search.pageInfo' <<< "$page_json")" \
        '.connections[$c].pages += 1 | .connections[$c].pageInfo = $info' "$manifest" > "$manifest.tmp" &&
        mv -f -- "$manifest.tmp" "$manifest" || return 1
      calls=$((calls+1))
    done
  done
  # One final merge through files; no repeatedly copying all prior PR bodies.
  for connection in recent boundary refs implements titles; do
    pages="$(jq -r --arg c "$connection" '.connections[$c].pages' "$manifest")"
    for ((next=2; next<=pages; next++)); do page_files+=("$dir/$connection-$next.json"); done
  done
  jq -cs --slurpfile manifest "$manifest" '
    .[0] as $initial | .[1:] as $pages |
    $initial | .data |= with_entries(.key as $c |
      .value.nodes += [$pages[] | select(.connection == $c) | .nodes[]] |
      .value.pageInfo = $manifest[0].connections[$c].pageInfo)
  ' "$initial" "${page_files[@]}" || return 1
  rm -f -- "$initial" "$manifest" "${page_files[@]}"
  rmdir "$dir" 2>/dev/null || :
}

# Reconcile at most one clear merged-PR match per tick. Paged searches discover
# matches; bounded item reads isolate failures. Shared transition owns state.
outcomes_reconcile_merged_issues() {
  local repo="$1" home="$2" now="$3"
  local OUTCOMES_GH_TIMEOUT_SECONDS=5
  local worker_deadline=$(( ${ZF_OUTCOMES_SECTION_TIMEOUT_SECONDS:-75} - 5 ))
  local outcomes_deadline="$worker_deadline"
  local cutoff_epoch cutoff_iso cutoff_date recent_date search_recent search_boundary search_refs search_implements search_titles
  local graph_json prs_json issues_json roster_json groups_json issue_ids_json issue_query query_fields
  local owner name
  local issue_id issue_json issue_state reason prs candidate_pr candidate_count candidate_prs labels closed_at close_epoch comments_json evidence_status
  local marker_pr marker_prs state_reason
  local state_file state_json run_pr_number run_outcome
  local comment_cursor_file comment_cursor_tmp comment_cursor=0 comment_start=0 comment_batches=0 comment_timeout comment_remaining comments_deferred_summary=none
  local comment_reserve_seconds=20 group_index=0 items_deferred_summary=none
  local selected_issue="" selected_pr="" ambiguous_count=0 invalid_closure_count=0 roster_file invalid_closure_summary=none
  local dry_run="${OUTCOMES_RECONCILE_DRY_RUN:-0}" match_count=0
  local -a unreadable_ids=() invalid_closure_ids=() issue_ids=() batch=() row_fields=() comment_ids=() rotated_comment_ids=() deferred_comment_ids=() deferred_read_ids=() group_issue_ids=() deferred_group_ids=() batch_files=() batch_pids=()
  local -A deferred_comment_lookup=()
  local offset=0 batch_json batch_dir batch_pid states_json='{"data":{"repository":{}}}'
  local state_cursor_file="$home/night/outcomes-merged-state-cursor" state_cursor=0 state_start=0
  local group_cursor_file="$home/night/outcomes-merged-group-cursor" group_cursor=0 last_group_issue=""

  [[ "$dry_run" == 0 || "$dry_run" == 1 ]] || {
    echo 'outcomes_reconcile_merged_issues: invalid dry-run setting' >&2
    return 1
  }

  # shortcut: 14-day merge recovery horizon, use issue-scoped lookup if older gaps recur
  cutoff_epoch=$((now - 1209600))
  cutoff_iso="$(date -u -d "@$cutoff_epoch" +%Y-%m-%dT%H:%M:%SZ)" || return 1
  cutoff_date="${cutoff_iso%%T*}"
  recent_date="$(date -u -d "@$((now - 172800))" +%Y-%m-%d)" || return 1
  search_recent="repo:$repo is:pr is:merged base:main merged:>=$recent_date"
  search_boundary="repo:$repo is:pr is:merged base:main merged:$cutoff_date"
  search_refs="repo:$repo is:pr is:merged base:main merged:>=$cutoff_date in:body Ref"
  search_implements="repo:$repo is:pr is:merged base:main merged:>=$cutoff_date in:body Implements"
  search_titles="repo:$repo is:pr is:merged base:main merged:>=$cutoff_date in:title issue"
  graph_json="$(outcomes_merged_pr_search "$home" "$repo" "$now" "$search_recent" "$search_boundary" \
    "$search_refs" "$search_implements" "$search_titles")" || return 1
  local connection
  for connection in recent boundary refs implements titles; do
    if ! jq -e --arg connection "$connection" '
      . as $root | $root.data[$connection] as $c |
      ($root | type) == "object" and ($root.errors // [] | length) == 0 and
      ($c.nodes | type) == "array" and ($c.pageInfo.hasNextPage | type) == "boolean" and
      all($c.nodes[];
        (.number | type) == "number" and (.title | type) == "string" and
        (.headRefName | type) == "string" and ((.body == null) or (.body | type) == "string") and
        (.mergedAt | type) == "string" and (.baseRefName | type) == "string")
    ' <<<"$graph_json" >/dev/null 2>&1; then
      echo "outcomes_reconcile_merged_issues: merged PR $connection search has invalid shape" >&2
      return 1
    fi
  done
  # Seven-day body matches can fall between the recent and boundary searches.
  prs_json="$(jq -c '
    [.data.recent.nodes[], .data.boundary.nodes[], .data.refs.nodes[], .data.implements.nodes[], .data.titles.nodes[]]
    | group_by(.number) | map(reduce .[] as $pr ({}; . * $pr)) | sort_by(.mergedAt)
  ' <<<"$graph_json")" || {
    echo 'outcomes_reconcile_merged_issues: cannot combine merged PR searches' >&2
    return 1
  }

  roster_json='{}'
  roster_file="$home/night/agents.txt"
  if [ -f "$roster_file" ]; then
    roster_json="$(awk -F '\t' 'NF >= 13 && $2 ~ /^hand-/ && $13 ~ /^[1-9][0-9]*$/ {print $2 "\t" $13}' "$roster_file" |
      jq -Rn '[inputs | split("\t") | {(.[0]): (.[1] | tonumber)}] | add // {}')" || return 1
    jq -e 'type == "object"' <<<"$roster_json" >/dev/null 2>&1 || return 1
  fi

  groups_json="$(printf '%s\n%s\n%s\n' "$prs_json" "$roster_json" "\"$cutoff_iso\"" | jq -cs '
    def explicit_ids($text): [
      ($text // "") | split("\n")[] | . as $line |
      if test("(?i)\\b(refs|fixes|closes|resolves|implements)\\s+(issue\\s+)?#?[1-9][0-9]*") then
        (match("(?i)\\b(refs|fixes|closes|resolves|implements)\\s+(issue\\s+)?#?[1-9][0-9]*").offset) as $start
        | $line[$start:] | scan("(?i)#[1-9][0-9]*|issue\\s+#?[1-9][0-9]*")
        | sub("(?i)^issue\\s+#?"; "") | ltrimstr("#") | tonumber
      else
        scan("(?i)\\bissue\\s+#?([1-9][0-9]*)")[] | tonumber
      end
    ];
    def explicitly_names($text; $issue):
      (($text // "") | test("(?i)\\bissue\\s+#?" + ($issue | tostring) + "\\b"));
    def title_ids($p): ([$p.title | scan("(?i)fix\\(#([1-9][0-9]*)\\)")[]? | tonumber] + explicit_ids($p.title));
    def branch_ids($p; $roster):
      ([try ($p.headRefName | capture("^agent/issue-(?<id>[1-9][0-9]*)(?:$|[-/])").id | tonumber) catch empty] +
       [try ($p.headRefName | capture("^hand/(?<id>[1-9][0-9]*)(?:$|[-/])").id | tonumber) catch empty] +
       [try (($p.headRefName | capture("^hand/(?<name>[^/]+)$").name) as $name |
             $roster[$name] | select(type == "number")) catch empty]);
    .[0] as $prs | .[1] as $roster | .[2] as $cutoff |
    [ $prs[] as $p
      | select($p.baseRefName == "main" and $p.mergedAt >= $cutoff)
      | (branch_ids($p; $roster) + title_ids($p)) as $strong
      | (($strong + explicit_ids($p.body)) | unique)[] as $issue
      | {
          issue: $issue, pr: $p.number, merged_at: $p.mergedAt,
          explicitly_named: (explicitly_names($p.title; $issue) or explicitly_names($p.body; $issue)),
          reverted: (($p.title | test("^(revert|reverts|reverted)(:|\\(|[[:space:]])"; "i")) or ($p.headRefName | startswith("revert/"))),
          eligible: (($p.title | test("^(revert|test|docs)(:|\\(|[[:space:]])"; "i") | not)
            and ($p.headRefName | startswith("revert/") | not) or ($strong | index($issue)) != null)
        }
    ]
    | group_by(.issue)
    | map(. as $rows | [$rows[] | select(.eligible)] as $candidates |
      (($candidates | length) > 1 and all($candidates[]; .explicitly_named and (.reverted | not))) as $rounds |
      (($candidates | length) == 1 and $candidates[0].reverted) as $only_revert |
      {
        issue: $rows[0].issue,
        prs: ([$rows[].pr] | unique),
        candidate_prs: ([$candidates[].pr] | unique),
        candidate_count: (if $only_revert then 0 else ($candidates | length) end),
        rounds: $rounds,
        first: (if $only_revert then null elif $rounds then ($candidates | sort_by(.merged_at, .pr) | last)
          else ($candidates | sort_by(.merged_at, .pr) | .[0]) end),
        reasons: (if ($candidates | length) > 1 and any($candidates[]; .reverted) then "reverted candidate PR"
          elif ($candidates | length) > 1 and ($rounds | not) then "multiple plausible merged PRs" else "" end)
      })
    | sort_by(.first.merged_at, .first.pr)
  ')" || {
    echo 'outcomes_reconcile_merged_issues: cannot associate merged PRs' >&2
    return 1
  }

  [ "$(jq 'length' <<<"$groups_json")" -gt 0 ] || {
    printf 'no eligible merged PR matches'
    return 0
  }
  if [[ -r "$group_cursor_file" ]]; then
    read -r group_cursor < "$group_cursor_file" || group_cursor=0
    [[ "$group_cursor" =~ ^[0-9]+$ ]] || group_cursor=0
    groups_json="$(jq -c --argjson cursor "$group_cursor" '
      (map(.issue) | index($cursor)) as $i |
      if $i == null then . else .[$i+1:] + .[:$i+1] end
    ' <<< "$groups_json")" || return 1
  fi
  issue_ids_json="$(jq -c '[.[].issue] | unique' <<<"$groups_json")" || return 1
  owner="${repo%%/*}"
  name="${repo#*/}"
  [[ "$owner" =~ ^[A-Za-z0-9_.-]+$ && "$name" =~ ^[A-Za-z0-9_.-]+$ && "$repo" == */* && "$name" != */* ]] || {
    echo 'outcomes_reconcile_merged_issues: invalid repository name for issue lookup' >&2
    return 1
  }
  mapfile -t issue_ids < <(jq -r '.[]' <<<"$issue_ids_json")
  if [[ -r "$state_cursor_file" ]]; then
    read -r state_cursor < "$state_cursor_file" || state_cursor=0
    [[ "$state_cursor" =~ ^[0-9]+$ ]] || state_cursor=0
    while ((state_start < ${#issue_ids[@]} && issue_ids[state_start] <= state_cursor)); do
      state_start=$((state_start+1))
    done
    ((state_start < ${#issue_ids[@]})) || state_start=0
    issue_ids=("${issue_ids[@]:state_start}" "${issue_ids[@]:0:state_start}")
  fi
  # shortcut: two concurrent reads, revisit fanout only if larger cohorts exceed the worker deadline.
  # Wait only for PIDs this scan starts.
  batch_dir="$(mktemp -d)" || return 1
  while ((offset < ${#issue_ids[@]})); do
    # A wave can cost two 5s attempts; leave time for item decisions. Missing
    # aliases remain unreadable, while the next tick starts after this wave.
    if ((SECONDS >= worker_deadline - 15)); then
      if ((offset > 0)); then
        printf '%s\n' "${issue_ids[offset-1]}" > "$state_cursor_file.tmp" &&
          mv -f -- "$state_cursor_file.tmp" "$state_cursor_file" || return 1
      fi
      break
    fi
    batch=("${issue_ids[@]:offset:25}")
    batch_files+=("$batch_dir/$offset.json")
    outcomes_merged_issue_batch "$owner" "$name" "${batch[@]}" >"$batch_dir/$offset.json" &
    batch_pids+=("$!")
    if ((${#batch_pids[@]} == 2)); then
      for batch_pid in "${batch_pids[@]}"; do wait "$batch_pid" || :; done
      batch_pids=()
    fi
    offset=$((offset + ${#batch[@]}))
  done
  for batch_pid in "${batch_pids[@]}"; do wait "$batch_pid" || :; done
  if ((offset == ${#issue_ids[@]})); then rm -f -- "$state_cursor_file"; fi
  states_json="$(jq -cs '
    reduce .[] as $page ({data:{repository:{}}}; .data.repository += $page.data.repository)
  ' "${batch_files[@]}" < /dev/null)" || { rm -f -- "${batch_files[@]}"; rmdir "$batch_dir"; return 1; }
  rm -f -- "${batch_files[@]}"
  rmdir "$batch_dir"
  # Fetch comment bodies only for issues that can require closure/decision evidence.
  mapfile -t comment_ids < <(printf '%s\n%s\n' "$groups_json" "$states_json" | jq -rs '
    .[1].data.repository as $states | .[0][] as $g | $states["i" + ($g.issue | tostring)] as $i |
    select(try ($i.__typename == "Issue" and ($i.labels.nodes | type) == "array" and
      (if $i.state == "CLOSED" then
        $i.stateReason != "NOT_PLANNED" and
        (any($i.labels.nodes[]; .name == "wontfix" or .name == "duplicate") | not) and
        (any($i.labels.nodes[]; .name == "pipeline-system") or
          (any($i.labels.nodes[]; .name == "released") | not))
      else ($g.reasons != "" or $g.first == null or $g.candidate_count > 1) and
         (any($i.labels.nodes[]; .name == "released") | not) end)) catch false) | $g.issue
  ' | sort -n -u)
  if ((${#comment_ids[@]} > 0)); then
    comment_cursor_file="$home/night/outcomes-merged-comment-cursor"
    if [[ -r "$comment_cursor_file" ]]; then
      IFS= read -r comment_cursor < "$comment_cursor_file" || comment_cursor=0
      [[ "$comment_cursor" =~ ^[0-9]+$ ]] || comment_cursor=0
    fi
    while ((comment_start < ${#comment_ids[@]} && comment_ids[comment_start] <= comment_cursor)); do
      comment_start=$((comment_start + 1))
    done
    ((comment_start < ${#comment_ids[@]})) || comment_start=0
    rotated_comment_ids=("${comment_ids[@]:comment_start}" "${comment_ids[@]:0:comment_start}")
    comment_ids=("${rotated_comment_ids[@]}")
  fi
  # Bulk metadata decoding removes per-item jq startup; reserve 20s for decisions.
  offset=0
  while ((offset < ${#comment_ids[@]})); do
    if ((comment_batches >= 2)); then
      deferred_comment_ids=("${comment_ids[@]:offset}")
      break
    fi
    comment_remaining=$((worker_deadline - SECONDS - 1))
    if ((comment_remaining < comment_reserve_seconds)); then
      deferred_comment_ids=("${comment_ids[@]:offset}")
      break
    fi
    comment_timeout=$((comment_remaining / 2))
    ((comment_timeout <= 3)) || comment_timeout=3
    batch=("${comment_ids[@]:offset:25}")
    query_fields=""
    for issue_id in "${batch[@]}"; do
      query_fields+="i$issue_id: issue(number:$issue_id){comments(last:100){nodes{body createdAt author{login}} pageInfo{hasPreviousPage}}} "
    done
    issue_query="query { repository(owner:\"$owner\",name:\"$name\") { $query_fields } }"
    outcomes_stage_mark merged-issue-comments || return 1
    batch_json="$(OUTCOMES_GH_TIMEOUT_SECONDS="$comment_timeout" gh_q api graphql -f query="$issue_query")" || :
    if jq -e '(.data.repository | type) == "object"' <<<"$batch_json" >/dev/null 2>&1; then
      states_json="$(printf '%s\n%s\n' "$states_json" "$batch_json" | jq -cs '
        .[0] * {data:{repository:(.[1].data.repository | with_entries(select(.value != null)))}}
      ')" || return 1
    fi
    offset=$((offset + ${#batch[@]}))
    comment_batches=$((comment_batches + 1))
    if mkdir -p "$home/night" 2>/dev/null; then
      comment_cursor_tmp="$(mktemp "$home/night/.outcomes-merged-comment-cursor.XXXXXX" 2>/dev/null)" || comment_cursor_tmp=""
      if [[ -n "$comment_cursor_tmp" ]] && printf '%s\n' "${batch[${#batch[@]}-1]}" > "$comment_cursor_tmp" &&
        mv -f -- "$comment_cursor_tmp" "$comment_cursor_file"; then
        :
      else
        rm -f -- "$comment_cursor_tmp"
        echo 'outcomes_reconcile_merged_issues: could not persist comment cursor' >&2
      fi
    else
      echo 'outcomes_reconcile_merged_issues: could not create comment cursor directory' >&2
    fi
  done
  for issue_id in "${deferred_comment_ids[@]}"; do deferred_comment_lookup["$issue_id"]=1; done
  issues_json="$states_json"
  mapfile -t group_issue_ids < <(jq -r '.[].issue' <<<"$groups_json")
  group_index=0
  local fields_file row_offset
  local -a group_fields=()
  fields_file="$(mktemp)" || return 1
  if ! printf '%s\n%s\n' "$groups_json" "$issues_json" | jq -js '
    .[1].data.repository as $states | .[0][] | .issue as $id | ("i" + ($id | tostring)) as $key |
    $states[$key] as $i |
    . + {readable:($states | has($key)),live_issue:$i,
      valid_shape:(try ($i.__typename == "Issue" and $i.number == $id and
        ($i.state == "OPEN" or $i.state == "CLOSED") and
        ($i.closedAt == null or ($i.closedAt | type) == "string") and
        ($i.stateReason == null or ($i.stateReason | type) == "string") and
        ($i.labels.nodes | type) == "array" and $i.labels.pageInfo.hasNextPage == false and
        all($i.labels.nodes[]; (.name | type) == "string")) catch false)} |
      (.live_issue | if type == "object" then . else {} end) as $i |
      [(.issue | tostring), (.readable | tostring), (.valid_shape | tostring),
        ($i.__typename // "" | tostring), ($i.state // "" | tostring),
        (if .valid_shape then [$i.labels.nodes[].name] | join(",") else "" end),
        ($i.closedAt // "" | tostring), ($i.stateReason // "" | tostring), .reasons,
        ([.prs[] | "#" + tostring] | join(",")), (.candidate_count | tostring),
        ([.candidate_prs[] | "#" + tostring] | join(",")), (.first.pr // "" | tostring),
        (.live_issue | tojson), (.prs | tojson),
        (any($i.labels.nodes[]?; .name == "released") | tostring),
        (any($i.labels.nodes[]?; .name == "awaiting-release") | tostring),
        (try ($i.closedAt as $at | ($at | fromdateiso8601) as $epoch |
          if ($epoch | todateiso8601) == $at then ($epoch | tostring) else "" end) catch ""),
        (($i.stateReason == "NOT_PLANNED" or any($i.labels.nodes[]?; .name == "wontfix" or .name == "duplicate") or
          (any($i.labels.nodes[]?; .name == "released") and
           (any($i.labels.nodes[]?; .name == "pipeline-system") | not))) | tostring)] |
        .[] | gsub("\u0000"; ""), "\u0000"
  ' > "$fields_file"; then
    rm -f -- "$fields_file"; return 1
  fi
  mapfile -d '' -t group_fields < "$fields_file"
  rm -f -- "$fields_file"
  for ((row_offset=0; row_offset<${#group_fields[@]}; row_offset+=19)); do
    row_fields=("${group_fields[@]:row_offset:19}")
    group="${row_fields[14]}"
    if ((SECONDS >= worker_deadline - 5)); then
      deferred_group_ids=("${group_issue_ids[@]:group_index}")
      unreadable_ids+=("${deferred_group_ids[@]}")
      break
    fi
    group_index=$((group_index + 1))
    last_group_issue="${row_fields[0]}"
    issue_id="${row_fields[0]}"
    if [ "${row_fields[1]}" != true ]; then
      echo "outcomes_reconcile_merged_issues: issue state unreadable for #$issue_id" >&2
      unreadable_ids+=("$issue_id"); continue
    fi
    issue_json="${row_fields[13]}"
    [ "$issue_json" != null ] || continue
    [ "${row_fields[3]}" != PullRequest ] || continue
    if [ "${row_fields[2]}" != true ]; then
      echo "outcomes_reconcile_merged_issues: issue state has invalid shape for #$issue_id" >&2
      unreadable_ids+=("$issue_id"); continue
    fi
    issue_state="${row_fields[4]}"
    labels="${row_fields[5]}"
    closed_at="${row_fields[6]}"
    state_reason="${row_fields[7]}"
    reason="${row_fields[8]}"
    prs="${row_fields[9]}"
    candidate_count="${row_fields[10]}"
    candidate_prs="${row_fields[11]}"
    candidate_pr="${row_fields[12]}"
    if [[ "${issue_state^^}" == CLOSED ]]; then
      close_epoch="${row_fields[17]}"
      [[ "$close_epoch" =~ ^[0-9]+$ ]] || close_epoch="$(outcomes_epoch "$closed_at" || true)"
      [[ "$close_epoch" =~ ^[0-9]+$ ]] || {
        echo "outcomes_reconcile_merged_issues: closed issue #$issue_id has unreadable close time" >&2
        unreadable_ids+=("$issue_id"); continue
      }
      # Same exemptions as the shared evaluator, with known-valid empty comments.
      [ "${row_fields[18]}" != true ] || continue
      if issue_closure_evidence_valid "${REPO_DIR:-$(pwd -P)}" "$issue_id" "$labels" '[]' \
        "${repo%%/*}" "$close_epoch" "$now" "" "$state_reason" "${ZF_HEALTH_PROBE_SHA:-}"; then
        continue
      else
        evidence_status=$?
        if [ "$evidence_status" -eq 2 ]; then
          echo "outcomes_reconcile_merged_issues: close evidence unreadable for #$issue_id" >&2
          unreadable_ids+=("$issue_id"); continue
        fi
      fi
      if [[ -n "${deferred_comment_lookup[$issue_id]:-}" ]]; then
        unreadable_ids+=("$issue_id"); deferred_read_ids+=("$issue_id"); continue
      fi
      comments_json="$(outcomes_cached_issue_comments "$issue_json")" || comments_json=""
      if [ -z "$comments_json" ]; then
        echo "outcomes_reconcile_merged_issues: close comments incomplete or unreadable for #$issue_id" >&2
        unreadable_ids+=("$issue_id"); continue
      fi
      if ! jq -e 'type == "array" and all(flatten[]?; type == "object")' <<<"$comments_json" >/dev/null 2>&1; then
        echo "outcomes_reconcile_merged_issues: close comments have invalid shape for #$issue_id" >&2
        unreadable_ids+=("$issue_id"); continue
      fi
      if issue_closure_evidence_valid "${REPO_DIR:-$(pwd -P)}" "$issue_id" "$labels" \
        "$comments_json" "${repo%%/*}" "$close_epoch" "$now" "" \
        "$state_reason" "${ZF_HEALTH_PROBE_SHA:-}"; then
        :
      else
        evidence_status=$?
        if [ "$evidence_status" -eq 2 ]; then
          echo "outcomes_reconcile_merged_issues: close evidence evaluation failed for #$issue_id" >&2
          unreadable_ids+=("$issue_id"); continue
        fi
        invalid_closure_count=$((invalid_closure_count + 1))
        invalid_closure_ids+=("$issue_id")
      fi
      continue
    fi
    [[ "${issue_state^^}" == OPEN ]] || continue
    if [ "${row_fields[15]}" = true ]; then
      continue
    fi
    # awaiting-release can outlive a failed state write; only recorded merge evidence makes it idempotent.
    if [ "${row_fields[16]}" = true ]; then
      state_file="$home/state/$issue_id.json"
      state_json='{}'
      if [ -f "$state_file" ]; then
        state_json="$(jq -ce 'select(type == "object")' "$state_file" 2>/dev/null)" || {
          echo "outcomes_reconcile_merged_issues: state file is invalid for #$issue_id" >&2
          unreadable_ids+=("$issue_id"); continue
        }
      fi
      run_outcome="$(jq -r '.run.outcome // empty' <<<"$state_json")" || return 1
      run_pr_number="$(jq -r '.run.evidence.pr_number // empty' <<<"$state_json")" || return 1
      if [[ "$run_outcome" == merged && "$run_pr_number" =~ ^[1-9][0-9]*$ ]]; then
        continue
      fi
    fi
    if [ -n "$reason" ] || [ -z "$candidate_pr" ] || [ "$candidate_count" -gt 1 ]; then
      if [[ -n "${deferred_comment_lookup[$issue_id]:-}" ]]; then
        unreadable_ids+=("$issue_id"); deferred_read_ids+=("$issue_id"); continue
      fi
      comments_json="$(outcomes_cached_issue_comments "$issue_json")" || comments_json=""
      if [ -z "$comments_json" ]; then
        echo "outcomes_reconcile_merged_issues: merge-marker comments incomplete or unreadable for #$issue_id" >&2
        [ -z "$candidate_pr" ] || unreadable_ids+=("$issue_id")
        continue
      fi
      if ! jq -e 'type == "array" and all(flatten[]?; type == "object" and
        ((.body == null) or (.body | type == "string")) and
        ((.user == null) or ((.user | type) == "object" and ((.user.login == null) or (.user.login | type == "string"))))
      )' <<<"$comments_json" >/dev/null 2>&1; then
        echo "outcomes_reconcile_merged_issues: merge-marker comments invalid for #$issue_id" >&2
        [ -z "$candidate_pr" ] || unreadable_ids+=("$issue_id")
        continue
      fi
      marker_prs="$(printf '%s\n%s\n%s\n' "$comments_json" "\"$issue_id\"" "\"$owner\"" | jq -cs '
        .[1] as $issue | .[2] as $owner |
        [.[0] | flatten[]?
          | select((.user.login // "" | ascii_downcase) == ($owner | ascii_downcase))
          | (.body // "") as $body |
          (try {kind:"marker",pr:($body | capture("<!-- zf-merged-outcome issue=" + $issue + " pr=(?<pr>[1-9][0-9]*) -->").pr)} catch empty),
          (try {kind:"decision",pr:($body | select(test("(?i)decision\\s*\\(supervisor")) |
            capture("(?i)PR\\s+#?(?<pr>[1-9][0-9]*)[^\\n]*is the accepted implementation").pr)} catch empty)
        ] as $signals |
        [$signals[] | select(.kind == "decision") | .pr] as $decisions |
        if ($decisions | length) > 0 then [$decisions[-1]]
        else [$signals[] | .pr] | unique end
      ')" || return 1
      if [ "$(jq 'length' <<<"$marker_prs")" = 1 ]; then
        marker_pr="$(jq -r '.[0]' <<<"$marker_prs")"
        if jq -e "index($marker_pr) != null" <<<"$group" >/dev/null; then
          candidate_pr="$marker_pr"
          reason=""
        fi
      fi
    fi
    # A reference-only test/docs/revert PR supplies context, not a blocker.
    [ -n "$candidate_pr" ] || continue
    if [ -n "$reason" ]; then
      if [ "$dry_run" = 1 ]; then
        printf 'ambiguous issue=#%s prs=%s reason=%s\n' "$issue_id" "$prs" "$reason"
      else
        outcomes_report_merged_pr_ambiguity "$home" "$issue_id" "$prs" "$reason" || return 1
      fi
      ambiguous_count=$((ambiguous_count + 1))
      continue
    fi
    if [ "$dry_run" = 1 ]; then
      if [ "$candidate_count" -gt 1 ] && [ -z "$reason" ]; then
        printf 'rounds issue=#%s prs=%s anchor=#%s\n' "$issue_id" "$candidate_prs" "$candidate_pr"
      fi
      printf 'match issue=#%s pr=#%s\n' "$issue_id" "$candidate_pr"
      match_count=$((match_count + 1))
      continue
    fi
    if [ -z "$selected_issue" ]; then
      selected_issue="$issue_id"
      selected_pr="$candidate_pr"
    fi
  done

  if ((${#deferred_group_ids[@]} > 0)); then
    if [[ -n "$last_group_issue" ]]; then
      printf '%s\n' "$last_group_issue" > "$group_cursor_file.tmp" &&
        mv -f -- "$group_cursor_file.tmp" "$group_cursor_file" || return 1
    fi
  else
    rm -f -- "$group_cursor_file"
  fi

  if ((${#invalid_closure_ids[@]} > 0)); then
    printf -v invalid_closure_summary '#%s,' "${invalid_closure_ids[@]}"
    invalid_closure_summary="${invalid_closure_summary%,}"
  fi
  if ((${#deferred_read_ids[@]} > 0)); then
    printf -v comments_deferred_summary '#%s,' "${deferred_read_ids[@]}"
    comments_deferred_summary="${comments_deferred_summary%,}"
  fi
  if ((${#deferred_group_ids[@]} > 0)); then
    printf -v items_deferred_summary '#%s,' "${deferred_group_ids[@]}"
    items_deferred_summary="${items_deferred_summary%,}"
  fi
  if [ "$dry_run" = 1 ]; then
    printf 'dry-run matches=%s ambiguous=%s invalid-closures=%s invalid-closure-issues=%s' \
      "$match_count" "$ambiguous_count" "$invalid_closure_count" "$invalid_closure_summary"
    printf '; comments-deferred=%s issues=%s' "${#deferred_read_ids[@]}" "$comments_deferred_summary"
    printf '; items-deferred=%s issues=%s' "${#deferred_group_ids[@]}" "$items_deferred_summary"
    printf '; unreadable=%s issues=%s' "${#unreadable_ids[@]}" "${unreadable_ids[*]}"
    return 0
  fi
  if [ -n "$selected_issue" ]; then
    OUTCOMES_GH_TIMEOUT_SECONDS=1
    if ! conclude_merged_run "$selected_issue" "$selected_pr" >/dev/null; then
      echo "outcomes_reconcile_merged_issues: conclude_merged_run failed for #$selected_issue via PR #$selected_pr" >&2
      return 1
    fi
    printf 'reconciled issue=#%s pr=#%s; ambiguous=%s invalid-closures=%s invalid-closure-issues=%s' \
      "$selected_issue" "$selected_pr" "$ambiguous_count" "$invalid_closure_count" "$invalid_closure_summary"
  else
    printf 'no eligible merged PR matches; ambiguous=%s invalid-closures=%s invalid-closure-issues=%s' \
      "$ambiguous_count" "$invalid_closure_count" "$invalid_closure_summary"
  fi
  printf '; comments-deferred=%s issues=%s' "${#deferred_read_ids[@]}" "$comments_deferred_summary"
  printf '; items-deferred=%s issues=%s' "${#deferred_group_ids[@]}" "$items_deferred_summary"
  printf '; unreadable=%s issues=%s' "${#unreadable_ids[@]}" "${unreadable_ids[*]}"
}

# Read awaiting-release state files once for both timeline selection and audit.
outcomes_awaiting_rows() {
  local home="$1" issues_json="$2" issue
  local -a files=()
  while IFS= read -r issue; do
    [ ! -f "$home/state/$issue.json" ] || files+=("$home/state/$issue.json")
  done < <(jq -r '.[] | select((.state | ascii_upcase) == "OPEN") | .number' <<< "$issues_json")
  jq -jn '
    input as $issues |
    [inputs | {key:(input_filename | split("/")[-1] | sub("\\.json$";"")),value:.}] as $rows |
    if all($rows[]; (.value | type) == "object") then
      ($rows | from_entries) as $states | $issues[] |
      ($states[.number | tostring] // {}) as $state |
      [.number, ((.title // "") | gsub("[\t\r\n]"; " ")), (.state | ascii_upcase),
       ([.labels[]?.name // ""] | join(",")), ($state.run.evidence.pr_number // ""),
       ($state.run.outcome // ""), ($state.run.merged_at // ""),
       (try ($state.run.merged_at as $at | ($at | fromdateiso8601) as $epoch |
         if ($epoch | todateiso8601) == $at then ($epoch | tostring) else "" end) catch "")] |
      .[] | tostring | gsub("\u0000"; ""), "\u0000"
    else error("awaiting-release state file must be an object") end
  ' <(printf '%s\n' "$issues_json") "${files[@]}"
}

outcomes_audit() {
  local repo="$1" home="$2" now="${3:-$(date +%s)}"
  local mode="${4:-reconcile}"
  # HEALTH consumes the existing evidence-complete merged preview contract;
  # this function-local setting never changes a dedicated lifecycle caller.
  local OUTCOMES_RECONCILE_DRY_RUN="${OUTCOMES_RECONCILE_DRY_RUN:-0}"
  case "$mode" in
    observe) OUTCOMES_RECONCILE_DRY_RUN=1 ;;
    reconcile) ;;
    *) outcomes_audit_error 'invalid audit mode'; return 2 ;;
  esac
  local OUTCOMES_GH_TIMEOUT_SECONDS=10
  local outcomes_deadline=$(( ${ZF_OUTCOMES_SECTION_TIMEOUT_SECONDS:-75} - 5 ))
  local cutoff_epoch cutoff_iso cutoff_date maintainer_login closed_json awaiting_json open_json open_prs_json state_label_detail
  local row issue title closed_at close_epoch labels state_reason comments_json comment_since evidence_status
  local prs_for_issue timeline_json commit_id state_file state pr_number outcome merged_at merged_epoch closed_linked_rows
  local closed_timeline_ids_json closed_timelines_json awaiting_timeline_ids_json awaiting_timelines_json
  local latest_label_at latest_label_event start_time_reason age detail reconciliation_detail reconciliation_invalid_closures reconciliation_unreadable
  local closed_count awaiting_count open_count pr_count closed_observation_detail closed_pending merged_pending merged_ambiguous
  local shared_snapshot_ok=0
  local -a closed_timeline_ids=() awaiting_timeline_ids=() state_label_drift_ids=()
  local -a problems=()

  [[ "$now" =~ ^[0-9]+$ && "$repo" == */* ]] || outcomes_audit_error 'invalid audit time or repository' || return 2
  cutoff_epoch=$((now - 86400))
  cutoff_iso="$(date -u -d "@$cutoff_epoch" +%Y-%m-%dT%H:%M:%SZ)" || outcomes_audit_error 'cannot calculate 24-hour cutoff' || return 2
  cutoff_date="${cutoff_iso%%T*}"
  maintainer_login="${repo%%/*}"
  if [[ -n "${ZF_OPEN_ISSUES_CACHE_FILE:-}" ]] && jq -e '
    (.sampled_at | fromdateiso8601) as $sampled |
    $sampled <= now and now - $sampled <= 900 and
    (.open_issues | type) == "array" and (.open_prs | type) == "array"
  ' "$ZF_OPEN_ISSUES_CACHE_FILE" >/dev/null 2>&1; then
    shared_snapshot_ok=1
  fi

  outcomes_stage_mark closed-issues-snapshot || outcomes_audit_error 'cannot mark recent closed issue read' || return 2
  closed_json="$(gh_q issue list --repo "$repo" --state closed --search "closed:>=$cutoff_date" \
    --limit 1000 --json number,title,closedAt,labels,stateReason)" || {
      outcomes_audit_error 'recent closed issue list unreadable'
      return 2
    }
  outcomes_stage_mark awaiting-release-snapshot || outcomes_audit_error 'cannot mark awaiting-release issue read' || return 2
  awaiting_json="$(gh_q issue list --repo "$repo" --state all --label awaiting-release \
    --limit 1000 --json number,title,state,labels)" || {
      outcomes_audit_error 'awaiting-release issue list unreadable'
      return 2
    }
  outcomes_stage_mark open-issues-snapshot || outcomes_audit_error 'cannot mark open issue read' || return 2
  if [ "$shared_snapshot_ok" = 1 ]; then
    open_json="$(jq -c '[.open_issues[] | {number,labels}]' "$ZF_OPEN_ISSUES_CACHE_FILE")" || {
      outcomes_audit_error 'shared open issue snapshot unreadable'
      return 2
    }
  else
    open_json="$(OUTCOMES_GH_TIMEOUT_SECONDS=10 gh_q issue list --repo "$repo" --state open --limit 1000 --json number,labels)" || {
      outcomes_audit_error 'open issue state-label snapshot unreadable'
      return 2
    }
  fi
  outcomes_stage_mark open-prs-snapshot || outcomes_audit_error 'cannot mark open PR read' || return 2
  if [ "$shared_snapshot_ok" = 1 ]; then
    open_prs_json="$(jq -c '[.open_prs[] | {number,closingIssuesReferences}]' "$ZF_OPEN_ISSUES_CACHE_FILE")" || {
      outcomes_audit_error 'shared open PR snapshot unreadable'
      return 2
    }
  else
    open_prs_json="$(gh_q pr list --repo "$repo" --state open --limit 1000 \
      --json number,closingIssuesReferences)" || {
        outcomes_audit_error 'open PR list unreadable'
        return 2
      }
  fi
  if ! jq -e 'type == "array" and all(.[]; (.number|type)=="number" and (.labels|type)=="array")' \
      <<< "$closed_json" >/dev/null 2>&1 ||
    ! jq -e 'type == "array" and all(.[]; (.number|type)=="number" and (.labels|type)=="array")' \
      <<< "$awaiting_json" >/dev/null 2>&1 ||
    ! jq -e 'type == "array" and all(.[]; (.number|type)=="number" and (.labels|type)=="array")' \
      <<< "$open_json" >/dev/null 2>&1 ||
    ! jq -e 'type == "array" and all(.[]; (.number|type)=="number" and ((.closingIssuesReferences // [])|type)=="array")' \
      <<< "$open_prs_json" >/dev/null 2>&1; then
    outcomes_audit_error 'GitHub outcome snapshots have invalid shape'
    return 2
  fi
  closed_count="$(jq 'length' <<< "$closed_json")"
  awaiting_count="$(jq 'length' <<< "$awaiting_json")"
  open_count="$(jq 'length' <<< "$open_json")"
  pr_count="$(jq 'length' <<< "$open_prs_json")"
  if [ "$closed_count" -ge 1000 ] || [ "$awaiting_count" -ge 1000 ] || [ "$open_count" -ge 1000 ] || [ "$pr_count" -ge 1000 ]; then
    outcomes_audit_error 'outcome audit reached a 1000-record scan cap'
    return 2
  fi
  # Only open issues can enter a stage; recent closed outcomes have their own evidence checks below.
  outcomes_state_label_drift "$home" "$open_json" state_label_drift_ids state_label_detail >/dev/null || {
    outcomes_audit_error 'state-label drift check failed'
    return 2
  }
  if [[ "$state_label_detail" != state-label-drift=0* ]]; then
    # `issue list` may return the same stale label row twice; issue detail is authoritative.
    open_json="$(outcomes_refresh_state_label_drift "$repo" "$home" "$open_json" state_label_drift_ids)" || {
      outcomes_audit_error 'direct issue refresh for state-label drift unreadable or invalid'
      return 2
    }
    state_label_detail="$(outcomes_state_label_drift "$home" "$open_json")" || {
      outcomes_audit_error 'direct issue state-label refresh check failed'
      return 2
    }
    if [[ "$state_label_detail" != state-label-drift=0* ]]; then
      problems+=("$state_label_detail")
    fi
  fi

  closed_linked_rows="$(printf '%s\n%s\n' "$closed_json" "$open_prs_json" | jq -sr '
    .[0] as $closed | .[1] as $prs |
    $closed[] as $issue |
    select(any($prs[]; any(.closingIssuesReferences[]?; (.number | tostring) == ($issue.number | tostring)))) |
    [$issue.number, ($issue.closedAt // "")] | @tsv
  ')" || {
    outcomes_audit_error 'cannot match closed issues to open PRs'
    return 2
  }
  while IFS=$'\t' read -r issue closed_at; do
    [ -n "$issue" ] || continue
    close_epoch="$(outcomes_epoch "$closed_at" || true)"
    [[ "$close_epoch" =~ ^[0-9]+$ ]] && [ "$close_epoch" -ge "$cutoff_epoch" ] || continue
    closed_timeline_ids+=("$issue")
  done <<< "$closed_linked_rows"
  closed_timeline_ids_json="$(printf '%s\n' "${closed_timeline_ids[@]}" | jq -Rn '[inputs | select(length > 0) | tonumber] | unique')" || {
    outcomes_audit_error 'cannot prepare closed issue timeline reads'
    return 2
  }
  closed_timelines_json="$(outcomes_timelines_json "$repo" "$closed_timeline_ids_json" closed)" || {
    outcomes_audit_error 'closed issue timelines unreadable or invalid'
    return 2
  }

  local metadata_file row_offset
  local -a awaiting_fields=() closed_fields=()
  metadata_file="$(mktemp)" || return 2
  if ! outcomes_awaiting_rows "$home" "$awaiting_json" > "$metadata_file"; then
    rm -f -- "$metadata_file"
    outcomes_audit_error 'awaiting-release state snapshot invalid'; return 2
  fi
  mapfile -d '' -t awaiting_fields < "$metadata_file"
  rm -f -- "$metadata_file"
  for ((row_offset=0; row_offset<${#awaiting_fields[@]}; row_offset+=8)); do
    issue="${awaiting_fields[row_offset]}"
    [ "${awaiting_fields[row_offset+2]}" = OPEN ] || continue
    pr_number="${awaiting_fields[row_offset+4]}"
    outcome="${awaiting_fields[row_offset+5]}"
    [[ "$pr_number" =~ ^[1-9][0-9]*$ && "$outcome" == merged ]] && continue
    merged_at="${awaiting_fields[row_offset+6]}"
    merged_epoch="${awaiting_fields[row_offset+7]}"
    [[ "$merged_epoch" =~ ^[0-9]+$ ]] || merged_epoch="$(outcomes_epoch "$merged_at" || true)"
    [[ "$merged_epoch" =~ ^[0-9]+$ ]] || awaiting_timeline_ids+=("$issue")
  done
  awaiting_timeline_ids_json="$(printf '%s\n' "${awaiting_timeline_ids[@]}" | jq -Rn '[inputs | select(length > 0) | tonumber] | unique')" || {
    outcomes_audit_error 'cannot prepare awaiting-release timeline reads'
    return 2
  }
  awaiting_timelines_json="$(outcomes_timelines_json "$repo" "$awaiting_timeline_ids_json" release)" || {
    outcomes_audit_error 'awaiting-release timelines unreadable or invalid'
    return 2
  }

  metadata_file="$(mktemp)" || return 2
  if ! printf '%s\n%s\n%s\n' "$closed_json" "$open_prs_json" "$closed_timelines_json" | jq -js --arg cutoff "$cutoff_iso" '
    .[1] as $prs | .[2] as $timelines | .[0][] | select(.closedAt != null) | . as $i |
    ([$prs[] | select(any(.closingIssuesReferences[]?; (.number | tostring) == ($i.number | tostring))) | .number] |
       unique | map(tostring) | join(",")) as $linked |
    (if $linked != "" and .closedAt >= $cutoff then
       $timelines[.number | tostring] |
       if type != "array" then error("closed issue timeline missing") else
         [flatten[]? | select(.event == "closed" and (.commit_id // "") != "" and (.created_at // "") >= $cutoff)] |
         sort_by(.created_at) | (last.commit_id // "")
       end
     else "" end) as $commit |
    [.number, ((.title // "") | gsub("[\t\r\n]"; " ")), .closedAt,
     ([.labels[]?.name // ""] | join(",")), (.stateReason // ""),
     $linked, (try (.closedAt as $at | ($at | fromdateiso8601) as $epoch |
       if ($epoch | todateiso8601) == $at then ($epoch | tostring) else "" end) catch ""), $commit] |
    .[] | tostring | gsub("\u0000"; ""), "\u0000"
  ' > "$metadata_file"; then
    rm -f -- "$metadata_file"; outcomes_audit_error 'closed issue metadata invalid'; return 2
  fi
  mapfile -d '' -t closed_fields < "$metadata_file"
  rm -f -- "$metadata_file"
  for ((row_offset=0; row_offset<${#closed_fields[@]}; row_offset+=8)); do
    issue="${closed_fields[row_offset]}"
    title="${closed_fields[row_offset+1]}"
    closed_at="${closed_fields[row_offset+2]}"
    labels="${closed_fields[row_offset+3]}"
    state_reason="${closed_fields[row_offset+4]}"
    prs_for_issue="${closed_fields[row_offset+5]}"
    commit_id="${closed_fields[row_offset+7]}"
    close_epoch="${closed_fields[row_offset+6]}"
    [[ "$close_epoch" =~ ^[0-9]+$ ]] || close_epoch="$(outcomes_epoch "$closed_at" || true)"
    [[ "$close_epoch" =~ ^[0-9]+$ ]] || continue
    [ "$close_epoch" -ge "$cutoff_epoch" ] || continue

    # Pipeline-system closes use their direct-main commit as delivery evidence.
    # Product closures retain the existing maintainer-decision / duplicate / wontfix exemptions.
    if [[ ",$labels," == *,priority:top,* ]] && {
      [[ ",$labels," == *,pipeline-system,* ]] ||
      { [[ ",$labels," != *,released,* && ",$labels," != *,wontfix,* && ",$labels," != *,duplicate,* ]] &&
        [[ "$state_reason" != NOT_PLANNED ]]; }
    }; then
      comment_since="$(date -u -d "@$((close_epoch - 86400))" +%Y-%m-%dT%H:%M:%SZ)" || {
        outcomes_audit_error "cannot calculate close-comment window for #$issue"
        return 2
      }
      outcomes_stage_mark priority-close-comments || outcomes_audit_error 'cannot mark close-comment read' || return 2
      comments_json="$(gh_q api "repos/$repo/issues/$issue/comments?since=$comment_since&per_page=100" --paginate --slurp)" || {
        outcomes_audit_error "close comments unreadable for #$issue"
        return 2
      }
      if ! jq -e 'type == "array" and all(flatten[]?; type == "object")' \
        <<< "$comments_json" >/dev/null 2>&1; then
        outcomes_audit_error "close comments have invalid shape for #$issue"
        return 2
      fi
      if issue_closure_evidence_valid "$REPO_DIR" "$issue" "$labels" \
        "$comments_json" "$maintainer_login" "$close_epoch" "$now" "" "$state_reason" \
        "${ZF_HEALTH_PROBE_SHA:-}"; then
        :
      else
        evidence_status=$?
        if [ "$evidence_status" -eq 2 ]; then
          outcomes_audit_error "close evidence evaluation failed for #$issue"
          return 2
        fi
        if [[ ",$labels," == *,pipeline-system,* ]]; then
          problems+=("#$issue${title:+ $title} pipeline-system close lacks comment citing reachable issue-linked origin/main commit")
        else
          problems+=("#$issue${title:+ $title} closed priority:top without released label or maintainer ruling comment")
        fi
      fi
    fi

    [ -n "$prs_for_issue" ] || continue
    [ -n "$commit_id" ] || continue
    problems+=("#$issue${title:+ $title} closed by main commit ${commit_id:0:12} while PRs #${prs_for_issue//,/ #} remain open")
  done

  for ((row_offset=0; row_offset<${#awaiting_fields[@]}; row_offset+=8)); do
    issue="${awaiting_fields[row_offset]}"
    title="${awaiting_fields[row_offset+1]}"
    labels="${awaiting_fields[row_offset+3]}"
    if [[ ",$labels," == *,in-progress,* ]]; then
      problems+=("#$issue${title:+ $title} carries both in-progress and awaiting-release")
    fi
    [ "${awaiting_fields[row_offset+2]}" = OPEN ] || continue
    pr_number="${awaiting_fields[row_offset+4]}"
    outcome="${awaiting_fields[row_offset+5]}"
    if [[ "$pr_number" =~ ^[1-9][0-9]*$ && "$outcome" == merged ]]; then
      continue
    fi
    merged_at="${awaiting_fields[row_offset+6]}"
    merged_epoch="${awaiting_fields[row_offset+7]}"
    [[ "$merged_epoch" =~ ^[0-9]+$ ]] || merged_epoch="$(outcomes_epoch "$merged_at" || true)"
    if ! [[ "$merged_epoch" =~ ^[0-9]+$ ]]; then
      timeline_json="$(jq -ce --arg issue "$issue" '.[$issue] | select(type == "array")' <<< "$awaiting_timelines_json")" || {
        outcomes_audit_error "awaiting-release timeline missing or invalid for #$issue"
        return 2
      }
      latest_label_at="$(jq -r '
        [flatten[]?
          | select((.event == "labeled" or .event == "unlabeled") and .label.name == "awaiting-release")]
        | sort_by(.created_at) | (last // {}) | if .event == "labeled" then (.created_at // "") else "" end
      ' <<< "$timeline_json")"
      merged_epoch="$(outcomes_epoch "$latest_label_at" || true)"
    fi
    if ! [[ "$merged_epoch" =~ ^[0-9]+$ ]]; then
      if [ -n "$latest_label_at" ]; then
        start_time_reason=timestamp-unparseable
      else
        latest_label_event="$(jq -r '
          [flatten[]?
            | select((.event == "labeled" or .event == "unlabeled") and .label.name == "awaiting-release")]
          | sort_by(.created_at) | (last.event // "none")
        ' <<< "$timeline_json")"
        case "$latest_label_event" in
          labeled) start_time_reason=timestamp-unparseable ;;
          unlabeled) start_time_reason=latest-event-unlabeled ;;
          *) start_time_reason=no-matching-label-event ;;
        esac
      fi
      outcomes_audit_error "awaiting-release start time unavailable for #$issue reason=$start_time_reason"
      return 2
    fi
    age=$((now - merged_epoch))
    if [ "$age" -gt 7200 ]; then
      problems+=("#$issue${title:+ $title} awaiting-release >2h without merged PR evidence in .run.evidence.pr_number")
    fi
  done

  if ! reconciliation_detail="$(outcomes_reconcile_merged_issues "$repo" "$home" "$now")"; then
    outcomes_audit_error 'merged-issue reconciliation failed'
    return 2
  fi
  reconciliation_invalid_closures="$(sed -nE 's/.*invalid-closures=([0-9]+).*/\1/p' <<<"$reconciliation_detail")"
  if [[ "$reconciliation_invalid_closures" =~ ^[0-9]+$ ]] && [ "$reconciliation_invalid_closures" -gt 0 ]; then
    problems+=("merged-pr reconciliation found $reconciliation_invalid_closures closed issue(s) without valid closure evidence")
  fi

  reconciliation_unreadable="$(sed -nE 's/.*unreadable=([0-9]+).*/\1/p' <<<"$reconciliation_detail")"
  if [[ "$reconciliation_unreadable" =~ ^[0-9]+$ ]] && [ "$reconciliation_unreadable" -gt 0 ]; then
    problems+=("merged-pr reconciliation skipped $reconciliation_unreadable unreadable issue(s)")
  fi

  if [[ "$mode" == observe ]]; then
    if ! closed_observation_detail="$(outcomes_reconcile_closed_states "$home" "$closed_json" observe)"; then
      outcomes_audit_error 'closed-issue state observation unreadable'
      return 2
    fi
    closed_pending="${closed_observation_detail%% *}"
    closed_pending="${closed_pending#pending=}"
    [[ "$closed_pending" =~ ^[0-9]+$ ]] || { outcomes_audit_error 'invalid closed-state observation'; return 2; }
    if ((closed_pending > 0)); then
      problems+=("closed-issue lifecycle reconciliation pending; $closed_observation_detail")
    fi
    if [[ "$reconciliation_detail" != 'no eligible merged PR matches' ]]; then
      merged_pending="$(sed -nE 's/^dry-run matches=([0-9]+).*/\1/p' <<< "$reconciliation_detail")"
      merged_ambiguous="$(sed -nE 's/^dry-run matches=[0-9]+ ambiguous=([0-9]+).*/\1/p' <<< "$reconciliation_detail")"
      [[ "$merged_pending" =~ ^[0-9]+$ && "$merged_ambiguous" =~ ^[0-9]+$ ]] || {
        outcomes_audit_error 'merged observation summary unreadable'; return 2;
      }
      if ((merged_pending > 0 || merged_ambiguous > 0)); then
        problems+=("merged-PR lifecycle reconciliation pending; matches=$merged_pending ambiguous=$merged_ambiguous")
      fi
    fi
    reconciliation_detail+="; closed-state-observation=$closed_observation_detail"
  elif ! outcomes_reconcile_closed_states "$home" "$closed_json"; then
    outcomes_audit_error 'closed-issue state reconciliation failed'
    return 2
  fi

  if [ "${#problems[@]}" -gt 0 ]; then
    detail="$(printf '%s; ' "${problems[@]}")"
    detail="${detail%; }"
    detail_file="$(jq_arg_file "$detail")" || return 2
    if jq -cn --rawfile detail "$detail_file" --arg reconciliation "$reconciliation_detail" \
      '{verdict:"BROKEN",detail:($detail + "; merged-pr-reconciliation=" + $reconciliation)}'; then
      rm -f -- "$detail_file"
    else
      rm -f -- "$detail_file"
      return 2
    fi
  else
    jq -cn --argjson closed "$closed_count" --argjson awaiting "$awaiting_count" --argjson open "$open_count" \
      --argjson prs "$pr_count" --arg state_label_drift "$state_label_detail" --arg reconciliation "$reconciliation_detail" \
      '{verdict:"OK",detail:"last-24h outcomes clean; closed-sampled=\($closed), awaiting-release=\($awaiting), open-issues=\($open), open-prs=\($prs), release-wait-bound=2h; \($state_label_drift); merged-pr-reconciliation=\($reconciliation)"}'
  fi
}
