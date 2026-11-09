
# 依赖链（2026-10-20：#3680–#3686 是同一张日报的串行票，前置未交付时 worker 正确地拒绝动手）：
# 报告写 BLOCKED-ON #N → 单元停在 blocked-external（不占开发产能），前置单元合并/落地或 issue 关闭后自动回到 implement-pending。
# 前 12 行认宽松写法；协议标记 `BLOCKED-ON: #N` 全文都认（#3469 评审把它写在第 16 行，被当成无前置的阻塞升级）。
# Issue-body dependency dispatch contract: docs/agents/issue-pipeline.md#autopilot-issue-body-dependencies (#4485).
blocked_on_of() {
  { head -12 "$1" | grep -oiE 'BLOCKED[- ]?(ON|BY)[^0-9#]{0,12}#?[0-9]+'; grep -oE 'BLOCKED-ON:[[:space:]]*#[0-9]+' "$1"; } 2>/dev/null \
    | grep -oE '[0-9]+$' | head -1
}
park_blocked() { # unit dep
  # supervisor 已在 reroute 中放弃的前置（dropped_deps）：worker 报告的 BLOCKED-ON 不停住单元，单元留在原环节再跑一次。
  # 调用方若刚把单元标成 blocked-external（评审路径），这里还原成可继续的环节。
  if [[ "$2" =~ ^[0-9]+$ ]] && jqf -e --arg id "$1" --argjson d "$2" 'any(.units[]; .id == $id and ((.dropped_deps // []) | index($d) != null))' "$UNITS" >/dev/null; then
    set_unit "$1" "$(hist dropped-dep-ignored "#$2") | (if .dep_wait_delivery == $2 then del(.dep_wait_delivery, .unpark_condition) else . end) | (if .stage == \"blocked-external\" then .stage = (if .pr != null then \"review-pending\" else \"implement-pending\" end) else . end)"
    say "unit $1 ignores dropped dependency #$2 from a worker report; it runs again"
    return 0
  fi
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
  # Blocked again on the same predecessor: the worker disagrees with the release (issue-1168 cost 375k tokens in 90 minutes). Only a delivery ends this wait.
  local real_wait=""
  if jqf -e --arg id "$1" --arg r "#$2" 'any(.units[]; .id == $id and any(.history[]?; .stage == "blocked-on" and .result == $r))' "$UNITS" >/dev/null; then
    real_wait=" | .dep_wait_delivery=$2 | .unpark_condition=$(js "#$2 delivered in the ledger or closed on GitHub")"
    (source "$SCHEDULER_AGENT_LIB"; supervisor_inbox_append_once "dep-disagreement:$1:$2" \
      "dep-disagreement unit=$1: a worker blocked twice on #$2 after a release; it now waits for #$2 to be delivered") \
      || say "dep-disagreement unit=$1: escalation not delivered"
  fi
  set_unit "$1" "$(hist blocked-on "#$2") | .blocked_on=$2 | .note=$(js "waiting for predecessor #$2") | .stage=\"blocked-external\"$real_wait"
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
unit_body_blockers() { # unit-json → stored full-body IDs, or fallback IDs from older task text, minus dropped_deps (supervisor reroute)
  {
    if jqf -e '(.body_blocked_by | type)=="array"' <<<"$1" >/dev/null; then
      jqf -r '.body_blocked_by[] | select(type=="number")' <<<"$1"
    else
      issue_body_blocked_by <<<"$(jqf -r '.task // ""' <<<"$1")"
    fi
  } | grep -vxF -f <(jqf -r '(.dropped_deps // [])[] | tostring' <<<"$1") || true
}
dep_delivered_snapshot() {
  local dep pr sha
  DEP_DELIVERED_CACHE=() DEP_DELIVERED_PR=() TRACKER_KIDS=()
  while IFS=$'\t' read -r dep pr sha; do
    [[ "$dep" =~ ^[0-9]+$ ]] || continue
    DEP_DELIVERED_CACHE["$dep"]=1
    # the PR and merge sha ride along so the review prompt can name them (review-rules.sh supervisor_rule)
    if [[ "$pr" =~ ^[0-9]+$ && "$sha" =~ ^[0-9a-f]{7,40}$ ]]; then DEP_DELIVERED_PR["$dep"]="PR #$pr merged at ${sha:0:12}"; fi
  done < <(jqf -r '.units[] | select(.stage | IN("merged","landed","awaiting-live-event"))
    | ((.pr // "") | tostring) as $p | (.merge_sha // .land_sha // "") as $s
    | ((.issue | select(type == "number")),
       (if ((.branch // "") | test("^agent/issue-[0-9]+$")) then (.branch | sub("^agent/issue-"; "") | tonumber) else empty end))
    | "\(.)\t\($p)\t\($s)"' <(units_history_index))
}
dep_delivered_in_ledger() { # release_dependency_blocks 从台账建一次快照，避免每个 blocker 重读全文件
  [[ "${DEP_DELIVERED_CACHE[$1]:-}" == 1 ]]
}
# 正文依赖状态由 release_dependency_blocks 按 DEP_CHECK_SECONDS 批量缓存；派发门禁只读缓存，不逐单元调用 GitHub。
dep_cache_info() { # predecessor issue → cached {state,labels} or {}
  jqf_optional_file "$A/dep-check.cache.json" -c --arg d "$1" '.states[$d] // {}' 2>/dev/null || echo '{}'
}
unit_body_declares_dependency() { # unit predecessor-issue → true when the issue body explicitly names this prerequisite
  unit_body_blockers "$1" | grep -Fxq "$2"
}
declare -A TRACKER_KIDS=() # blocker → its recut_children, "-" when it is no tracker parent; one state read per blocker per tick (dep_delivered_snapshot resets it)
# A tracker counts as delivered only when every recut child is, so a child that names its own parent as blocker waits on itself forever (#5714 on #5712),
# and a latched real_wait skipped the one path that knows trackers (#2511 on #2510). Wait on the OTHER children only; no other children = cleared.
tracker_dep_cleared() { # blocker blocked-issue → 0 when the blocker is a tracker parent and every recut child but the blocked issue is delivered or closed
  local dep="$1" issue="$2" st kids c s
  [[ "$dep" =~ ^[0-9]+$ ]] || return 1
  if [[ -z "${TRACKER_KIDS[$dep]:-}" ]]; then
    kids=""
    # shortcut: the text test skips jq for the common non-tracker blocker (the release pass must not grow its jq runs with blocked units); pretty or compact JSON both match
    if st="$(scheduler_issue_state "$dep" 2>/dev/null)" && [[ "$st" == *'"recut_children"'* ]]; then
      kids="$(jqf -r 'if (.state == "tracker" or .tracker_parent == true) and ((.recut_children | type) == "array") then [.recut_children[] | select(type == "number")] | join(" ") else empty end' <<<"$st")"
    fi
    TRACKER_KIDS["$dep"]="${kids:--}"
  fi
  [[ "${TRACKER_KIDS[$dep]}" != - ]] || return 1
  for c in ${TRACKER_KIDS[$dep]}; do
    [[ "$c" != "$issue" ]] || continue
    dep_delivered_in_ledger "$c" && continue
    s="$(jqf -r '.state // empty' <<<"$(dep_cache_info "$c")")"
    [[ "$s" == CLOSED || "$s" == MERGED ]] || return 1
  done
  [[ " ${TRACKER_KIDS[$dep]} " != *" $issue "* ]] || say "issue #$issue waits on tracker #$dep, its own parent: dependency rewritten to its sibling children, all delivered"
  return 0
}
dep_cleared() { # unit-json predecessor → 0 when the ledger and the cached GitHub state already count it as cleared
  local info state labels
  dep_delivered_in_ledger "$2" && return 0
  ! dep_dead_ruled "$1" "$2" || return 0
  info="$(dep_cache_info "$2")"
  state="$(jqf -r '.state // empty' <<<"$info")"
  [[ "$state" == CLOSED || "$state" == MERGED ]] && return 0
  labels="$(jqf -r '.labels // ""' <<<"$info")"
  [[ "$state" == OPEN && ",$labels," =~ ,roadmap(-epic|-theme)?, ]] && return 0
  tracker_dep_cleared "$2" "$(jqf -r '.issue // empty' <<<"$1")"
}
blocking_body_dependency() { # unit-json → first predecessor not yet delivered/cleared by the local cache
  local dep
  while read -r dep; do
    [[ "$dep" =~ ^[0-9]+$ ]] || continue
    dep_cleared "$1" "$dep" && continue
    printf '%s' "$dep"; return 0
  done < <(unit_body_blockers "$1")
  return 1
}
# unit-json → N when the unit's last run ended blocked-on #N with no commit and nothing since cleared it: no release, no
# supervisor or typesafe ruling. A handoff requeue is no ruling (see dep_dead_ruled), so it cannot free the unit by itself.
unit_blocked_run_dep() {
  jqf -r '(.history // []) as $h | ([$h | to_entries[] | select(.value.stage == "write-start") | .key] | max) as $s
    | if $s == null then empty else $h[$s:] as $r
      | (($r | map(select(.stage == "write-end")) | last) // {}) as $e
      | ([$r | to_entries[] | select(.value.stage == "blocked-on") | .key] | max) as $b
      | if $e.result == "[]" and $b != null
          and all($r[($b + 1):][]; (.stage == "unblocked" or ((.stage | IN("supervisor-requeue","supervisor-reroute","supervisor-cap-rule")) and (.decision.owner | IN("supervisor","typesafe")))) | not)
        then ($r[$b].result // "" | ltrimstr("#")) else empty end end' <<<"$1" 2>/dev/null
}
dep_dead_ruled() { # unit-json predecessor → 0 only when dep_dead_sweep proved it and the arbiter then ruled; a handoff requeue is no ruling
  jqf -e --argjson d "$2" '.dep_dead_proved == $d and ((.history // []) | (map(.stage) | rindex("dep-dead-proved")) as $p
    | $p != null and any(.[($p + 1):][]; (.stage | IN("supervisor-requeue","supervisor-reroute","supervisor-cap-rule")) and (.decision.owner | IN("supervisor","typesafe"))))' <<<"$1" >/dev/null 2>&1
}
dep_marker_open() { # unit-json → the marked predecessor while it is undelivered; a roadmap label does not clear a marker, unlike a body dependency
  local dep state
  dep="$(jqf -r '.dep_wait_delivery // empty' <<<"$1")"
  [[ "$dep" =~ ^[0-9]+$ ]] || return 1
  dep_delivered_in_ledger "$dep" && return 1
  ! dep_dead_ruled "$1" "$dep" || return 1
  state="$(jqf -r '.state // empty' <<<"$(dep_cache_info "$dep")")"
  [[ "$state" != MERGED ]] || return 1
  [[ "$state" != CLOSED ]] || dep_has_unit "$dep" || return 1
  ! tracker_dep_cleared "$dep" "$(jqf -r '.issue // empty' <<<"$1")" || return 1
  printf '%s' "$dep"
}
dep_has_unit() { # issue → 0 when the ledger has rows and none is settled: with no delivery, a closed state there is work given up or a stale read, not work done. A wontfix, duplicate, done or parked row will not move on its own, and the sweep could never prove it.
  local rc=0
  dep_rows_flag "$1" 2 || rc=$?
  (( rc == 2 )) || return "$rc"
  dep_q_flush
  jqf -e --argjson d "$1" '[.units[] | select(.issue == $d)] | length > 0 and all(.[]; .stage | IN("wontfix", "duplicate", "done", "parked") | not)' <(units_history_doc) >/dev/null
}
park_if_body_blocked() { # unit-json → 0 当按正文前置停住（不派发）
  local id dep
  id="$(jqf -r .id <<<"$1")"
  dep="$(blocking_body_dependency "$1")" || return 1
  [[ "$dep" =~ ^[0-9]+$ ]] || return 1
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
    q+=" i$d: issueOrPullRequest(number: $d) { ... on Issue { state stateReason updatedAt labels(first: 30) { nodes { name } } closedByPullRequestsReferences(first: 10) { nodes { number merged } } } ... on PullRequest { state updatedAt labels(first: 30) { nodes { name } } } }"
    q+=" p$d: pullRequests(headRefName: \"agent/issue-$d\", states: MERGED, first: 1) { totalCount }"
  done
  # awaiting-release is only set after a verified merge into main (AGENTS.md), so it counts as delivered here too, whatever the PR branch is called.
  # issue 要到发布后才关（close-after-release）：只看 issue 状态，前置合并了后继还要多等一整个发布周期
  # （10-22 #3122/#3431 已合并、后继仍停着）。流水线的实现分支是 agent/issue-N：它的 PR 合并即交付。
  gh api graphql -F owner='{owner}' -F name='{repo}' -f query="query(\$owner: String!, \$name: String!) { repository(owner: \$owner, name: \$name) {$q } }" \
    --jq '.data.repository | . as $r | to_entries[] | select((.key | startswith("i")) and .value != null) | .key[1:] as $d
      | "\($d)\t\(if ($r["p" + $d].totalCount // 0) > 0 or ([.value.labels.nodes[].name] | index("awaiting-release")) != null then "MERGED" else .value.state end)\t\([.value.labels.nodes[].name] | join(","))\t\(.value.state)\t\(.value.stateReason // "")\t\(.value.updatedAt // "")\t\(([.value.closedByPullRequestsReferences.nodes[]? | select(.merged) | .number] | first) // "")"' 2>/dev/null
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
  tick_prs_prime
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
  dep_rows_all_closed "$dep" || return 1
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
  dep_now to_supervisor "$id" "blocker #$dep is closed in the ledger but its issue is open with no recut children: decide"
}
dep_stopped_waiting_on() { # unit-id blocker [true|false, when the caller already read it] → 0 when the scheduler already released this unit from that blocker once
  [[ -z "${3:-}" ]] || { [[ "$3" == true ]]; return; }
  jqf -e --arg id "$1" --arg p "stopped waiting on #$2:" 'any(.units[]; .id == $id and any(.history[]?; .stage == "unblocked" and ((.result // "") | startswith($p))))' "$UNITS" >/dev/null
}
dep_task_note() { # unit-id note: append a scheduler note to the worker brief
  set_unit "$1" ".task += $(js $'\n\n'"$2")"
}
dep_stop_waiting() { # unit-id blocker why: a dead blocker never holds a waiter; real code dependence fails later in the unit's own review or merge
  dep_task_note "$1" $'Scheduler note: predecessor #'"$2"$' is parked or can never deliver ('"$3"$'), so this unit no longer waits for it. Do not report BLOCKED-ON #'"$2"$'. Implement what you can; if the dependency is real in code, say so in the report and let review decide.'
  unblock_unit "$1" "stopped waiting on #$2: $3"
}
dep_release_delivered() { # unit-id blocker [true|false, when the caller already read it]: the scheduler counts the blocker delivered; its issue may stay open until release, so tell the worker once
  local note
  note="$(dep_delivered_note "$2")"
  if [[ -n "${3:-}" ]]; then [[ "$3" == true ]] || dep_task_note "$1" "$note"
  else jqf -e --arg id "$1" --arg n "$note" 'any(.units[]; .id == $id and ((.task // "") | contains($n)))' "$UNITS" >/dev/null || dep_task_note "$1" "$note"; fi
  unblock_unit "$1" "#$2 delivered" "$2" delivered "#$2 delivered: ${DEP_DELIVERED_PR[$2]:-PR merged to main}"
}
# One pass over the blocked units (2026-11-08: 349 s on a ledger of 59 blocked units, the 10:47Z tick then died in dispatch_pending).
# A row used to cost ~14 jq calls plus one parse of the merged hot+archive ledger (13 MB, ~0.4 s) for the dead-blocker and
# has-unit checks; every freed row was one locked ledger write of its own. Now: one jq per loop lists each row with every field
# the decisions read, one history pass indexes the rows per issue (DEP_ROWS), and set_unit calls queue (SET_UNIT_QUEUE) into one
# units_update per loop. Decisions, log lines and gh calls are unchanged; dependencies-onepass.test.sh pins both.
declare -A DEP_ROWS=() DEP_ROWS_IDS=() DEP_ROWS_TOUCHED=()
declare -a DEP_Q_IDS=() DEP_Q_EXPRS=()
declare -A DEP_ROWSJSON=()
DEP_ROWS_PASS=0 DEP_ROWS_BUILT=0 SET_UNIT_QUEUE=0 DEP_SWEEP=0 DEP_ROWSJSON_BUILT=0
dep_delivered_note() { # blocker → the worker note dep_release_delivered appends once
  printf 'Scheduler note: predecessor #%s is delivered (its change is merged into main; an issue stays open until release). Do not report BLOCKED-ON #%s.' "$1" "$1"
}
dep_body_declares() { # body-list unit-json predecessor: the stored body list names it; an older unit with no list parses its task text
  if [[ "$1" == '?' ]]; then unit_body_declares_dependency "$2" "$3"; else [[ " $1 " == *" $3 "* ]]; fi
}
dep_rows_build() { # one history pass: per issue, whether every row is closed, whether none is settled, and which units they are
  local n closed live ids
  DEP_ROWS=(); DEP_ROWS_IDS=(); DEP_ROWS_TOUCHED=()
  while IFS=$'\t' read -r n closed live ids; do
    DEP_ROWS["$n"]="$closed $live"; DEP_ROWS_IDS["$n"]="$ids"
  done < <(jqf -r '[.units[] | select((.issue | type) == "number")] | group_by(.issue)[]
    | [.[0].issue, all(.[]; .stage == "closed"), all(.[]; .stage | IN("wontfix", "duplicate", "done", "parked") | not), (map(.id) | join(" "))] | @tsv' <(units_history_doc))
  DEP_ROWS_BUILT=1
}
dep_rows_flag() { # issue 1|2 → 0/1 for closed/live; 2 = a queued stage write touches a unit of that issue, so ask the ledger
  local id row
  (( DEP_ROWS_PASS )) && [[ "$1" =~ ^[0-9]+$ ]] || return 2
  (( DEP_ROWS_BUILT )) || { dep_q_flush; dep_rows_build; } # the first lookup indexes the ledger as written so far
  for id in ${DEP_ROWS_IDS[$1]:-}; do [[ -z "${DEP_ROWS_TOUCHED[$id]:-}" ]] || return 2; done
  row="${DEP_ROWS[$1]:-false false}"
  if [[ "$2" == 1 ]]; then [[ "${row%% *}" == true ]]; else [[ "${row#* }" == true ]]; fi
}
dep_rows_all_closed() { # issue → 0 when it has ledger rows and every one is closed
  local rc=0
  dep_rows_flag "$1" 1 || rc=$?
  (( rc == 2 )) || return "$rc"
  dep_q_flush
  jqf -e --argjson d "$1" '[.units[] | select(.issue == $d)] | length > 0 and all(.[]; .stage == "closed")' <(units_history_doc) >/dev/null
}
dep_q_enqueue() { # id jq_update_expression: set_unit while SET_UNIT_QUEUE=1; a second stage write to one unit flushes first, so each flush sees one transition
  if [[ "$2" == *".stage"* ]]; then
    if [[ -n "${DEP_ROWS_TOUCHED[$1]:-}" ]]; then dep_q_flush; fi
    DEP_ROWS_TOUCHED["$1"]=1
  fi
  DEP_Q_IDS+=("$1"); DEP_Q_EXPRS+=("$2")
}
dep_q_flush() { # apply the queued set_unit calls as one units_update; if the batch is refused, replay them one by one like set_unit would
  local i id old new prog started=$SECONDS rc=0
  local -A old_stage=()
  (( ${#DEP_Q_IDS[@]} )) || return 0
  local -a ids=("${DEP_Q_IDS[@]}") exprs=("${DEP_Q_EXPRS[@]}")
  DEP_Q_IDS=(); DEP_Q_EXPRS=()
  for i in "${!ids[@]}"; do [[ "${exprs[i]}" == *".stage"* ]] && old_stage["${ids[i]}"]=""; done
  if (( ${#old_stage[@]} )) && declare -F footprint_owner_transition >/dev/null; then
    while IFS=$'\t' read -r id old; do [[ -v "old_stage[$id]" ]] && old_stage["$id"]="$old"; done < <(jqf -r '.units[] | [.id, .stage] | @tsv' "$UNITS")
  fi
  prog="$(mktemp "$A/dep-batch.XXXXXX")" || rc=1
  if (( rc == 0 )); then
    for i in "${!ids[@]}"; do
      (( i == 0 )) || printf ' | ' >> "$prog"
      printf '(.units[] |= (if .id == %s then (%s) else . end))' "$(js "${ids[i]}")" "${exprs[i]}" >> "$prog"
    done
    units_update -f "$prog" || rc=$?
    rm -f -- "$prog"
  fi
  if (( rc != 0 )); then
    say "dependency batch write refused (rc=$rc); replaying ${#ids[@]} writes one by one"
    local SET_UNIT_QUEUE=0
    for i in "${!ids[@]}"; do set_unit "${ids[i]}" "${exprs[i]}" || :; done
  elif declare -F footprint_owner_transition >/dev/null; then
    for id in "${!old_stage[@]}"; do # the transition only acts on a unit that left a writer stage
      old="${old_stage[$id]}"
      [[ -n "$old" && "$FOOTPRINT_LIVE_WRITER_STAGES$FOOTPRINT_QUEUED_WRITER_STAGES" == *"\"$old\""* ]] || continue
      new="$(unit_field "$id" '.stage')" || new=""
      footprint_owner_transition "$id" "$old" "$new" || say "footprint wait cleanup failed owner=$id stage=$new"
    done
  fi
  intake_step_secs[ledger_write]=$(( ${intake_step_secs[ledger_write]:-0} + SECONDS - started )); intake_step_counts[ledger_write]=$(( ${intake_step_counts[ledger_write]:-0} + 1 ))
  intake_step_at=$(( intake_step_at + SECONDS - started )) # the write is its own step, not the surrounding one
}
dep_now() { # run a command that reads the ledger it just wrote (to_supervisor counts its own entry) with every queued write applied
  dep_q_flush
  local SET_UNIT_QUEUE=0
  "$@"
}
release_dependency_blocks() {
  local id dep issue state labels gh_due=1 last decision dep_results dep_states_json dep_cache_file dep_cache u line
  local blocker_issue pair_key real_wait recut stacked bb has_info pilot has_note epic_seen marked pilot_label delivered_note
  local -a deps=() unique_deps=()
  local -A DEP_BLOCKED_PAIR_COUNTS=() intake_step_secs=() intake_step_counts=()
  local intake_step_at=$SECONDS US=$'\x1f'
  tick_prs_prime
  dep_delivered_snapshot
  while IFS=$'\t' read -r blocker_issue dep; do
    [[ "$blocker_issue" =~ ^[0-9]+$ && "$dep" =~ ^[0-9]+$ ]] || continue
    pair_key="$blocker_issue:$dep"
    DEP_BLOCKED_PAIR_COUNTS["$pair_key"]=$((${DEP_BLOCKED_PAIR_COUNTS[$pair_key]:-0} + 1))
  done < <(jqf -r '.units[] | select(.stage=="blocked-external" and .blocked_on != null and (.issue | type)=="number") | [.issue,.blocked_on] | @tsv' "$UNITS")
  intake_mark snapshot
  dep_cache_file="$A/dep-check.cache.json"
  last="$(cat "$A/dep-check.epoch" 2>/dev/null)"
  if [[ "$last" =~ ^[0-9]+$ ]] && (( NOW_EPOCH - last < ${DEP_CHECK_SECONDS:-600} )); then gh_due=0; else echo "$NOW_EPOCH" > "$A/dep-check.epoch"; fi
  if (( gh_due )); then
    while IFS= read -r dep; do
      [[ "$dep" =~ ^[0-9]+$ ]] || continue
      dep_delivered_in_ledger "$dep" || deps+=("$dep")
    done < <(jqf -r '[.units[] | select((.stage=="blocked-external" or (.stage=="parked" and (.parked_reason == null or .parked_reason == "waiting-predecessor"))) and .blocked_on != null) | .blocked_on | numbers] | unique | .[]' "$UNITS")
    while IFS= read -r dep; do # 自己的 issue 已关的单元要能被收掉（带 PR 的也查，not_planned 时关 PR）：并入同一次批量查询
      [[ "$dep" =~ ^[0-9]+$ ]] && deps+=("$dep")
    done < <(jqf -r '.units[] | select((.stage=="blocked-external" or .stage=="parked" or .stage=="supervisor-review" or .stage=="implement-pending") and (.issue | type)=="number") | .issue' "$UNITS")
    # a blocked unit goes pending this tick: its other predecessors must already be cached, or it blocks on one that is closed.
    # Two jq runs for all units: stored body lists as numbers, and the saved task text of an older unit without a list (RS-separated; awk parses it).
    while IFS= read -r dep; do
      [[ "$dep" =~ ^[0-9]+$ ]] || continue
      dep_delivered_in_ledger "$dep" || deps+=("$dep")
    done < <(jqf -r '.units[] | select(.stage=="implement-pending" or .stage=="blocked-external" or (.stage=="repair-pending" and .hold_handoff_episode != null))
      | select((.body_blocked_by | type) == "array") | .body_blocked_by[] | select(type == "number")' "$UNITS")
    while IFS= read -r -d $'\x1e' line; do
      while IFS= read -r dep; do
        [[ "$dep" =~ ^[0-9]+$ ]] || continue
        dep_delivered_in_ledger "$dep" || deps+=("$dep")
      done < <(issue_body_blocked_by <<<"$line")
    done < <(jqf -j '.units[] | select(.stage=="implement-pending" or .stage=="blocked-external" or (.stage=="repair-pending" and .hold_handoff_episode != null))
      | select((.body_blocked_by | type) != "array") | ((.task // "") | tostring), "\u001e"' "$UNITS")
    if (( ${#deps[@]} > 0 )); then
      while IFS= read -r dep; do [[ -n "$dep" ]] && unique_deps+=("$dep"); done \
        < <(printf '%s\n' "${deps[@]}" | sort -n -u)
      dep_results="$(dep_states "${unique_deps[@]}" 2>/dev/null || true)"
      dep_states_json="$(printf '%s\n' "$dep_results" | jqf -Rn '
        [inputs | split("\t") | select(length >= 2 and .[0] != "" and .[1] != "")]
        | map({key:.[0],value:({state:.[1],labels:(.[2] // ""),issue_state:(.[3] // ""),state_reason:(.[4] // "")}
          + (if (.[5] // "") == "" then {} else {updated_at:.[5]} end)
          + {merged_closer:(.[6] // "")})}) | from_entries')"
    else
      dep_states_json='{}'
    fi
    sched_dep_cache_refresh_merge "$dep_cache_file" "$NOW_EPOCH" "$dep_states_json" \
      || say "dep cache refresh failed; preserving the prior snapshot"
  fi
  intake_mark gh_batch
  dep_cache="$(jqf_optional_file "$dep_cache_file" -c 'if (.states|type)=="object" then .states else {} end' 2>/dev/null || echo '{}')"
  DEP_ROWS_PASS=1 DEP_ROWS_BUILT=0 SET_UNIT_QUEUE=1; DEP_Q_IDS=(); DEP_Q_EXPRS=()
  while IFS=$'\t' read -r id issue; do # 自己的 issue 已关或已交付：单元作废（2026-10-30 issue-3681 等 5 个）
    set_unit "$id" "$(hist issue-closed "issue #$issue already closed on GitHub") | .stage=\"closed\" | del(.blocked_on) | .note=null"
    say "unit=$id issue #$issue already closed on GitHub; retired"
  done < <(jqf -r --slurpfile c <(printf '%s' "$dep_cache") '.units[] | select((.stage=="blocked-external" or .stage=="parked" or .stage=="supervisor-review") and .pr == null and (.issue | type)=="number"
    and ((($c[0][(.issue | tostring)].state) // "") | IN("CLOSED","MERGED"))) | [.id, .issue] | @tsv' "$UNITS")
  dep_q_flush
  intake_mark retire_closed
  while IFS=$'\t' read -r id issue pr; do # 自己的 issue 以 not_planned 关闭、PR 仍开：关 PR 一次，单元走同一条终局路径
    [[ "$pr" =~ ^[0-9]+$ ]] || continue
    jqf -e --argjson p "$pr" 'any(.[]; .number == $p)' <<<"$(tick_prs)" >/dev/null || continue
    gh pr close "$pr" --comment "Autopilot: issue #$issue was closed as not planned; this PR is superseded." >/dev/null 2>&1 \
      || { say "unit=$id issue #$issue not_planned: could not close PR #$pr; next tick retries"; continue; }
    set_unit "$id" "$(hist issue-closed "issue #$issue closed as not planned; PR #$pr closed") | .stage=\"closed\" | del(.blocked_on) | .note=null"
    say "unit=$id issue #$issue closed as not planned; PR #$pr closed, unit retired"
  done < <(jqf -r --slurpfile c <(printf '%s' "$dep_cache") '.units[] | select((.stage=="blocked-external" or .stage=="parked") and (.pr | type)=="number" and (.issue | type)=="number"
    and ((($c[0][(.issue | tostring)].issue_state) // "") == "CLOSED") and ((($c[0][(.issue | tostring)].state_reason) // "") == "NOT_PLANNED")) | [.id, .issue, .pr] | @tsv' "$UNITS")
  dep_q_flush
  intake_mark retire_not_planned
  pilot_label="$(stack_pilot_label)"; delivered_note="$(dep_delivered_note '@@')"
  # One row per blocked unit with everything the decisions below read; \x1f keeps empty fields, the unit json only rides along when a helper needs it.
  while IFS="$US" read -r id dep issue recut stacked bb real_wait state labels has_info pilot has_note epic_seen u; do
    intake_mark release_row
    [[ "$dep" =~ ^[0-9]+$ ]] || continue
    if [[ "$recut" == true ]]; then continue; fi
    if [[ "$stacked" == true ]] && ! dep_body_declares "$bb" "$u" "$dep"; then continue; fi
    if dep_delivered_in_ledger "$dep"; then
      dep_blocker_forget "$issue" "$dep"
      dep_release_delivered "$id" "$dep" "$has_note"; continue
    fi
    # 两个单元互相等对方（2026-10-20 #2743↔#3330）：放开这一个，另一个继续等它交付。
    pair_key="$dep:$issue"
    if [[ "$real_wait" != true && "$issue" =~ ^[0-9]+$ && "${DEP_BLOCKED_PAIR_COUNTS[$pair_key]:-0}" =~ ^[1-9][0-9]*$ ]]; then
      dep_blocker_forget "$issue" "$dep"
      unblock_unit "$id" "#$dep waits on #$issue: dependency cycle broken here"; continue
    fi
    [[ "$has_info" == true ]] || continue
    if (( gh_due )) && [[ "$state" == OPEN && "$real_wait" != true && "$pilot" == true ]] && ! dep_body_declares "$bb" "$u" "$dep" \
        && dep_now stack_approved_dependency "$id" "$dep" "$u"; then continue; fi
    # A marker ends on delivery or a ruling: a closed issue that delivered nothing goes to dep_dead_sweep, and a stale closed state cannot release it (#536).
    if [[ "$real_wait" == true && "$state" == CLOSED ]] && dep_has_unit "$dep"; then continue; fi
    if [[ "$state" == CLOSED || "$state" == MERGED ]]; then
      dep_blocker_forget "$issue" "$dep"
      if [[ "$state" == MERGED ]]; then dep_release_delivered "$id" "$dep" "$has_note"; else unblock_unit "$id" "#$dep delivered"; fi
      continue
    fi
    # A tracker whose other children are all delivered is delivered for this unit, even when real_wait latched (dead_blocker_resolve below only runs without it).
    if [[ "$state" == OPEN ]] && tracker_dep_cleared "$dep" "$issue"; then
      dep_blocker_forget "$issue" "$dep"
      unblock_unit "$id" "#$dep tracker: every other child delivered"; continue
    fi
    if [[ "$state" == OPEN && "$real_wait" != true ]] && dead_blocker_resolve "$id" "$dep" "$issue"; then
      dep_blocker_forget "$issue" "$dep"; continue
    fi
    # 路线图 epic/主题是伞形 issue，永远不会"交付"；停在它上面就是永远停（2026-10-20 六个单元）。放开一次，
    # 同一个 epic 第二次停住就交给 supervisor。
    if [[ "$real_wait" != true && ",$labels," =~ ,roadmap(-epic|-theme)?, ]]; then
      if [[ "$epic_seen" == true ]]; then
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
  done < <(jqf -r --arg label "$pilot_label" --arg note "$delivered_note" --slurpfile c <(printf '%s' "$dep_cache") '
    .units[] | select(.stage=="blocked-external" and .blocked_on != null)
    | (.blocked_on | tostring) as $d | ($c[0][$d]) as $x
    | (if (.body_blocked_by | type) == "array" then ([.body_blocked_by[] | select(type == "number") | tostring] | join(" ")) else "?" end) as $bb
    | (($label != "") and (try any(.labels[]?; if type == "string" then . == $label else .name == $label end) catch false)) as $pilot
    | [.id, $d, ((.issue // "") | tostring), (.size_recut_pending == true), (.stacked_on != null and .stacked_on_released != true), $bb,
       (((.dep_wait_delivery // "") | tostring) == $d),
       (if ($x | type) == "object" then ($x.state // "") else "" end), (if ($x | type) == "object" then (($x.labels // "") | tostring) else "" end),
       ($x != null and $x != false), $pilot,
       (try (((.task // "") | contains($note | gsub("@@"; $d)))) catch false),
       (try any(.history[]?; .stage == "epic-not-predecessor" and .result == ("#" + $d)) catch false),
       (if $bb == "?" or $pilot then tojson else "" end)]
    | map(tostring) | join("\u001f")' "$UNITS")
  dep_q_flush
  intake_mark release_row
  # supervisor 搁置（park）的单元仍带着 .blocked_on，却没有任何机制在前置交付后放开它；只放有前置号、无其它 parked_reason 的
  # （cap/stop-loss/founder 问题的搁置不点名前置，保持搁置）。
  while IFS="$US" read -r id dep marked state; do
    if [[ "$marked" == "$dep" ]] && ! dep_delivered_in_ledger "$dep" && dep_has_unit "$dep" && [[ "$state" != MERGED ]]; then continue; fi
    if dep_delivered_in_ledger "$dep" || [[ "$state" =~ ^(CLOSED|MERGED)$ ]]; then
      unblock_unit "$id" "parked on #$dep, which is delivered"
    fi
  done < <(jqf -r --slurpfile c <(printf '%s' "$dep_cache") '.units[] | select(.stage=="parked" and (.parked_reason == null or .parked_reason == "waiting-predecessor") and .size_recut_pending != true and (.blocked_on | type)=="number")
    | [.id, (.blocked_on | tostring), ((.dep_wait_delivery // "") | tostring), (try ($c[0][(.blocked_on | tostring)].state // "") catch "")] | join("\u001f")' "$UNITS")
  dep_q_flush
  DEP_ROWS_PASS=0 SET_UNIT_QUEUE=0
  intake_mark parked_release
  # A ready issue without a recorded predecessor has no release event to wait for. If GitHub
  # still labels it ready, release it; keep non-ready issues on the supervisor route.
  while IFS="$US" read -r id ready; do
    if [[ "$ready" == true ]]; then
      unblock_unit "$id" "no predecessor recorded; issue remains ready-for-agent"
    else
      to_supervisor "$id" "blocked-external without a predecessor: nothing can release it"
    fi
  done < <(jqf -r --slurpfile c <(printf '%s' "$dep_cache") '.units[]
    | select(.stage=="blocked-external" and .blocked_on == null and .size_recut_pending != true)
    | [ .id, (((($c[0][(.issue | tostring)].labels // "") | split(",")) | index("ready-for-agent")) != null) ]
    | map(tostring) | join("\u001f")' "$UNITS")
  intake_mark no_blocker_escalate
  dep_hold_parked; intake_mark hold_parked
  if (( gh_due )); then
    reconcile_stacked_units; intake_mark reconcile_stacked
    DEP_SWEEP=1; dep_rows_prime
    dep_dead_sweep || :; intake_mark dep_dead_sweep
    dep_dead_unpark || :; intake_mark dep_dead_unpark
    DEP_SWEEP=0 DEP_ROWSJSON_BUILT=0
    obsolete_close_retry || :; intake_mark obsolete_close_retry
    park_label_sweep || :; intake_mark park_label_sweep
  fi
  intake_steps_say "dep detail steps"
}
dep_rows_prime() { # one history pass for every waiter's predecessor; the sweeps call it in the main shell, dep_rows_json reads it from a subshell
  local n rows need
  DEP_ROWSJSON=(); DEP_ROWSJSON_BUILT=0
  need="$(jqf -c '[.units[] | .dep_wait_delivery | numbers] | unique' "$UNITS")" || return 0
  while IFS=$'\x1f' read -r n rows; do DEP_ROWSJSON["$n"]="$rows"; done < <(jqf -r --argjson need "$need" \
    '. as $doc | $need[] | . as $d | "\($d)\u001f\([$doc.units[] | select(.issue == $d)] | tojson)"' <(units_history_doc))
  DEP_ROWSJSON_BUILT=1
}
dep_rows_json() { # issue → its ledger rows as a json array
  if (( DEP_ROWSJSON_BUILT )) && [[ -v "DEP_ROWSJSON[$1]" ]]; then printf '%s' "${DEP_ROWSJSON[$1]}"; return; fi
  jqf -c --argjson d "$1" '[.units[] | select(.issue == $d)]' <(units_history_doc)
}
# Fail closed: any fact that cannot be read means not dead. Prints the arbiter's evidence.
dep_predecessor_dead() { # waiter-unit-json predecessor
  local dep="$2" waiter rows st prs subs c b sha branches=""
  dep_delivered_in_ledger "$dep" && return 1
  rows="$(dep_rows_json "$dep")" || return 1
  st="$(scheduler_issue_state "$dep")" && [[ -n "$st" ]] || return 1
  # An open tracker with no unit never delivers by itself, so only its children can end the wait.
  jqf -e --slurpfile st <(printf '%s' "$st") 'if length == 0 then $st[0].state == "tracker" else all(.[]; .stage == "closed") end' <<<"$rows" >/dev/null || return 1
  jqf -e --slurpfile w "$A/workers.json" 'map(.id) as $ids | all($w[0].workers[]; .harvested == true or (.unit as $u | ($ids | index($u)) == null))' <<<"$rows" >/dev/null || return 1
  prs="$(tick_prs)" || return 1
  jqf -e --slurpfile rows <(printf '%s' "$rows") --arg d "$dep" '
    ($rows[0] | map(.pr)) as $own | ($rows[0] | map(.branch) + ["agent/issue-" + $d]) as $heads
    | all(.[]; (.number as $n | $own | index($n)) == null and (.headRefName as $h | $heads | index($h)) == null
      and ((.body // "") | test("#" + $d + "([^0-9]|$)") | not))' <<<"$prs" >/dev/null || return 1
  subs="$(gh api --paginate "repos/{owner}/{repo}/issues/$dep/sub_issues?per_page=100" --jq '.[].number' 2>/dev/null)" || return 1
  waiter="$(jqf -r '.issue // empty' <<<"$1")"
  for c in $(printf '%s\n%s\n' "$(jqf -r '(.recut_children // [])[]' <<<"$st")" "$subs" | sort -un); do
    [[ "$c" != "$waiter" ]] || continue
    dep_delivered_in_ledger "$c" && continue
    jqf -e --argjson c "$c" --argjson d "$dep" 'any(.units[]; .issue == $c and .dep_wait_delivery == $d)' "$UNITS" >/dev/null && continue # waits on the same dead predecessor
    [[ "$(dep_states "$c" | cut -f2)" =~ ^(CLOSED|MERGED)$ ]] || { say "dep-dead skip waiter=#$waiter predecessor=#$dep live child #$c"; return 1; }
  done
  for b in $(jqf -r --arg d "$dep" 'map(.branch // empty) + ["agent/issue-" + $d] | unique | .[]' <<<"$rows"); do
    sha="$(gh api "repos/{owner}/{repo}/git/ref/heads/$b" --jq .object.sha 2>/dev/null)" || sha=gone
    branches+=" $b@${sha:0:12}"
  done
  printf 'predecessor #%s can never deliver (%s), no open PR, no live worker, no live child; branches:%s' \
    "$dep" "$(jqf -r 'if length == 0 then "open tracker with no unit" else "unit closed undelivered: " + (last.note // "no note" | .[0:200]) end' <<<"$rows")" "$branches"
}
dep_dead_sweep() { # at most one unit per sweep reaches the arbiter; no state, so nothing can wedge it
  local u id dep evidence
  while IFS= read -r u; do
    id="$(jqf -r .id <<<"$u")"; dep="$(jqf -r '.dep_wait_delivery // .blocked_on' <<<"$u")"
    evidence="$(dep_predecessor_dead "$u" "$dep")" || continue
    if [[ "$(jqf -r '.dep_dead_proved // empty' <<<"$u")" == "$dep" ]] && ! dep_stopped_waiting_on "$id" "$dep"; then
      dep_stop_waiting "$id" "$dep" "dead predecessor blocked it again after arbitration"
      echo "[$STAMP] dep-dead unit=$id predecessor=#$dep action=released reason=repeat" >> "$A/alerts/events.md"
    elif [[ "$(jqf -r '.dep_dead_proved // empty' <<<"$u")" == "$dep" ]]; then
      set_unit "$id" "$(hist supervisor-park "blocked on dead predecessor #$dep again after arbitration") | .dep_wait_delivery=$dep | del(.blocked_on) | .stage=\"parked\" | .parked_reason=\"dep-dead-repeat\" | .note=$(js "$evidence") | .unpark_condition=$(js "#$dep delivered in the ledger")"
      echo "[$STAMP] dep-dead unit=$id predecessor=#$dep action=parked reason=repeat" >> "$A/alerts/events.md"
    else
      set_unit "$id" "$(hist dep-dead-proved "#$dep") | .dep_dead_proved=$dep | .dep_wait_delivery=$dep | del(.blocked_on, .unpark_condition)"
      to_supervisor "$id" "$evidence. Decide: recut this unit with the prerequisite included, close it, or rule that it starts without #$dep"
    fi
    return 0
  done < <(jqf -c '[.units[] | select(.size_recut_pending != true and ((.stage=="blocked-external" and .dep_wait_delivery != null and .dep_wait_delivery == .blocked_on) or (.stage=="parked" and .parked_reason=="waiting-predecessor" and (.blocked_on | type)=="number")))] | sort_by(-.issue) | .[]' "$UNITS")
}
dep_dead_unpark() { # delivery clears every repeat park; a dead undelivered blocker gets only the one pre-repeat release, so a refusing worker cannot loop
  local u id dep
  while IFS= read -r u; do
    id="$(jqf -r .id <<<"$u")"; dep="$(jqf -r .dep_wait_delivery <<<"$u")"
    if dep_delivered_in_ledger "$dep"; then
      set_unit "$id" ".blocked_on=$dep | del(.parked_reason, .unpark_condition)"
      dep_release_delivered "$id" "$dep" true
      (( ! DEP_SWEEP )) || dep_rows_prime # a released waiter can be another waiter's predecessor row
      echo "[$STAMP] dep-dead unit=$id predecessor=#$dep action=released reason=delivered" >> "$A/alerts/events.md"
      continue
    fi
    dep_stopped_waiting_on "$id" "$dep" && continue
    dep_predecessor_dead "$u" "$dep" >/dev/null || continue # fail closed: closed on GitHub is not delivered, and not proven dead stays parked
    set_unit "$id" ".blocked_on=$dep | del(.parked_reason, .unpark_condition)"
    dep_stop_waiting "$id" "$dep" "it was closed without delivering, its work is not in main"
    (( ! DEP_SWEEP )) || dep_rows_prime # a released waiter can be another waiter's predecessor row
    echo "[$STAMP] dep-dead unit=$id predecessor=#$dep action=released reason=parked-before-release" >> "$A/alerts/events.md"
  done < <(jqf -c '.units[] | select(.stage=="parked" and .parked_reason=="dep-dead-repeat" and (.dep_wait_delivery | type)=="number")' "$UNITS")
}
# A parked blocker holds its dependents (2026-11-08: five released ones ran against prerequisites that never shipped, 5 implement + 5 review rounds lost).
# Two ledger-only passes per tick, both idempotent (the ledger decides, no marker): units the old release rule freed while they have no PR wait on
# the blocker again, then every parked or supervisor-review unit carries the count of units waiting on it, and a supervisor-park one is escalated once.
dep_hold_parked() {
  local id n note
  while IFS=$'\t' read -r id n; do
    dep_delivered_in_ledger "$n" && continue
    set_unit "$id" "$(hist blocker-held "released while #$n is parked or open and nothing was built; waiting again") | .blocked_on=$n | .note=$(js "waiting for predecessor #$n") | .stage=\"blocked-external\" | .task |= (. // \"\" | sub(\"\\n\\nScheduler note: predecessor #$n is parked or can never deliver \\\\([^)]*\\\\)[^\\n]*\"; \"\"))"
    say "unit $id blocked again on #$n: the scheduler had stopped waiting on a blocker that is parked or open"
  done < <(jqf -r '. as $r | .units[] | select(.stage == "implement-pending" and .pr == null and .blocked_on == null and .size_recut_pending != true)
    | ((.history // []) | map(select(.stage == "unblocked")) | last // {}) as $e
    | select(($e.result // "") | test("^stopped waiting on #[0-9]+:"))
    | ($e.result | capture("^stopped waiting on #(?<n>[0-9]+):").n | tonumber) as $n
    | select([$r.units[] | select(.issue == $n)] | length > 0 and all(.[]; .stage | IN("closed", "wontfix", "duplicate", "done") | not))
    | select(.history | (map(.stage) | rindex("unblocked")) as $at | all(.[$at + 1:][]; (.stage | IN("supervisor-requeue", "supervisor-reroute", "supervisor-cap-rule")) | not))
    | [.id, $n] | @tsv' "$UNITS")
  while IFS=$'\t' read -r id n note; do
    set_unit "$id" "$(if [[ "$n" == 0 ]]; then printf 'del(.held_dependents)'; else printf '.held_dependents=%s' "$n"; fi)"
    [[ -z "$note" ]] || to_supervisor "$id" "parked blocker holds $n dependents: deliver it, recut it, close it or rule it obsolete"
  done < <(jqf -r '. as $r | def reaches($u; $n; $seen): ($u.blocked_on) as $b
      | if ($b | type) != "number" then false elif $b == $n then true elif ($seen | index($b)) != null then false
        else any($r.units[]; .stage == "blocked-external" and .issue == $b and reaches(.; $n; $seen + [$b])) end;
    .units[] | select((.stage == "parked" or .stage == "supervisor-review") and (.issue | type) == "number") | . as $p
    | ([$r.units[] | select(.stage == "blocked-external" and .size_recut_pending != true and reaches(.; $p.issue; []))] | length) as $n
    | select($n != (.held_dependents // 0))
    | [.id, $n, (if $p.stage == "parked" and $p.parked_reason == "supervisor-park" and $p.held_dependents == null and $n > 0 then "escalate" else "" end)] | @tsv' "$UNITS")
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
unblock_unit() { # unit reason [released-issue kind why]: the triple lands in .released_deps so the review prompt can say the scheduler released it (review-rules.sh)
  local rel=""
  [[ "${3:-}" =~ ^[0-9]+$ ]] && rel=" | .released_deps = (((.released_deps // []) | map(select(.issue != $3))) + [{issue: $3, kind: $(js "$4"), reason: $(js "$5")}])"
  set_unit "$1" "$(hist unblocked "$2")$rel | (if .dep_wait_delivery != null and .dep_wait_delivery == .blocked_on then del(.dep_wait_delivery, .unpark_condition) else . end) | del(.blocked_on) | .note=null | .stage=(if .blocked_resume_stage == \"repair-pending\" then \"repair-pending\" elif .pr != null then \"review-pending\" else \"implement-pending\" end) | del(.blocked_resume_stage)"
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
      tick_prs_changed
      git -C "$wt" push -q --force-with-lease="refs/heads/$branch:$remote_head" origin "$branch" || return 1
    fi
  elif [[ "$child_head" != "$base_sha" ]]; then
    tick_prs_changed
    git -C "$wt" push -q -u origin "$branch" || return 1
  fi
  pr="$(unit_field "$id" '.pr // empty')"
  if [[ "$pr" =~ ^[0-9]+$ ]]; then tick_prs_changed; gh pr edit "$pr" --base "$2" >/dev/null 2>&1 || return 1; fi
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
  tick_prs_changed
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
  tick_prs_prime
  prs="$(tick_prs 2>/dev/null)" || prs='[]'
  while IFS= read -r child; do
    if [[ -z "$TICK_PRS" ]]; then tick_prs_prime; prs="${TICK_PRS:-[]}"; fi
    id="$(jqf -r .id <<<"$child")"; dep="$(jqf -r '.blocked_on // empty' <<<"$child")"
    parent_id="$(jqf -r '.stacked_on_unit // empty' <<<"$child")"
    parent="$(jqf -c --arg id "$parent_id" '.units[] | select(.id==$id)' <(units_history_doc))"
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
    # A worker refused this release twice: an open parent frees nothing here, and the MERGED branch above is the delivery.
    jqf -e '.stage == "blocked-external" and .dep_wait_delivery != null and .dep_wait_delivery == .blocked_on' <<<"$child" >/dev/null && continue
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
    parent="$(jqf -c --arg id "$parent_id" '.units[] | select(.id==$id)' <(units_history_doc))"
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
