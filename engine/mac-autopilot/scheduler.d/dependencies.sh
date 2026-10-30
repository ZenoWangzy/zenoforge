
# 依赖链（2026-10-20：#3680–#3686 是同一张日报的串行票，前置未交付时 worker 正确地拒绝动手）：
# 报告写 BLOCKED-ON #N → 单元停在 blocked-external（不占开发产能），前置单元合并/落地或 issue 关闭后自动回到 implement-pending。
# 前 12 行认宽松写法；协议标记 `BLOCKED-ON: #N` 全文都认（#3469 评审把它写在第 16 行，被当成无前置的阻塞升级）。
# Issue-body dependency dispatch contract: docs/agents/issue-pipeline.md#autopilot-issue-body-dependencies (#4485).
blocked_on_of() {
  { head -12 "$1" | grep -oiE 'BLOCKED[- ]?(ON|BY)[^0-9#]{0,12}#?[0-9]+'; grep -oE 'BLOCKED-ON:[[:space:]]*#[0-9]+' "$1"; } 2>/dev/null \
    | grep -oE '[0-9]+$' | head -1
}
park_blocked() { # unit dep
  # 生产热修回迁不等前置（代码已在线）：第一次退回按热修规则重评，第二次交 supervisor（pr-3596 被 #3145 挡住）。
  if [[ "$(unit_field "$1" '.hotpatch // false')" == true ]]; then
    if jqf -e --arg id "$1" 'any(.units[]; .id == $id and any(.history[]?; .stage == "hotpatch-not-blocked"))' "$UNITS" >/dev/null; then
      to_supervisor "$1" "hot-patch forward-port blocked on #$2 twice"
    else
      set_unit "$1" "$(hist hotpatch-not-blocked "#$2") | .reviewed_sha=null | .reviewed_pr_head=null | .stage=\"review-pending\""
      say "unit $1 is a production hot-patch forward-port; predecessor #$2 does not block it -> fresh review"
    fi
    return 0
  fi
  set_unit "$1" "$(hist blocked-on "#$2") | .blocked_on=$2 | .note=$(js "waiting for predecessor #$2") | .stage=\"blocked-external\""
  say "unit $1 blocked on predecessor #$2"
}
# 正文 `## Blocked by` 只认小节内的 issue 引用；小节外的 #N 不算前置（#4485 正文自己就引用了 #4384/#4486）。
blocked_by_ids_from_body() { # stdin: issue body → references within its Blocked by section
  awk 'tolower($0) ~ /^#+[[:space:]]*blocked[[:space:]]+by([[:space:]:]|$)/{s=1;next} s && /^#/{s=0} s' \
    | grep -oE '#[0-9]+' | tr -d '#' | awk '!p[$0]++' || true
}
issue_body_blocked_by() { # stdin: saved task text → refs from its issue-body section
  local task body
  task="$(cat)"
  body="$(awk '/^--- issue 正文（任务数据）---$/{b=1;next} /^--- 正文结束 ---$/{b=0} b' <<<"$task")"
  blocked_by_ids_from_body <<<"$body"
}
unit_body_blockers() { # unit-json → stored full-body IDs, or fallback IDs from older task text
  if jqf -e '(.body_blocked_by | type)=="array"' <<<"$1" >/dev/null; then
    jqf -r '.body_blocked_by[] | select(type=="number")' <<<"$1"
  else
    issue_body_blocked_by <<<"$(jqf -r '.task // ""' <<<"$1")"
  fi
}
dep_delivered_in_ledger() { # release_dependency_blocks 从台账建一次快照，避免每个 blocker 重读全文件
  [[ "${DEP_DELIVERED_CACHE[$1]:-}" == 1 ]]
}
# 正文依赖状态由 release_dependency_blocks 按 DEP_CHECK_SECONDS 批量缓存；派发门禁只读缓存，不逐单元调用 GitHub。
dep_cache_info() { # predecessor issue → cached {state,labels} or {}
  jqf -c --arg d "$1" '.states[$d] // {}' "$A/dep-check.cache.json" 2>/dev/null || echo '{}'
}
unit_body_declares_dependency() { # unit predecessor-issue → true when the issue body explicitly names this prerequisite
  unit_body_blockers "$1" | grep -Fxq "$2"
}
blocking_body_dependency() { # unit-json → first predecessor not yet delivered/cleared by the local cache
  local dep info state labels
  while read -r dep; do
    [[ "$dep" =~ ^[0-9]+$ ]] || continue
    dep_delivered_in_ledger "$dep" && continue
    info="$(dep_cache_info "$dep")"
    state="$(jqf -r '.state // empty' <<<"$info")"
    [[ "$state" == CLOSED || "$state" == MERGED ]] && continue
    labels="$(jqf -r '.labels // ""' <<<"$info")"
    [[ "$state" == OPEN && ",$labels," =~ ,roadmap(-epic|-theme)?, ]] && continue
    printf '%s' "$dep"; return 0
  done < <(unit_body_blockers "$1")
  return 1
}
park_if_body_blocked() { # unit-json → 0 当按正文前置停住（不派发）
  local id dep
  id="$(jqf -r .id <<<"$1")"
  dep="$(blocking_body_dependency "$1")" || return 1
  park_blocked "$id" "$dep"
}
# 前置状态每 DEP_CHECK_SECONDS（默认 600）向 GitHub 刷新一次，同一前置每拍只查一次：逐单元 gh issue view
# 让这一步占了一拍 58 秒（2026-10-20，42 个 blocked 单元）。台账内可判定的（已交付、互等）仍每拍处理。
# 一拍 500–660 秒，600 秒的刷新几乎每拍都到期；逐个前置 gh issue view（39 个）一拍 60 秒（10-21 09:10）。
# 改成一次 GraphQL 批量查；issueOrPullRequest 让前置是 PR 号时也能判（gh issue view 对 PR 号失败，永远放不开）。
dep_states() { # issue/PR 号… → 每行 "号<TAB>STATE<TAB>标签,…"；一次 GraphQL 调用
  (( $# > 0 )) || return 0
  local q="" d
  for d in "$@"; do
    q+=" i$d: issueOrPullRequest(number: $d) { ... on Issue { state labels(first: 30) { nodes { name } } } ... on PullRequest { state labels(first: 30) { nodes { name } } } }"
    q+=" p$d: pullRequests(headRefName: \"agent/issue-$d\", states: MERGED, first: 1) { totalCount }"
  done
  # issue 要到发布后才关（close-after-release）：只看 issue 状态，前置合并了后继还要多等一整个发布周期
  # （10-22 #3122/#3431 已合并、后继仍停着）。流水线的实现分支是 agent/issue-N：它的 PR 合并即交付。
  gh api graphql -F owner='{owner}' -F name='{repo}' -f query="query(\$owner: String!, \$name: String!) { repository(owner: \$owner, name: \$name) {$q } }" \
    --jq '.data.repository | . as $r | to_entries[] | select((.key | startswith("i")) and .value != null) | .key[1:] as $d
      | "\($d)\t\(if ($r["p" + $d].totalCount // 0) > 0 then "MERGED" else .value.state end)\t\([.value.labels.nodes[].name] | join(","))\t\(.value.state)"' 2>/dev/null
}
stack_pilot_label() { jqf -r 'if .stacking.enabled == false then "" else (.stacking.pilot_label // "stack-pilot") end' <<<"$CFG"; }
unit_has_stack_pilot() { # unit-json
  local label; label="$(stack_pilot_label)"
  [[ -n "$label" ]] && jqf -e --arg label "$label" 'any(.labels[]?; if type=="string" then .==$label else .name==$label end)' <<<"$1" >/dev/null 2>&1
}
stack_approved_dependency() { # dependent unit-id issue-number unit-json; 0 when an approved local predecessor releases this pilot unit
  local child="$1" dep="$2" unit="${3:-}" predecessor pr_number approved head state snapshot prs
  [[ -n "$unit" ]] || unit="$(jqf -c --arg id "$child" '.units[] | select(.id==$id)' "$UNITS")"
  unit_has_stack_pilot "$unit" || return 1
  jqf -e '.lane=="pr"' <<<"$unit" >/dev/null || return 1
  jqf -e '(.stacked_on // null)==null' <<<"$unit" >/dev/null || return 1
  predecessor="$(jqf -c --argjson dep "$dep" '.units[] | select(.issue==$dep and .stage=="ready-to-merge"
    and .lane=="pr" and (.pr | type)=="number" and (.branch | type)=="string" and (.branch|length)>0
    and (.approved_sha | type)=="string" and (.approved_sha|test("^[0-9a-f]{40}$"))
    and .reviewed_pr_head==.approved_sha)' "$UNITS")"
  [[ -n "$predecessor" ]] || return 1
  pr_number="$(jqf -r .pr <<<"$predecessor")"; approved="$(jqf -r .approved_sha <<<"$predecessor")"
  prs="$(tick_prs 2>/dev/null)" || prs='[]'
  snapshot="$(jqf -c --argjson pr_number "$pr_number" '[.[] | select(.number==$pr_number) | {headRefOid}] | .[0] // empty' <<<"$prs")"
  if [[ -n "$snapshot" ]]; then
    state=OPEN; head="$(jqf -r '.headRefOid // empty' <<<"$snapshot")"
  else
    snapshot="$(gh pr view "$pr_number" --json state,headRefOid 2>/dev/null)" || return 1
    state="$(jqf -r '.state // empty' <<<"$snapshot")"; head="$(jqf -r '.headRefOid // empty' <<<"$snapshot")"
  fi
  [[ "$state" == OPEN && "$head" == "$approved" ]] || return 1
  stack_initial_branch "$child" "$(jqf -r .branch <<<"$predecessor")" "$approved" || {
    say "unit $child remains waiting: could not base its branch on $(jqf -r .id <<<"$predecessor")@$approved"
    return 1
  }
  set_unit "$child" "$(hist stacked_on "$(jqf -r .id <<<"$predecessor")@$approved") | .stacked_on=$(js "$(jqf -r .id <<<"$predecessor")@$approved") | .stacked_on_unit=$(js "$(jqf -r .id <<<"$predecessor")") | .stacked_on_sha=$(js "$approved") | .stacked_on_branch=$(js "$(jqf -r .branch <<<"$predecessor")") | .stage=\"implement-pending\""
  say "unit $child stacked on $(jqf -r .id <<<"$predecessor")@$approved"
  return 0
}
# blocker 的台账单元已 closed（recut 或 PR 关闭）而 issue 仍开：永远等不到 CLOSED/MERGED，也无人升级（2026-10-30 17 个单元）。
# 有 recut_children → 改等子票（排除自己）；无子票且 issue 为 tracker/concluded/released（有意关闭的 spec/epic 父票）→ 视为已交付；
# 其余 → 升级 supervisor 一次。Airflow upstream_failed / Temporal timeout：每个等待都要有失败传播或超时。返回 0 = 已处理。
dead_blocker_resolve() { # unit-id blocker-issue dependent-issue
  local id="$1" dep="$2" issue="$3" st children c next=""
  jqf -e --argjson d "$dep" '[.units[] | select(.issue == $d)] | length > 0 and all(.[]; .stage == "closed")' "$UNITS" >/dev/null || return 1
  st="$(scheduler_issue_state "$dep")" || return 1 # 子 shell 才载入 lib.sh；读不到就下一拍再试，不能当成无子票而升级
  children="$(jqf -r --argjson i "${issue:-0}" '(.recut_children // [])[] | select(. != $i)' <<<"$st")"
  if [[ -n "$children" ]]; then
    for c in $children; do dep_delivered_in_ledger "$c" || { next="$c"; break; }; done
    if [[ -z "$next" ]]; then unblock_unit "$id" "#$dep recut; children delivered"; return 0; fi
    set_unit "$id" "$(hist blocker-repointed "#$dep closed in ledger after recut; now waits on child #$next") | .blocked_on=$next"
    say "unit $id blocker #$dep dead (recut): repointed to child #$next"; return 0
  fi
  if jqf -e '.state | IN("tracker","concluded","released")' <<<"$st" >/dev/null; then
    unblock_unit "$id" "#$dep closed on purpose (tracker/spec parent)"; return 0
  fi
  to_supervisor "$id" "blocker #$dep is closed in the ledger but its issue is open with no recut children: decide"
}
release_dependency_blocks() {
  local id dep issue info state labels gh_due=1 last decision dep_results dep_states_json dep_cache_file dep_cache u
  local blocker_issue pair_key
  local -a deps=() unique_deps=()
  local -A DEP_BLOCKED_PAIR_COUNTS=()
  DEP_DELIVERED_CACHE=()
  while IFS= read -r dep; do
    [[ "$dep" =~ ^[0-9]+$ ]] && DEP_DELIVERED_CACHE["$dep"]=1
  done < <(jqf -r '.units[] | select(.stage | IN("merged","landed","awaiting-live-event"))
    | ((.issue | select(type == "number")),
       (if ((.branch // "") | test("^agent/issue-[0-9]+$")) then (.branch | sub("^agent/issue-"; "") | tonumber) else empty end))' "$UNITS")
  while IFS=$'\t' read -r blocker_issue dep; do
    [[ "$blocker_issue" =~ ^[0-9]+$ && "$dep" =~ ^[0-9]+$ ]] || continue
    pair_key="$blocker_issue:$dep"
    DEP_BLOCKED_PAIR_COUNTS["$pair_key"]=$((${DEP_BLOCKED_PAIR_COUNTS[$pair_key]:-0} + 1))
  done < <(jqf -r '.units[] | select(.stage=="blocked-external" and .blocked_on != null and (.issue | type)=="number") | [.issue,.blocked_on] | @tsv' "$UNITS")
  dep_cache_file="$A/dep-check.cache.json"
  last="$(cat "$A/dep-check.epoch" 2>/dev/null)"
  if [[ "$last" =~ ^[0-9]+$ ]] && (( NOW_EPOCH - last < ${DEP_CHECK_SECONDS:-600} )); then gh_due=0; else echo "$NOW_EPOCH" > "$A/dep-check.epoch"; fi
  if (( gh_due )); then
    while IFS= read -r dep; do
      [[ "$dep" =~ ^[0-9]+$ ]] || continue
      dep_delivered_in_ledger "$dep" || deps+=("$dep")
    done < <(jqf -r '[.units[] | select(.stage=="blocked-external" and .blocked_on != null) | .blocked_on | numbers] | unique | .[]' "$UNITS")
    while IFS= read -r dep; do # 自己的 issue 已关的闲置单元要能被收掉：并入同一次批量查询
      [[ "$dep" =~ ^[0-9]+$ ]] && deps+=("$dep")
    done < <(jqf -r '.units[] | select((.stage=="blocked-external" or .stage=="parked") and .pr == null and (.issue | type)=="number") | .issue' "$UNITS")
    while IFS= read -r u; do
      while IFS= read -r dep; do
        [[ "$dep" =~ ^[0-9]+$ ]] || continue
        dep_delivered_in_ledger "$dep" || deps+=("$dep")
      done < <(unit_body_blockers "$u")
    done < <(jqf -c '.units[] | select(.stage=="implement-pending" or (.stage=="repair-pending" and .hold_handoff_episode != null))' "$UNITS")
    if (( ${#deps[@]} > 0 )); then
      while IFS= read -r dep; do [[ -n "$dep" ]] && unique_deps+=("$dep"); done \
        < <(printf '%s\n' "${deps[@]}" | sort -n -u)
      dep_results="$(dep_states "${unique_deps[@]}" 2>/dev/null || true)"
      dep_states_json="$(printf '%s\n' "$dep_results" | jqf -Rn '
        [inputs | split("\t") | select(length >= 2 and .[0] != "" and .[1] != "")]
        | map({key:.[0],value:{state:.[1],labels:(.[2] // ""),issue_state:(.[3] // "")}}) | from_entries')"
    else
      dep_states_json='{}'
    fi
    jqf -cn --argjson epoch "$NOW_EPOCH" --argjson states "$dep_states_json" \
      '{epoch:$epoch,states:$states}' > "$dep_cache_file.tmp" && mv "$dep_cache_file.tmp" "$dep_cache_file"
  fi
  dep_cache="$(jqf -c 'if (.states|type)=="object" then .states else {} end' "$dep_cache_file" 2>/dev/null || echo '{}')"
  while IFS=$'\t' read -r id issue; do # 自己的 issue 已关或已交付：单元作废（2026-10-30 issue-3681 等 5 个）
    set_unit "$id" "$(hist issue-closed "issue #$issue already closed on GitHub") | .stage=\"closed\" | del(.blocked_on) | .note=null"
    say "unit=$id issue #$issue already closed on GitHub; retired"
  done < <(jqf -r --argjson c "$dep_cache" '.units[] | select((.stage=="blocked-external" or .stage=="parked") and .pr == null and (.issue | type)=="number"
    and ((($c[(.issue | tostring)].state) // "") | IN("CLOSED","MERGED"))) | [.id, .issue] | @tsv' "$UNITS")
  while IFS= read -r u; do
    id="$(jqf -r '.id' <<<"$u")"; dep="$(jqf -r '.blocked_on' <<<"$u")"; issue="$(jqf -r '.issue // empty' <<<"$u")"
    [[ "$dep" =~ ^[0-9]+$ ]] || continue
    if jqf -e '.size_recut_pending==true' <<<"$u" >/dev/null; then continue; fi
    if jqf -e '.stacked_on != null and .stacked_on_released != true' <<<"$u" >/dev/null \
        && ! unit_body_declares_dependency "$u" "$dep"; then continue; fi
    if dep_delivered_in_ledger "$dep"; then
      dep_blocker_forget "$issue" "$dep"
      unblock_unit "$id" "#$dep delivered"; continue
    fi
    # 两个单元互相等对方（2026-10-20 #2743↔#3330）：放开这一个，另一个继续等它交付。
    pair_key="$dep:$issue"
    if [[ "$issue" =~ ^[0-9]+$ && "${DEP_BLOCKED_PAIR_COUNTS[$pair_key]:-0}" =~ ^[1-9][0-9]*$ ]]; then
      dep_blocker_forget "$issue" "$dep"
      unblock_unit "$id" "#$dep waits on #$issue: dependency cycle broken here"; continue
    fi
    info="$(jqf -c --arg d "$dep" '.[$d] // empty' <<<"$dep_cache")"; [[ -n "$info" ]] || continue
    state="$(jqf -r '.state // empty' <<<"$info")"; labels="$(jqf -r '.labels // ""' <<<"$info")"
    if (( gh_due )) && [[ "$state" == OPEN ]] && ! unit_body_declares_dependency "$u" "$dep" \
        && stack_approved_dependency "$id" "$dep" "$u"; then continue; fi
    if [[ "$state" == CLOSED || "$state" == MERGED ]]; then
      dep_blocker_forget "$issue" "$dep"
      unblock_unit "$id" "#$dep delivered"; continue
    fi
    if [[ "$state" == OPEN ]] && dead_blocker_resolve "$id" "$dep" "$issue"; then
      dep_blocker_forget "$issue" "$dep"; continue
    fi
    # 路线图 epic/主题是伞形 issue，永远不会"交付"；停在它上面就是永远停（2026-10-20 六个单元）。放开一次，
    # 同一个 epic 第二次停住就交给 supervisor。
    if [[ ",$labels," =~ ,roadmap(-epic|-theme)?, ]]; then
      if jqf -e --arg id "$id" --arg r "#$dep" 'any(.units[]; .id == $id and any(.history[]?; .stage == "epic-not-predecessor" and .result == $r))' "$UNITS" >/dev/null; then
        dep_blocker_forget "$issue" "$dep"
        decision="$(decision_entry 'Hand off repeated roadmap block to supervisor' 'the same roadmap epic blocked this unit twice' "history contains repeated epic-not-predecessor events for #$dep" '["Keep waiting for the roadmap epic to close"]' scheduler)"
        set_unit "$id" "$(hist supervisor-escalated "parked twice on roadmap epic #$dep" "$decision") | del(.blocked_on) | .note=$(js "parked twice on roadmap epic #$dep: decide scope") | .stage=\"supervisor-review\""
        say "unit $id escalated: parked twice on roadmap epic #$dep"
      else
        dep_blocker_forget "$issue" "$dep"
        set_unit "$id" "$(hist epic-not-predecessor "#$dep") | del(.blocked_on) | .note=$(js "#$dep is a roadmap epic, not a predecessor: implement this slice") | .stage=(if .blocked_resume_stage == \"repair-pending\" then \"repair-pending\" elif .pr != null then \"review-pending\" else \"implement-pending\" end) | del(.blocked_resume_stage)"
        say "unit $id released: #$dep is a roadmap epic, not a predecessor"
      fi
    fi
  done < <(jqf -c '.units[] | select(.stage=="blocked-external" and .blocked_on != null)' "$UNITS")
  # 停在 blocked-external 却没有前置号的单元没有任何机制会放开它（issue-2536）：交 supervisor。
  for id in $(jqf -r '.units[] | select(.stage=="blocked-external" and .blocked_on == null and .size_recut_pending != true) | .id' "$UNITS"); do
    to_supervisor "$id" "blocked-external without a predecessor: nothing can release it"
  done
  if (( gh_due )); then reconcile_stacked_units; fi
}
dep_blocker_forget() { # dynamic local map: keep mutual-cycle checks current as units leave blocked-external
  local key="$1:$2" count
  count="${DEP_BLOCKED_PAIR_COUNTS[$key]:-0}"
  if (( count > 1 )); then
    DEP_BLOCKED_PAIR_COUNTS["$key"]=$((count - 1))
  else
    unset "DEP_BLOCKED_PAIR_COUNTS[$key]"
  fi
}
unblock_unit() { # unit reason
  set_unit "$1" "$(hist unblocked "$2") | del(.blocked_on) | .note=null | .stage=(if .blocked_resume_stage == \"repair-pending\" then \"repair-pending\" elif .pr != null then \"review-pending\" else \"implement-pending\" end) | del(.blocked_resume_stage)"
  say "unit $1 unblocked: $2"
}

stack_initial_branch() { # unit base-branch base-sha; rebase existing implementation work onto a newly approved predecessor
  local id="$1" branch base_sha="$3" remote_head wt base_ref child_head fork_sha child_count pr
  branch="$(unit_field "$id" .branch)"
  [[ -n "$branch" && "$base_sha" =~ $SHA_RE ]] || return 1
  remote_head="$(git -C "$ROOT" ls-remote origin "refs/heads/$branch" 2>/dev/null | awk 'NR==1 {print $1}')"
  if [[ "$remote_head" =~ $SHA_RE ]]; then
    wt="$(ensure_clone "$id" "$branch" 1 "$remote_head" "$2" "$base_sha")" || return 1
  else
    wt="$(ensure_clone "$id" "$branch" 0 "" "$2" "$base_sha")" || return 1
  fi
  base_ref="refs/remotes/origin/$2"
  child_head="$(git -C "$wt" rev-parse -q --verify "refs/heads/$branch^{commit}" 2>/dev/null)" || return 1
  if ! git -C "$wt" merge-base --is-ancestor "$base_sha" "$child_head" 2>/dev/null; then
    fork_sha="$(git -C "$wt" merge-base "$child_head" "$base_ref" 2>/dev/null)" || return 1
    child_count="$(git -C "$wt" rev-list --count "$fork_sha..$branch" 2>/dev/null)" || return 1
    if [[ "$child_count" == 0 ]]; then
      git -C "$wt" checkout -q "$branch" && git -C "$wt" reset --hard "$base_ref" >/dev/null || return 1
    else
      git -C "$wt" rebase --onto "$base_ref" "$fork_sha" "$branch" >/dev/null 2>&1 || {
        git -C "$wt" rebase --abort >/dev/null 2>&1 || :
        return 1
      }
    fi
  fi
  child_head="$(git -C "$wt" rev-parse "refs/heads/$branch^{commit}")" || return 1
  if [[ "$remote_head" =~ $SHA_RE ]]; then
    if [[ "$child_head" != "$remote_head" ]]; then
      git -C "$wt" push -q --force-with-lease="refs/heads/$branch:$remote_head" origin "$branch" || return 1
    fi
  elif [[ "$child_head" != "$base_sha" ]]; then
    git -C "$wt" push -q -u origin "$branch" || return 1
  fi
  pr="$(unit_field "$id" '.pr // empty')"
  if [[ "$pr" =~ ^[0-9]+$ ]]; then gh pr edit "$pr" --base "$2" >/dev/null 2>&1 || return 1; fi
}

restack_branch() { # unit base-branch base-sha; rebase only this unit's commits and publish against the observed child head
  local id="$1" branch="$2" base_sha="$3" old_base old_base_branch pr remote_head wt base_ref child_head child_count
  branch="$(unit_field "$id" .branch)"; old_base="$(unit_field "$id" '.stacked_on_sha // empty')"
  old_base_branch="$(unit_field "$id" '.stacked_on_branch // empty')"; pr="$(unit_field "$id" '.pr // empty')"
  [[ "$branch" ]] && [[ "$base_sha" =~ $SHA_RE ]] && [[ "$old_base" =~ $SHA_RE ]] || return 1
  remote_head="$(git -C "$ROOT" ls-remote origin "refs/heads/$branch" 2>/dev/null | awk 'NR==1 {print $1}')"
  if [[ "$remote_head" =~ $SHA_RE ]]; then
    wt="$(ensure_clone "$id" "$branch" 1 "$remote_head" "$2" "$base_sha")" || return 1
  else
    wt="$(ensure_clone "$id" "$branch" 0 "" "$2" "$base_sha")" || return 1
  fi
  base_ref="refs/remotes/origin/$2"
  child_head="$(git -C "$wt" rev-parse -q --verify "refs/heads/$branch^{commit}" 2>/dev/null)" || return 1
  if git -C "$wt" merge-base --is-ancestor "$old_base" "$child_head" 2>/dev/null; then
    child_count="$(git -C "$wt" rev-list --count "$old_base..$branch" 2>/dev/null)" || return 1
    if [[ "$child_count" == 0 ]]; then
      git -C "$wt" checkout -q "$branch" && git -C "$wt" reset --hard "$base_ref" >/dev/null || return 1
    else
      git -C "$wt" rebase --onto "$base_ref" "$old_base" "$branch" >/dev/null 2>&1 || {
        git -C "$wt" rebase --abort >/dev/null 2>&1 || :
        return 1
      }
    fi
  elif ! git -C "$wt" merge-base --is-ancestor "$base_ref" "$child_head" 2>/dev/null; then
    return 1
  fi
  if [[ "$remote_head" =~ $SHA_RE ]]; then
    git -C "$wt" push -q --force-with-lease="refs/heads/$branch:$remote_head" origin "$branch" || return 1
  else
    git -C "$wt" push -q -u origin "$branch" || return 1
  fi
  if [[ -n "$pr" && "$old_base_branch" != "$2" ]]; then gh pr edit "$pr" --base "$2" >/dev/null 2>&1 || return 1; fi
}

reconcile_stacked_units() {
  local child id dep parent parent_id parent_pr parent_branch parent_stage parent_approved parent_reviewed parent_state parent_head parent_snapshot dep_info prs
  local child_stage old_stack issue_state
  prs="$(tick_prs 2>/dev/null)" || prs='[]'
  while IFS= read -r child; do
    id="$(jqf -r .id <<<"$child")"; dep="$(jqf -r '.blocked_on // empty' <<<"$child")"
    parent_id="$(jqf -r '.stacked_on_unit // empty' <<<"$child")"
    parent="$(jqf -c --arg id "$parent_id" '.units[] | select(.id==$id)' "$UNITS")"
    [[ -n "$dep" && -n "$parent" ]] || continue
    parent_pr="$(jqf -r '.pr // empty' <<<"$parent")"; parent_branch="$(jqf -r '.branch // empty' <<<"$parent")"
    parent_stage="$(jqf -r .stage <<<"$parent")"; parent_approved="$(jqf -r '.approved_sha // empty' <<<"$parent")"
    parent_reviewed="$(jqf -r '.reviewed_pr_head // empty' <<<"$parent")"
    child_stage="$(jqf -r .stage <<<"$child")"; old_stack="$(jqf -r '.stacked_on_sha // empty' <<<"$child")"
    [[ "$(jqf -r '.size_recut_pending // false' <<<"$child")" == true ]] && continue
    # A worker owns the clone while running. A size escalation owns the unit
    # afterward: restacking must not silently send it back to review (#4482).
    case "$child_stage" in implement|review|repair|rereview|supervisor-review|parked) continue ;; esac
    [[ "$parent_pr" =~ ^[0-9]+$ && -n "$parent_branch" ]] || continue
    parent_snapshot="$(jqf -c --argjson pr "$parent_pr" '[.[] | select(.number==$pr) | {headRefOid}] | .[0] // empty' <<<"$prs")"
    if [[ -n "$parent_snapshot" ]]; then
      parent_state=OPEN
      parent_head="$(jqf -r '.headRefOid // empty' <<<"$parent_snapshot")"
    else
      parent_state="$(pr_view "$parent_pr" state)"
      parent_head=""
    fi
    case "$parent_state" in
      CLOSED)
        set_unit "$id" "$(hist stack-waiting predecessor-PR-$parent_pr-closed) | .stage=\"blocked-external\""
        say "unit $id waits: stacked predecessor PR #$parent_pr closed"
        continue ;;
      MERGED)
        dep_info="$(dep_cache_info "$dep")"
        issue_state="$(jqf -r '.issue_state // empty' <<<"$dep_info")"
        [[ -n "$issue_state" ]] || issue_state="$(gh issue view "$dep" --json state --jq .state 2>/dev/null)"
        [[ "$issue_state" == CLOSED && "$MAIN_HEAD" =~ $SHA_RE ]] || {
          [[ "$child_stage" == blocked-external ]] || set_unit "$id" "$(hist stack-waiting predecessor-PR-$parent_pr-merged-waiting-for-release) | .stage=\"blocked-external\""
          continue
        }
        if ! restack_branch "$id" main "$MAIN_HEAD"; then
          say "unit $id remains stacked: could not restack on main $MAIN_HEAD"
          continue
        fi
        set_unit "$id" "$(hist stack-released main@$MAIN_HEAD-after-predecessor-release) | .stacked_on_released=true | .stacked_on_branch=\"main\" | .stacked_on_sha=$(js "$MAIN_HEAD") | del(.blocked_on) | .approved_sha=null | .reviewed_sha=null | .reviewed_pr_head=null | .stage=(if .pr != null then \"review-pending\" else \"implement-pending\" end)"
        say "unit $id restacked on main@$MAIN_HEAD after predecessor release"
        continue ;;
      OPEN) ;;
      *)
        [[ "$child_stage" == blocked-external ]] || set_unit "$id" "$(hist stack-waiting predecessor-PR-$parent_pr-state-$parent_state) | .stage=\"blocked-external\""
        continue ;;
    esac
    [[ "$parent_head" =~ $SHA_RE ]] || parent_head="$(pr_view "$parent_pr" headRefOid)"
    [[ "$parent_head" =~ $SHA_RE ]] || continue
    if [[ "$parent_head" != "$old_stack" ]]; then
      if ! restack_branch "$id" "$parent_branch" "$parent_head"; then
        say "unit $id remains stacked: could not restack on $parent_id@$parent_head"
        continue
      fi
      set_unit "$id" "$(hist stacked_on $parent_id@$parent_head) | .stacked_on=$(js "$parent_id@$parent_head") | .stacked_on_sha=$(js "$parent_head") | .stacked_on_branch=$(js "$parent_branch") | .approved_sha=null | .reviewed_sha=null | .reviewed_pr_head=null | .stage=\"blocked-external\""
      child_stage=blocked-external
      say "unit $id restacked on $parent_id@$parent_head"
    fi
    parent="$(jqf -c --arg id "$parent_id" '.units[] | select(.id==$id)' "$UNITS")"
    parent_stage="$(jqf -r .stage <<<"$parent")"; parent_approved="$(jqf -r '.approved_sha // empty' <<<"$parent")"
    parent_reviewed="$(jqf -r '.reviewed_pr_head // empty' <<<"$parent")"
    if [[ "$parent_stage" == ready-to-merge && "$parent_approved" == "$parent_head" && "$parent_reviewed" == "$parent_head" ]]; then
      if [[ "$child_stage" == blocked-external ]]; then
        set_unit "$id" "$(hist stack-resumed $parent_id@$parent_head-approved) | .stage=(if .pr != null then \"review-pending\" else \"implement-pending\" end)"
        say "unit $id resumed on approved predecessor $parent_id@$parent_head"
      fi
    elif [[ "$child_stage" != blocked-external ]]; then
      set_unit "$id" "$(hist stack-waiting predecessor-$parent_id-not-approved-at-$parent_head) | .stage=\"blocked-external\""
      say "unit $id waits: predecessor $parent_id is not approved at $parent_head"
    fi
  done < <(jqf -c '.units[] | select(.stacked_on != null and .stacked_on_released != true)' "$UNITS")
}
