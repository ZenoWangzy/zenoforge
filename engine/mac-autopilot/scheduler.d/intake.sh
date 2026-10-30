
# ---------- 4a. issue 收单：按空闲产能收（work-conserving），不是固定 3 个 ----------
# 2026-10-20 maintainer：8 个 worker 是雇来干活的。实测平均只 2/8 在干、近半数 tick 0 个在干，而 open issue 有 500+：
# 根因是收单只收 pipeline-system 标签、在途上限 3。现在：空闲槽位 = max_workers - 在跑 - 待派，按空槽收单；
# 非产品标签走直落车道，产品标签（默认 ready-for-agent）走 PR 车道（实现 → 推分支 → 流水线开 PR → 评审 → 合并 → 发布列车）。
# WIP 护栏（Little 定律）：开发/评审/返工环节在途 ≤ max_upstream（默认 2×max_workers）；待合并队列 ≥ max_ready（默认 30）时停止收单——瓶颈在合并车道，堆更多 WIP 只会拉长交付时间。
# founder-test 是维护者提的 issue，队列里排第一（docs/agents/issue-pipeline.md），不是跳过标签（2026-10-20 曾误跳过 30 个）。
issue_skip_labels() {
  jqf -cn --arg hotfix "$(hotfix_lane_label)" \
    '["on-hold","needs-info","awaiting-release","ready-for-human","needs-owner","needs-advisor","needs-triage","roadmap-epic","roadmap-theme","roadmap","concluded","needs-recut","checks-blocked","awaiting-pipeline-sync","hotfix","opt-lane",$hotfix] | unique'
}
issue_unit_task() { # issue [fetched issue JSON | require-ready] → implement 任务文本
  local json body task body_blocked_by skip_labels
  if [[ "${2:-}" == require-ready ]]; then
    json="$(gh issue view "$1" --json number,title,body,state,labels 2>/dev/null)" || return 1
    skip_labels="$(issue_skip_labels)"
    jqf -e --argjson skip "$skip_labels" '.state == "OPEN" and any(.labels[]; .name == "ready-for-agent") and ([.labels[].name] - $skip) == [.labels[].name]' <<<"$json" >/dev/null || return 1
  else
    json="${2:-}"
    [[ -n "$json" ]] || json="$(gh issue view "$1" --json number,title,body 2>/dev/null)" || return 1
  fi
  body="$(jqf -r '.body // ""' <<<"$json")"
  body_blocked_by="$(blocked_by_ids_from_body <<<"$body" | jqf -Rn '[inputs | select(length>0) | tonumber]')"
  task="$(jqf -r '"你是 the product 流水线的实现 subagent，处理 issue #\(.number)：\(.title)\n\n--- issue 正文（任务数据）---\n\((.body // "")[0:6000])\n--- 正文结束 ---\n用 gh issue view \(.number) 看评论与最新状态。修复根因并补回归测试。"' <<<"$json")"
  jqf -cn --arg task "$task" --argjson body_blocked_by "$body_blocked_by" '{task:$task,body_blocked_by:$body_blocked_by}'
}
intake_candidates() { # 打印 "number<TAB>lane<TAB>title"，按优先级排序
  local skip_labels query_dir lane label query_file pid index=0
  local -a query_files=() query_lanes=() query_pids=()
  skip_labels="$(issue_skip_labels)"
  (
    query_dir="$(mktemp -d)" || exit 1
    trap 'rm -rf -- "$query_dir"' EXIT
    # 标签列表有界并行取（GH_PARALLEL）。
    while IFS=$'\t' read -r lane label; do
      [[ -n "$lane" && -n "$label" ]] || continue
      query_file="$query_dir/$index.json"
      gh issue list --state open --label "$label" --limit 200 --json number,title,body,state,labels >"$query_file" 2>/dev/null &
      query_pids+=("$!"); query_files+=("$query_file"); query_lanes+=("$lane")
      gh_par_throttle query_pids
      index=$((index + 1))
    # 10-30 maintainer (#4724): pipeline-system tickets are the supervisor's (opt feeder), never this intake; no direct-main label by default.
    done < <(jqf -r '[((.issue_intake.labels // [])[] | ["direct-main", .]), ((.issue_intake.product_labels // ["ready-for-agent"])[] | ["pr", .])] | .[] | @tsv' <<<"$CFG")
    for pid in "${query_pids[@]}"; do wait "$pid" || :; done
    {
      for ((index = 0; index < ${#query_files[@]}; index++)); do
        jqf -c --arg lane "${query_lanes[$index]}" '.[] | . + {lane:$lane}' "${query_files[$index]}" || true
      done
    } | jqf -rs --argjson skip "$skip_labels" '
      def rank: [.labels[].name] as $n
        | if ($n | index("founder-test")) then 0 elif ($n | index("priority:top")) then 1
          elif ($n | index("critical-path")) then 2  # 批次 STATE 的关键路径（#4363）：排在普通功能前、遗留后
          elif ($n | index("focus")) then 3 elif ($n | index("finish-first")) then 4 elif ($n | index("bug")) then 5
          elif ($n | index("legacy")) then 7 else 6 end;
      map(select(([.labels[].name] - $skip) == [.labels[].name]))
      | group_by(.number) | map(sort_by(.lane) | .[0])
      | sort_by([rank, -.number]) | .[] | "\(.number)\t\(.lane)\t\(.title | gsub("\t"; " "))\t\([.labels[].name] | tojson)\t\({number,title,body,state,labels} | @base64)"'
  )
}
predecessor_candidates() { # 停在前置上的单元：先把前置 issue 批量拉进来（拓扑顺序）
  local dep issue skip_labels q response start
  local -a deps=() deps_filtered=() chunk=()
  local -A issue_in_ledger=()
  skip_labels="$(issue_skip_labels)"
  mapfile -t deps < <(jqf -r '[.units[] | select(.stage=="blocked-external" and .blocked_on != null) | .blocked_on] | unique | .[]' "$UNITS")
  while IFS= read -r issue; do [[ "$issue" =~ ^[0-9]+$ ]] && issue_in_ledger["$issue"]=1; done \
    < <(jqf -r '[.units[].issue | numbers] | unique | .[]' "$UNITS")
  for dep in "${deps[@]}"; do
    [[ "${issue_in_ledger[$dep]:-}" == 1 ]] || deps_filtered+=("$dep")
  done
  for ((start=0; start<${#deps_filtered[@]}; start+=20)); do
    chunk=("${deps_filtered[@]:start:20}"); q=""
    for dep in "${chunk[@]}"; do
      [[ "$dep" =~ ^[0-9]+$ ]] || continue
      q+=" i$dep: issue(number: $dep) { number title body state labels(first: 100) { nodes { name } } }"
    done
    [[ -n "$q" ]] || continue
    response="$(gh api graphql -F owner='{owner}' -F name='{repo}' -f query="query(\$owner: String!, \$name: String!) { repository(owner: \$owner, name: \$name) {$q} }" 2>/dev/null)" || continue
    jqf -r --argjson skip "$skip_labels" '
      [.data.repository | to_entries[] | .value | select(type=="object")
        | {number,title,body:(.body // ""),state,labels:[.labels.nodes[]? | {name}]}]
      | sort_by(.number)[] | select(.state=="OPEN")
      | select(([.labels[].name] - $skip) == [.labels[].name])
      | "\(.number)\t\(if any(.labels[]; .name=="pipeline-system") then "direct-main" else "pr" end)\t\(.title | gsub("\t"; " "))\t\([.labels[].name] | tojson)\t\(. | @base64)"' <<<"$response"
  done
}
existing_handoff_candidates() {
  local state_dir="${AGENT_HOME:-${HOME:-}/.zenoforge}/state"
  local files=( "$state_dir"/*.json )
  [[ -f "${files[0]}" ]] || return 0
  jqf -r '
    select(.state == "ready-for-agent" and (.scheduler_handoff.episode // "") != "")
    | (input_filename | capture("(?<n>[0-9]+)\\.json$").n | tonumber) as $n
    | [$n, "pr", "handoff", "[]"] | @tsv
  ' "${files[@]}" 2>/dev/null
}
handoff_open_pr() { # issue → matching PR rows from this tick's single census
  local n="$1"
  [[ -n "${HANDOFF_PR_CENSUS:-}" ]] || return 1
  jqf -c --slurpfile u "$UNITS" --arg n "$n" '
    [.[] | . as $p
      | [($p.body // "") | match("(?i)\\b(?:fix(?:es)?|closes|resolves)[[:space:]:]+#(?<id>[0-9]+)"; "g") | .captures[0].string] as $fixes
      | [($p.body // "") | match("(?im)^[[:space:]]*[-*]?[[:space:]]*refs[[:space:]:]+#(?<id>[0-9]+)"; "g") | .captures[0].string] as $refs
      | (if ($fixes | length) > 0 then $fixes else $refs end) as $claims
      | ([($p.headRefName // "") | capture("^agent/issue-(?<id>[0-9]+)$").id] + $claims | unique) as $issues
      | select(($issues | index($n)) != null)
      | $p + {ambiguousIssues: (($issues | length) > 1)}]
    | map(. as $p | select($p.ambiguousIssues or (any($u[0].units[]; .pr == $p.number and .issue != null and (.issue | tostring) != $n) | not)))
    | map({number,headRefName,ambiguousIssues,hotfix:any(.labels[]; .name == "hotfix")})
  ' <<<"$HANDOFF_PR_CENSUS"
}
handoff_include_pr() { # fallback after a failed census: inspect only a known PR
  local pr_number="$1" row
  row="$(gh pr view "$pr_number" --json number,headRefName,title,body,state,labels 2>/dev/null)" || row=""
  if ! jqf -e --argjson pr "$pr_number" 'type=="object" and .number==$pr and (.headRefName|type)=="string" and (.state | IN("OPEN","CLOSED","MERGED")) and (.labels | type)=="array" and all(.labels[]; (.name | type)=="string")' <<<"$row" >/dev/null; then
    jqf --argjson pr "$pr_number" '.units |= map(if .pr == $pr then .hold_handoff_lookup_pending=true | .hold_handoff_waiting=true else . end)' "$UNITS" | write_state "$UNITS"
    return 1
  fi
  jqf --argjson pr "$pr_number" '.units |= map(if .pr == $pr then del(.hold_handoff_lookup_pending) | if ((.hold_handoff_wait_issues // []) | length) == 0 then del(.hold_handoff_waiting) else . end else . end)' "$UNITS" | write_state "$UNITS"
  if jqf -e '.state == "OPEN"' <<<"$row" >/dev/null; then
    HANDOFF_PR_CENSUS="$(jqf -c --slurpfile row <(printf '%s' "$row") '. + [$row[0]]' <<<"$HANDOFF_PR_CENSUS")"
  fi
}
register_new_issues() {
  local enabled live pending idle upstream max_up ready_q max_ready want added=0 n lane title labels task_record task body_blocked_by branch busy handoff state_file acceptance
  local episode existing_id existing_pr prior_pr pr_changed pr_state lane_policy handoff_all handoff_pr handoff_branch recovery_sha
  local cached_prs busy_prs issue64
  local existing_only="${1:-0}" only_pred=0 ids lookup handoff_rows matches ids_state pr_number known_prs known_failed hotfix_prs prior_worktree prior_reason episode_hash related_id related_hash unsafe_clones
  local issue_json parent_reason parent_status parent_transition_status
  hotfix_issue_numbers || say "hotfix issue list unavailable; linked issue PRs may not be classified this tick"
  enabled="$(jqf -r 'if .issue_intake.enabled == false then "false" else "true" end' <<<"$CFG")"
  [[ "$enabled" == true || "$existing_only" == 1 ]] || return 0
  if (( existing_only )); then
    # Existing units consume their handoff even when new intake is at capacity.
    handoff_rows="$(existing_handoff_candidates)"
    [[ -n "$handoff_rows" ]] || return 0
    if [[ "${2:-}" != reuse ]]; then
      HANDOFF_CENSUS_PARTIAL=0; HANDOFF_WAIT_PRS='[]'; HANDOFF_WAIT_BRANCHES='[]'
      cached_prs="$(tick_prs 2>/dev/null || true)"
      if [[ -n "$cached_prs" ]] && jqf -e 'type=="array" and length < 300' <<<"$cached_prs" >/dev/null; then
        HANDOFF_PR_CENSUS="$(jqf -c '[.[] | {number,headRefName,title,body,labels}]' <<<"$cached_prs")"
      else
        HANDOFF_PR_CENSUS="$(gh pr list --state open --limit 500 --json number,headRefName,title,body,labels 2>/dev/null)" || HANDOFF_PR_CENSUS=""
      fi
      jqf -e 'type == "array" and all(.[]; (.number | type)=="number" and (.labels | type)=="array" and all(.labels[]; (.name | type)=="string"))' <<<"${HANDOFF_PR_CENSUS:-}" >/dev/null || HANDOFF_PR_CENSUS=""
      if [[ -z "$HANDOFF_PR_CENSUS" ]]; then
        HANDOFF_CENSUS_PARTIAL=1; HANDOFF_PR_CENSUS='[]'
        while read -r pr_number; do handoff_include_pr "$pr_number" || true; done < <(jqf -r '[.units[] | select((.stage | IN("merged","landed","closed","done","wontfix","duplicate")) | not) | .pr | select(type=="number")] | unique | .[]' "$UNITS")
      else
        jqf '.units |= map(if .hold_handoff_lookup_pending == true then del(.hold_handoff_lookup_pending) | if ((.hold_handoff_wait_issues // []) | length) == 0 then del(.hold_handoff_waiting) else . end else . end)' "$UNITS" | write_state "$UNITS"
      fi
    fi
    want=1000000000; busy=""
  else
  live="$(live_workers)"
  # 被 footprint 互斥挡住的 pending 不用 worker，不占产能（仍计入 upstream 的 WIP 额度）
  pending="$(jqf '[.units[] | select(.stage | test("-pending$")) | select((.footprint_wait_owner // "") == "")] | length' "$UNITS")"
  idle=$(( MAX - live - pending ))
  (( idle > 0 )) || { say "intake held: no idle slot (live $live pending $pending max $MAX)"; return 0; }
  max_up="$(jqf -r ".issue_intake.max_upstream // $((2 * MAX))" <<<"$CFG")"; [[ "$max_up" =~ ^[0-9]+$ ]] || max_up=$((2 * MAX))
  max_ready="$(jqf -r '.issue_intake.max_ready // 30' <<<"$CFG")"; [[ "$max_ready" =~ ^[0-9]+$ ]] || max_ready=30
  upstream="$(jqf '[.units[] | select(.stage | test("^(implement|review|rereview|repair)(-pending)?$"))] | length' "$UNITS")"
  ready_q="$(jqf '[.units[] | select(.stage=="ready-to-merge" or .stage=="landing")] | length' "$UNITS")"
  # 合并车道是约束时停收新单，但挡着别人的前置照收：它们不收，停着的后继永远放不开（10-22 49 个单元停在前置上，
  # 其中 10 个前置从没进过流水线，因为 intake 一直 held）。
  want=$(( max_up - upstream )); (( idle < want )) && want=$idle
  if (( ready_q >= max_ready )); then
    say "intake held: $ready_q units wait to merge (max_ready $max_ready); the merge lane is the constraint; predecessors still admitted"
    only_pred=1; want=$idle
  fi
  (( want > 0 )) || { say "intake held: $upstream units upstream (max_upstream $max_up)"; return 0; }
  # 已有 open PR 的 issue 不再收（#3957 已由 #3958 实现，分支名却不是 agent/issue-N）：看分支、标题和正文里是否提到它。
  if [[ -n "${HANDOFF_PR_CENSUS:-}" && "${HANDOFF_CENSUS_PARTIAL:-0}" != 1 ]]; then
    busy="$(jqf -r '.[] | "\(.headRefName) \(.title) \(.body // "")"' <<<"$HANDOFF_PR_CENSUS")"
  else
    busy_prs="$(tick_prs 2>/dev/null)" || busy_prs=""
    if [[ -n "$busy_prs" ]]; then
      busy="$(jqf -r '.[] | "\(.headRefName) \(.title) \(.body // "")"' <<<"$busy_prs")"
    else
      busy="$(gh pr list --state open --limit 200 --json headRefName,title,body --jq '.[] | "\(.headRefName) \(.title) \(.body // "")"' 2>/dev/null)" || return 0
    fi
  fi
  fi
  while IFS=$'\t' read -r n lane title labels issue64; do
    [[ "$n" =~ ^[0-9]+$ ]] || continue
    (( added < want )) || break
    issue_json=""
    [[ -n "$issue64" ]] && issue_json="$(printf '%s' "$issue64" | base64 -d 2>/dev/null)" || true
    state_file="${AGENT_HOME:-${HOME:-}/.zenoforge}/state/$n.json"
    episode="$(jqf -r 'select(.state == "ready-for-agent") | .scheduler_handoff.episode // empty' "$state_file" 2>/dev/null)"
    handoff_all="$(jqf -c 'select(.state == "ready-for-agent") | .scheduler_handoff // {}' "$state_file" 2>/dev/null)"
    [[ -n "$handoff_all" ]] || handoff_all='{}'
    handoff_pr="$(jqf -r '.open_pr // empty' <<<"$handoff_all")"
    handoff_branch="$(jqf -r '.open_branch // empty' <<<"$handoff_all")"
    if [[ -n "$episode" ]]; then
      if (( existing_only )); then
        # An unavailable PR lookup must not release an already known unit's old approval.
        jqf --argjson n "$n" --arg episode "$episode" '.units |= map(if (.issue == $n or .branch == ("agent/issue-" + ($n | tostring))) and .hold_handoff_episode != $episode then .hold_handoff_wait_issues = (((.hold_handoff_wait_issues // []) + [$n]) | unique) | .hold_handoff_waiting=true else . end)' "$UNITS" | write_state "$UNITS"
      fi
      # Recorded PRs can be outside the census or attached to an existing unit.
      # Read their current labels before reusing them, rather than inferring
      # ownership from an old hold snapshot.
      known_prs="$(jqf -c --argjson n "$n" --arg pr "$handoff_pr" '
        ([.units[] | select(.issue == $n or .branch == ("agent/issue-" + ($n | tostring))) | .pr | select(type == "number")]
          + (if ($pr | test("^[0-9]+$")) then [($pr | tonumber)] else [] end)) | unique' "$UNITS")"
      known_failed=0
      while read -r pr_number; do
        if ! jqf -e --argjson pr "$pr_number" 'any(.[]; .number == $pr)' <<<"${HANDOFF_PR_CENSUS:-[]}" >/dev/null; then
          handoff_include_pr "$pr_number" || known_failed=1
        fi
      done < <(jqf -r '.[]' <<<"$known_prs")
      if (( known_failed )); then
        HANDOFF_WAIT_PRS="$(jqf -c --argjson add "$known_prs" '. + $add | unique' <<<"${HANDOFF_WAIT_PRS:-[]}")"
        HANDOFF_WAIT_BRANCHES="$(jqf -c --arg branch "$handoff_branch" 'if $branch == "" then . else (. + [$branch] | unique) end' <<<"${HANDOFF_WAIT_BRANCHES:-[]}")"
        jqf --argjson n "$n" --argjson prs "$known_prs" '.units |= map(if .issue == $n or .branch == ("agent/issue-" + ($n | tostring)) or ((.pr // null) as $pr | $prs | index($pr)) != null then .hold_handoff_wait_issues = (((.hold_handoff_wait_issues // []) + [$n]) | unique) | .hold_handoff_waiting=true else . end)' "$UNITS" | write_state "$UNITS"
        continue
      fi
      if [[ "$handoff_pr" =~ ^[0-9]+$ ]] && ! jqf -e --argjson pr "$handoff_pr" 'any(.[]; .number == $pr)' <<<"${HANDOFF_PR_CENSUS:-[]}" >/dev/null; then
        handoff_pr=""; handoff_branch=""
      fi
      # A PR can appear after the handoff, or use a non-agent branch.
      lookup="$(handoff_open_pr "$n")" || { [[ -n "$handoff_pr" ]] && lookup='[]' || continue; }
      if [[ "$handoff_pr" =~ ^[0-9]+$ ]]; then
        lookup="$(jqf -c --argjson pr "$handoff_pr" --slurpfile census <(printf '%s' "$HANDOFF_PR_CENSUS") '
          if any(.[]; .number == $pr) then . else
            . + [$census[0][] | select(.number == $pr) | {number,headRefName,ambiguousIssues:false,hotfix:any(.labels[]; .name == "hotfix")}]
          end' <<<"$lookup")"
      fi
      hotfix_prs="$(jqf -c --argjson prs "$known_prs" '[.[] | select(.number as $p | $prs | index($p)) | select(any(.labels[]; .name == "hotfix")) | .number]' <<<"${HANDOFF_PR_CENSUS:-[]}")"
      if jqf -e --argjson known "$hotfix_prs" 'any(.[]; .hotfix == true) or ($known | length > 0)' <<<"$lookup" >/dev/null; then
        ids="$(jqf -c --argjson known "$hotfix_prs" '([.[].number] + $known) | unique' <<<"$lookup")"
        HANDOFF_WAIT_PRS="$(jqf -c --argjson add "$ids" '. + $add | unique' <<<"${HANDOFF_WAIT_PRS:-[]}")"
        HANDOFF_WAIT_BRANCHES="$(jqf -c --argjson prs "$ids" --slurpfile census <(printf '%s' "$HANDOFF_PR_CENSUS") --arg branch "$handoff_branch" '
          . + [$census[0][] | select(.number as $p | $prs | index($p)) | .headRefName | select(type=="string" and length>0)] + (if $branch == "" then [] else [$branch] end) | unique' <<<"${HANDOFF_WAIT_BRANCHES:-[]}")"
        jqf --argjson n "$n" --argjson prs "$ids" '.units |= map(if .issue == $n or .branch == ("agent/issue-" + ($n | tostring)) or ((.pr // null) as $pr | $prs | index($pr)) != null then .hold_handoff_wait_issues = (((.hold_handoff_wait_issues // []) + [$n]) | unique) | .hold_handoff_waiting=true else . end)' "$UNITS" | write_state "$UNITS"
        continue
      fi
      # Clear this issue's wait from a PR once its successfully read association
      # no longer points here; other handoffs may still be waiting on the PR.
      ids="$(jqf -c '[.[].number] | unique' <<<"$lookup")"
      jqf --argjson n "$n" --argjson prs "$ids" '.units |= map(
        if ((.hold_handoff_wait_issues // []) | index($n)) != null and .issue != $n
          and .hold_handoff_lookup_pending != true and ((.pr // null) as $pr | $prs | index($pr)) == null
        then .hold_handoff_wait_issues |= map(select(. != $n))
          | if (.hold_handoff_wait_issues | length) == 0 then del(.hold_handoff_wait_issues, .hold_handoff_waiting) else . end
        else . end)' "$UNITS" | write_state "$UNITS"
      # Individually read ledger PRs can protect their old approvals, but do not
      # establish that an unregistered PR for this issue does not also exist.
      if [[ "${HANDOFF_CENSUS_PARTIAL:-0}" == 1 ]]; then
        HANDOFF_WAIT_PRS="$(jqf -c --argjson add "$ids" '. + $add | unique' <<<"${HANDOFF_WAIT_PRS:-[]}")"
        jqf --argjson n "$n" --argjson prs "$ids" '.units |= map(if .issue == $n or ((.pr // null) as $pr | $prs | index($pr)) != null then .hold_handoff_wait_issues = (((.hold_handoff_wait_issues // []) + [$n]) | unique) | .hold_handoff_waiting=true else . end)' "$UNITS" | write_state "$UNITS"
        continue
      fi
      matches="$(jqf 'length' <<<"$lookup")"
      if (( matches > 1 )) || jqf -e 'any(.[]; .ambiguousIssues == true)' <<<"$lookup" >/dev/null; then
        ids="$(jqf -c '[.[].number] | sort' <<<"$lookup")"
        HANDOFF_WAIT_PRS="$(jqf -c --argjson add "$ids" '. + $add | unique' <<<"${HANDOFF_WAIT_PRS:-[]}")"
        ids_state="$(jqf -r 'map(tostring) | join("-")' <<<"$ids")"
        jqf --argjson n "$n" --argjson prs "$ids" '.units |= map(if .issue == $n or ((.pr // null) as $pr | $prs | index($pr)) != null then .hold_handoff_wait_issues = (((.hold_handoff_wait_issues // []) + [$n]) | unique) | .hold_handoff_waiting=true else . end)' "$UNITS" | write_state "$UNITS"
        (source "$SCHEDULER_AGENT_LIB"; supervisor_inbox_append_once "handoff-pr-ambiguous:$n:$ids" "handoff-pr-ambiguous issue=#$n status=prs-$ids_state prs=$ids") \
          || say "handoff issue #$n: could not notify supervisor about ambiguous PRs $ids"
        continue
      elif (( matches == 1 )); then
        handoff_pr="$(jqf -r '.[0].number' <<<"$lookup")"
        handoff_branch="$(jqf -r '.[0].headRefName' <<<"$lookup")"
      fi
    fi
    handoff="$(jqf -c --arg n "$n" '(.scheduler_handoff // {}) | select((.start_ref // "") | test("^rescued/.*(issue-|hand-)" + $n + "([^0-9]|$)")) | select((.start_sha // "") | test("^[0-9a-f]{40}$"))' "$state_file" 2>/dev/null)"
    [[ -n "$handoff" ]] || handoff='{}'
    existing_id="$(jqf -r --argjson n "$n" --arg pr "$handoff_pr" '[.units[] | select(.issue == $n or ($pr != "" and ((.pr // "") | tostring) == $pr))] | sort_by([if ($pr != "" and ((.pr // "") | tostring) == $pr) then 0 else 1 end, if (.stage | IN("parked","supervisor-review","blocked-external","done","closed","landed","merged","wontfix","duplicate")) then 1 else 0 end]) | .[0].id // empty' "$UNITS")"
    if [[ -n "$existing_id" ]]; then
      (( existing_only )) || continue
      [[ -n "$episode" ]] || continue
      ids="$(jqf -c --argjson n "$n" --arg pr "$handoff_pr" '[.units[] | select(.issue == $n or ($pr != "" and ((.pr // "") | tostring) == $pr)) | .id]' "$UNITS")"
      if jqf -e --argjson n "$n" --arg pr "$handoff_pr" --arg episode "$episode" 'all(.units[] | select(.issue == $n or ($pr != "" and ((.pr // "") | tostring) == $pr)); .hold_handoff_episode == $episode) and ($pr == "" or any(.units[]; ((.pr // "") | tostring) == $pr))' "$UNITS" >/dev/null; then
        jqf --argjson ids "$ids" --argjson n "$n" '.units |= map(if (.id as $id | $ids | index($id)) != null then .hold_handoff_wait_issues = ((.hold_handoff_wait_issues // []) | map(select(. != $n))) | if (.hold_handoff_wait_issues | length) == 0 and .hold_handoff_lookup_pending != true then del(.hold_handoff_wait_issues, .hold_handoff_waiting) else . end else . end)' "$UNITS" | write_state "$UNITS"
        continue
      fi
      HANDOFF_WAIT_PRS="$(jqf -c --argjson add "$(jqf -c '[.[].number]' <<<"$lookup")" '. + $add | unique' <<<"${HANDOFF_WAIT_PRS:-[]}")"
      lane="$(unit_field "$existing_id" '.lane // empty')"
      # Block the old approval while any matching unit still has a live owner.
      jqf --argjson ids "$ids" --argjson n "$n" '.units |= map(if (.id as $id | $ids | index($id)) != null then .hold_handoff_wait_issues = (((.hold_handoff_wait_issues // []) + [$n]) | unique) | .hold_handoff_waiting=true else . end)' "$UNITS" | write_state "$UNITS"
      jqf -e --argjson ids "$ids" 'any(.workers[]; (.unit as $id | $ids | index($id)) != null and .harvested != true)' "$WORKERS" >/dev/null && continue
      # A worker which has already started may have read the old issue; do not
      # consume the new episode until it exits and the continuation can run.
      jqf -e --argjson ids "$ids" 'any(.units[]; (.id as $id | $ids | index($id)) != null and (.stage == "landing" or .self_check_pid != null or .advisor_pid != null or .precheck_pid != null or (.stage == "blocked-external" and .blocked_on != null)))' "$UNITS" >/dev/null && continue
      # Any related unit may contain work that the chosen unit cannot deliver.
      unsafe_clones=0
      episode_hash="$(printf '%s' "$episode" | sha256sum)"; episode_hash="${episode_hash%% *}"
      while IFS= read -r related_id; do
        prior_worktree="$WT_ROOT/wt-$related_id"
        if prior_reason="$(worktree_cleanup_block_reason "$prior_worktree")"; then
          unsafe_clones=1
          related_hash="$(printf '%s' "$related_id" | sha256sum)"; related_hash="${related_hash%% *}"
          (source "$SCHEDULER_AGENT_LIB"; supervisor_inbox_append_once "handoff-preserved-clone:$n:$episode:$related_id" \
            "handoff-preserved-clone issue=#$n status=episode-$episode_hash-unit-$related_hash unit=$related_id worktree=$prior_worktree reason=$prior_reason") \
            || say "handoff issue #$n: could not notify supervisor about the preserved clone"
        fi
      done < <(jqf -r '.[]' <<<"$ids")
      (( unsafe_clones == 0 )) || continue
      prior_pr="$(unit_field "$existing_id" '.pr // empty')"
      existing_pr="$prior_pr"; pr_changed=false
      if [[ "$handoff_pr" =~ ^[0-9]+$ ]]; then existing_pr="$handoff_pr"; fi
      pr_state=""
      if [[ "$existing_pr" =~ ^[0-9]+$ ]]; then
        pr_state="$(pr_view "$existing_pr" state)" || continue
      fi
      if [[ "$pr_state" == OPEN ]]; then
        lane="$(classify_lane "$existing_pr")" || { say "hold handoff issue #$n: cannot classify PR#$existing_pr; retry next tick"; continue; }
        lane_policy="$(lane_policy_blob)"
        [[ "$existing_pr" == "$prior_pr" ]] || pr_changed=true
      else
        [[ -n "$lane" ]] || lane=pr
        pr_changed=true
      fi
    else
      if [[ -n "$episode" ]]; then
        HANDOFF_WAIT_PRS="$(jqf -c --argjson add "$(jqf -c '[.[].number]' <<<"$lookup")" '. + $add | unique' <<<"${HANDOFF_WAIT_PRS:-[]}")"
      fi
      (( existing_only )) && continue
      if [[ -n "$episode" && "$handoff_pr" =~ ^[0-9]+$ && -n "$handoff_branch" ]]; then
        pr_state="$(pr_view "$handoff_pr" state)" || continue
        if [[ "$pr_state" == OPEN ]]; then
          lane="$(classify_lane "$handoff_pr")" || { say "hold handoff issue #$n: cannot classify PR#$handoff_pr; retry next tick"; continue; }
          lane_policy="$(lane_policy_blob)"
        else
          handoff_pr=""
        fi
      else
        handoff_pr=""
      fi
      [[ -n "$handoff_pr" ]] || ! grep -qE "(#|issue-)${n}([^0-9]|\$)" <<<"$busy" || continue
    fi
    if (( ! existing_only )) && [[ -z "$episode" ]]; then
      [[ -n "$issue_json" ]] || issue_json="$(gh issue view "$n" --json number,title,body,state,labels 2>/dev/null)" || continue
      if parent_reason="$(scheduler_issue_intake_parent_reason "$n" "$issue_json")"; then
        if scheduler_issue_transition "$n" needs-triage "intake-parent:$parent_reason" . 0 "$issue_json"; then
          say "intake issue #$n -> needs-triage (parent: $parent_reason)"
        else
          parent_transition_status=$?
          # roadmap_ensure_issue_parent returns 3 only for a confirmed roadmap container.
          if (( parent_transition_status == 3 )); then
            if scheduler_issue_transition "$n" tracker "intake-parent:roadmap-container:$parent_reason" '.tracker_parent = true' 0 "$issue_json"; then
              say "intake issue #$n -> tracker (roadmap container parent: $parent_reason)"
            else
              say "intake issue #$n held: roadmap container parent tracker update failed"
            fi
          else
            say "intake issue #$n held: parent detected but needs-triage label update failed"
          fi
        fi
        continue
      else
        parent_status=$?
        if (( parent_status != 1 )); then
          say "intake issue #$n deferred: could not verify parent status"
          continue
        fi
      fi
    fi
    if (( ! existing_only )) && [[ -z "$episode" && -z "${existing_id:-}" && "$lane" == direct-main ]]; then
      acceptance="$(jqf -r '.body // ""' <<<"$issue_json" | acceptance_block_from_body || true)"
      # M5（#4501）：pipeline-system 票的验收块必须绑定 live-event 到登记机制，否则退回补写。
      if ! acceptance_has_live_event "${acceptance:-}" || ! acceptance_live_event_registered "${acceptance:-}"; then
        if scheduler_issue_transition "$n" needs-info "m5-live-event-missing" . 0 "$issue_json"; then
          gh issue comment "$n" --body "M5 生效即验收（#4495/#4501）：pipeline-system 票的验收块（\`\`\`json 围栏内的 acceptance 数组）必须包含一项 id=live-event，并通过 event 字段或登记表 acceptance_item_ids 绑定到 engine/state/mechanism-registry.json 中的机制。补写后重新加 ready-for-agent 标签。" >/dev/null 2>&1
          say "intake issue #$n -> needs-info (M5 live-event missing)"
        else
          say "intake issue #$n: M5 live-event relabel failed; retry next tick"
        fi
        continue
      fi
    fi
    if (( existing_only )) || [[ -n "$episode" ]]; then
      task_record="$(issue_unit_task "$n" require-ready)" || continue
    else
      task_record="$(issue_unit_task "$n" "$issue_json")" || continue
    fi
    task="$(jqf -r .task <<<"$task_record")"
    body_blocked_by="$(jqf -c '.body_blocked_by // []' <<<"$task_record")"
    if [[ "$lane" == direct-main ]]; then branch="agent/auto-issue-$n"; else branch="agent/issue-$n"; fi
    recovery_sha="$(jqf -r '.worktree_sha // .start_sha // empty' <<<"$handoff_all")"
    if [[ "$recovery_sha" =~ $SHA_RE ]]; then
      if [[ "$lane" == pr ]]; then branch="agent/issue-$n-recovered-${recovery_sha:0:12}"
      else branch="agent/auto-issue-$n-recovered-${recovery_sha:0:12}"; fi
    fi
    if [[ -n "$existing_id" ]]; then
      jqf --arg id "$existing_id" --argjson n "$n" --arg episode "$episode" --arg pr_state "$pr_state" --arg task "$task" --argjson body_blocked_by "$body_blocked_by" \
        --arg lane "$lane" --arg lane_policy "${lane_policy:-}" --arg branch "$branch" --arg existing_pr "$existing_pr" --arg handoff_branch "$handoff_branch" --argjson pr_changed "$pr_changed" --argjson ids "$ids" --argjson handoff "$handoff" --argjson handoff_all "$handoff_all" --arg at "$STAMP" \
        '.units |= map(if (.id as $unit | $ids | index($unit)) != null then
          .hold_handoff_wait_issues = ((.hold_handoff_wait_issues // []) | map(select(. != $n)))
          | if (.hold_handoff_wait_issues | length) == 0 and .hold_handoff_lookup_pending != true then del(.hold_handoff_wait_issues, .hold_handoff_waiting) else . end
        else . end | if .id != $id then
          if (.id as $other | $ids | index($other)) != null then
            .stage="parked" | .approved_sha=null | .hold_handoff_episode=$episode
            | .note=("Superseded by handoff unit " + $id)
          else . end
        else
          .issue = $n | .body_blocked_by = $body_blocked_by | .hold_handoff_episode = $episode | .approved_sha = null | .reviewed_sha = null | .reviewed_pr_head = null | del(.blocked_on, .self_fix_pending)
          | if $pr_changed then del(.ci_adopt_head, .ci_adopt_at, .ci_sync_head, .ci_ready_sha, .ci_ready_at, .ci_held_sha, .ci_wip_wait, .gated, .lane_policy, .product_paths) else . end
          | .history = ((.history // []) + [{stage:"supervisor-requeue",result:"ownerless hold handoff; read issue comments",at:$at}])
          | if $pr_state == "OPEN" then
              .stage = "repair-pending" | .pr = ($existing_pr | tonumber) | .lane = $lane | .lane_policy = $lane_policy | del(.product_paths)
              | if $handoff_branch != "" then .branch = $handoff_branch else . end
              | .repair_hint = "Read the issue comments for the ownerless hold handoff and complete the existing PR."
            else
              .stage = "implement-pending" | .task = $task | .lane = $lane | .branch = $branch
              | del(.pr, .handoff_start_ref, .handoff_start_sha, .handoff_start_applied)
              | if $handoff.start_ref then .handoff_start_ref = $handoff.start_ref | .handoff_start_sha = $handoff.start_sha else . end
            end
          | del(.handoff_worktree, .handoff_worktree_sha, .handoff_worktree_dirty, .handoff_worktree_applied, .handoff_integration_sha, .handoff_original_pr_head, .handoff_delivery_verified_sha)
          | del(.handoff_start_ref, .handoff_start_sha, .handoff_start_applied)
          | if $handoff.start_ref then .handoff_start_ref = $handoff.start_ref | .handoff_start_sha = $handoff.start_sha else . end
          | if (($handoff_all.worktree_sha // "") | test("^[0-9a-f]{40}$")) then
              .handoff_worktree = $handoff_all.worktree | .handoff_worktree_sha = $handoff_all.worktree_sha | .handoff_worktree_dirty = $handoff_all.worktree_dirty
            else . end
          end)' "$UNITS" | write_state "$UNITS"
      say "hold handoff issue #$n resumed existing unit=$existing_id"
    else
      if [[ "$handoff_pr" =~ ^[0-9]+$ ]]; then branch="$handoff_branch"; fi
      jqf --argjson n "$n" --arg title "$title" --argjson labels "${labels:-[]}" --arg task "$task" --argjson body_blocked_by "$body_blocked_by" --arg lane "$lane" --arg lane_policy "${lane_policy:-}" --arg branch "$branch" --arg episode "$episode" --argjson handoff "$handoff" --argjson handoff_all "$handoff_all" \
        --arg pr "$handoff_pr" --arg acceptance "${acceptance:-}" \
        '.units += [{id:("issue-"+($n|tostring)), issue:$n, title:$title, labels:$labels, stage:"implement-pending", lane:$lane, branch:$branch, task:$task, body_blocked_by:$body_blocked_by, history:[],hold_handoff_episode:$episode}
          + (if $acceptance != "" then {acceptance:($acceptance | fromjson)} else {} end)
          + (if $pr != "" then {pr:($pr | tonumber),stage:"repair-pending",lane_policy:$lane_policy,repair_hint:"Read the issue comments for the ownerless hold handoff and complete the existing PR."} else {} end)
          + (if (($handoff_all.worktree_sha // "") | test("^[0-9a-f]{40}$")) then {handoff_worktree:$handoff_all.worktree,handoff_worktree_sha:$handoff_all.worktree_sha,handoff_worktree_dirty:$handoff_all.worktree_dirty} else {} end)
          + (if $handoff.start_ref then {handoff_start_ref:$handoff.start_ref,handoff_start_sha:$handoff.start_sha} else {} end)]' \
        "$UNITS" | write_state "$UNITS"
    fi
    added=$((added+1))
    say "intake issue #$n -> implement-pending ($lane)"
  done < <(if (( existing_only )); then printf '%s\n' "$handoff_rows"; else predecessor_candidates; (( only_pred )) || intake_candidates; fi)
  if (( ! existing_only && added == 0 && ! only_pred )) && [[ ! -f "$A/.idle-alert" || -n "$(find "$A/.idle-alert" -mmin +60 2>/dev/null)" ]]; then
    touch "$A/.idle-alert"
    echo "[$STAMP] IDLE-CAPACITY live=$live/$MAX pending=$pending: intake found no eligible issue (labels or skip labels too narrow?)" >> "$A/alerts/slo.md"
  fi
}
