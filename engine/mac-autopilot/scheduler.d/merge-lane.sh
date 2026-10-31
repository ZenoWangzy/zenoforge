
# 打开 PR census 的归一化：同名检查去重（--latest-checks）→ 以 PR 号为键的对象（head/draft/bucket 化的检查行与
# ci 档位）。merge_candidates 的排序输入与 start.sh 的 pin 切换自检共用这一条链，自检跑的正是合并车道要用的管线。
pr_census_by_number() { # stdin: gh pr list JSON → stdout: {"<pr>": {head,draft,checks,ci}}
  node "$HERE/../ci/pr-required-aggregate.mjs" --latest-checks | jqf 'map({key: (.number | tostring), value: {head: .headRefOid, draft: .isDraft, mergeable: .mergeable, checks: [.statusCheckRollup[]? | {name: (.name // .context // ""), link: (.detailsUrl // .targetUrl // ""), started_at: (if .__typename == "CheckRun" then (.startedAt // .started_at // null) else (.createdAt // .created_at // null) end), bucket: (if .__typename == "StatusContext" then ((.state // "" | ascii_downcase) as $s | if $s == "success" then "pass" elif ($s == "failure" or $s == "error") then "fail" else "pending" end) elif (.status // "COMPLETED") != "COMPLETED" then "pending" else ((.conclusion // "" | ascii_downcase) as $c | if $c == "success" then "pass" elif $c == "neutral" then "skipping" elif $c == "cancelled" then "cancel" elif ($c | IN("failure", "timed_out", "action_required", "startup_failure")) then "fail" else "pending" end) end)}], ci: ([.statusCheckRollup[]? | if .__typename == "StatusContext" then (.state // "" | ascii_downcase) elif (.status // "COMPLETED") != "COMPLETED" then "pending" else (.conclusion // "" | ascii_downcase) end] | if any(.[]; IN("pending", "expected", "queued", "in_progress", "waiting", "requested")) then 2 elif any(.[]; IN("failure", "error", "cancelled", "timed_out", "action_required", "startup_failure")) then 1 else 0 end)}}) | from_entries'
}
tick_pr_check_census() { # full open-PR check rows, normalized once per tick from TICK_PRS
  local prs
  if [[ -z "$TICK_PR_CHECK_CENSUS" ]]; then
    prs="$(tick_prs)" || return 1
    TICK_PR_CHECK_CENSUS="$(printf '%s' "$prs" | pr_census_by_number)" || return 1
    jqf -e 'type == "object"' <<<"$TICK_PR_CHECK_CENSUS" >/dev/null || { TICK_PR_CHECK_CENSUS=""; return 1; }
  fi
  printf '%s' "$TICK_PR_CHECK_CENSUS"
}
repair_check_rows() { # PR number → latest normalized check rows from the tick census
  local pr="$1" census checks
  census="$(tick_pr_check_census 2>/dev/null || true)"
  if [[ -n "$census" ]] && jqf -e --arg pr "$pr" 'has($pr)' <<<"$census" >/dev/null; then
    jqf -c --arg pr "$pr" '.[$pr].checks // []' <<<"$census"
    return
  fi
  checks="$(unset GH_TOKEN; gh pr checks "$pr" --json name,bucket,link 2>/dev/null)" || return 1
  node "$HERE/../ci/pr-required-aggregate.mjs" --latest-checks <<<"$checks" 2>/dev/null
}

# 队头阻塞（2026-10-21 06:42）：车道每拍只看排序后的前 BATCH_MAX*3 个就绪单元（热修、critical、最老），82 个就绪里
# 前 12 个全在等 CI 或被挡，排在 21–60 位的绿单元从来轮不到看。对 ready-to-merge PR 子集批量取检查汇总再排序：
# 还没占到 CI 名额的（本拍不可能合）排到最后；其余同档内 CI 已出结论（绿/红）的先看，还在跑的其次。
merge_candidates() { # window → 就绪单元（每行一个 JSON）
  local rf prs; rf="$(mktemp)" || return 0
  # Use the same open-PR census, but normalize checks only for ready-to-merge PRs before sorting all candidates.
  prs="$(jqf -c '[.units[] | select(.stage=="ready-to-merge" and (.hold_handoff_waiting // false) == false and (.pr // null) != null and (.lane // "") != "direct-main") | .pr | tostring] | unique' "$UNITS")"
  if [[ "$prs" == '[]' ]]; then
    printf '{}\n' > "$rf"
  else
    tick_prs | jqf --argjson prs "$prs" '[.[] | select((.number | tostring) as $n | $prs | index($n) != null)]' | pr_census_by_number > "$rf"
  fi
  jqf -e 'type == "object"' "$rf" >/dev/null 2>&1 || echo '{}' > "$rf"
  jqf -c --slurpfile r "$rf" '[.units[] | select(.stage=="ready-to-merge" and (.hold_handoff_waiting // false) == false and (.pr // null) != null and (.lane // "") != "direct-main")]
    | sort_by([(if (.ci_wip_wait != null and .ci_wip_wait == .approved_sha) then 1 else 0 end),
        (if .hotpatch == true then 0 elif .critical == true then 1 else 2 end),
        ($r[0][(.pr | tostring)].ci // 2), (.merge_checked_epoch // 0), (.ready_since // 0)])
    | .[0:'"$1"'] | map(. + {pr_open_head: ($r[0][(.pr | tostring)].head // null), pr_open_draft: $r[0][(.pr | tostring)].draft, pr_open_mergeable: $r[0][(.pr | tostring)].mergeable, pr_open_checks: ($r[0][(.pr | tostring)].checks // null)}) | .[]' "$UNITS"
  rm -f -- "$rf"
}

# 冲突的单元送修复：作废批准、留历史、给 repair 提示。合并车道两处发现冲突（checks 未齐时、合并失败后）共用；
# cause 同时进历史和日志，hint 各处自己的话（热修回迁 / 迁移编号）。
merge_conflict_to_repair() { # id pr cause repair_hint head
  local head="${5:-}" fresh files
  # GitHub 的 CONFLICTING 常是过期事实（83 个冲突修复里 8 个没有真冲突）：再问一次当前 mergeability，已无冲突就服务端
  # update-branch 一次（按 unit/head 记账，写在台账行里），批准随后由 approval_carries 沿用。锁文件与迁移 PR、更新失败、
  # 仍冲突或未知都照旧派修复。
  if [[ "$head" =~ $SHA_RE && "$(unit_field "$1" '.conflict_update_head // empty')" != "$head" ]]; then
    set_unit "$1" ".conflict_update_head=$(js "$head")" || :
    fresh="$(gh pr view "$2" --json mergeable,headRefOid --jq '"\(.mergeable) \(.headRefOid)"' 2>/dev/null)"
    if [[ "$fresh" == "MERGEABLE $head" ]]; then
      files="$(gh pr view "$2" --json files --jq '.files[].path' 2>/dev/null)"
      if [[ -n "$files" ]] && ! grep -qE '(^|/)(pnpm-lock\.yaml|package-lock\.json|yarn\.lock)$|(^|/)migrations/' <<<"$files" \
        && ci_update_branch "$2" "$head"; then
        set_unit "$1" "$(hist conflict-cleared "PR#$2 GitHub reports no conflict; update-branch at $head")"
        say "PR#$2 conflict already gone; update-branch requested at $head, approval carries on the new head"
        return 0
      fi
    fi
  fi
  set_unit "$1" "$(hist merge-conflict "PR#$2 $3") | .approved_sha=null | .repair_hint=$(js "$4") | .stage=\"repair-pending\""
  say "merge skipped PR#$2 ($3) -> repair-pending"
}

# 合入即写 awaiting-release（#4515 发布状态单一事实源）：unit 台账的 unit→issue 关系驱动，
# 不读 PR 正文。无 issue 的单元（外部 PR，关闭词由 GitHub 在合并时自动关票）无事可写。
# 写失败不回滚合入（PR 已在 main 上），告警到 alerts/merge.md 人工补 conclude_merged_run。
merge_lane_awaiting_release() { # ready-unit-json pr
  local issue
  issue="$(jqf -r '.issue // empty' <<<"$1")"
  [[ "$issue" =~ ^[1-9][0-9]*$ ]] || return 0
  if scheduler_conclude_merged_pr "$issue" "$2" >>"$LOG" 2>&1; then
    say "issue #$issue entered awaiting-release at merge of PR#$2"
  else
    echo "[$STAMP] merged PR#$2 but the awaiting-release write for issue #$issue failed; rerun conclude_merged_run #$issue $2" >> "$A/alerts/merge.md"
    say "awaiting-release write failed for issue #$issue after PR#$2 merge"
  fi
  return 0
}

# 10-29 事故：jqf 吞错后 check census 静默不可用约 2 小时，每拍只有一行不起眼的 skip。连续 2 拍
# census 缺失经 supervisor inbox 告警一次（append_once 按 episode 递增的 key 去重），恢复前不重发。
merge_census_watch() { # missed=1/0：本拍 merge lane 是否出现 check census unavailable
  local f="$A/merge-census-watch.json" streak alerted episode
  [[ -f "$f" ]] || printf '{"streak":0,"alerted":0,"episode":0}\n' > "$f"
  streak="$(jqf -r '.streak // 0' "$f")"; alerted="$(jqf -r '.alerted // 0' "$f")"; episode="$(jqf -r '.episode // 0' "$f")"
  if [[ "$1" == 1 ]]; then
    streak=$((streak + 1))
    if (( streak >= 2 && alerted == 0 )); then
      episode=$((episode + 1))
      if ( source "$SCHEDULER_AGENT_LIB" && supervisor_inbox_append_once "merge-census-down:$episode" \
        "merge-census-down check census 连续 ${streak} 拍不可用，合并车道整拍空转；根因多为上游坏 JSON，查 scheduler.log 当拍 jqf error 行" ) >/dev/null 2>&1; then
        alerted=1
      fi
    fi
  else
    streak=0; alerted=0
  fi
  jqf -cn --argjson streak "$streak" --argjson alerted "$alerted" --argjson episode "$episode" \
    '{streak:$streak,alerted:$alerted,episode:$episode}' | write_state "$f" || say "merge census watch: could not persist state"
}

run_merge_lane() {
  local merge_max eval_sha gate_run suites grid glf gnet gtest tmpnr ready id pr adoption_pr_number approved head state branch adopted_head adopt_at adopted_label pre_merge_sha merge_sha checks red fails missing_required ready_at ready_sha rule_head rule_result rule_event rule_hint rule_actor rule_ok candidate_ids cands detail_started detail_elapsed candidate_pr candidate_head candidate_ref behind_main merge_head_fetch_started merge_head_fetch_elapsed merge_head_batch_ok=false
  local -A merge_head_ref=()
  local -a merge_head_refspecs=() merge_head_refs=()
  # 所有 PR（含流水线 PR）都只由自己 head 上的必需检查把关，合并后由 main CI 验证；没有待验证批、没有合并后等裁决的 merging 态。
  # main 已完成的红裁决仍拦流水线 PR（pipe_open）；产品 PR 照旧不被脚本红拦（2026-10-20：15 个产品 PR 排队 3–22 小时）。
  local pipe_open=1 pipe_dep merged_count=0 mstate i
  MERGE_CENSUS_MISSED=0
  [[ "$(jqf -r .auto_merge <<<"$CFG")" == "true" ]] || return 0
  # fast_land_lane may advance main earlier in this tick; refresh the rule-lane and suite-gate base here.
  detail_started=$SECONDS
  if git -C "$ROOT" fetch -q origin main 2>/dev/null; then
    MAIN_HEAD="$(git -C "$ROOT" rev-parse -q --verify refs/remotes/origin/main 2>/dev/null)"
  fi
  detail_elapsed=$((SECONDS - detail_started))
  (( detail_elapsed < 2 )) || say "merge detail refresh_main=${detail_elapsed}s"
  merge_max="$(jqf -r '.batch_max // 4' <<<"$CFG")"
  [[ "$merge_max" =~ ^[1-9][0-9]*$ ]] || merge_max=4
  eval_sha=""; gate_run=""
  local candidate
  # 取候选链上最新一个「已完成」的 run；更新的 [skip ci] 直落提交只有在跑的 run 时不让产品合并干等它（直落频繁会饿死车道）。
  local first_eval="" first_run="" run
  detail_started=$SECONDS
  for candidate in $(gate_eval_sha); do
    [[ "$candidate" =~ $SHA_RE ]] || continue
    run="$(suites_run_for "$candidate")"
    [[ -n "$run" ]] || { [[ -z "$first_eval" ]] && first_eval="$candidate"; continue; }
    [[ -z "$first_eval" ]] && { first_eval="$candidate"; first_run="$run"; }
    # 被取消的 run 不是裁决（去重会取消被取代的排队 run），继续往链上找
    if [[ "$(jqf -r '.status // empty' <<<"$run")" == completed && "$(jqf -r '.conclusion // empty' <<<"$run")" != cancelled ]]; then eval_sha="$candidate"; gate_run="$run"; break; fi
  done
  [[ -n "$eval_sha" ]] || { eval_sha="$first_eval"; gate_run="$first_run"; }
  detail_elapsed=$((SECONDS - detail_started))
  (( detail_elapsed < 2 )) || say "merge detail suite_gate_lookup=${detail_elapsed}s"
  detail_started=$SECONDS
  ci_classify_run "$gate_run" "$eval_sha"
  detail_elapsed=$((SECONDS - detail_started))
  (( detail_elapsed < 2 )) || say "merge detail main_ci_classify=${detail_elapsed}s"
  suites="$(jqf -r '.conclusion // empty' <<<"$gate_run")"
  if [[ "$(jqf -r '.status // empty' <<<"$gate_run")" == completed && "$suites" == failure ]]; then
    local retry_record
    MAIN_RED_REVERTED=0; MAIN_RED_PENDING=0
    open_landed_red_unit "$eval_sha" "$CI_RUN_ID" "$CI_RUN_ATTEMPT"
    [[ "$CI_CLASS" != code ]] || main_red_attribution "$eval_sha" "$CI_RUN_ID" "$CI_RUN_ATTEMPT"
    [[ -f "$A/gate-net-rerun.json" ]] || echo '{}' > "$A/gate-net-rerun.json"
    retry_record="$(jqf -c --arg sha "$eval_sha" 'if has($sha) then .[$sha] else null end' "$A/gate-net-rerun.json" 2>/dev/null)" || retry_record='{}'
    ci_failure_retry_status "$eval_sha" "$gate_run" "$retry_record"
    if (( MAIN_RED_REVERTED )); then
      CI_REASON="$CI_REASON; culprit reverted, awaiting Pipeline suites on the revert"
    elif [[ "$CI_RETRY_ACTION" == request ]]; then
      if jqf --arg sha "$eval_sha" --argjson record "$CI_RETRY_RECORD" \
        '.[$sha]=$record' "$A/gate-net-rerun.json" | write_state "$A/gate-net-rerun.json"; then
        if gh run rerun "$CI_RUN_ID" --failed >/dev/null 2>&1; then
          CI_REASON="$CI_REASON; first-failure rerun requested (1/1), awaiting a later attempt"
        else
          CI_REASON="$CI_REASON; first-failure rerun request unconfirmed (1/1), awaiting server evidence"
        fi
      else
        CI_REASON="$CI_REASON; retry reservation failed, lane held"
      fi
    elif [[ "$CI_RETRY_ACTION" == observed && "$CI_CLASS" == code ]]; then
      if (( MAIN_RED_PENDING )); then CI_REASON="$CI_REASON; reproduction still running, main-red unit waits"
      else open_main_red_unit "$eval_sha" "$CI_RUN_ID" "$CI_RUN_ATTEMPT"; fi
    fi
  fi
  local pending_pass=0 hotpatch_pass=0
  if [[ "$CI_CLASS" == unknown ]] && jqf -e --arg sha "$eval_sha" '
      type=="object" and .headSha==$sha and ($sha | test("^[0-9a-f]{40}$"))
      and (.databaseId | type=="number" and .>0 and floor==.)
      and (.conclusion==null or .conclusion=="")
      and (.status | IN("queued", "in_progress", "waiting", "pending", "requested"))
    ' <<<"$gate_run" >/dev/null; then pending_pass=1; fi
  if [[ "$CI_CLASS" == pass ]] || (( pending_pass )); then hotpatch_pass=1; fi
  if [[ "$CI_CLASS" != pass ]] && (( ! pending_pass )); then
    gate_note "GATE class=$CI_CLASS main=${eval_sha:-unknown} run=${CI_RUN_ID:-unknown}; $CI_REASON; merge lane held for pipeline PRs; product PRs still merge"
    pipe_open=0
  elif [[ "$suites" != "success" ]] && (( pipe_open )); then
    gate_note "GATE main=${eval_sha:-unknown} run=${CI_RUN_ID:-unknown} status=$(jqf -r .status <<<"$gate_run") — pipeline PRs merge on their own checks; main CI verifies after merge"
  elif (( pipe_open )); then
    gate_note "GATE main=$eval_sha suites=success — merge lane open"
  fi

  # 候选的检查行取自 merge_candidates 那一次批量 gh pr list（census），不再逐个 gh pr checks；合并仍用 --match-head-commit 钉住 head。
  tick_prs_prime
  detail_started=$SECONDS
  cands="$(merge_candidates "$((merge_max * 3))")"
  candidate_ids="$(jqf -cs '[.[] | select(type=="object") | .id] | unique' <<<"$cands")"
  if jqf -e 'length > 0' <<<"$candidate_ids" >/dev/null; then
    units_update --argjson ids "$candidate_ids" --argjson checked "$NOW_EPOCH" \
      '.units |= map(if (.id as $id | $ids | index($id)) != null then .merge_checked_epoch=$checked else . end)' \
      || { detail_elapsed=$((SECONDS - detail_started)); (( detail_elapsed < 2 )) || say "merge detail candidate_build=${detail_elapsed}s"; say "merge lane stopped: could not record the current candidate scan"; return 0; }
  fi
  detail_elapsed=$((SECONDS - detail_started))
  (( detail_elapsed < 2 )) || say "merge detail candidate_build=${detail_elapsed}s"
  # Fetch all bounded candidate heads in one GitHub round trip. The census SHA
  # remains authoritative: if a PR moves after the census, its fetched ref will
  # not match and that candidate waits for the next pass.
  merge_head_fetch_started=$SECONDS
  while IFS=$'\t' read -r candidate_pr candidate_head; do
    [[ "$candidate_pr" =~ ^[1-9][0-9]*$ && "$candidate_head" =~ $SHA_RE ]] || continue
    candidate_ref="refs/autopi/merge-candidates/$NOW_EPOCH/$candidate_pr"
    merge_head_ref["$candidate_pr"]="$candidate_ref"
    merge_head_refs+=("$candidate_ref")
    merge_head_refspecs+=("+refs/pull/$candidate_pr/head:$candidate_ref")
  done < <(jqf -sr '.[] | select((.pr | type) == "number" and (.pr_open_head | type) == "string") | [.pr,.pr_open_head] | @tsv' <<<"$cands")
  if (( ${#merge_head_refspecs[@]} > 0 )) \
      && git -C "$ROOT" fetch -q --no-tags origin "${merge_head_refspecs[@]}" 2>/dev/null; then
    merge_head_batch_ok=true
  elif (( ${#merge_head_refspecs[@]} > 0 )); then
    say "merge candidate head batch fetch incomplete; validating candidates individually"
  fi
  merge_head_fetch_elapsed=$((SECONDS - merge_head_fetch_started))
  (( merge_head_fetch_elapsed < 2 )) || say "merge detail candidate_head_fetch=${merge_head_fetch_elapsed}s"
  detail_started=$SECONDS
  while IFS= read -r ready; do
    [[ -z "$ready" || "$ready" == "null" ]] && break
    tick_prs_prime
    id="$(jqf -r .id <<<"$ready")"; pr="$(jqf -r .pr <<<"$ready")"
    checks="$(jqf -c '.pr_open_checks // null' <<<"$ready")"
    if [[ "$checks" == null && "${TICK_PR_STATE[$pr]:-}" != MERGED && "${TICK_PR_STATE[$pr]:-}" != CLOSED ]]; then
      say "merge skipped PR#$pr (check census unavailable)"
      MERGE_CENSUS_MISSED=1
      continue
    fi
    # Fair bounded scans rotate past repeatedly blocked candidates; their scan time was written as one ledger update above.
    approved="$(jqf -r '.approved_sha // empty' <<<"$ready")"
    head="$(jqf -r '.pr_open_head // empty' <<<"$ready")"
    if [[ "$head" =~ $SHA_RE ]]; then
      state=OPEN
    elif [[ -n "${TICK_PR_STATE[$pr]:-}" ]]; then
      state="${TICK_PR_STATE[$pr]}"
    else
      state="$(pr_view "$pr" state)"
      [[ -n "$state" ]] && TICK_PR_STATE["$pr"]="$state"
    fi
    if [[ "$state" == "MERGED" || "$state" == "CLOSED" ]]; then
      [[ "$state" == MERGED ]] && state=merged || state=closed
      set_unit "$id" "$(hist pr-"$state" "outside the merge lane") | .stage=\"$state\""
      say "unit=$id PR#$pr already $state; left the merge lane"
      continue
    fi
    if ! jqf -e '(.stacked_on == null) or (.stacked_on_released == true)' <<<"$ready" >/dev/null; then
      say "merge skipped PR#$pr (stacked predecessor has not completed its release cycle)"
      continue
    fi
    if [[ -n "${READIED_PRS[$pr]:-}" ]]; then say "merge skipped PR#$pr (readied this pass; CI starts now)"; continue; fi
    [[ "$head" =~ $SHA_RE ]] || head="$(pr_view "$pr" headRefOid)"
    # 先沿用批准再跳过 draft：slot_sync 的 update-branch 会换 draft 的 head，不沿用的话 gated_ready 永远不 ready 它
    if [[ "$approved" =~ $SHA_RE && "$head" =~ $SHA_RE && "$head" != "$approved" ]] && approval_carries "$pr" "$approved" "$head"; then
      set_unit "$id" "$(hist approval-carried "clean main merge $head on approved $approved") | .approved_sha=$(js "$head")"
      say "approval carried PR#$pr $approved -> $head (clean update-branch merge)"
      post_approved_status "$id" "$head"
      approved="$head"
    fi
    if [[ "$(jqf -r '.pr_open_draft // false' <<<"$ready")" == true ]]; then say "merge skipped PR#$pr (draft, waiting for its CI slot)"; continue; fi
    if [[ ! "$head" =~ $SHA_RE ]]; then say "merge skipped PR#$pr (head unreadable; unit left unchanged)"; continue; fi
    if [[ ! "$approved" =~ $SHA_RE || "$head" != "$approved" ]]; then
      # 批准绑定的 head 已变（或旧台账无绑定）：新提交必须先评审，不能带着旧批准合并。
      set_unit "$id" "$(hist approval-stale "approved=${approved:-none} head=${head:-unknown}") | .stage=\"rereview-pending\""
      say "merge skipped PR#$pr (head ${head:-unknown} != approved ${approved:-none}) -> rereview-pending"
      continue
    fi
    # #4484：非 agent 分支的接管 PR，重活 job 的 if 只认 agent/issue- 前缀或 pipeline-ci 标签，不打标签
    # 就永远拿不到必需检查。首次接管确保产生 labeled 事件并记录时间下限；已有同名标签时先移除再加回，
    # 因为 gh pr edit --add-label 对已有标签是 no-op，不会启动 policy 与重活检查。之后新 head 的
    # synchronize/update-branch 事件已开 CI，沿用原下限，避免把已经启动的检查误判为过期。
    branch="$(jqf -r '.branch // empty' <<<"$ready")"
    adopted_head="$(unit_field "$id" '.ci_adopt_head // empty')"
    adopt_at="$(unit_field "$id" '.ci_adopt_at // empty')"
    if [[ -n "$branch" && ! "$branch" =~ $GATED_BRANCH_RE && "$adopted_head" != "$head" ]]; then
      if [[ -n "$adopt_at" ]]; then
        # The label already triggered CI for the prior head; synchronize/update-branch started
        # fresh checks for this head. Keep the original floor rather than resetting it after
        # those runs have already started.
        set_unit "$id" ".ci_adopt_head=$(js "$head")"
        say "adopt PR#$pr: $PIPELINE_CI_LABEL retained for new head; synchronize CI supplies fresh checks"
      else
        ensure_pipeline_ci_label
        adoption_pr_number="$pr"
        adopted_label="$(tick_prs | jqf -r --arg pr "$adoption_pr_number" --arg label "$PIPELINE_CI_LABEL" '[.[] | select((.number | tostring) == $pr) | .labels[]?.name] | any(.[]; . == $label)')"
        if tick_prs_changed \
          && { [[ "$adopted_label" != true ]] || gh pr edit "$pr" --remove-label "$PIPELINE_CI_LABEL" >/dev/null 2>&1; } \
          && gh pr edit "$pr" --add-label "$PIPELINE_CI_LABEL" >/dev/null 2>&1; then
          set_unit "$id" "$(hist ci-adopt "non-agent branch gets a fresh $PIPELINE_CI_LABEL labeled event; heavy PR CI starts") | .ci_adopt_head=$(js "$head") | .ci_adopt_at=$(js "$STAMP")"
          say "adopt PR#$pr: $PIPELINE_CI_LABEL label event started branch policy and heavy gates"
        else
          say "merge skipped PR#$pr ($PIPELINE_CI_LABEL label event setup failed; retried next pass)"
        fi
      fi
      continue
    fi
    [[ "$checks" != null && -n "$checks" ]] || { say "merge skipped PR#$pr (check census unavailable)"; MERGE_CENSUS_MISSED=1; continue; }
    fails="$(jqf -r '[.[] | select(.bucket == "fail") | .name] | sort | join(",")' <<<"$checks" 2>/dev/null || true)"
    if [[ -n "$fails" && "$(jqf -r '.ci_test_checked // empty' <<<"$ready")" != "$head:$fails" ]]; then
      set_unit "$id" ".ci_test_checked=$(js "$head:$fails")"
      red_out="$(ci_test_red_checks "$checks")"
      red="$(head -n1 <<<"$red_out")"; red_facts="$(tail -n +2 <<<"$red_out")"
      if [[ -n "$red" ]]; then
        if ci_stale_base_hop "$id" "$pr" "$head" "$red_facts"; then continue; fi
        set_unit "$id" ".ci_facts_head=$(js "$head") | .ci_facts=$(js "$red_facts")"
        say "triage PR#$pr head ${head:0:9}: $(ci_triage "$head" "$red_facts") (verdict only; routing unchanged)"
        cancel_branch_runs "$(jqf -r '.branch // empty' <<<"$ready")" "tests already red; repair pushes a new head"
        set_unit "$id" "$(hist ci-test-red "$red") | .approved_sha=null | .repair_hint=$(js "PR head $head 的必需检查已有测试失败：${red}。用 gh pr checks $pr 与失败 job 日志定位；失败的是集成测试就先在本机测试库复现（RUN_INTEGRATION=1 npx vitest run <文件>，PGTEST_URL 已配好），修到本地绿再 push；本 PR 引起的就修并补回归测试；确属与本 PR 无关的环境故障就不改代码，在报告里写明证据。$(ci_fact_hint "$head" "$red_facts")") | .stage=\"repair-pending\""
        say "merge skipped PR#$pr (tests failed in: $red) -> repair-pending without waiting for the other checks or a rerun"
        continue
      fi
    fi
    if ! jqf -e 'length > 0 and all(.[]; .bucket != "pending")' <<<"$checks" >/dev/null; then
      # 冲突的 PR GitHub 不跑 pull_request CI，checks 永远 pending；以前只在合并失败后才查冲突，于是永远等下去
      # （2026-10-20 热修回迁 pr-3588 已批准却 CONFLICTING）。checks 未齐时先看是否冲突，冲突就派修复合 main。
      candidate_ref="${merge_head_ref[$pr]:-}"
      if [[ "$merge_head_batch_ok" == true && -n "$candidate_ref" ]]; then
        candidate_head="$(git -C "$ROOT" rev-parse --verify "${candidate_ref}^{commit}" 2>/dev/null || true)"
        [[ "$candidate_head" == "$head" ]] || { say "merge skipped PR#$pr (head moved after census)"; continue; }
        state="$(jqf -r '.pr_open_mergeable // empty' <<<"$ready")"
      else
        state="$(tick_pr_mergeable "$pr")"
      fi
      if [[ "$state" == CONFLICTING ]]; then
        merge_conflict_to_repair "$id" "$pr" "conflicts with main; CI cannot start" "PR 与最新 main 冲突，GitHub 不会跑 CI 也拒绝合并。git merge --no-edit origin/main，按两边意图解决冲突（热修回迁以生产已验证行为为准），跑受影响测试，推送。" "$head"
        continue
      fi
      say "merge skipped PR#$pr (checks pending or unavailable)"
      continue
    fi
    red="$(jqf -r '[.[] | select(.bucket=="fail" or .bucket=="cancel") | .name] | unique | join(", ")' <<<"$checks")"
    if [[ -n "$red" ]]; then
      if jqf -e 'any(.[]; .bucket == "fail")' <<<"$checks" >/dev/null; then
        if ci_cancelled_upstream "$checks"; then
          if [[ "$(unit_field "$id" '.ci_wip_wait // empty')" == "$head" ]]; then say "merge skipped PR#$pr (CI waits for a WIP slot)"
          else ci_cancelled "$id" "$pr" "$head" "$red" upstream; fi
        else ci_red "$id" "$pr" "$head" "$red"; fi
      elif [[ "$(unit_field "$id" '.ci_wip_wait // empty')" == "$head" ]]; then say "merge skipped PR#$pr (CI waits for a WIP slot)"
      else ci_cancelled "$id" "$pr" "$head" "$red"; fi
      continue
    fi
    if [[ "$(jqf -r '.gated // false' <<<"$ready")" == true ]]; then
      ready_at="$(jqf -r '.ci_ready_at // empty' <<<"$ready")"
      ready_sha="$(jqf -r '.ci_ready_sha // empty' <<<"$ready")"
      if [[ -z "$ready_at" || "$ready_sha" != "$head" ]]; then
        say "merge skipped PR#$pr (ready_for_review evidence missing for approved head)"
        continue
      fi
      missing_required="$(required_checks_without_pass "$checks" "$ready_at")"
    else
      # #4484：接管（打 pipeline-ci 标签）前的旧绿行不算数，时间下限同门控 ready_for_review 语义；
      # 标签留在 PR 上，所以后续 synchronize/update-branch 已触发同一批检查；保留首次 labeled 时间下限。
      adopt_at="$(jqf -r '.ci_adopt_at // empty' <<<"$ready")"
      missing_required="$(required_checks_without_pass "$checks" "$adopt_at")"
    fi
    if [[ -n "$missing_required" ]]; then
      # #4484：聚合 job 定义在分支自带的 workflow 里，先于它创建的分支永远没有这一行。不是无限等：
      # 落后 main 且干净就服务端 update-branch（新 head 带上聚合 job 与 label 条件，批准由
      # approval_carries 沿用），冲突照旧派修复合 main；只在真正转移时记账，每个 head 一次，
      # 转不动的由 ready-to-merge SLO 升级。
      behind_main=false
      candidate_ref="${merge_head_ref[$pr]:-}"
      if [[ "$merge_head_batch_ok" == true && -n "$candidate_ref" ]]; then
        candidate_head="$(git -C "$ROOT" rev-parse --verify "${candidate_ref}^{commit}" 2>/dev/null || true)"
        if [[ "$candidate_head" == "$head" && -n "$MAIN_HEAD" ]] \
            && ! git -C "$ROOT" merge-base --is-ancestor "$MAIN_HEAD" "$head" 2>/dev/null; then
          behind_main=true
        fi
        state="$(jqf -r '.pr_open_mergeable // empty' <<<"$ready")"
      elif pr_behind_main "$pr" "$head"; then
        behind_main=true
        state="$(tick_pr_mergeable "$pr")"
      fi
      if [[ "$(unit_field "$id" '.ci_sync_head // empty')" != "$head" && "$behind_main" == true ]]; then
        if [[ "$state" == MERGEABLE ]] && ci_update_branch "$pr" "$head"; then
          set_unit "$id" "$(hist ci-sync-update-branch "required checks missing: $missing_required") | .ci_sync_head=$(js "$head")"
          say "merge skipped PR#$pr (required checks without a real pass: $missing_required) -> update-branch refreshes the branch workflows"
          continue
        fi
        if [[ "$state" == CONFLICTING ]]; then
          set_unit "$id" ".ci_sync_head=$(js "$head")"
          merge_conflict_to_repair "$id" "$pr" "required checks never ran; branch conflicts with main" "PR 长期拿不到必需检查且与最新 main 冲突。git merge --no-edit origin/main，按两边意图解决冲突，跑受影响测试，推送。" "$head"
          continue
        fi
      fi
      say "merge skipped PR#$pr (required checks without a real pass: $missing_required)"
      continue
    fi
    pipe_dep=0
    jqf -e 'any(.[]; .name | startswith("Pipeline suites") or . == "Select pipeline-suite scope")' <<<"$checks" >/dev/null && pipe_dep=1
    if (( pipe_dep && ! pipe_open )); then
      if (( hotpatch_pass )) && [[ "$(jqf -r '.hotpatch // false' <<<"$ready")" == true ]]; then
        say "merge PR#$pr hot patch while main suites are pending (not red)"
      else
        say "merge skipped PR#$pr (touches pipeline paths; pipeline merges held)"; continue
      fi
    fi
    # 先取当前 PR ref 并确认它仍是刚才审核/批准的 head，再对这个固定 SHA 执行同一规则判定（#4548 CTO 裁决
    # 2026-10-29）：原样复用 rule-lane.sh，actor 与 direct-main 同源取合并身份——supervisor 起拍
    # （ZF_AGENT_NAME=supervisor）时非 unit 分支的 PR 走规则通道，按 2026-10-31 裁决做语法检查；
    # unit worker 的分支（agent/issue-*、agent/auto-issue-*、factory/*、hand/*）无论环境一律按 unit 判定，
    # 改到规则文件即拒、PR 留修复说明并转 supervisor 队列。
    candidate_ref="${merge_head_ref[$pr]:-}"
    if [[ -z "$candidate_ref" ]]; then
      say "merge skipped PR#$pr (rule diff unavailable)"
      continue
    fi
    if [[ "$merge_head_batch_ok" != true ]] \
        && ! git -C "$ROOT" fetch -q --no-tags origin "+refs/pull/$pr/head:$candidate_ref" 2>/dev/null; then
      say "merge skipped PR#$pr (rule diff unavailable)"
      continue
    fi
    rule_head="$(git -C "$ROOT" rev-parse --verify "$candidate_ref^{commit}" 2>/dev/null || true)"
    if [[ "$rule_head" != "$head" ]]; then
      say "merge skipped PR#$pr (rule diff head moved)"
      continue
    fi
    case "$branch" in
      agent/issue-*|agent/auto-issue-*|factory/*|hand/*) rule_actor="unit:${branch}" ;;
      *) rule_actor="${ZF_AGENT_NAME:-unit}" ;;
    esac
    if rule_result="$(cd "$ROOT" && ZF_AGENT_NAME="$rule_actor" bash "${ZF_ENGINE_DIR:-$ROOT/engine}/rule-lane.sh" "$MAIN_HEAD" "$rule_head" 2>&1)"; then
      rule_ok=1
    else
      rule_ok=0
    fi
    rule_event="${rule_result%%$'\n'*}"
    if [[ "$rule_event" != rule-lane:\ decision=* ]]; then
      say "merge skipped PR#$pr (rule lane unavailable: ${rule_event:-no result})"
      continue
    fi
    say "$rule_event"
    if (( ! rule_ok )); then
      if [[ "$rule_event" == *decision=unit-reject* ]]; then
        if [[ "$(unit_field "$id" '.rule_lane_commented_sha // empty')" != "$head" ]]; then
          rule_hint="${rule_result#*$'\n'}"
          rule_hint="${rule_hint#rule-lane: }"
          if gh pr comment "$pr" --body "$rule_hint" >/dev/null 2>&1; then
            set_unit "$id" ".rule_lane_commented_sha=$(js "$head")" \
              || say "rule-lane: could not record repair comment PR#$pr head=${head:0:12}"
          else
            say "rule-lane: repair comment failed PR#$pr head=${head:0:12}"
          fi
        fi
        to_supervisor "$id" "PR#$pr 改到规则文件（${rule_event#*files=}）：unit 不能合入规则改动，转 supervisor 规则通道处理"
      elif [[ "$rule_event" == *decision=rule-reject* ]]; then
        say "merge skipped PR#$pr (rule lane rejected the syntax check)"
      else
        say "merge skipped PR#$pr (rule lane failed)"
      fi
      continue
    fi
    pre_merge_sha="$(git -C "$ROOT" ls-remote origin refs/heads/main 2>/dev/null | awk 'NR==1 {print $1}')"
    # main may advance while PR checks run or another lane lands; exact-head PR checks gate the merge,
    # and post-merge exact-SHA CI verifies the resulting main commit without a stable-main barrier.
    if [[ "$pre_merge_sha" =~ $SHA_RE ]]; then
      tick_prs_changed
      if gh pr merge "$pr" --squash --match-head-commit "$approved" >/dev/null 2>&1; then
        merge_sha="$(gh pr view "$pr" --json mergeCommit --jq '.mergeCommit.oid // empty' 2>/dev/null)"
        [[ "$merge_sha" =~ $SHA_RE ]] || merge_sha=""
        if [[ -n "$merge_sha" ]]; then
          set_unit "$id" "$(hist merged "merged on green PR CI; main CI verifies $merge_sha") | (.stage=\"merged\") | .merge_sha=\"$merge_sha\" | .pre_merge_sha=\"$pre_merge_sha\""
          merge_lane_awaiting_release "$ready" "$pr"
          merged_count=$((merged_count + 1))
          say "merged PR#$pr merge=$merge_sha (own checks green; main CI verifies)"
          (( merged_count >= merge_max )) && break
          continue
        fi
        set_unit "$id" "$(hist merged "merged on green PR CI; mergeCommit SHA unavailable") | (.stage=\"merged\")"
        merge_lane_awaiting_release "$ready" "$pr"
        echo "[$STAMP] merged PR#$pr but mergeCommit SHA unavailable; unit=$id marked merged, main CI covers it" >> "$A/alerts/merge.md"
        break
      elif mstate="$(pr_view "$pr" mergeable)"; for i in 1 2 3; do [[ "$mstate" == UNKNOWN ]] || break; sleep 2; mstate="$(pr_view "$pr" mergeable)"; done; [[ "$mstate" == CONFLICTING ]]; then
        # GitHub 合并失败后 mergeable 常短暂为 UNKNOWN：以前当成"squash 失败"每拍空试（#3885/#3860 又空转 10+ 小时）
        # 冲突不会自己消失：以前每拍空试 merge（#3885/#3860 空转数小时），现在直接派修复合 main。
        merge_conflict_to_repair "$id" "$pr" "conflicts with main" "PR 与最新 main 冲突，GitHub 拒绝合并。git merge --no-edit origin/main，按两边意图解决冲突（迁移编号顺延到 main 之后），跑受影响测试后 push。" "$head"
      else
        say "merge skipped PR#$pr (synchronous squash merge failed)"
      fi
    else
      say "merge skipped PR#$pr (pre-merge main SHA unavailable)"
    fi
  done <<<"$cands"
  merge_census_watch "$MERGE_CENSUS_MISSED"
  detail_elapsed=$((SECONDS - detail_started))
  (( detail_elapsed < 2 )) || say "merge detail candidate_pass=${detail_elapsed}s"
  detail_started=$SECONDS
  retry_blocked_units
  detail_elapsed=$((SECONDS - detail_started))
  (( detail_elapsed < 2 )) || say "merge detail blocked_pr_recheck=${detail_elapsed}s"
  for candidate_ref in "${merge_head_refs[@]}"; do
    git -C "$ROOT" update-ref -d "$candidate_ref" 2>/dev/null || :
  done
}
