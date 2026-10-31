
dispatch_pending() {
  local local_refill="${1:-false}" u id stage rounds total since allowed branch title pr_num rep wt prompt failure sha pr_head target prev_sha prev_pr_head prev_report task lane hint deliver issue key subject prless stack_branch stack_sha resume_branch resume_sha decision budget hold_cli handoff_status handoff_original budget_started budget_elapsed escalate_started step_started step_elapsed plan_started plan_elapsed
  local TICK_DISPATCH_PENDING_ACTIVE=true
  # Load the open-PR census in this shell: $(tick_prs) in a subshell cannot cache it, so every lookup re-ran the 300-PR list.
  tick_prs >/dev/null 2>&1 || true
  TICK_DISPATCH_LOCAL_REFILL="$local_refill"
  if [[ "$local_refill" != true ]] && declare -F advisor_harvest >/dev/null; then
    step_started=$SECONDS
    advisor_harvest
    step_elapsed=$((SECONDS - step_started))
    (( step_elapsed < 2 )) || say "dispatch detail advisor_harvest secs=${step_elapsed}s"
  fi
  while read -r u; do
    id="$(jqf -r .id <<<"$u")"; stage="$(jqf -r .stage <<<"$u")"
    # The independent refill controller only starts implementation workers from local ledger data.
    # Repair, review, rerun, and supervisor transitions need GitHub or a slower gate and stay on the slow tick.
    [[ "$local_refill" != true || "$stage" == implement-pending ]] || continue
    [[ "$(jqf -r '.hold_handoff_waiting // false' <<<"$u")" != false ]] && continue
    [[ -n "$(jqf -r '.advisor_pid // empty' <<<"$u")" ]] && continue
    if [[ "$(jqf -r '.self_fix_pending // false' <<<"$u")" == true ]]; then
      [[ "$local_refill" != true ]] || continue
      self_fix_dispatch "$u" || true
      continue
    fi
    # 止损预算（#4363）：第 4 轮（implement 加 repair）或超 4h 墙钟不再派发——
    # 原票经 hold.sh（on-hold 的唯一写入口，带 24h 过期的 durable hold 记录）自动搁置并评论附原因，
    # 单元转 supervisor（#4369 terra 裁决）；裁决后重新给满额度。
    if [[ "$stage" == implement-pending || "$stage" == repair-pending ]]; then
      budget_started=$SECONDS
      budget="$(ticket_budget_reason "$u")"
      budget_elapsed=$((SECONDS - budget_started))
      (( budget_elapsed < 2 )) || say "dispatch detail stop_loss_check unit=$id secs=${budget_elapsed}s"
      if [[ -n "$budget" ]]; then
        escalate_started=$SECONDS
        [[ "$local_refill" != true ]] || continue
        issue="$(jqf -r '.issue // empty' <<<"$u")"
        pr="$(jqf -r '.pr // empty' <<<"$u")"
        if [[ "$issue" =~ ^[0-9]+$ && -z "$pr" ]]; then
          supervisor_budget_recut "$id" "ticket stop-loss budget: $budget"
          (( SECONDS - escalate_started < 2 )) || say "dispatch detail stop_loss_escalate unit=$id secs=$((SECONDS - escalate_started))s"
          continue
        fi
        if [[ -n "$issue" ]]; then
          hold_cli="${ZF_ENGINE_DIR:-$ROOT/engine}/hold.sh"
          [[ -r "$hold_cli" ]] || hold_cli="$HERE/../hold.sh"
          bash "$hold_cli" --hold "$issue" --holder scheduler-stop-loss \
            --release 'supervisor rules on the stop-loss escalation; requeue or approve refills the budget' \
            --expires 24h --kind stop-loss >/dev/null 2>&1 || true
          gh issue comment "$issue" --body "止损预算（#4363）：这张票自最近一次裁决起已用 ${budget}，自动搁置（on-hold，24h 后未裁决自动恢复），停止下一轮自动派发。单元 $id 已转 supervisor 裁决；supervisor requeue/approve 后预算重新给满。" >/dev/null 2>&1 || true
        fi
        to_supervisor "$id" "stop-loss: $budget since the last supervisor ruling; the issue is held on-hold" \
          'Held at the per-ticket stop-loss budget; supervisor decides rescope, split, or requeue' \
          'the per-ticket round and wall-clock budget was reached' \
          "budget of $TICKET_ROUND_BUDGET rounds (implement+repair) or $((TICKET_WALL_BUDGET_SECONDS / 60)) minutes exceeded: $budget" \
          '["Dispatch another implement/repair round at the same scope"]'
        (( SECONDS - escalate_started < 2 )) || say "dispatch detail stop_loss_escalate unit=$id secs=$((SECONDS - escalate_started))s"
        continue
      fi
    fi
    if [[ "$stage" == repair-pending || "$stage" == rereview-pending ]]; then
      total="$(jqf -r '[(.history // [])[] | select(.stage=="review-request-changes")] | length' <<<"$u")"
      # 顾问裁决或仲裁评审之后重新数打回：从那次事件起算满 ADVISOR_ROUNDS 次才再问。
      # advisor-retry 是 wedge 重试的待重问状态：打回仍是最近一次实质事件，直接原位重试（每轮一次，见 advisor_harvest）。
      since="$(jqf -r '(.history // []) as $h | ([$h | to_entries[] | select(.value.stage | IN("advisor-ruling","arbiter-review")) | .key] | max // -1) as $i | [$h[($i + 1):][] | select(.stage=="review-request-changes")] | length' <<<"$u")"
      if [[ "$stage" == repair-pending ]] && (( since >= ADVISOR_ROUNDS )) && (( total > $(jqf -r '.advisor_round // 0' <<<"$u") )) \
        && [[ "$(jqf -r 'if .advisor == false then "off" else "on" end' <<<"$CFG")" == on ]] && [[ "$(jqf -r '.history[-1].stage // ""' <<<"$u")" =~ ^(review-request-changes|advisor-retry)$ ]]; then
        jqf -e 'any(.units[]; .advisor_pid != null)' "$UNITS" >/dev/null || advisor_launch "$u" "$total"
        continue
      fi
      allowed="$(jqf -r --argjson d "$LOOP_TOTAL_ROUNDS" '.loop_total_allowed // $d' <<<"$u")"
      if (( total >= allowed )); then
        # 不收敛不是再修一轮能解决的：交 supervisor 拆票或重定范围；裁决后再给 4 轮额度。
        set_unit "$id" ".loop_total_allowed=$((total + 4))"
        to_supervisor "$id" "non-converging: $total request-changes rounds in total; re-scope or split the issue instead of another repair" \
          'Request supervisor rescope or split' 'the lifetime review-rejection allowance was reached' \
          "$total request-changes rounds; lifetime allowance $allowed" '["Dispatch another repair without rescoping"]'
        continue
      fi
    fi
    rounds="$(loop_rounds "$u")"
    if [[ "${rounds:-0}" =~ ^[0-9]+$ ]] && (( rounds >= LOOP_BREAKER_ROUNDS )); then
      [[ "$local_refill" != true ]] || continue
      # 先给一次仲裁评审（全新视角、只认阻断级）；仲裁后仍不收敛才转人工。
      if (( $(jqf -r '[(.history // [])[] | select(.stage=="arbiter-review")] | length' <<<"$u") == 0 )); then
        decision="$(decision_entry 'Route to one arbiter review' 'review loop reached breaker threshold' "$rounds failed rounds; no prior arbiter review" '["Dispatch another ordinary repair"]' scheduler)"
        set_unit "$id" "$(hist arbiter-review "loop-breaker: $rounds failed rounds" "$decision") | .arbiter=true | .reviewed_sha=null | .reviewed_pr_head=null | .stage=\"review-pending\""
        say "loop-breaker unit=$id: $rounds rounds -> one arbiter review"
      else
        to_supervisor "$id" "loop-breaker: $rounds failed rounds after an arbiter review" \
          'Stop automated repair and escalate to supervisor' 'loop breaker reached again after one arbiter review' \
          "$rounds failed rounds after an arbiter review" '["Dispatch another repair or arbiter review"]'
      fi
      continue
    fi
    title="$(jqf -r '.title // ""' <<<"$u")"; pr_num="$(jqf -r '.pr // empty' <<<"$u")"
    issue="$(jqf -r '.issue // empty' <<<"$u")"; lane="$(jqf -r '.lane // empty' <<<"$u")"
    key="${pr_num:-$id}"; subject="$(subject_of "$pr_num" "$issue")"
    prless=0; [[ -z "$pr_num" && "$lane" == direct-main ]] && prless=1
    case "$stage" in
      repair-pending)
        [[ -n "$pr_num" || "$prless" == 1 ]] || { to_supervisor "$id" "repair-pending without a PR"; continue; }
        if [[ -n "$(jqf -r '.hold_handoff_episode // empty' <<<"$u")" ]] && park_if_body_blocked "$u"; then
          [[ "$(unit_field "$id" .stage)" != blocked-external ]] || set_unit "$id" '.blocked_resume_stage="repair-pending"'
          continue
        fi
        room_for "$id" repair "$u" false || continue
        pick implement "$u" || continue
        branch="$(jqf -r '.branch // empty' <<<"$u")"
        if [[ -z "$branch" && -n "$pr_num" ]]; then
          branch="$(tick_pr_branch "$pr_num")"
          [[ -n "$branch" ]] && set_unit "$id" ".branch=$(js "$branch")"
        fi
        [[ -n "$branch" ]] || { say "repair-pending unit=$id: PR branch unavailable"; continue; }
        footprint_room "$id" "$u" true || continue
        wt=""
        if [[ "$pr_num" =~ ^[0-9]+$ && "$lane" != direct-main ]]; then
          wt="$(pre_dispatch_pr_admission "$id" "$branch" "$pr_num" "repair-pending before dispatch")" || continue
        fi
        prev_report="$(jqf -r '.review_report // empty' <<<"$u")"
        [[ -n "$prev_report" ]] || prev_report="$(cd "$SUP" && ls -t "review-${key}-"*.md 2>/dev/null | grep -v worker | head -1)"
        [[ -n "$prev_report" || -n "$(jqf -r '.repair_hint // empty' <<<"$u")" ]] || { to_supervisor "$id" "repair-pending without a review report"; continue; }
        handoff_original=""
        if [[ -n "$pr_num" ]] && { [[ -n "$(jqf -r '.handoff_worktree_sha // empty' <<<"$u")" && "$(jqf -r '.handoff_worktree_applied // false' <<<"$u")" != true ]] || [[ -n "$(jqf -r '.handoff_start_ref // empty' <<<"$u")" && "$(jqf -r '.handoff_start_applied // false' <<<"$u")" != true ]]; }; then
          handoff_original="$(tick_pr_head "$pr_num")" || continue
          [[ "$handoff_original" =~ $SHA_RE ]] || continue
        fi
        if [[ -n "$(jqf -r '.handoff_worktree_sha // empty' <<<"$u")" && "$(jqf -r '.handoff_worktree_applied // false' <<<"$u")" != true ]]; then
          handoff_status=0
          wt="$(handoff_worktree_clone "$id" "$branch" "$(jqf -r '.handoff_worktree // empty' <<<"$u")" "$(jqf -r '.handoff_worktree_sha' <<<"$u")" "$(jqf -r '.handoff_worktree_dirty // false' <<<"$u")" "$((1 - prless))" "$(jqf -r '.handoff_start_ref // empty' <<<"$u")" "$(jqf -r '.handoff_start_sha // empty' <<<"$u")" "$(jqf -r 'if .stacked_on_released == true then empty else .stacked_on_branch // empty end' <<<"$u")" "$(jqf -r 'if .stacked_on_released == true then empty else .stacked_on_sha // empty end' <<<"$u")")" || handoff_status=$?
          if (( handoff_status != 0 )); then
            if (( handoff_status == 73 )); then to_supervisor "$id" "handoff conflicts with the existing branch; inspect the preserved owner worktree and PR"; else say "repair-pending unit=$id: previous worktree unavailable"; fi
            continue
          fi
          record_handoff_integration "$id" "$wt" "$handoff_original" || continue
        elif [[ -n "$(jqf -r '.handoff_start_ref // empty' <<<"$u")" && "$(jqf -r '.handoff_start_applied // false' <<<"$u")" != true ]]; then
          handoff_status=0
          wt="$(handoff_worktree_clone "$id" "$branch" "" "$(jqf -r '.handoff_start_sha' <<<"$u")" false "$((1 - prless))" "$(jqf -r '.handoff_start_ref' <<<"$u")" "$(jqf -r '.handoff_start_sha' <<<"$u")" "$(jqf -r 'if .stacked_on_released == true then empty else .stacked_on_branch // empty end' <<<"$u")" "$(jqf -r 'if .stacked_on_released == true then empty else .stacked_on_sha // empty end' <<<"$u")")" || handoff_status=$?
          if (( handoff_status != 0 )); then
            if (( handoff_status == 73 )); then to_supervisor "$id" "rescued handoff conflicts with the existing branch; inspect the preserved rescue and PR"; else say "repair-pending unit=$id: rescued ref unavailable"; fi
            continue
          fi
          record_handoff_integration "$id" "$wt" "$handoff_original" || continue
        else
          if [[ -z "$wt" ]]; then
            wt="$(ensure_clone "$id" "$branch" "$((1 - prless))" "$([[ -n "$pr_num" ]] && tick_pr_head "$pr_num")")" || { say "repair-pending unit=$id: clone/branch $branch unavailable"; continue; }
          fi
        fi
        resume_handoff_integration "$id" "$wt" || continue
        rep="impl-${key}-fix-${TAG}.md"
        failure="$(repair_failure_prompt "$u" "$prev_report")" || { to_supervisor "$id" "repair-pending: cannot read the failure evidence ($prev_report)"; continue; }
        hint="$(jqf -r '.repair_hint // empty' <<<"$u")"
        [[ -n "$hint" ]] && hint="
本轮额外阻断（优先处理；评审报告若已 READY，只需处理这一条）：$hint"
        if [[ "$lane" == direct-main ]]; then
          deliver="node scripts/branch-delivery-preflight.mjs --mode commit 通过后在本地分支 ${branch} 提交即可，【不要 push】：这是非产品快车道，复审通过后流水线会把它压成一个提交经 land-direct-main.sh 直落 main。提交信息不要带 [skip ci]。"
        else
          deliver="node scripts/branch-delivery-preflight.mjs --mode push --publish-topic 通过后 push 到 origin ${branch}（绝不推 main、不 force）。"
        fi
        prompt="你是 the product 流水线的实现 subagent，修复 ${subject} 的评审阻断发现。当前目录是隔离 clone：${wt}（分支 ${branch}，已同步 origin）。
$(matt_method_rule "$wt")
0. 先看 git stash list：若有「autopilot: kept before redispatch」，那是上一轮未推送的修复，先 git stash pop 恢复并在其基础上继续。
0b. 先合入最新 main：git merge --no-edit origin/main（不 rebase、不 force；有冲突按两边意图解决）。push preflight 的 freshness 门禁拒绝落后 main 过多的分支，不合就永远推不上。
1. 读评审报告 $SUP/${prev_report}，逐条处理其中的阻断发现（${title}）。不得为凑绿弱化断言。按缺陷类别修，不按单点修：每条发现先归纳成一类问题（例：单位码被显示名覆盖、幂等键缺字段），在本 PR 全部改动里搜出同类位置一并处理，每一类补一条回归测试；只修被点名的那一行，下一轮评审会在同类的另一处再打回。${hint}
1b. 修复报告必须按 $REVIEW_CONTRACT_MD 中的 author-disposition schema，为上一轮每个 finding ID 记录处置和一行理由；复审会从单元历史读取这些处置。
2. 补/改回归测试，定向跑受影响测试与 typecheck 全绿。${INTEGRATION_RULE}
3. ${deliver}
   若本地分支已有上一轮未推送的提交（git log origin/${branch}..HEAD 非空），在其基础上继续，不要重做。
4. 禁止：动主 checkout、合并 PR（gh pr merge）、改 GitHub 状态、部署。0b 的 git merge origin/main 不在此列。
5. 修复说明（改动、验证输出摘要、push SHA 或本地提交 SHA）写到 $SUP/${rep}，交付完即结束。
$(decision_scope "$u")"
        dispatch_if_room "$id" "repair" "repair" "${rep%.md}.worker.log" "$rep" \
          "$PICK_MODEL" "$PICK_EFFORT" "$prompt$(sweep_rule "$u")$(supervisor_rule "$u")" "" "$wt" "" "$failure" "$u" false && [[ -n "$pr_num" ]] && repair_demote "$id" "$pr_num" "$branch"
        true ;;
      rereview-pending)
        [[ -n "$pr_num" || "$prless" == 1 ]] || { to_supervisor "$id" "rereview-pending without a PR"; continue; }
        if [[ "$(jqf -r '.reopen_pr // false' <<<"$u")" == true ]]; then reopen_reverted_pr "$id" "$pr_num"; continue; fi
        room_for "$id" rereview "$u" || continue
        pick review || continue
        target="$(unit_review_target "$id" "$pr_num" "$lane" "$(jqf -r '.branch // empty' <<<"$u")")" || continue
        read -r pr_head sha <<<"$target"
        [[ "$sha" =~ $SHA_RE ]] || continue
        verify_handoff_delivery "$id" "$pr_num" "$(jqf -r '.branch // empty' <<<"$u")" "$sha" || continue
        prev_sha="$(jqf -r '.reviewed_sha // empty' <<<"$u")"
        prev_pr_head="$(jqf -r '.reviewed_pr_head // empty' <<<"$u")"
        if [[ "$prev_sha" == "$sha" && "$prev_pr_head" == "$pr_head" ]]; then
          if [[ "$pr_num" =~ ^[0-9]+$ ]] && approved_ci_repair_unchanged "$u" "$sha" "$pr_head"; then
            # Repair returned the exact approved head after a CI red: reuse the existing unit-row retry budget,
            # and mark this head rerun so the merge lane does not spend an uncounted first retry.
            local k n=0 r failed_runs rerun_failed=0
            k="$(unit_field "$id" '.ci_infra_reruns // 0')"; [[ "$k" =~ ^[0-9]+$ ]] || k=0
            if (( k < CI_INFRA_RERUNS )); then
              failed_runs="$(gh run list --commit "$sha" --json databaseId,conclusion --jq '.[] | select(.conclusion=="failure" or .conclusion=="cancelled") | .databaseId' 2>/dev/null)" \
                || { to_supervisor "$id" "could not list failed CI runs for unchanged approved head $sha"; continue; }
              [[ -n "$failed_runs" ]] || { to_supervisor "$id" "no failed CI run found for unchanged approved head $sha"; continue; }
              for r in $failed_runs; do
                if gh run rerun "$r" --failed >/dev/null 2>&1; then n=$((n+1)); else rerun_failed=1; fi
              done
              (( n > 0 && rerun_failed == 0 )) || { to_supervisor "$id" "GitHub rejected a failed-run rerun for unchanged approved head $sha"; continue; }
              set_unit "$id" "$(hist ci-repair-rerun "unchanged approved head $sha; rerun $((k+1))/$CI_INFRA_RERUNS") | .ci_infra_reruns=$((k+1)) | .ci_rerun_sha=$(js "$sha") | .approved_sha=$(js "$sha") | .stage=\"ready-to-merge\""
              say "repair-no-push unit=$id: approved head $sha unchanged after CI failure -> reran $n failed run(s), retry $((k+1))/$CI_INFRA_RERUNS"
            else
              to_supervisor "$id" "approved head $sha remained unchanged after $k bounded CI reruns"
            fi
            continue
          fi
          # repair 交付了报告却没推出新 head（多为 GitHub 间歇断连，改动留在 clone/stash）：自动重试 repair 两次再转人工。
          if [[ "$(jqf -r '(.history // [])[-1].stage // ""' <<<"$u")" == repair-delivered ]] \
            && (( $(jqf -r '[(.history // [])[] | select(.stage=="repair-no-push")] | length' <<<"$u") < 2 )); then
            set_unit "$id" "$(hist repair-no-push "head $sha unchanged after repair") | .stage=\"repair-pending\""
            say "repair-no-push unit=$id: head $sha unchanged after repair -> retry repair"
            continue
          fi
          # 修复者两次都没推新提交，多半认为评审发现不成立：先做一次仲裁评审，仍不收敛才转人工。
          if (( $(jqf -r '[(.history // [])[] | select(.stage=="arbiter-review")] | length' <<<"$u") == 0 )); then
            decision="$(decision_entry 'Route to one arbiter review' 'repair returned without a new commit' "head $sha unchanged since last review" '["Dispatch another repair without independent review"]' scheduler)"
            set_unit "$id" "$(hist arbiter-review "head $sha unchanged since last review" "$decision") | .arbiter=true | .reviewed_sha=null | .reviewed_pr_head=null"
            say "head unchanged unit=$id -> one arbiter review"
          else
            to_supervisor "$id" "head $sha unchanged since last review after an arbiter review"
          fi
          continue
        fi
        wt="$(ensure_clone "$id")" || { say "rereview-pending unit=$id: clone unavailable"; continue; }
        checkout_pr_head "$wt" "$pr_num" "$sha" "$pr_head" || { say "rereview-pending unit=$id: PR head $sha unavailable"; continue; }
        prev_report="$(jqf -r '.review_report // empty' <<<"$u")"
        # 增量复审的前提是上轮 head 是当前 head 的真祖先（prev..sha 即修复增量）。PR head 随每次修复推送而变，
        # 不能用"PR head 未变"当前提：7c38abda0 那样判定后，2026-10-20 起 PR 车道零增量复审，每轮都是重新抽样的全量评审，
        # 每轮挖出新发现、永不收敛（L63）。rebase/force-push（不再是祖先）或候选未变才回落到完整评审。
        if [[ ! "$prev_sha" =~ $SHA_RE || -z "$prev_report" || "$prev_sha" == "$sha" ]] \
          || ! git -C "$wt" merge-base --is-ancestor "$prev_sha" "$sha" 2>/dev/null; then
          # 没有可核销的上一轮基线：做一次完整评审，不允许空 diff 的"增量复审"放行。
          rep="review-${key}-${TAG}.md"
          prompt="$(review_prompt "$subject" "$title" "$sha" "$rep" "$lane" "$wt")$(sweep_rule "$u" "$sha")$(arbiter_rule "$u")$(hotpatch_rule "$u")$(supervisor_rule "$u")"
        dispatch_if_room "$id" "review" "review" "${rep%.md}.worker.log" "$rep" \
            "$PICK_MODEL" "$PICK_EFFORT" "$prompt" "$sha" "$wt" "$pr_head" "$prompt" "$u" || true
          continue
        fi
        rep="review-${key}-r-${TAG}.md"
        prompt="你是 the product 流水线的独立代码评审 subagent，只读增量复审。当前目录是隔离 clone，已检出 PR 当前 head（detached），origin/main 为最新 main。
复审 ${subject}（${title}）当前 head ${sha}，上轮 head ${prev_sha}。按正式契约中的 Targeted re-review 流程，仅检查 ${prev_sha}..${sha} 的 PR 增量及其直接依赖闭包；报告写到 $SUP/${rep}。
读取上轮报告 $SUP/${prev_report} 和单元历史中的作者处置，再按处置逐条核验。$(review_contract_rule)
只读边界：不编辑/commit/push/merge/评论。$(review_dispositions_context "$u")$(risk_class_safety_rule "$wt")$(lane_rule "$lane" "$sha")$(sweep_rule "$u" "$sha")$(hotpatch_rule "$u")$(supervisor_rule "$u")"
        dispatch_if_room "$id" "rereview" "rereview" "${rep%.md}.worker.log" "$rep" \
          "$PICK_MODEL" "$PICK_EFFORT" "$prompt" "$sha" "$wt" "$pr_head" "$prompt" "$u" || true ;;
      review-pending)
        [[ -n "$pr_num" || "$prless" == 1 ]] || continue
        room_for "$id" review "$u" || continue
        pick review || continue
        target="$(unit_review_target "$id" "$pr_num" "$lane" "$(jqf -r '.branch // empty' <<<"$u")")" || continue
        read -r pr_head sha <<<"$target"
        [[ "$sha" =~ $SHA_RE ]] || continue
        verify_handoff_delivery "$id" "$pr_num" "$(jqf -r '.branch // empty' <<<"$u")" "$sha" || continue
        wt="$(ensure_clone "$id")" || { say "review-pending unit=$id: clone unavailable"; continue; }
        checkout_pr_head "$wt" "$pr_num" "$sha" "$pr_head" || { say "review-pending unit=$id: PR head $sha unavailable"; continue; }
        rep="review-${key}-${TAG}.md"
        prompt="$(review_prompt "$subject" "$title" "$sha" "$rep" "$lane" "$wt")$(arbiter_rule "$u")$(hotpatch_rule "$u")$(supervisor_rule "$u")"
        dispatch_if_room "$id" "review" "review" "${rep%.md}.worker.log" "$rep" \
          "$PICK_MODEL" "$PICK_EFFORT" "$prompt" "$sha" "$wt" "$pr_head" "$prompt" "$u" || true ;;
      implement-pending)
        task="$(jqf -r '.task // empty' <<<"$u")"; branch="$(jqf -r '.branch // ""' <<<"$u")"
        [[ -z "$task" ]] && { say "implement-pending unit=$id has no .task; supervisor required"; continue; }
        [[ -z "$branch" ]] && { say "implement-pending unit=$id has no .branch; supervisor required"; continue; }
        wt=""
        if [[ "$local_refill" == true ]]; then
          [[ -z "$(blocking_body_dependency "$u")" ]] || continue
          if [[ -n "$(jqf -r '.handoff_worktree_sha // empty' <<<"$u")" && "$(jqf -r '.handoff_worktree_applied // false' <<<"$u")" != true ]] \
            || [[ -n "$(jqf -r '.handoff_start_ref // empty' <<<"$u")" && "$(jqf -r '.handoff_start_applied // false' <<<"$u")" != true ]]; then
            continue
          fi
        else
          park_if_body_blocked "$u" && continue
        fi
        room_for "$id" implement "$u" false || continue
        pick implement "$u" || continue
        footprint_room "$id" "$u" true || continue
        if [[ "$local_refill" != true && "$pr_num" =~ ^[0-9]+$ && "$lane" != direct-main ]]; then
          wt="$(pre_dispatch_pr_admission "$id" "$branch" "$pr_num" "implement-pending before dispatch")" || continue
        fi
        stack_branch="$(jqf -r 'if .stacked_on_released == true then empty else .stacked_on_branch // empty end' <<<"$u")"; stack_sha="$(jqf -r 'if .stacked_on_released == true then empty else .stacked_on_sha // empty end' <<<"$u")"
        resume_branch="$(jqf -r '.handoff_start_ref // empty' <<<"$u")"; resume_sha="$(jqf -r '.handoff_start_sha // empty' <<<"$u")"
        if [[ -n "$(jqf -r '.handoff_worktree_sha // empty' <<<"$u")" && "$(jqf -r '.handoff_worktree_applied // false' <<<"$u")" != true ]]; then
          handoff_status=0
          wt="$(handoff_worktree_clone "$id" "$branch" "$(jqf -r '.handoff_worktree // empty' <<<"$u")" "$(jqf -r '.handoff_worktree_sha' <<<"$u")" "$(jqf -r '.handoff_worktree_dirty // false' <<<"$u")" 0 "$(jqf -r '.handoff_start_ref // empty' <<<"$u")" "$(jqf -r '.handoff_start_sha // empty' <<<"$u")" "$stack_branch" "$stack_sha")" || handoff_status=$?
          if (( handoff_status != 0 )); then
            if (( handoff_status == 73 )); then to_supervisor "$id" "handoff conflicts with the existing branch; inspect the preserved owner worktree and PR"; else say "implement-pending unit=$id: previous worktree unavailable"; fi
            continue
          fi
          record_handoff_integration "$id" "$wt" "" || continue
        elif [[ -n "$resume_branch" && "$resume_sha" =~ $SHA_RE && "$(jqf -r '.handoff_start_applied // false' <<<"$u")" != true ]]; then
          handoff_status=0
          wt="$(handoff_worktree_clone "$id" "$branch" "" "$resume_sha" false 0 "$resume_branch" "$resume_sha" "$stack_branch" "$stack_sha")" || handoff_status=$?
          if (( handoff_status != 0 )); then
            if (( handoff_status == 73 )); then to_supervisor "$id" "rescued handoff conflicts with the stacked branch; inspect both histories"; else say "implement-pending unit=$id: rescued checkout unavailable"; fi
            continue
          fi
          record_handoff_integration "$id" "$wt" "" || continue
        elif [[ -n "$stack_branch" && -n "$stack_sha" ]]; then
          if [[ -z "$wt" ]]; then
            if [[ "$local_refill" == true ]]; then
              wt="$(ensure_clone "$id" "$branch" 0 "" "$stack_branch" "$stack_sha" true)" || { say "implement-pending unit=$id: stacked clone unavailable"; continue; }
            else
              wt="$(ensure_clone "$id" "$branch" 0 "" "$stack_branch" "$stack_sha")" || { say "implement-pending unit=$id: stacked clone unavailable"; continue; }
            fi
          fi
        else
          if [[ -z "$wt" ]]; then
            if [[ "$local_refill" == true ]]; then
              wt="$(ensure_clone "$id" "$branch" 0 "" "" "" true)" || { say "implement-pending unit=$id: clone unavailable"; continue; }
            else
              wt="$(ensure_clone "$id" "$branch")" || { say "implement-pending unit=$id: clone unavailable"; continue; }
            fi
          fi
        fi
        resume_handoff_integration "$id" "$wt" || continue
        rep="impl-${id}-${TAG}.md"
        set_unit "$id" ".report=$(js "$rep")"
        if [[ "$lane" == direct-main ]]; then
          deliver="ACCEPTANCE：
先确认问题在当前 main 上仍存在：已被修复或不再适用就不改代码，报告第一行写 OBSOLETE: <证据>。${OPT_PREMISE_RULE}${BLAST_RADIUS_RULE}
VERIFY：
本地定向验证全绿；node scripts/branch-delivery-preflight.mjs --mode commit 通过后在本地分支 ${branch} 提交（提交信息不带 [skip ci]）——这是非产品快车道，评审通过后流水线把它压成一个提交经 land-direct-main.sh 直落 main。
FORBIDDEN：
只改非产品路径（scripts/、lessons/、docs/、.agents/ 等）；修复必须改产品代码（packages/、apps/、services/）或 .github/workflows 时不要改，报告第一行写 NEEDS-PR: <原因>。不要 push、不开 PR；禁止 merge PR/部署/改 GitHub 状态。
REPORT：
产出说明写到 $SUP/${rep}（根因、改动、验证输出摘要、本地提交 SHA）。交付完即结束。"
        else
          deliver="ACCEPTANCE：
先确认问题在当前 main 上仍存在：已被修复或不再适用就不改代码，报告第一行写 OBSOLETE: <证据>。否则修根因并补回归测试。${OPT_PREMISE_RULE}${BLAST_RADIUS_RULE}
尺寸准入：${branch} 相对 main 的改动合计（Markdown/文档、生成物、锁文件、测试快照不计入）不超过 ${SIZE_ADMISSION_LINES} 行，push 前用 git diff --numstat origin/main...HEAD 自查。整张票放不进限额时不要硬塞：只实现第一个可独立交付的完整切片（含必要测试），报告第一行改写 SPLIT: <剩余范围一句话>，剩余工作由流水线另开续作票承接；不要为压行数砍掉切片必需的测试。
VERIFY：
本地定向验证全绿；${INTEGRATION_RULE}node scripts/branch-delivery-preflight.mjs --mode push --publish-topic 通过后 push 分支 ${branch} 到 origin。
FORBIDDEN：
不 push main、不 force、不开 PR——流水线会开 PR 并派评审；禁止 merge PR/部署/改 GitHub 状态。
REPORT：
产出说明写到 $SUP/${rep}（根因、改动、验证输出摘要、push SHA；SPLIT 时写清已交付切片的边界和剩余范围）。交付完即结束。"
        fi
        feature_issue="$(jqf -r '.issue // empty' <<<"$u")"
        feature_state='{}'
        if [[ -n "$feature_issue" && -n "${STATE_DIR:-}" ]]; then
          feature_state="$(cat "$STATE_DIR/$feature_issue.json" 2>/dev/null)"
          [[ -n "$feature_state" ]] || feature_state='{}'
        fi
        plan_started=$SECONDS
        feature_plan="$(verification_plan_for_state "$wt" "$feature_state")"
        plan_elapsed=$((SECONDS - plan_started))
        (( plan_elapsed < 2 )) || say "dispatch detail feature_plan unit=$id secs=${plan_elapsed}s"
        feature_brief="$(verification_plan_brief "$feature_plan")"
        prompt="GOAL：
$task

SCOPE：
issue 写明的前置 issue 尚未交付（仍 open、没有已合并的修复）时不要改代码，报告第一行写 BLOCKED-ON: #<前置 issue 号>，流水线会在前置交付后重派。路线图 epic/主题（roadmap-epic、roadmap-theme、roadmap 标签的伞形 issue）不是前置：不要对它写 BLOCKED-ON，直接实现本 issue 自己的切片。
当前目录是隔离 clone：${wt}（分支 ${branch}，基于最新 main 或该分支已有的进度）。若 git stash list 有「autopilot: kept before redispatch」，是上一轮未提交的进度，先 git stash pop 恢复。
$(matt_method_rule "$wt")
$(decision_scope "$u")
Feature verification plan (advisory, from ticket-declared paths): $feature_brief
After implementation, refresh IDs from the actual changed paths with node engine/verification-plan.mjs --root . --base origin/main --head HEAD. Run node scripts/e2e/yangfeng-regression/verify-feature.mjs --feature <IDs> --target <base-url> --json only when a candidate target already serves this build. Record the JSON output path. If no candidate target exists, say so; do not build a local stack. This is worker evidence, not a merge gate.

$deliver"
        dispatch_if_room "$id" "implement" "implement" "${rep%.md}.worker.log" "$rep" \
          "$PICK_MODEL" "$PICK_EFFORT" "$prompt" "" "$wt" "" "$prompt" "$u" false || true ;;
    esac
  done < <(dispatch_order)
}
