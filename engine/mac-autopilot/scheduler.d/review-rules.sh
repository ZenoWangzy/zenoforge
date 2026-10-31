supervisor_rule() {
  local note r
  note="$(jqf -r '.note // ""' <<<"$1")"
  [[ "$note" == CTO* ]] && printf '\n【supervisor 裁决（必须遵守，不得据此 BLOCK 或打回）】%s' "$note"
  while IFS= read -r r; do
    [[ -n "$r" && "$r" != "$note" ]] && printf '\n【supervisor 裁决（必须遵守，不得据此 BLOCK 或打回）】%s' "$r"
  done < <(jqf -r '(.cto_rulings // [])[]' <<<"$1")
  return 0
}
decision_scope() { # unit-json -> prior decisions in history, for the next implementation worker
  local decisions
  decisions="$(jqf -r '[(.history // [])[] | select(.decision != null) |
    "- \(.at // "") [\(.decision.owner // "")] \(.decision.decision // "")\n  Why: \(.decision.why // "")\n  Evidence: \(.decision.evidence // "")\n  Rejected: \((.decision.rejected // []) | if type == "array" then join(", ") else tostring end)"] | join("\n")' <<<"$1")"
  [[ -n "$decisions" ]] || return 0
  printf 'Decided earlier (do not reopen without new evidence):\n%s' "$decisions"
}
hotpatch_rule() { [[ "$(jqf -r '.hotpatch // false' <<<"$1")" == true ]] && printf '%s' "$HOTPATCH_REVIEW_RULE"; return 0; }
arbiter_rule() { [[ "$(jqf -r '.arbiter // false' <<<"$1")" == true ]] && printf '%s' "$ARBITER_RULE"; return 0; }
risk_class_safety_rule() { # checkout → safety prompt for risk classes found by the repository classifier
  local checkout="$1" hits classes paths
  [[ -n "$checkout" && -d "$checkout" ]] || return 0
  hits="$(cd "$checkout" && node "$HERE/../risk-class.mjs" --json origin/main...HEAD 2>/dev/null)" || return 0
  classes="$(jq -r '[.[].kind] | unique | join(", ")' <<<"$hits" 2>/dev/null)"
  [[ -n "$classes" ]] || return 0
  paths="$(jq -r '.[] | "- \(.kind): \(.path)"' <<<"$hits")"
  printf '\nRisk-class paths from the existing classifier (%s):\n%s\n' "$classes" "$paths"
}
lane_rule() { # lane sha
  [[ "$1" == direct-main ]] || return 0
  printf '%s' "
本单元走非产品快车道（direct-main）：评审对象是本 clone 当前检出的提交 $2，它可能只在本地、尚未推到 PR 或根本没有 PR（非产品改动不开 PR、不推 topic），GitHub 上的 PR head、PR diff 与 CI 状态因此不同步属正常——diff 以本地 git 为准，不用 gh pr diff。批准后流水线把它压成一个提交经 land-direct-main.sh 直落 main（落地时跑 focused 检查，suites 在落地后跑）。PR head 不同步、无 CI run、交付路径都不是阻断理由。"
}
subject_of() { # pr issue → 评审/修复对象的称呼（无 PR 的直落单元用 issue 或单元 id）
  if [[ -n "$1" ]]; then printf 'PR #%s' "$1"; elif [[ -n "$2" ]]; then printf 'issue #%s 的本地实现（无 PR）' "$2"; else printf '本地实现（无 PR）'; fi
}
review_prompt() { # pr-or-subject title sha report [lane] [checkout]
  local subject="$1"; [[ "$subject" =~ ^[0-9]+$ ]] && subject="PR #$subject"
  printf '%s' "你是 the product 流水线的独立代码评审 subagent，只读【增量评审】（diff-scoped，不做全库漫游）。当前目录是隔离 clone，已检出被评审提交（detached），origin/main 为最新 main；本地 diff：git diff origin/main...HEAD。评审 ${subject}（$2）fixed head $3：
评审面：① diff（merge-base..head）与关联 issue 验收条件逐条对照；② 变更文件的直接 import/依赖闭包；③ 只读边界下可核实的测试与行为证据。
请完整读取并遵守正式评审契约，按其要求评审与交付。$(review_contract_rule)
效率纪律：不重述代码内容；不展开未变更文件的细节；低风险样式性改动一行带过。目标 15-25 分钟内交付。
只读边界：不编辑/commit/push/merge/评论。报告写到 $SUP/$4。落盘后交付完即结束。$(risk_class_safety_rule "${6:-}")$(lane_rule "${5:-}" "$3")"
}

pr_view() { gh pr view "$1" --json "$2" --jq ".$2" 2>/dev/null; }
tick_pr_head() { # PR → head SHA from this tick's open-PR census, with a direct fallback for a census miss
  local pr="$1" prs="" head=""
  prs="$(tick_prs 2>/dev/null || true)"
  if [[ -n "$prs" ]]; then
    head="$(jqf -r --argjson p "$pr" '[.[] | select(.number == $p) | .headRefOid][0] // empty' <<<"$prs")"
  fi
  [[ "$head" =~ $SHA_RE ]] || head="$(pr_view "$pr" headRefOid)" || return 1
  [[ "$head" =~ $SHA_RE ]] || return 1
  printf '%s\n' "$head"
}
tick_pr_base() { # PR → base branch from this tick's open-PR census, with a direct fallback for a census miss
  local pr="$1" prs="" base=""
  prs="$(tick_prs 2>/dev/null || true)"
  if [[ -n "$prs" ]]; then
    base="$(jqf -r --argjson p "$pr" '[.[] | select(.number == $p) | .baseRefName][0] // empty' <<<"$prs")"
  fi
  [[ -n "$base" ]] || base="$(pr_view "$pr" baseRefName)" || return 1
  [[ -n "$base" ]] || return 1
  printf '%s\n' "$base"
}
tick_pr_branch() { # PR → head branch from this tick's open-PR census, with a direct fallback for a census miss
  local pr="$1" prs="" branch=""
  prs="$(tick_prs 2>/dev/null || true)"
  if [[ -n "$prs" ]]; then
    branch="$(jqf -r --argjson p "$pr" '[.[] | select(.number == $p) | .headRefName][0] // empty' <<<"$prs")"
  fi
  [[ -n "$branch" ]] || branch="$(pr_view "$pr" headRefName)" || return 1
  [[ -n "$branch" ]] || return 1
  printf '%s\n' "$branch"
}
classify_lane() { # pr → direct-main|pr（取不到文件列表返回 1）
  local files json verdict
  # The REST file list includes previous_filename for renames; both sides must be classified.
  # gh refuses --slurp together with --jq (exit 1 before any request): from 10-20 every call failed, 506 a hour on
  # 10-22, and no unit got a lane, so non-product PRs never took the direct-main lane. --jq runs per page instead.
  files="$(gh api --paginate "repos/{owner}/{repo}/pulls/$1/files" \
    --jq '.[] | .filename, (.previous_filename // empty)' 2>/dev/null)" || return 1
  json="$(jq -Rsc 'split("\n") | map(select(length > 0))' <<<"$files")" || return 1
  [[ "$json" != '[]' ]] || return 1
  verdict="$(node "$POLICY_SCRIPT" --classify-path-set - <<<"$json" 2>/dev/null)" || return 1
  [[ "$verdict" == eligible ]] && echo direct-main || echo pr
}
lane_policy_blob() { git -C "$ROOT" rev-parse "HEAD:${POLICY_SCRIPT#"$ROOT"/}" 2>/dev/null || echo unknown; }
fast_land_candidates() { # → 快车道要看的 ready-to-merge 单元（每行一个 JSON）
  # 记成 pr 车道但分类策略已变的单元也要进来，让 ensure_lane 重分；只取 lane != pr 时它们永远留在产品车道
  # （10-22：94 个待合并单元里 35 个策略过期，其中 4 个非产品 PR 一直排 CI 名额）。
  jqf -c --arg p "$(lane_policy_blob)" '[.units[] | select(.stage=="ready-to-merge" and (.hold_handoff_waiting // false) == false
      and ((.pr // null) != null or (.lane // "") == "direct-main")
      and ((.lane // "") != "pr" or (.lane_policy // "") != $p))] | sort_by(.ready_since // 0) | .[]' "$UNITS"
}
ensure_lane() { # id pr → 打印并记录 lane
  # 分类随策略文件变：pr 车道的单元在 branch-delivery-policy.mjs 改动后重分一次（10-22 R1 把 workflow 划进直落 main，
  # 之前被记成 pr 的 #4044 若不重分会永远走产品 PR 车道）。direct-main 不回退：PR 新增产品路径会在派发前被拒。
  local lane policy; lane="$(unit_field "$1" .lane)"
  policy="$(lane_policy_blob)"
  if [[ -z "$lane" || ( "$lane" == pr && "$(unit_field "$1" '.lane_policy // empty')" != "$policy" ) ]]; then
    lane="$(classify_lane "$2")" || return 1
    set_unit "$1" ".lane=\"$lane\" | .lane_policy=\"$policy\""
  fi
  printf '%s' "$lane"
}
# 评审目标绑定一对 SHA：远端 PR head 是审核时观察到的基线，候选 SHA 可以是该 head 的本地修复后代。
unit_review_target() { # id pr lane branch → <pr-head> <candidate-sha>
  local pr_head local_head dir="$WT_ROOT/wt-$1"
  if [[ -z "$2" ]]; then
    # 无 PR 的直落单元：候选是本地分支 head，基线是它与 main 的分叉点（批准绑定这一对）。
    [[ "$3" == direct-main && -n "$4" && -d "$dir/.git" ]] || return 1
    local_head="$(git -C "$dir" rev-parse -q --verify "refs/heads/$4" 2>/dev/null)"
    pr_head="$(git -C "$dir" merge-base refs/remotes/origin/main "$local_head" 2>/dev/null)"
    [[ "$local_head" =~ $SHA_RE && "$pr_head" =~ $SHA_RE && "$local_head" != "$pr_head" ]] || return 1
    printf '%s %s' "$pr_head" "$local_head"; return 0
  fi
  pr_head="$(tick_pr_head "$2")" || return 1
  if [[ "$3" == direct-main && -n "$4" && -d "$dir/.git" ]]; then
    local_head="$(git -C "$dir" rev-parse -q --verify "refs/heads/$4" 2>/dev/null)"
    if [[ "$local_head" =~ $SHA_RE && "$local_head" != "$pr_head" ]] \
      && git -C "$dir" merge-base --is-ancestor "$pr_head" "$local_head" 2>/dev/null; then
      printf '%s %s' "$pr_head" "$local_head"; return 0
    fi
  fi
  printf '%s %s' "$pr_head" "$pr_head"
}
unit_head() { # id pr lane branch → candidate SHA (compatibility helper)
  local target
  target="$(unit_review_target "$1" "$2" "$3" "$4")" || return 1
  printf '%s' "${target#* }"
}
