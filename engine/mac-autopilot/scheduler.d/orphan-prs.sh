
# ---------- 4b. 环节 SLO 护栏：每个等待环节有预算，超了写 alerts/slo.md（每单元每次停留只报一次） ----------
handoff_pr_waiting() { # PR issue: unresolved handoffs retain every associated PR
  local pr_number="$1" n="${2:-0}" state_file episode
  jqf -e --argjson pr "$pr_number" 'index($pr) != null' <<<"${HANDOFF_WAIT_PRS:-[]}" >/dev/null && return 0
  jqf -e --argjson pr "$pr_number" --argjson n "$n" 'any(.units[]; .hold_handoff_waiting == true and (.pr == $pr or .issue == $n or ((.hold_handoff_wait_issues // []) | index($n)) != null))' "$UNITS" >/dev/null && return 0
  (( n > 0 )) || return 1
  state_file="${AGENT_HOME:-${HOME:-}/.zenoforge}/state/$n.json"
  episode="$(jqf -r 'select(.state == "ready-for-agent") | .scheduler_handoff.episode // empty' "$state_file" 2>/dev/null)"
  [[ -n "$episode" ]] || return 1
  ! jqf -e --argjson n "$n" --arg episode "$episode" 'any(.units[]; .issue == $n and .hold_handoff_episode == $episode)' "$UNITS" >/dev/null
}
orphan_issue_states() { # issue numbers... → {"number":"OPEN|CLOSED"} from one targeted GraphQL census
  (( $# > 0 )) || { printf '{}\n'; return 0; }
  local query="" number
  for number in "$@"; do
    [[ "$number" =~ ^[0-9]+$ ]] || continue
    query+=" i$number: issue(number: $number) { state }"
  done
  [[ -n "$query" ]] || { printf '{}\n'; return 0; }
  gh api graphql -F owner='{owner}' -F name='{repo}' \
    -f query="query(\$owner: String!, \$name: String!) { repository(owner: \$owner, name: \$name) {$query} }" \
    --jq '.data.repository | to_entries | map(select(.value != null) | {key:(.key[1:]),value:.value.state}) | from_entries' 2>/dev/null
}
reconcile_orphan_prs() {
  local last prs states_by_number orphan_issue_numbers blocked rows n prn branch draft title issue_state gated reg=0 max="${ORPHAN_REGISTER_MAX:-3}" agent_left=0 foreign=0 now
  local -a issue_numbers=()
  last="$(cat "$A/orphan-check.epoch" 2>/dev/null)"
  [[ "$last" =~ ^[0-9]+$ ]] && (( NOW_EPOCH - last < ${ORPHAN_CHECK_SECONDS:-1800} )) && return 0
  echo "$NOW_EPOCH" > "$A/orphan-check.epoch"
  tick_prs_prime
  prs="$(tick_prs)" || return 0
  blocked="$(jqf -c '[.units[] | select(.stage=="blocked-external" and .blocked_on != null) | .blocked_on]' "$UNITS")"
  orphan_issue_numbers="$(jqf -c --slurpfile u "$UNITS" '
      ($u[0].units | map(.pr) | map(select(. != null))) as $known
      | [.[] | select(.number as $n | $known | index($n) | not)
          | (try (.headRefName | capture("^agent/(auto-)?issue-(?<n>[0-9]+)$").n | tonumber) catch null)
          | select(. != null)] | unique' <<<"$prs")" || return 0
  mapfile -t issue_numbers < <(jqf -r '.[]' <<<"$orphan_issue_numbers")
  if (( ${#issue_numbers[@]} > 0 )); then
    states_by_number="$(orphan_issue_states "${issue_numbers[@]}")" || return 0
  else
    states_by_number='{}'
  fi
  rows="$(jqf -r --slurpfile u "$UNITS" --argjson b "$blocked" --argjson states "$states_by_number" '
      ($u[0].units | map(.pr) | map(select(. != null))) as $known
      | map(select(.number as $n | $known | index($n) | not))
      | map(((.headRefName | capture("^agent/(auto-)?issue-(?<n>[0-9]+)$").n | tonumber)? // null) as $i
          | . + {issue:$i})
      | map(.issue as $i | . + {blocks: ($i != null and ($b | index($i)) != null), issue_state: (if $i != null then ($states[($i | tostring)] // "UNKNOWN") else "UNKNOWN" end)})
      | sort_by([(if .blocks then 0 else 1 end), .number]) | .[]
      | "\(.number)\t\(.headRefName)\t\(.isDraft)\t\(.issue // "")\t\(.title | gsub("\t"; " "))\t\(.issue_state)"' <<<"$prs")"
  now="$(date -u +%FT%TZ)"
  # 生产热修的源 PR 先收（任意分支），它们挡着所有 Example 发布（release_train.sh 写 release-blockers.json）。
  for prn in $(jqf -r '.blockers[]?' "$A/release-blockers.json" 2>/dev/null); do
    [[ "$prn" =~ ^[0-9]+$ ]] || continue
    if [[ -n "${HANDOFF_PR_CENSUS:-}" && "${HANDOFF_CENSUS_PARTIAL:-0}" == 1 ]]; then
      handoff_include_pr "$prn" || continue
      register_new_issues 1 reuse
    fi
    handoff_pr_waiting "$prn" 0 && continue
    jqf -e --argjson p "$prn" 'any(.units[]; .pr == $p)' "$UNITS" >/dev/null && continue
    jqf -e --argjson p "$prn" 'any(.[]; .number == $p)' <<<"$prs" >/dev/null || continue
    jqf --argjson prn "$prn" --arg b "$(jqf -r --argjson p "$prn" '.[] | select(.number == $p) | .headRefName' <<<"$prs")" \
      --arg t "$(jqf -r --argjson p "$prn" '.[] | select(.number == $p) | .title' <<<"$prs")" --arg now "$now" --arg h "$HOTPATCH_HINT" \
      '.units += [{id:("pr-"+($prn|tostring)), title:$t, stage:"review-pending", pr:$prn, branch:$b, critical:true, hotpatch:true, repair_hint:$h,
        note:"release blocker: production hot patch not on main; forward-port and merge first",
        history:[{stage:"orphan-registered", result:"release blocker (carried production hot patch)", at:$now}]}]' "$UNITS" | write_state "$UNITS"
    say "release-blocker PR#$prn registered (carried production hot patch)"
  done
  while IFS=$'\t' read -r prn branch draft n title issue_state; do
    [[ "$prn" =~ ^[0-9]+$ ]] || continue
    jqf -e --argjson p "$prn" 'any(.units[]; .pr == $p)' "$UNITS" >/dev/null && continue
    if [[ ! "$n" =~ ^[0-9]+$ ]]; then foreign=$((foreign + 1)); continue; fi
    handoff_pr_waiting "$prn" "$n" && { agent_left=$((agent_left + 1)); continue; }
    if [[ "$issue_state" == CLOSED ]]; then
      tick_prs_changed
      gh pr close "$prn" --comment "Autopilot: issue #$n is closed; this PR outside the pipeline ledger is superseded." >/dev/null 2>&1 \
        && say "orphan PR#$prn closed: issue #$n is closed"
      continue
    fi
    if jqf -e --argjson n "$n" 'any(.units[]; .issue == $n)' "$UNITS" >/dev/null; then
      # 台账单元自己没有 PR 又没结束时，这个孤儿 PR 可能就是唯一的实现：不关，也不再收一个单元，留给 supervisor。
      if ! jqf -e --argjson n "$n" 'any(.units[]; .issue == $n and (.pr != null or (.stage | test("^(merged|landed|closed|done)$"))))' "$UNITS" >/dev/null; then
        agent_left=$((agent_left + 1)); say "orphan PR#$prn kept: issue #$n has a ledger unit without its own PR"; continue
      fi
      tick_prs_changed
      gh pr close "$prn" --comment "Autopilot: issue #$n is handled by $(jqf -r --argjson n "$n" '[.units[] | select(.issue == $n)][0].id' "$UNITS") in the pipeline ledger; this older PR is superseded." >/dev/null 2>&1 \
        && say "orphan PR#$prn closed: issue #$n already has a ledger unit"
      continue
    fi
    if (( reg >= max )); then agent_left=$((agent_left + 1)); continue; fi
    # 收编不 ready：draft 的 agent/issue-* 孤儿只加门控标签，批准且占到名额后才由名额门 ready；非 draft 孤儿保持旧路径直到第一次 repair。
    # 不符合门控条件的 draft（如 agent/auto-issue-*）沿用旧行为，ready 后走旧路径。
    gated=0
    if [[ "$draft" == true ]]; then
      if [[ "$branch" =~ $GATED_BRANCH_RE ]]; then gated_flag_pr "$prn" && gated=1; else tick_prs_changed; gh pr ready "$prn" >/dev/null 2>&1; fi
    fi
    jqf --argjson prn "$prn" --argjson n "$n" --arg b "$branch" --arg t "$title" --arg now "$now" \
      '.units += [{id:("pr-"+($prn|tostring)), title:$t, stage:"review-pending", pr:$prn, issue:$n, branch:$b,
        critical:([.units[] | select(.stage=="blocked-external" and .blocked_on == $n)] | length > 0),
        history:[{stage:"orphan-registered", result:"open PR outside the ledger", at:$now}]}]' "$UNITS" | write_state "$UNITS"
    (( gated )) && set_unit "pr-$prn" '.gated=true'
    reg=$((reg + 1))
    say "orphan PR#$prn registered for review (issue #$n)"
  done <<<"$rows"
  echo "agent=$agent_left foreign=$foreign" > "$A/orphan-prs.count"
}
aged_pr_intent_issue() { # branch → issue number（agent/issue-N / agent/auto-issue-N），无则空
  [[ "$1" =~ ^agent/(auto-)?issue-([0-9]+)$ ]] && printf '%s' "${BASH_REMATCH[2]}"
  return 0
}
aged_pr_ticket_body() { # prn branch age behind issue intent_title intent_body
  local prn="$1" branch="$2" age="$3" behind="$4" issue="$5" title="$6" body="$7" origin_line
  origin_line="此票由旧 PR 生命周期 sweep 按 #4360 重开。
- 原 PR：#${prn}（分支 ${branch}，超龄关闭：年龄 $((age / 86400)) 天、落后 main ${behind} 个提交）"
  if [[ -n "$issue" ]]; then
    origin_line="$origin_line
- 原 ticket：#${issue}"
  fi
  printf '%s\n' "$origin_line" "
## 原意图摘要
${title}

${body:0:2000}

## 说明
旧 PR 经三分类判定为「仍需要」，未合入的改动按原意图在当前 main 上重做；原 PR 已关闭，理由见其 PR 评论。"
}
aged_pr_close() { # prn branch age behind class reason [new-issue] → 0 关闭成功
  local prn="$1" branch="$2" age="$3" behind="$4" class="$5" reason="$6" m="${7:-}" unit_id comment
  comment="Autopilot 旧 PR 生命周期（#4360）：关闭此 PR。
- 分类：${class}
- 理由：${reason}
- 触发：年龄 $((age / 86400)) 天、落后 main ${behind} 个提交（阈值 7 天 / 300 提交）"
  tick_prs_changed
  if ! gh pr close "$prn" --comment "$comment" >/dev/null 2>&1; then
    say "aged PR#$prn: close failed; retry next round"
    return 1
  fi
  unit_id="$(jqf -r --argjson p "$prn" '[.units[] | select(.pr == $p) | .id] | first // empty' "$UNITS")"
  [[ -n "$unit_id" ]] && set_unit "$unit_id" "$(hist aged-triage "${class}: ${reason}") | .stage=\"closed\""
  say "aged PR#$prn ($branch): ${class} — ${reason}${m:+; reopened as #${m}}"
  return 0
}
aged_pr_lifecycle() {
  local last pr_json rows prn branch head created created_epoch age behind n issue_json intent_title intent_body pr_json_meta
  local live_prs mt rc plus total files f missing file_total done_n=0 left=0 max="${AGED_PR_MAX:-6}" main_ref="refs/remotes/origin/main" m_url m_n
  [[ "${HANDOFF_CENSUS_PARTIAL:-0}" != 1 ]] || { say "aged PR lifecycle deferred: handoff PR census unavailable"; return 0; }
  last="$(cat "$A/aged-pr-check.epoch" 2>/dev/null || true)"
  [[ "$last" =~ ^[0-9]+$ ]] && (( NOW_EPOCH - last < ${AGED_PR_CHECK_SECONDS:-3600} )) && return 0
  echo "$NOW_EPOCH" > "$A/aged-pr-check.epoch"
  tick_prs_prime
  pr_json="$(tick_prs 2>/dev/null)" || return 0
  rows="$(jqf -r 'map(select(.baseRefName == "main" and (.headRefName | test("^(agent|hand)/"))))
      | sort_by(.createdAt) | .[]
      | [.number, .headRefName, .headRefOid, .createdAt] | @tsv' <<<"$pr_json")"
  # 一次批量取回所有候选分支的对象，之后 patch-id/merge-tree/落后计数全是本地判定。
  git -C "$ROOT" fetch -q origin $(jqf -r 'map(select(.baseRefName == "main" and (.headRefName | test("^(agent|hand)/"))) | .headRefName) | unique | .[]' <<<"$pr_json") 2>/dev/null || true
  # 超龄指无人推进：台账单元在年龄窗口内还有历史记录的 PR 是在途工作，不分类（10-29 同一拍关掉了刚复审 READY 的 #4004 和刚交付全绿的 #4022）。
  live_prs="$(jqf -c --argjson cut "$((NOW_EPOCH - AGED_PR_AGE_SECONDS))" '[.units[]
      | select(.pr != null and (.stage | IN("merged","closed") | not))
      | select(([.history[]?.at // empty | try fromdateiso8601 catch 0] | max // 0) > $cut) | .pr]' "$UNITS")"
  while IFS=$'\t' read -r prn branch head created; do
    [[ "$prn" =~ ^[0-9]+$ && "$head" =~ $SHA_RE ]] || continue
    jq -e --argjson p "$prn" 'index($p) != null' <<<"$live_prs" >/dev/null && continue
    n="$(aged_pr_intent_issue "$branch")"
    handoff_pr_waiting "$prn" "${n:-0}" && continue
    created_epoch="$(ap_iso_epoch "$created")"
    [[ "$created_epoch" =~ ^[0-9]+$ && "$created_epoch" -gt 0 ]] || continue
    age=$(( NOW_EPOCH - created_epoch ))
    behind=""
    if git -C "$ROOT" rev-parse -q --verify "$head^{commit}" >/dev/null 2>&1; then
      behind="$(git -C "$ROOT" rev-list --count "$head..$main_ref" 2>/dev/null)"
    fi
    if (( age <= AGED_PR_AGE_SECONDS )) && [[ "${behind:-0}" -le $AGED_PR_BEHIND_COMMITS ]]; then continue; fi
    if (( done_n >= max )); then left=$((left + 1)); continue; fi
    # 原 ticket 已关闭：意图已有结局，这个 PR 不再承载活的东西。
    if [[ -n "$n" ]]; then
      issue_json="$(gh issue view "$n" --json state,title,body 2>/dev/null)" || { say "aged PR#$prn: issue #$n unreadable; retry next round"; continue; }
      if [[ "$(jqf -r .state <<<"$issue_json")" == CLOSED ]]; then
        aged_pr_close "$prn" "$branch" "$age" "${behind:-?}" "已在 main" "原 ticket #$n 已关闭，此 PR 不再承载活的意图" "" || continue
        done_n=$((done_n + 1)); continue
      fi
    fi
    if ! git -C "$ROOT" rev-parse -q --verify "$head^{commit}" >/dev/null 2>&1; then
      say "aged PR#$prn: head $head not fetchable; retry next round"; continue
    fi
    plus="$(git -C "$ROOT" cherry "$main_ref" "$head" 2>/dev/null | grep -c '^+' || true)"
    total="$(git -C "$ROOT" cherry "$main_ref" "$head" 2>/dev/null | grep -c '^[-+]' || true)"
    if [[ "$plus" == 0 && "$total" -gt 0 ]]; then
      aged_pr_close "$prn" "$branch" "$age" "${behind:-?}" "已在 main" "$total 个提交的 patch-id 全部与 main 等价" "" || continue
      done_n=$((done_n + 1)); continue
    fi
    rc=0
    mt="$(git -C "$ROOT" merge-tree --write-tree "$main_ref" "$head" 2>/dev/null)" || rc=$?
    if [[ $rc -eq 0 ]]; then
      if [[ "$(head -1 <<<"$mt")" == "$(git -C "$ROOT" rev-parse -q --verify "$main_ref^{tree}" 2>/dev/null)" ]]; then
        aged_pr_close "$prn" "$branch" "$age" "${behind:-?}" "已在 main" "改动与 main 合并后的树与 main 完全一致，改动已经存在" "" || continue
        done_n=$((done_n + 1)); continue
      fi
    else
      files="$(git -C "$ROOT" diff --name-only "$(git -C "$ROOT" merge-base "$main_ref" "$head" 2>/dev/null)" "$head" 2>/dev/null)"
      file_total="$(grep -c . <<<"$files" || true)"
      missing=0
      while IFS= read -r f; do
        [[ -n "$f" ]] || continue
        git -C "$ROOT" cat-file -e "$main_ref:$f" 2>/dev/null || missing=$((missing + 1))
      done <<<"$files"
      if (( file_total > 0 && missing == file_total )); then
        aged_pr_close "$prn" "$branch" "$age" "${behind:-?}" "已过时" "改动的 $file_total 个文件在 main 上已全部删除" "" || continue
        done_n=$((done_n + 1)); continue
      fi
      # 冲突只说明 main 动了，不说明意图过时：落到下方「仍需要」按原意图重开。
    fi
    # 仍需要：按原意图在新 main 上开新 ticket，旧 PR 关闭。
    if [[ -n "$n" ]]; then
      intent_title="$(jqf -r .title <<<"$issue_json")"; intent_body="$(jqf -r .body <<<"$issue_json")"
    else
      pr_json_meta="$(jqf -c --argjson pr "$prn" '[.[] | select(.number == $pr) | {title,body}][0] // empty' <<<"$pr_json")"
      [[ -n "$pr_json_meta" ]] || pr_json_meta="$(gh pr view "$prn" --json title,body 2>/dev/null)" || { say "aged PR#$prn: pr view failed; retry next round"; continue; }
      intent_title="$(jqf -r .title <<<"$pr_json_meta")"; intent_body="$(jqf -r .body <<<"$pr_json_meta")"
    fi
    m_url="$(gh issue create --title "重做（旧 PR #${prn}）：${intent_title}" \
      --body "$(aged_pr_ticket_body "$prn" "$branch" "$age" "${behind:-?}" "$n" "$intent_title" "$intent_body")" \
      --label ready-for-agent 2>/dev/null)" || { say "aged PR#$prn: new ticket create failed; retry next round"; continue; }
    m_n="${m_url##*/}"
    [[ "$m_n" =~ ^[0-9]+$ ]] || { say "aged PR#$prn: new ticket URL unparsable: ${m_url:-empty}; PR left open"; continue; }
    if [[ -n "$n" ]]; then
      gh issue close "$n" --comment "Autopilot 旧 PR 生命周期（#4360）：此票的意图已按当前 main 重开为 #${m_n}（原 PR #${prn} 超龄关闭，新票带原意图摘要）。本票随之关闭，如有问题请 reopen。" >/dev/null 2>&1 \
        || say "aged PR#$prn: supersede-close of issue #$n failed; new ticket #${m_n} stands"
    fi
    aged_pr_close "$prn" "$branch" "$age" "${behind:-?}" "仍需要" "原意图已按新 main 重开为 #${m_n}" "$m_n" || continue
    done_n=$((done_n + 1))
  done <<<"$rows"
  (( done_n > 0 || left > 0 )) && say "aged PR lifecycle: classified=$done_n deferred=$left"
  echo "classified=$done_n deferred=$left" > "$A/aged-prs.count"
  return 0
}
