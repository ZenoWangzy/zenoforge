
recover_orphan_landing() { # landing 无活 land worker（被杀/重启）→ 回 ready-to-merge 重试
  local id wp has_live
  for id in $(jqf -r '.units[] | select(.stage=="landing") | .id' "$UNITS"); do
    has_live=false
    for wp in $(jqf -r --arg u "$id" '.workers[] | select(.unit==$u and .harvested != true) | .pid' "$WORKERS"); do
      alive "$wp" && has_live=true && break
    done
    [[ "$has_live" == true ]] || { set_unit "$id" '.stage="ready-to-merge"'; say "orphan-recover unit=$id landing -> ready-to-merge"; }
  done
}

# 失败回合数：只数返工/阻断/回退/无产出，不数正常推进（批准、合并不算）。
loop_rounds() { # 只数最近一次 supervisor 裁决（requeue/approve）或仲裁之后的失败回合（裁决后重新给满额度）
  # supervisor-approve 以前不算：issue-3560 获批后 CI 测试红转 repair，旧的 5 轮被重算，没修就直接转人工（05:13）。
  jqf -r '(.history // []) as $h | ([$h | to_entries[] | select(.value.stage | IN("supervisor-requeue","supervisor-approve","arbiter-review")) | .key] | max // -1) as $i | [$h[($i + 1):][] | select(.stage=="review-request-changes" or .stage=="review-block" or .stage=="merge-reverted" or .stage=="worker-no-output")] | length' <<<"$1"
}

# 止损预算（#4363）：自最近一次裁决（supervisor requeue/approve 或顾问裁决）起，
# 已花费的 implement/repair 轮数（每个 write-start 一轮）与第一轮至今的墙钟。裁决重置预算，
# 让既有顾问收敛通道完整跑完；没有任何裁决拦得住的单元才止损转 supervisor。
# 预算内输出空；超轮数输出 "rounds N of B"，超墙钟输出 "wall Xmin of Ymin after N rounds"。
ticket_budget_reason() { # unit-json
  jqf -r --argjson round_budget "$TICKET_ROUND_BUDGET" --argjson wall_budget "$TICKET_WALL_BUDGET_SECONDS" --argjson now "$NOW_EPOCH" '
    (.history // []) as $h
    | ([$h | to_entries[] | select(.value.stage | IN("supervisor-requeue","supervisor-approve","advisor-ruling")) | .key] | max // -1) as $ruling
    | [$h[($ruling + 1):][] | select(.stage == "write-start")] as $rounds
    | if ($rounds | length) >= $round_budget
      then "rounds \($rounds | length) of \($round_budget)"
      else ($rounds | map(.at // empty) | first) as $first
      | select($first != null)
      | (($first | sub("\\.[0-9]+"; "") | fromdateiso8601) as $t
        | select($now - $t > $wall_budget)
        | "wall \((($now - $t) / 60) | floor)min of \(($wall_budget / 60) | floor)min after \($rounds | length) rounds")
      end' <<<"$1" 2>/dev/null
}

repair_rounds_since_ruling() { # unit-json → repair starts since the last successful review or supervisor/advisor decision
  jqf -r '
    (.history // []) as $h
    | ([$h | to_entries[] | select(.value.stage | IN("supervisor-arbiter","supervisor-arbiter-round","supervisor-requeue","supervisor-approve","advisor-ruling","review-approve")) | .key] | max // -1) as $ruling
    | $h[$ruling + 1:] as $recent
    | ($recent | [to_entries[] | select(.value.stage == "write-start" and .value.work_type == "repair") | .key] | min // ($recent | length)) as $first_tagged
    | ([$recent[0:$first_tagged][] | select(.stage == "repair-delivered" or .stage == "self-fix-delivered" or (.stage == "worker-no-output" and .result == "repair"))] | length) as $legacy
    | ([$recent[] | select(.stage == "write-start" and .work_type == "repair")] | length) as $tagged
    | $legacy + $tagged' <<<"$1"
}
repair_cap_admission() { # unit-id unit-json → two failed repair rounds escalate before another worker is prepared
  local rounds
  rounds="$(repair_rounds_since_ruling "$2")"
  [[ "$rounds" =~ ^[0-9]+$ ]] && (( rounds >= 2 )) || return 0
  to_supervisor "$1" "repair cap: $rounds failed repair rounds; escalate to the configured Terra/Sol arbiter" \
    'Escalate to supervisor arbitration after two failed repair rounds' \
    'two repair write-starts have failed since the last approval or arbitration' \
    "$rounds failed repair rounds; configured supervisor arbitration profile=${SUPERVISOR_ARBITER_PROFILE}" \
    '["Dispatch a third repair without arbitration"]'
  say "repair cap unit=$1 rounds=$rounds limit=2 -> supervisor-review"
  return 1
}

# ---------- 2. 派发（焦点与并发；预算只告警） ----------
# 新 worker slot 按 main-red、热修回迁、critical 的现有紧急度排序；其后按配置 tier，再按环节。
# 2026-10-20 三个热修回迁在 review-pending 等了 56 分钟，名额被新收的孤儿 PR 先拿走（L62）。
dispatch_order() {
  local started=$SECONDS rc=0 elapsed
  jqf -c --argjson priority_order "$DISPATCH_PRIORITY_ORDER" '
    .units
    | map(select(.stage | test("-pending$")))
    | sort_by([
        (if .main_red == true then 0 else 1 end),
        (if .hotpatch == true then 0 else 1 end),
        (if .critical == true then 0 else 1 end),
        ((if .hotpatch == true then "hotfix" elif (.lane // "") == "direct-main" then "opt" else "normal" end) as $tier
          | ($priority_order | index($tier) // ($priority_order | length))),
        (if .stage == "repair-pending" or .stage == "rereview-pending" then 0 elif .stage == "review-pending" then 1 elif .stage == "implement-pending" then 2 else 3 end),
        (.id // "")
      ])[]
  ' "$UNITS" || rc=$?
  elapsed=$((SECONDS - started))
  [[ "${TICK_DISPATCH_PENDING_ACTIVE:-false}" != true ]] || (( elapsed < 2 )) || say "dispatch detail candidate_order secs=${elapsed}s"
  return "$rc"
}
# 合并后验证失败被 revert 的单元回到 repair，但原 PR 已是 MERGED：GitHub 不再把分支新提交挂到它上面，repair 推了也
# 显示"head 未变"，单元在 repair-no-push / 仲裁评审里空转到升级（2026-10-21 issue-3451 / #4009 空转 4 小时）。
# repair 交付后用同一分支开新 PR（已有 open PR 就沿用），评审与 CI 在新 PR 上进行。
reopen_reverted_pr() { # unit old-pr
  local branch issue title out pr
  branch="$(unit_field "$1" .branch)"; issue="$(unit_field "$1" '.issue // empty')"
  [[ -n "$branch" ]] || { to_supervisor "$1" "merge of #$2 was reverted but the unit has no branch to re-deliver"; return 0; }
  title="$(unit_field "$1" .title)"
  scheduler_pr_open "$branch" "${title:-$1}${issue:+ (#$issue)}" "${issue:+Refs #$issue

}Re-delivery of #$2: its squash merge was reverted on main after post-merge verification failed. This PR carries the same branch with the repair on top."
  pr="$SCHED_PR_NUM"
  if [[ ! "$pr" =~ ^[0-9]+$ ]]; then say "unit=$1 re-delivery PR for reverted #$2 not created yet (branch $branch)"; return 0; fi
  set_unit "$1" "$(hist pr-reopened "#$2 -> #$pr after merge revert") | .pr=$pr | del(.reopen_pr) | .reviewed_sha=null | .reviewed_pr_head=null$([[ "$branch" =~ $GATED_BRANCH_RE ]] && printf ' | .gated=true')"
  say "unit=$1 merge of #$2 was reverted -> re-delivered as PR #$pr"
}
approved_ci_repair_unchanged() { # unit-json head pr-head
  jqf -e --arg sha "$2" --arg pr_head "$3" '
    (.history // []) as $h
    | ([$h | to_entries[] | select(.value.stage | IN("review-approve", "review-request-changes", "review-block")) | .key] | max // -1) as $last_review
    | .reviewed_sha == $sha and .reviewed_pr_head == $pr_head
      and $last_review >= 0 and $h[$last_review].stage == "review-approve" and $h[$last_review].result == $sha
      and $h[-1].stage == "repair-delivered"
      and any($h[($last_review + 1):][]; .stage == "ci-test-red" or .stage == "ci-red")
  ' <<<"$1" >/dev/null
}
repair_failure_prompt() { # unit-json review-report -> only this repair's failure evidence
  local u="$1" report="$2" hint pr checks name link job tmp i pid step_file log_file started=$SECONDS elapsed index=0
  local -a names=() links=() step_files=() log_files=() pids=()
  hint="$(jqf -r '.repair_hint // empty' <<<"$u")"
  [[ -z "$hint" ]] || printf '%s\n' "$hint"
  case "$(jqf -r '.history[-1].stage // empty' <<<"$u")" in
    ci-red|ci-test-red)
      pr="$(jqf -r '.pr // empty' <<<"$u")"
      checks="$(repair_check_rows "$pr")" || checks='[]'
      tmp="$(mktemp -d)" || return 1
      # 失败 job 的元数据与日志有界并行取（GH_PARALLEL）。
      while IFS=$'\t' read -r name link; do
        job="${link##*/job/}"; [[ "$job" =~ ^[0-9]+$ ]] || continue
        step_file="$tmp/$index.steps"; log_file="$tmp/$index.log"
        names+=("$name"); links+=("$link"); step_files+=("$step_file"); log_files+=("$log_file")
        (unset GH_TOKEN; gh api "repos/{owner}/{repo}/actions/jobs/$job" \
          --jq '.steps[]? | select(.conclusion=="failure") | "Failing CI step: " + .name' \
          >"$step_file") 2>/dev/null &
        pids+=("$!"); gh_par_throttle pids
        (unset GH_TOKEN
          # 只取报告用的末尾 80 行，不再整份下载 job 日志（05:10:42Z 拍 2 个检查 17s）。日志端点
          # 302 到 Azure blob：后缀区间（bytes=-N）Azure 不认，先 bytes=0-0 探出总长
          # （Content-Range 尾段就是总字节数），再按显式区间只取末 64KB；探不出总长回落整份。
          total="$(gh api -i -H "Range: bytes=0-0" "repos/{owner}/{repo}/actions/jobs/$job/logs" 2>/dev/null \
            | tr -d '\r' | grep -i '^content-range:' | grep -oE '[0-9]+$' || true)"
          if [[ "$total" =~ ^[0-9]+$ ]] && (( total > 0 )); then
            start=$(( total > 65536 ? total - 65536 : 0 ))
            exec gh api --allow-escape-sequences -H "Range: bytes=$start-$((total - 1))" \
              "repos/{owner}/{repo}/actions/jobs/$job/logs"
          else
            exec gh api --allow-escape-sequences "repos/{owner}/{repo}/actions/jobs/$job/logs"
          fi
        ) >"$log_file" 2>/dev/null &
        pids+=("$!"); gh_par_throttle pids
        index=$((index + 1))
      done < <(jqf -r '.[] | select(.bucket=="fail") | [.name,.link] | @tsv' <<<"$checks")
      for pid in "${pids[@]}"; do wait "$pid" || :; done
      for i in "${!names[@]}"; do
        printf '\nFailing CI check: %s\n%s\n' "${names[$i]}" "${links[$i]}"
        cat "${step_files[$i]}" 2>/dev/null || true
        tail -80 "${log_files[$i]}" 2>/dev/null || true
      done
      rm -rf -- "$tmp"
      elapsed=$((SECONDS - started))
      (( elapsed >= 2 )) && say "dispatch detail repair_failure_evidence PR#$pr checks=${#names[@]} secs=${elapsed}s"
      ;;
    *)
      # Review findings come with the hint too (a hotpatch unit carries a hint and then gets REQUEST-CHANGES).
      if [[ -n "$report" && -r "$SUP/$report" ]]; then
        [[ -z "$hint" ]] || printf '\n评审报告 %s：\n' "$report"
        cat -- "$SUP/$report"
      elif [[ -z "$hint" ]]; then
        return 1
      fi
      ;;
  esac
  return 0
}
