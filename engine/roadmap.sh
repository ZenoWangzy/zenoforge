#!/usr/bin/env bash

roadmap_switch_value() {
  local policy="${MODEL_POLICY_FILE:-${AGENT_HOME:-${HOME:?HOME is not set}/.zenoforge}/model-policy.json}"
  jq -r 'if .switches["roadmap-order"] == true then "true" else "false" end' "$policy" 2>/dev/null || printf 'false\n'
}

roadmap_cache_path() {
  printf '%s.roadmap.json\n' "$1"
}

roadmap_snapshot_path() {
  printf '%s\n' "${ZF_ROADMAP_SNAPSHOT_FILE:-${AGENT_HOME:?}/night/roadmap-tree.snapshot.json}"
}

# Only admission falls back; HEALTH continues to report the failed live read.
roadmap_fetch_for_admission() {
  local cache_file="$1" repo="$2" snapshot tree fetched_at now age tmp
  local ttl="${ZF_ROADMAP_SNAPSHOT_TTL_SECONDS:-7200}"
  ROADMAP_TREE_STALE=0
  ROADMAP_SNAPSHOT_AGE_SECONDS=0
  if roadmap_fetch_tree "$cache_file" "$repo"; then return 0; fi
  snapshot="$(roadmap_snapshot_path)" || return 1
  now="$(date +%s)" || return 1
  fetched_at="$(jq -er --arg repo "$repo" --argjson now "$now" '
    select(.repo == $repo) | .fetched_at | select(type == "number" and . > 0 and . <= $now and . == floor)
  ' "$snapshot" 2>/dev/null)" || fetched_at=0
  age=$((now - fetched_at))
  if [[ "$ttl" =~ ^[1-9][0-9]{0,8}$ ]] && (( fetched_at > 0 && age >= 0 && age <= ttl )) \
    && tree="$(jq -ce '.tree' "$snapshot")" && roadmap_tree_is_valid "$tree"; then
    mkdir -p -- "$(dirname -- "$cache_file")" || return 1
    tmp="$(mktemp "$cache_file.XXXXXX")" || return 1
    if ! printf '%s\n' "$tree" > "$tmp" || ! mv -f -- "$tmp" "$cache_file"; then
      rm -f -- "$tmp"
      return 1
    fi
    ROADMAP_TREE_STALE=1
    ROADMAP_SNAPSHOT_AGE_SECONDS="$age"
    supervisor_inbox_append_once "roadmap-stale:$repo:$fetched_at" \
      "roadmap-stale node=roadmap status=stale-$fetched_at snapshot=stale age_seconds=$age ttl_seconds=$ttl repo=$repo; fresh tree read failed; admission uses last good tree, holds and blockers still enforced" || true
    echo "roadmap: snapshot=stale age_seconds=$age ttl_seconds=$ttl" >&2
    return 0
  fi
  rm -f -- "$cache_file" "$cache_file.placed" "$cache_file.linked"
  supervisor_inbox_append_once "roadmap-unavailable:$repo:$fetched_at" \
    "roadmap-unavailable node=roadmap status=closed-$fetched_at age_seconds=$age ttl_seconds=$ttl repo=$repo; fresh read failed and snapshot missing, invalid or expired; admission closed" || true
  return 1
}

# Large JSON (the flattened tree, open issues) reaches jq through --slurpfile: as --argjson it
# exceeded the per-argument limit on 2026-10-11 ("Argument list too long").
# One flat page per 100 open issues, each with its parent link and ordered child numbers; jq rebuilds
# the tree. The 2026-10-11 nested four-level query requested 1,000,000 possible nodes and GitHub refused
# it (MAX_NODE_LIMIT_EXCEEDED), so the roadmap node read failed on every tick.
roadmap_tree_graphql_query() {
  cat <<'GRAPHQL'
query($owner:String!, $name:String!, $endCursor:String) {
  repository(owner:$owner, name:$name) {
    issues(first:100, after:$endCursor, states:[OPEN]) {
      nodes {
        number title state createdAt updatedAt
        labels(first:30) { nodes { name } }
        milestone { title }
        blocking(first:100) { nodes { state } pageInfo { hasNextPage } }
        blockedBy(first:30) { pageInfo { hasNextPage } nodes { number state } }
        subIssues(first:100) { totalCount pageInfo { hasNextPage } nodes { number } }
      }
      pageInfo { hasNextPage endCursor }
    }
  }
}
GRAPHQL
}

roadmap_tree_normalize_pages() {
  jq -ce '
    def issue:
      {
        number: .number,
        title: (.title // ""),
        state: ((.state // "") | ascii_downcase),
        createdAt: (.createdAt // ""),
        updatedAt: (.updatedAt // ""),
        labels: [(.labels.nodes // [])[]?.name],
        milestone: (.milestone.title // null),
        dependents_count: ([.blocking.nodes[]? | select((.state // "") == "OPEN")] | length),
        dependents_truncated: (.blocking.pageInfo.hasNextPage // false),
        blockedBy: [(.blockedBy.nodes // [])[]? | {number, state:(.state | ascii_downcase)}],
        blockers_truncated: (.blockedBy.pageInfo.hasNextPage // false),
        children_total: (.subIssues.totalCount // 0),
        children_truncated: (.subIssues.pageInfo.hasNextPage // false),
        child_numbers: [(.subIssues.nodes // [])[]?.number]
      };
    # Only open issues are fetched, so a child missing from the page set is closed.
    def build($nodes; $depth):
      if $depth > 8 then error("roadmap tree deeper than 8 levels")
      else
        (if $nodes[(.number | tostring)] then $nodes[(.number | tostring)]
         else {number:.number,title:"",state:"closed",createdAt:"",updatedAt:"",labels:[],milestone:null,
               dependents_count:0,dependents_truncated:false,
               blockedBy:[],blockers_truncated:false,children_total:0,children_truncated:false,child_numbers:[]} end) as $node
        | $node + {children:[$node.child_numbers[] | {number:.} | build($nodes; $depth + 1)]}
        | del(.child_numbers)
      end;
    if type != "array" or length == 0 or any(.[]; (.data.repository.issues.nodes | type) != "array") then
      error("invalid paginated roadmap response")
    else
      ([.[].data.repository.issues.nodes[] | issue]) as $all
      | ($all | map({key:(.number | tostring), value:.}) | from_entries) as $nodes
      | {roots:[$all[] | select(.labels | index("roadmap")) | build($nodes; 0)]}
    end
  ' <<< "$1"
}

roadmap_fetch_tree() {
  local cache_file="$1" repo="$2" owner name query raw tree tmp snapshot
  owner="${repo%%/*}"
  name="${repo#*/}"
  [[ -n "$owner" && -n "$name" && "$name" != "$repo" ]] || return 64
  query="$(roadmap_tree_graphql_query)" || return 1
  raw="$(timeout "${ZF_ROADMAP_QUERY_TIMEOUT_SECONDS:-60}s" gh api graphql --paginate --slurp \
    -f query="$query" -F owner="$owner" -F name="$name")" || return 1
  tree="$(roadmap_tree_normalize_pages "$raw")" || return 1
  roadmap_tree_is_valid "$tree" || return 1
  mkdir -p -- "$(dirname -- "$cache_file")" || return 1
  tmp="$cache_file.tmp.$$"
  if ! (umask 077; printf '%s\n' "$tree" > "$tmp") || ! mv -f -- "$tmp" "$cache_file"; then
    rm -f -- "$tmp"
    return 1
  fi
  snapshot="$(roadmap_snapshot_path)" || return 1
  mkdir -p -- "$(dirname -- "$snapshot")" || return 1
  tmp="$(mktemp "$snapshot.XXXXXX")" || return 1
  if ! jq -cn --arg repo "$repo" --slurpfile tree "$cache_file" \
    '{repo:$repo,fetched_at:(now | floor),tree:$tree[0]}' > "$tmp" || ! mv -f -- "$tmp" "$snapshot"; then
    rm -f -- "$tmp"
    return 1
  fi
}

roadmap_tree_is_valid() {
  jq -e '
    def valid_node:
      type == "object"
      and (.number | type == "number" and . > 0 and . == floor)
      and (.title | type == "string")
      and (.state | type == "string")
      and (.labels | type == "array" and all(.[]; type == "string"))
      and ((.dependents_count // 0) | type == "number" and . >= 0)
      and ((.dependents_truncated // false) == false)
      and ((.children_truncated // false) == false)
      and ((.blockers_truncated // false) == false)
      and (.children | type == "array" and all(.[]; valid_node));
    type == "object" and (.roots | type == "array" and all(.[]; valid_node))
  ' <<< "$1" >/dev/null 2>&1
}

roadmap_flatten() {
  jq -ce '
    def flat($parent; $root; $depth; $theme; $theme_milestone):
      . as $node
      | (if ($node.labels | index("roadmap-theme")) != null then $node.number else $theme end) as $next_theme
      | (if ($node.labels | index("roadmap-theme")) != null then $node.milestone else $theme_milestone end) as $next_milestone
      | [{
          number:$node.number, title:$node.title, state:$node.state,
          labels:$node.labels, createdAt:$node.createdAt, updatedAt:$node.updatedAt,
          milestone:$node.milestone, theme:$next_theme, theme_milestone:$next_milestone,
          blockedBy:($node.blockedBy // []), dependents_count:($node.dependents_count // 0), children:($node.children // []),
          children_total:($node.children_total // (($node.children // []) | length)),
          parent:$parent, root:$root, depth:$depth
        }]
        + [($node.children // []) | to_entries[] as $entry
           | $entry.value | flat($node.number; $root; $depth + 1; $next_theme; $next_milestone)]
      | flatten;
    if type != "object" or (.roots | type) != "array" then error("invalid roadmap tree")
    else
      [.roots[] as $root | $root | flat(null; $root.number; 0; null; null)]
      | add // []
      | to_entries | map(. as $entry | $entry.value + {order:$entry.key})
    end
  ' <<< "$1"
}

roadmap_order_candidates() {
  local tree="$1" candidates="$2" merged_labels="${3:-[]}" flat
  flat="$(roadmap_flatten "$tree")" || return 1
  jq -r --argjson merged_labels "$merged_labels" --slurpfile tree_s <(printf '%s' "$flat") '($tree_s[0]) as $tree |
    def names: [(.labels // [])[] | if type == "string" then . else .name // "" end];
    def blockers: if (.blockedBy | type) == "object" then (.blockedBy.nodes // []) else (.blockedBy // []) end;
    def child_nodes: if (.subIssues | type) == "object" then (.subIssues.nodes // []) else [] end;
    def child_total: if (.subIssues | type) == "object" then (.subIssues.totalCount // 0) else 0 end;
    def has_children:
      any(.children[]?; ((.state // "OPEN") | ascii_downcase) == "open")
      or ((.subIssuesSummary.total // 0) > (.subIssuesSummary.completed // 0))
      or any(child_nodes[]?; ((.state // "OPEN") | ascii_downcase) == "open")
      or ((.subIssues | type) == "array" and any(.subIssues[]?; ((.state // "OPEN") | ascii_downcase) == "open"))
      or ((.children | type) == "array" and (.children_total // (.children | length)) > (.children | length))
      or ((.subIssuesSummary | type) != "object" and child_total > (child_nodes | length))
      or ((.children | type) != "array" and (.subIssuesSummary | type) != "object"
        and (.subIssues | type) != "object" and (.subIssues | type) != "array"
        and (.children_total // 0) > 0);
    ($tree | map({key:(.number|tostring),value:.}) | from_entries) as $nodes
    | if type != "array" then error("invalid roadmap candidate list") else . end
    | [ .[] as $candidate
        | ($nodes[($candidate.number|tostring)] // null) as $node
        | select((($candidate.state // "OPEN") | ascii_downcase) == "open")
        | select((($node.state // "OPEN") | ascii_downcase) == "open")
        | select((($candidate | has_children) or ($node | has_children)) | not)
        | (($candidate | names) + ($node | names)) as $labels
        | select($labels | index("on-hold") == null)
        | select($labels | any(. == "roadmap" or . == "roadmap-theme" or . == "roadmap-epic") | not)
        | select(all((($candidate | blockers) + ($node | blockers))[]?;
            ((.state // "") | ascii_downcase) != "open"
            or ((names + ($nodes[(.number | tostring)] // {} | names)) | any(. as $label | $merged_labels | index($label) != null))))
        | {number:$candidate.number, mapped:($node != null and $node.depth == 3),
           bug_top:(($labels | index("bug")) != null and ($labels | index("priority:top")) != null),
           top:($labels | index("priority:top") != null),
           dependents:($node.dependents_count // 0), order:$node.order}
      ]
    # Ordering is not admission: unknown and other-depth leaves retain incoming order.
    | [.[] | select(.mapped | not)] as $fallback
    | (if ($fallback | length) > 0 then
         ("roadmap: appended fallback candidates " + ($fallback | map(.number | tostring) | join(",")) + "\n" | stderr | empty)
       else empty end),
      (([.[] | select(.mapped)] | sort_by([if .bug_top then 0 elif .top then 1 else 2 end, -.dependents, .order]))
       + $fallback | .[].number)
  ' <<< "$candidates"
}

roadmap_order_candidate_json() {
  local tree="$1" candidates="$2" ordered
  ordered="$(roadmap_order_candidates "$tree" "$candidates")" || return 1
  jq -cn --slurpfile candidates_s <(printf '%s' "$candidates") --arg ordered "$ordered" '($candidates_s[0]) as $candidates |
    [$ordered | split("\n")[] | select(length > 0) as $number
      | $candidates[] | select(.number == ($number | tonumber))]
  '
}

roadmap_epics() {
  local flat
  flat="$(roadmap_flatten "$1")" || return 1
  jq -c '[.[] | select(.depth == 2 and (.labels | index("roadmap-epic") != null)) | {number,title,milestone: .theme_milestone,order}]' <<< "$flat"
}

roadmap_choose_epic() {
  local tree="$1" issue_json="$2" source_issue="${3:-}" flat
  flat="$(roadmap_flatten "$tree")" || return 1
  jq -ce --slurpfile flat_s <(printf '%s' "$flat") --arg source "$source_issue" '($flat_s[0]) as $flat |
    def names($s): [$s | ascii_downcase | scan("[a-z0-9]{2,}")];
    def chinese_bigrams($s):
      ($s | explode) as $chars
      | [range(0; (($chars | length) - 1)) as $i
         | select($chars[$i] >= 19968 and $chars[$i] <= 40959
             and $chars[$i + 1] >= 19968 and $chars[$i + 1] <= 40959)
         | [$chars[$i], $chars[$i + 1]] | implode];
    def issue_labels: [(.labels // [])[] | if type == "string" then . else .name // "" end];
    def score($text_words; $text_bigrams; $title):
      ([names($title)[] as $word | select($text_words | index($word)) | $word] | unique | length) * 3
      + ([chinese_bigrams($title)[] as $pair | select($text_bigrams | index($pair)) | $pair] | unique | length);
    . as $issue
    | ($flat | map({key:(.number|tostring),value:.}) | from_entries) as $nodes
    | [$flat[] | select(.depth == 2 and (.labels | index("roadmap-epic") != null))] as $epics
    | ($issue | issue_labels) as $labels
    | (if ($labels | index("pipeline-system")) != null then
         [$epics[] | select(.theme_milestone == "开发流水线与运行稳定")]
       else $epics end) as $candidate_epics
    | (if ($labels | index("pipeline-system")) != null
         and (($issue.title // "") | ascii_downcase | startswith("pipeline health:")) then
         [$candidate_epics[] | select(.title == "自动派发与规则校验持续可靠")][0]
       else null end) as $pipeline_health_epic
    | (if ($source | test("^[1-9][0-9]*$")) then $nodes[$source] else null end) as $source_node
    | (if $source_node != null then $nodes[($source_node.parent|tostring)] else null end) as $inherited
    | ((($issue.title // "") + "\n" + ($issue.body // "")) as $text
       | names($text) as $text_words
       | chinese_bigrams($text) as $text_bigrams
       | (if $pipeline_health_epic != null then $pipeline_health_epic
          elif $inherited != null and ($inherited.labels | index("roadmap-epic") != null)
            and (($labels | index("pipeline-system")) == null
              or $inherited.theme_milestone == "开发流水线与运行稳定") then $inherited
          else
            ([$candidate_epics[] | . + {score:score($text_words;$text_bigrams;.title)} | select(.score > 0)]
             | sort_by([-.score,.order]) | .[0]) as $best
            | ($candidate_epics | map(select(.title == "待归类")) | (map(select(.theme_milestone != "开发流水线与运行稳定")) + .) | .[0]) as $fallback
            | $best // $fallback
          end) as $preferred
       | if $preferred == null then error("roadmap has no matching or 待归类 epic")
         else
           (if (($preferred.children_total // (($preferred.children // []) | length)) < 100) then $preferred
            else
              [$candidate_epics[]
               | select(.theme == $preferred.theme)
               | select((.children_total // ((.children // []) | length)) < 100)
               | . + {score:score($text_words;$text_bigrams;.title)}]
              | sort_by([-.score,.order]) | .[0]
            end) as $selected
           | if $selected == null then error("roadmap theme has no non-full epic")
             else {epic:$selected.number,title:$selected.title,milestone:$selected.theme_milestone} end
         end)
  ' <<< "$issue_json"
}

roadmap_source_issue() {
  jq -r '(.body // "") | try capture("(?:由[[:space:]]*|父票[：:]?[[:space:]]*)#(?<number>[1-9][0-9]*)").number catch ""' \
    <<< "${1:-{}}" 2>/dev/null || true
}

roadmap_ledger_add() {
  local ledger="$1" number="$2" lock_file="${3:-$1.lock}" lock_fd
  exec {lock_fd}>"$lock_file" || return 1
  flock -x "$lock_fd" || { exec {lock_fd}>&-; return 1; }
  if ! grep -Fqx -- "$number" "$ledger" 2>/dev/null; then
    if ! (umask 077; printf '%s\n' "$number" >> "$ledger"); then
      flock -u "$lock_fd"; exec {lock_fd}>&-; return 1
    fi
  fi
  if ! chmod 600 "$ledger" 2>/dev/null; then
    flock -u "$lock_fd"; exec {lock_fd}>&-; return 1
  fi
  flock -u "$lock_fd"
  exec {lock_fd}>&-
}

roadmap_place_issue() {
  local cache_file="$1" number="$2" issue_json="$3" source="${4:-}" tree flat existing selected epic milestone placed_file linked_file sub_issue_id link_out
  [[ "$number" =~ ^[1-9][0-9]*$ && -r "$cache_file" ]] || return 64
  tree="$(cat -- "$cache_file")" || return 1
  roadmap_tree_is_valid "$tree" || return 1
  flat="$(roadmap_flatten "$tree")" || return 1
  if existing="$(jq -ce --argjson number "$number" '[.[] | select(.number == $number)][0] // empty' <<< "$flat")"; then
    if jq -e 'any(.children[]?; ((.state // "OPEN") | ascii_downcase) == "open")
      or any(.labels[]?; . == "roadmap" or . == "roadmap-theme" or . == "roadmap-epic")' <<< "$existing" >/dev/null; then
      echo "roadmap: refusing to place container #$number as a ticket" >&2
      return 1
    fi
    milestone="$(jq -r '.theme_milestone // empty' <<< "$existing")" || return 1
    if [[ -n "$milestone" && "$(jq -r '.milestone // empty' <<< "$existing")" != "$milestone" ]]; then
      guarded_write gh issue edit "$number" --repo "$REPO" --milestone "$milestone" || return 1
    fi
    return 0
  fi
  placed_file="$cache_file.placed"
  if [ -r "$placed_file" ] && grep -Fqx -- "$number" "$placed_file"; then return 0; fi
  linked_file="$cache_file.linked"
  [[ "$source" =~ ^[1-9][0-9]*$ ]] || source="$(roadmap_source_issue "$issue_json")"
  selected="$(roadmap_choose_epic "$tree" "$issue_json" "$source")" || return 1
  epic="$(jq -er '.epic | select(type == "number" and . > 0)' <<< "$selected")" || return 1
  milestone="$(jq -r '.milestone // empty' <<< "$selected")" || return 1
  if ! grep -Fqx -- "$number" "$linked_file" 2>/dev/null; then
    sub_issue_id="$(gh api "repos/$REPO/issues/$number" --jq '.id | select(type == "number" and . > 0)')" || return 1
    [[ "$sub_issue_id" =~ ^[1-9][0-9]*$ ]] || return 1
    # "duplicate sub-issues" = already under this epic (stale tree cache): goal met.
    link_out="$(guarded_write gh api "repos/$REPO/issues/$epic/sub_issues" --method POST \
      -F "sub_issue_id=$sub_issue_id" -F replace_parent=true 2>&1)" \
      || { [[ "$link_out" == *"may not contain duplicate sub-issues"* ]] || { printf '%s\n' "$link_out" >&2; return 1; }; }
    roadmap_ledger_add "$linked_file" "$number" "$placed_file.lock" || return 1
  fi
  if [[ -n "$milestone" ]]; then
    guarded_write gh issue edit "$number" --repo "$REPO" --milestone "$milestone" || return 1
  fi
  roadmap_ledger_add "$placed_file" "$number" "$placed_file.lock"
}

roadmap_issue_create() {
  local -a command_args=("$@")
  local -a labels=() parsed_labels=()
  local target_repo="${REPO:-}" title="" body_file="" source="" temp_dir="" cache_file="" tree="" issue_input selected created_url issue_number issue_json status value labels_json
  local i cache_valid=0 has_stage_label=0
  [[ "${command_args[0]:-}" == gh && "${command_args[1]:-}" == issue && "${command_args[2]:-}" == create ]] || return 64
  if [[ "${DRY_RUN:-0}" == 1 ]]; then
    ROADMAP_ISSUE_CREATE_INNER=1 guarded_write "${command_args[@]}"
    return $?
  fi

  for ((i = 3; i < ${#command_args[@]}; i++)); do
    case "${command_args[i]}" in
      --repo|-R) ((i += 1)); target_repo="${command_args[i]:-}" ;;
      --repo=*) target_repo="${command_args[i]#*=}" ;;
    esac
  done
  if [[ "${target_repo,,}" != "${REPO,,}" ]]; then
    ROADMAP_ISSUE_CREATE_INNER=1 guarded_write "${command_args[@]}"
    return $?
  fi

  temp_dir="$(umask 077; mktemp -d "${TMPDIR:-/tmp}/zf-roadmap-create.XXXXXX")" || return 1
  for ((i = 3; i < ${#command_args[@]}; i++)); do
    case "${command_args[i]}" in
      --repo|-R) ((i += 1)) ;;
      --repo=*) ;;
      --title|-t)
        ((i += 1)); title="${command_args[i]:-}"
        ;;
      --title=*) title="${command_args[i]#*=}" ;;
      --body|-b)
        ((i += 1)); value="${command_args[i]:-}"
        body_file="$temp_dir/body.md"
        if ! printf '%s' "$value" > "$body_file"; then rm -rf -- "$temp_dir"; return 1; fi
        ;;
      --body=*)
        body_file="$temp_dir/body.md"
        if ! printf '%s' "${command_args[i]#*=}" > "$body_file"; then rm -rf -- "$temp_dir"; return 1; fi
        ;;
      --body-file)
        ((i += 1)); value="${command_args[i]:-}"
        if [[ "$value" == - ]]; then
          body_file="$temp_dir/body.md"
          if ! cat > "$body_file"; then rm -rf -- "$temp_dir"; return 1; fi
          command_args[i]="$body_file"
        else
          body_file="$value"
        fi
        ;;
      --body-file=*)
        value="${command_args[i]#*=}"
        if [[ "$value" == - ]]; then
          body_file="$temp_dir/body.md"
          if ! cat > "$body_file"; then rm -rf -- "$temp_dir"; return 1; fi
          command_args[i]="--body-file=$body_file"
        else
          body_file="$value"
        fi
        ;;
      --label|-l)
        ((i += 1)); value="${command_args[i]:-}"
        IFS=, read -r -a parsed_labels <<< "$value"
        labels+=("${parsed_labels[@]}")
        ;;
      --label=*|-l=*)
        value="${command_args[i]#*=}"
        IFS=, read -r -a parsed_labels <<< "$value"
        labels+=("${parsed_labels[@]}")
        ;;
      --parent)
        ((i += 1)); source="${command_args[i]:-}"
        ;;
      --parent=*) source="${command_args[i]#*=}" ;;
      --) break ;;
    esac
  done
  if [[ -z "$title" || -z "$body_file" || ! -r "$body_file" ]]; then
    echo "roadmap: refusing to create issue in $target_repo without explicit title and readable body" >&2
    rm -rf -- "$temp_dir"
    return 64
  fi

  for value in "${labels[@]}"; do
    if roadmap_stage_requires_parent "$value"; then has_stage_label=1; break; fi
  done
  if [[ "$has_stage_label" != 1 ]]; then
    # Placement happens after GitHub accepts the create; keep a failed placement visible to triage.
    labels+=(needs-triage)
    command_args+=(--label needs-triage)
  fi

  cache_file="${ZF_ROADMAP_TREE_CACHE_FILE:-}"
  if [[ -n "$cache_file" && -r "$cache_file" ]]; then
    tree="$(cat -- "$cache_file")" || tree=""
    if [[ -n "$tree" ]] && roadmap_tree_is_valid "$tree"; then cache_valid=1; fi
  fi
  if [[ "$cache_valid" != 1 ]]; then
    cache_file="$temp_dir/tree.json"
    if ! ZF_ROADMAP_SNAPSHOT_FILE="$temp_dir/snapshot.json" roadmap_fetch_tree "$cache_file" "$target_repo"; then
      echo "roadmap: refusing to create issue; could not read roadmap tree for $target_repo" >&2
      rm -rf -- "$temp_dir"
      return 1
    fi
    tree="$(cat -- "$cache_file")" || tree=""
  fi
  if ((${#labels[@]})); then
    labels_json="$(printf '%s\n' "${labels[@]}" | jq -R . | jq -cs .)" || {
      echo "roadmap: refusing to create issue; could not read issue labels for classification" >&2
      rm -rf -- "$temp_dir"
      return 1
    }
  else
    labels_json='[]'
  fi
  issue_input="$(jq -cn --arg title "$title" --rawfile body "$body_file" --argjson labels "$labels_json" '{title:$title,body:$body,labels:$labels}')" || {
    echo "roadmap: refusing to create issue; could not prepare roadmap classification" >&2
    rm -rf -- "$temp_dir"
    return 1
  }
  [[ "$source" =~ ^[1-9][0-9]*$ ]] || source="$(roadmap_source_issue "$issue_input")"
  selected="$(roadmap_choose_epic "$tree" "$issue_input" "$source")" || {
    echo "roadmap: refusing to create issue; no roadmap epic matches its title/body" >&2
    rm -rf -- "$temp_dir"
    return 1
  }
  jq -e '.epic | type == "number" and . > 0' <<< "$selected" >/dev/null || {
    echo "roadmap: refusing to create issue; roadmap classification returned no parent" >&2
    rm -rf -- "$temp_dir"
    return 1
  }

  if created_url="$(ROADMAP_ISSUE_CREATE_INNER=1 guarded_write "${command_args[@]}")"; then
    :
  else
    status=$?
    rm -rf -- "$temp_dir"
    return "$status"
  fi
  if [[ "$created_url" =~ /issues/([1-9][0-9]*)$ ]]; then
    issue_number="${BASH_REMATCH[1]}"
  else
    echo "roadmap: issue create returned no issue number; refusing success (output: $created_url)" >&2
    rm -rf -- "$temp_dir"
    return 1
  fi
  if ! issue_json="$(timeout 20s gh issue view "$issue_number" --repo "$target_repo" --json number,title,body,state,labels)"; then
    echo "roadmap: issue #$issue_number was created at $created_url but could not be read for parent placement" >&2
    rm -rf -- "$temp_dir"
    return 1
  fi
  if ! roadmap_place_issue "$cache_file" "$issue_number" "$issue_json" "$source" >/dev/null; then
    echo "roadmap: issue #$issue_number was created at $created_url but parent placement failed" >&2
    rm -rf -- "$temp_dir"
    return 1
  fi
  rm -rf -- "$temp_dir"
  printf '%s\n' "$created_url"
}

roadmap_stage_requires_parent() {
  case "${1:-}" in
    needs-triage|needs-info|ready-for-agent|ready-for-human|needs-owner|checks-blocked|needs-advisor|needs-recut|awaiting-release|awaiting-pipeline-sync|awaiting-pipeline-health|on-hold) return 0 ;;
    *) return 1 ;;
  esac
}

roadmap_node_is_container() {
  jq -e 'any(.children[]?; ((.state // "OPEN") | ascii_downcase) == "open")
    or any(.labels[]?; . == "roadmap" or . == "roadmap-theme" or . == "roadmap-epic")' \
    <<< "$1" >/dev/null 2>&1
}

# Use the same tick snapshot that guards stage transitions when deciding
# whether an advisor verdict belongs to a roadmap container.
roadmap_issue_is_container() {
  local number="$1" cache_file="${ZF_ROADMAP_TREE_CACHE_FILE:-}" tree flat node
  [[ "$number" =~ ^[1-9][0-9]*$ ]] || return 2
  [[ "$(roadmap_switch_value)" == true ]] || return 1
  [[ -n "$cache_file" && -r "$cache_file" ]] || return 2
  tree="$(cat -- "$cache_file")" || return 2
  roadmap_tree_is_valid "$tree" || return 2
  flat="$(roadmap_flatten "$tree")" || return 2
  node="$(jq -ce --argjson number "$number" '[.[] | select(.number == $number)][0] // empty' <<< "$flat")" || return 1
  roadmap_node_is_container "$node"
}

roadmap_ensure_issue_parent() (
  local number="$1" state="$2" issue_json="${3:-}" source="${4:-}" cache_file tree flat node scratch=""
  [[ "$(roadmap_switch_value)" == true ]] || return 0
  roadmap_stage_requires_parent "$state" || return 0
  cache_file="${ZF_ROADMAP_TREE_CACHE_FILE:-}"
  if [[ -z "$cache_file" || ! -r "$cache_file" ]]; then
    mkdir -p -- "$AGENT_HOME/night" || return 1
    scratch="$(mktemp -d "$AGENT_HOME/night/.roadmap-parent.XXXXXX")" || return 1
    trap 'rm -rf -- "$scratch"' EXIT
    cache_file="$scratch/tree.json"
    roadmap_fetch_tree "$cache_file" "$REPO" || return 1
  fi
  tree="$(cat -- "$cache_file")" || return 1
  flat="$(roadmap_flatten "$tree")" || return 1
  if node="$(jq -ce --argjson number "$number" '[.[] | select(.number == $number)][0] // empty' <<< "$flat")"; then
    if roadmap_node_is_container "$node"; then
      echo "roadmap: refusing stage $state on container #$number" >&2
      return 3 # A confirmed container lets intake route this parent to tracker.
    fi
    roadmap_place_issue "$cache_file" "$number" "$issue_json" "$source"
    return $?
  fi
  if [ -r "$cache_file.placed" ] && grep -Fqx -- "$number" "$cache_file.placed"; then return 0; fi
  if [ -z "$issue_json" ]; then
    issue_json="$(timeout 20s gh issue view "$number" --repo "$REPO" --json number,title,body 2>/dev/null)" || return 1
  fi
  roadmap_place_issue "$cache_file" "$number" "$issue_json" "$source"
)

roadmap_health_assess() {
  local tree="$1" open_issues="$2" now="$3" tree_ok="${4:-true}"
  local stage_labels="${5:-[\"needs-triage\",\"needs-advisor\",\"needs-info\",\"ready-for-agent\",\"needs-recut\",\"awaiting-release\",\"on-hold\",\"concluded\",\"released\"]}"
  local issues_ok="${6:-true}" flat
  if [[ "$tree_ok" != true ]]; then
    jq -cn '{verdict:"BROKEN",item_keys:["tree-read"],detail:"tree read failed; item-keys=tree-read"}'
    return
  fi
  if ! roadmap_tree_is_valid "$tree"; then
    jq -cn '{verdict:"BROKEN",item_keys:["tree-read"],detail:"tree cache invalid; item-keys=tree-read"}'
    return
  fi
  if [[ "$(jq '.roots | length' <<< "$tree")" == 0 ]]; then
    jq -cn '{verdict:"NONE",item_keys:[],detail:"no open roadmap root; item-keys=none"}'
    return
  fi
  if [[ "$issues_ok" != true ]] || ! jq -e 'type == "array"' <<< "$open_issues" >/dev/null 2>&1; then
    jq -cn '{verdict:"BROKEN",item_keys:["open-issues-read"],detail:"open issue snapshot incomplete; item-keys=open-issues-read"}'
    return
  fi
  flat="$(roadmap_flatten "$tree")" || {
    jq -cn '{verdict:"BROKEN",item_keys:["tree-read"],detail:"tree flatten failed; item-keys=tree-read"}'
    return
  }
  jq -cn --slurpfile tree_s <(printf '%s' "$flat") --slurpfile open_s <(printf '%s' "$open_issues") --argjson now "$now" --argjson stages "$stage_labels" '($tree_s[0]) as $tree | ($open_s[0]) as $open |
    def label_names: [(.labels // [])[] | if type == "string" then . else .name // "" end];
    def is_container:
      ((label_names | any(. == "roadmap" or . == "roadmap-theme" or . == "roadmap-epic"))
       or (if (.children | type) == "array" then
             any(.children[]?; ((.state // "OPEN") | ascii_downcase) == "open")
           elif (.subIssuesSummary | type) == "object" then
             (.subIssuesSummary.total // 0) > (.subIssuesSummary.completed // 0)
           else
             ((.subIssues.totalCount // 0) > 0)
           end));
    def has_stage:
      label_names as $labels
      | any($labels[]; . as $label | ($stages | index($label)) != null);
    def age($value): try ($value | fromdateiso8601) catch null;
    ($tree | map({key:(.number|tostring),value:.}) | from_entries) as $nodes
    | [$tree[] | select(is_container) | select(has_stage)
       | "container-stage:#" + (.number|tostring)] as $tree_container_keys
    | [$open[] | select(is_container) | select(has_stage)
       | "container-stage:#" + (.number|tostring)] as $open_container_keys
    | [$open[] as $issue
       | select(($nodes[($issue.number|tostring)] // null) == null)
       | select(($issue | is_container) | not)
       | (age($issue.createdAt // $issue.created_at)) as $created
       | select($created == null or ($now - $created) > 1800)
       | "orphan:#" + ($issue.number|tostring)] as $orphan_keys
    | [$open[] as $issue
       | ($nodes[($issue.number|tostring)] // null) as $node
       | select($node != null)
       | ($nodes[($node.parent|tostring)] // null) as $parent
       | select($parent != null and $parent.title == "待归类")
       | (age($issue.createdAt // $issue.created_at)) as $created
       | select($created == null or ($now - $created) > 86400)
       | "unclassified:#" + ($issue.number|tostring)] as $unclassified_keys
    | [$tree[] | select(.depth == 1 and (.labels | index("roadmap-theme") != null))
       | select(. as $theme | any($tree[]; .parent == $theme.number and .title == "待归类") | not)
       | "fallback-epic-missing:#" + (.number|tostring)] as $fallback_keys
    | ($tree_container_keys + $open_container_keys + $orphan_keys + $unclassified_keys + $fallback_keys | unique | sort) as $keys
    | {verdict:(if ($keys|length)>0 then "BROKEN" else "OK" end),item_keys:$keys,
       detail:("root=#" + (($tree | map(select(.depth==0)) | .[0].number)|tostring)
         + " open=" + ($open|length|tostring)
         + " item-keys=" + (if ($keys|length)>0 then ($keys|join(",")) else "none" end))}
  '
}
