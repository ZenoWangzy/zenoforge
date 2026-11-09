
# 尺寸准入的计数：分支相对 PR 基线（普通 PR 为 main，堆叠 PR 为父分支）的代码加删行数；文档、生成物、锁文件与测试快照不计，
# 避免这些内容单独变大就触发重切。数不出来（clone 丢了、fetch 失败）返回空，不挡评审。
changed_lines_count() {
  awk -F'\t' '$3 ~ /(^|\/)fixtures?\/.*\.json$/ { f += $1 + $2; next } $3 !~ /(^|\/)(pnpm-lock\.yaml|package-lock\.json|yarn\.lock)$/ && $3 !~ /^(docs|lessons|\.trellis)\// && $3 !~ /(^|\/)[^/]+\.md$/ && $3 !~ /(^|\/)(__snapshots__|generated|dist|build|coverage)(\/|$)/ && $3 !~ /(^|\/)[^/]*\.generated\.[^/]+$/ && $3 !~ /\.snap$/ { n += $1 + $2 } END { if (f > 500) n += f; print n }'  # shortcut: fixture JSON counts only past 500 lines (then in full), hardcoded; move to config if it needs tuning
}
changed_lines_of() { # dir branch base-branch [refs-current] → 行数或空
  local base base_branch="${3:-main}" refs_current="${4:-false}"
  if [[ "$refs_current" != true || "$base_branch" != main ]]; then
    git -C "$1" fetch -q origin "+refs/heads/$base_branch:refs/remotes/origin/$base_branch" "+refs/heads/$2:refs/remotes/origin/$2" 2>/dev/null || return 0
  fi
  base="$(git -C "$1" merge-base "refs/remotes/origin/$base_branch" "refs/remotes/origin/$2" 2>/dev/null)" || return 0
  git -C "$1" diff --numstat "$base" "refs/remotes/origin/$2" 2>/dev/null | changed_lines_count
}
changed_lines_in_checkout() { # dir base-branch → checkout diff 行数或空
  local base
  base="$(git -C "$1" merge-base "refs/remotes/origin/$2" HEAD 2>/dev/null)" || return 0
  [[ -n "$base" ]] || return 0
  git -C "$1" diff --numstat "$base" 2>/dev/null | changed_lines_count
}
changed_files_of() { # dir branch base-branch → actual diff paths as JSON
  local base
  base="$(git -C "$1" merge-base "refs/remotes/origin/$3" "refs/remotes/origin/$2" 2>/dev/null)" || return 0
  [[ -n "$base" ]] || return 0
  (set -o pipefail; git -C "$1" diff --no-renames --name-only -z "$base" "refs/remotes/origin/$2" 2>/dev/null \
    | jqf -Rsc '[splits("\u0000") | select(length > 0)]')
}

size_admission_exempt_unit() { # unit-json → true when the configured hotpatch exemption applies
  jqf -e --slurpfile cfg <(printf '%s' "$CFG") '($cfg[0].size_admission // {}) as $sa
    | (.hotpatch == true)
      and (if ($sa | has("exempt_hotpatch")) then $sa.exempt_hotpatch == true else true end)' <<<"$1" >/dev/null
}

# 监督者手工写入的 .size_waiver = {max_lines, by, at, reason}（scheduler 锁内，无工具）：只抬高该
# unit 的上限，不是豁免——复查仍计数，改动行数超过 max_lines 的 head 照样拒绝。字段缺失或非数值时回落默认上限。
size_admission_limit_for() { # unit-json → effective limit: a supervisor size_waiver.max_lines raises the configured floor
  local waived
  waived="$(jqf -r '.size_waiver.max_lines | select(type == "number") // empty' <<<"$1")"
  if [[ "$waived" =~ ^[0-9]+$ ]] && (( waived > SIZE_ADMISSION_LINES )); then
    printf '%s\n' "$waived"
  else
    printf '%s\n' "$SIZE_ADMISSION_LINES"
  fi
}

# 尺寸准入在 write-start、开 PR、派已有 PR 的 implement/repair 前和每次 repair/self-fix 交付后复查。
# repair-pending 的超线 PR 先走现有 needs-recut 通道，不占 worker；同一 head 已拒过或不能路由时转 supervisor。
# repair/self-fix 仍需复查新 head（#4482：PR #4396 从 611 增到 1090、#4403 从 796 增到 1063）。返回 1 = 已升级。
# A head already sent to recut routes again after a held or resumed recut; only a refused recut (recut_refused_at on the
# issue state) makes it a person's problem. An unreadable state stays refused.
size_recut_refused_on_head() { # unit head issue
  local state
  jqf -e --arg id "$1" --arg head "$2" 'any(.units[] | select(.id==$id) | .history[]?; .stage=="size-recut" and (.result | contains("head="+$head)))' "$UNITS" >/dev/null || return 1
  state="$(scheduler_issue_state "$3" 2>/dev/null)" || return 0
  jqf -e 'has("recut_refused_at")' <<<"$state" >/dev/null
}
unit_history_count() { # unit stage [result-regex] → history entries of that stage whose result matches
  jqf -r --arg id "$1" --arg st "$2" --arg re "${3:-}" '[.units[] | select(.id==$id) | (.history // [])[] | select(.stage==$st and ((.result // "") | test($re)))] | length' "$UNITS"
}
# A refused recut leaves the issue at the same scope, so escalating a second time cannot change the outcome (28 lines over
# 11 units in 24 h). The implement brief already carries the SPLIT contract (first independent slice, remainder filed as a
# needs-triage ticket, see dispatch-queue.sh); admit the worker once on that contract. Harvest still recounts the real diff, so the limit holds.
size_split_admit() { # unit issue lines limit → 0 after recording the one admission
  set_unit "$1" "$(hist size-split-admitted "issue #$2: $3 lines exceed $4 and recut refused; one worker run on the SPLIT contract")"
}
size_admission_reject() { # unit lines branch context head estimate actual checkpoint [limit]
  local issue limit="${9:-$SIZE_ADMISSION_LINES}" refused=false
  issue="$(unit_field "$1" '.issue // empty')"
  if [[ "$5" =~ $SHA_RE && "$issue" =~ ^[0-9]+$ ]]; then
    ! size_recut_refused_on_head "$1" "$5" "$issue" || refused=true
  fi
  if [[ "$8" == write-start && "$refused" == true ]] \
    && (( $(unit_history_count "$1" supervisor-escalated '^size admission:') >= 1 )) \
    && (( $(unit_history_count "$1" size-split-admitted) == 0 )) \
    && size_split_admit "$1" "$issue" "$2" "$limit"; then
    say "size admission write-start unit=$1 issue=#$issue estimate=${6:-unknown} actual=${7:-unknown} limit=$limit -> admitted once for a SPLIT delivery"
    return 0
  fi
  if [[ "$5" =~ $SHA_RE && "$issue" =~ ^[0-9]+$ && "$refused" == false ]] \
    && scheduler_size_recut "$issue" "$2" "$limit" "$1" "$3" "$5"; then
    set_unit "$1" "$(hist size-recut "issue #$issue: $2 lines exceed $limit; head=$5") | .stage=\"blocked-external\" | .size_recut_pending=true"
    if [[ "$8" == write-start ]]; then
      say "size admission write-start unit=$1 issue=#$issue estimate=${6:-unknown} actual=${7:-unknown} limit=$limit -> needs-recut"
    else
      say "unit $1 size admission routed issue #$issue to recut"
    fi
    return 1
  fi
  to_supervisor "$1" "size admission: ${2} changed lines $4 exceed the ${limit}-line limit (documentation, generated files, lockfiles, and snapshots excluded): re-scope or split before review" \
    'Request recut or split before review' 'changed lines exceed the size admission limit' \
    "${2} changed lines $4 exceed ${limit}-line limit" \
    '["Open PR for review without recutting"]'
  if [[ "$8" == write-start ]]; then
    say "size admission write-start unit=$1 issue=${issue:-none} estimate=${6:-unknown} actual=${7:-unknown} limit=$limit -> supervisor-review"
  fi
  return 1
}
size_admission_recheck_impl() { # unit dir branch context [initial-head] [refs-current]
  local lines base_branch head="${5:-}" files pr unit_json limit
  unit_json="$(jqf -c --arg id "$1" '[.units[] | select(.id==$id)][0] // {}' "$UNITS")"
  size_admission_exempt_unit "$unit_json" && return 0
  [[ -n "${head}" ]] || say "size recheck without head: $1 $4"
  [[ -n "$2" && -n "$3" ]] || return 0
  base_branch="$(unit_field "$1" '.stacked_on_branch // "main"')"
  lines="$(changed_lines_of "$2" "$3" "$base_branch" "${6:-false}")"
  [[ "$lines" =~ ^[0-9]+$ ]] || return 0
  # PR 自己的文件清单（GitHub 权威，不依赖本地 refs 的新旧）；本地 refs 过期时 merge-base 退回旧提交，
  # 把合入分支的 main 改动算进来（#4631 实 13 个文件却记成 362）。超过 100 个文件 gh 会截断，退回 git diff。
  pr="$(unit_field "$1" '.pr // empty')"
  files=""
  if [[ "$pr" =~ ^[0-9]+$ ]]; then
    files="$(gh pr view "$pr" --json files --jq '.files[].path' | jqf -Rsc '[split("\n")[] | select(length > 0)]' || true)"
  fi
  jqf -e 'type == "array" and length > 0 and length < 100' <<<"$files" >/dev/null 2>&1 || files="$(changed_files_of "$2" "$3" "$base_branch")"
  if jqf -e 'type == "array"' <<<"$files" >/dev/null 2>&1; then
    set_unit "$1" ".footprint=$files | .footprint_source=\"pr-diff\""
  fi
  limit="$(size_admission_limit_for "$unit_json")"
  (( lines > limit )) || return 0
  size_admission_reject "$1" "$lines" "$3" "$4" "$head" "" "$lines" admission "$limit"
}
size_admission_recheck() { # Keep the per-candidate diff+fetch visible inside dispatch_pending's phase total.
  local started=$SECONDS rc=0 elapsed
  size_admission_recheck_impl "$@" || rc=$?
  elapsed=$((SECONDS - started))
  (( elapsed < 2 )) || say "dispatch detail size_recheck unit=$1 secs=${elapsed}s"
  return "$rc"
}
size_admission_write_start() { # unit workdir unit-json → block before worker launch when estimate or current diff is oversized
  local issue estimate actual="" lines="" source="" branch base_branch head state limit est_limit reject_limit
  size_admission_exempt_unit "$3" && return 0
  issue="$(jqf -r '.issue // empty' <<<"$3")"
  estimate="$(jqf -r '.estimated_changed_lines // empty' <<<"$3")"
  if [[ ! "$estimate" =~ ^[0-9]+$ && "$issue" =~ ^[1-9][0-9]*$ ]]; then
    state="$(scheduler_issue_state "$issue" 2>/dev/null || true)"
    estimate="$(jqf -r '.estimated_changed_lines // empty' <<<"$state")"
  fi
  branch="$(jqf -r '.branch // empty' <<<"$3")"
  base_branch="$(jqf -r 'if .stacked_on_released == true then "main" else .stacked_on_branch // "main" end' <<<"$3")"
  if [[ -n "$2" && -d "$2" ]]; then
    actual="$(changed_lines_in_checkout "$2" "$base_branch")"
  fi
  head="$(git -C "$2" rev-parse -q --verify HEAD 2>/dev/null || true)"
  limit="$(size_admission_limit_for "$3")"
  # An unwaived ticket whose estimate passes 80% of the limit is cut before a worker starts (row 117: 41.2% of 641-800 estimates needed a size recut later, only 20.9% of 481-640); a waiver already means the recut ran out.
  est_limit="$limit"; (( limit != SIZE_ADMISSION_LINES )) || est_limit=$((limit * 80 / 100))
  if [[ "$estimate" =~ ^[0-9]+$ ]] && (( estimate > est_limit )); then
    lines="$estimate"; source=estimate
  fi
  if [[ "$actual" =~ ^[0-9]+$ ]] && (( actual > limit )) && (( actual > ${lines:-0} )); then
    lines="$actual"; source=diff
  fi
  reject_limit="$limit"; [[ "$source" != estimate ]] || reject_limit="$est_limit"
  [[ -n "$lines" ]] || return 0
  [[ "$source" != estimate || ! "$actual" =~ ^[0-9]+$ ]] || (( actual > limit )) || (( $(unit_history_count "$1" size-split-admitted) == 0 )) || return 0
  # The 30-second refill may start implement workers using local data only. It
  # defers an oversized ticket for the slow tick, which owns the existing recut
  # issue transition and records the decision once.
  [[ "${TICK_DISPATCH_LOCAL_REFILL:-false}" != true ]] || return 1
  size_admission_reject "$1" "$lines" "$branch" "write-start ($source)" "$head" "${estimate:-unknown}" "${actual:-unknown}" write-start "$reject_limit"
}
pre_dispatch_pr_admission() { # unit branch PR context → prepared clone; nonzero means defer or recut
  local id="$1" branch="$2" pr="$3" context="$4" head dir
  head="$(tick_pr_head "$pr")" || return 1
  dir="$(ensure_clone "$id" "$branch" 1 "$head")" || { say "$context unit=$id: PR branch unavailable"; return 1; }
  size_admission_recheck "$id" "$dir" "$branch" "$context" "$head" true || return 1
  printf '%s\n' "$dir"
}

# "Delivered nothing twice" recurs once per arbiter round, because the retry counter never resets: 9 lines over 2 units in
# 24 h. After a supervisor ruling has already followed one such escalation, send the issue through the same recut route the
# cap triage uses (once per unit); a unit that already had a recut, an uncommitted tree or no issue still goes to the supervisor.
implement_nothing_escalate() { # unit message [dirty]
  local issue
  issue="$(unit_field "$1" '.issue // empty')"
  if [[ -z "${3:-}" && "$issue" =~ ^[1-9][0-9]*$ ]] \
    && (( $(unit_history_count "$1" supervisor-escalated '^implement (delivered no changes|pushed no branch)') >= 1 )) \
    && jqf -e --arg id "$1" '[.units[] | select(.id==$id)][0] | (.recut_routed != true) and all((.history // [])[]; .stage != "supervisor-budget-recut" and .stage != "supervisor-cap-triage-recut" and .stage != "supervisor-cap-default")' "$UNITS" >/dev/null; then
    supervisor_budget_recut "$1" "$2; escalated before and ruled on, same result" null "implement delivered nothing again" "implement delivered nothing again after a supervisor ruling"
    return 0
  fi
  to_supervisor "$1" "$2"
}
# 产品 issue 的实现：worker 推分支，流水线开 PR（Refs #N）→ 进评审；OBSOLETE 直接结案。
pr_create_failure_transient() { # gh output rc → true for retryable server/transport failures
  local output="${1:-}" rc="${2:-0}"
  [[ "$rc" == 124 ]] && return 0
  grep -Eiq 'HTTP([[:space:]]|/[0-9.]+[[:space:]])5[0-9]{2}|GraphQL:[[:space:]]*Something went wrong|ECONNRESET|ETIMEDOUT|timeout|timed[[:space:]]+out|deadline exceeded' <<<"$output"
}
harvest_pr_implement() { # unit report-path
  local first issue branch dir head title pr out base local_head ahead dirty push_out create_error create_rc retry_limit retry_count adopt_rc
  first="$(grep -m1 -v '^[[:space:]]*$' "$2" 2>/dev/null)"
  issue="$(unit_field "$1" .issue)"; branch="$(unit_field "$1" .branch)"; dir="$WT_ROOT/wt-$1"
  local dep; dep="$(blocked_on_of "$2")"
  [[ -n "$dep" ]] && { park_blocked "$1" "$dep"; return 0; }
  if [[ "$first" == OBSOLETE:* ]]; then
    obsolete_unit_close "$1" "$issue" "$first"; return 0
  fi
  if [[ "$first" == NEEDS-DIRECT:* ]]; then
    needs_direct_route "$1" "$first"; return 0
  fi
  head="$(git -C "$dir" ls-remote origin "refs/heads/$branch" 2>/dev/null | awk 'NR==1 {print $1}')"
  if [[ ! "$head" =~ $SHA_RE ]]; then
    # 远端没有分支时先诊断 worktree，再决定是否值得再跑一轮 implement（#5180/#5071/#5246）。
    local_head=""; ahead=""; dirty=""
    if [[ -d "$dir" ]]; then
      local_head="$(git -C "$dir" rev-parse -q --verify "refs/heads/$branch" 2>/dev/null)"
      [[ "$local_head" =~ $SHA_RE ]] && ahead="$(git -C "$dir" rev-list -n1 "refs/remotes/origin/main..$local_head" 2>/dev/null)"
      dirty="$(git -C "$dir" status --porcelain 2>/dev/null | head -1)"
    fi
    if [[ -n "$ahead" ]]; then
      # 已提交未推送（worker 遵守产品侧 preflight 拒绝、网络故障等，交付提交留在 clone 里）：
      # 分支本来就要经 scheduler_pr_open 开 PR 再过评审与合并门禁，引擎代推 topic 分支
      # 不落 main、不绕过任何门禁；推不动才带 push 错误转 supervisor，不盲跑第二轮。
      if push_out="$(git -C "$dir" push origin "refs/heads/$branch:refs/heads/$branch" 2>&1)"; then
        head="$local_head"
        set_unit "$1" "$(hist implement-push-recovered "engine pushed worker commit $local_head to $branch")"
        say "implement-no-push unit=$1: engine pushed committed work $local_head -> $branch"
      else
        push_out="$(grep -am1 -E '(! \[remote rejected\]|^error:|^fatal:|^remote:)' <<<"$push_out" | cut -c1-160)"
        [[ -n "$push_out" ]] || push_out="$(printf '%s\n' "$push_out" | head -1 | cut -c1-160)"
        to_supervisor "$1" "implement committed $local_head on $branch but publishing it failed: ${push_out:-git push exited nonzero} (report $(basename "$2"))"
        return 0
      fi
    elif [[ "$local_head" =~ $SHA_RE && -z "$dirty" ]]; then
      # 空交付是独立的 no changes 类（改动落在了别的 checkout/远端，指定 worktree 既无提交
      # 也无未提交改动）：提示语点名原因，两次空交付才转 supervisor，消息同样带原因。
      if [[ "$(unit_retries "$1" implement-no-changes)" == 0 ]]; then
        set_unit "$1" "$(hist implement-no-changes "$(basename "$2")") | .task += $(js "

上一轮交付了报告，但指定 worktree 的 ${branch} 上既没有本地提交也没有未提交改动（改动可能落在了别的 checkout 或别的远端）。本轮必须在指定 worktree 内完成并提交改动（或按协议写 OBSOLETE:）。") | .stage=\"implement-pending\""
      else
        implement_nothing_escalate "$1" "implement delivered no changes in the assigned worktree twice: $branch has no local commits and a clean tree, so the work likely landed in another checkout or remote (report $(basename "$2"))"
      fi
      return 0
    else
      if [[ "$(unit_retries "$1" implement-no-push)" == 0 ]]; then
        set_unit "$1" "$(hist implement-no-push "$(basename "$2")") | .task += $(js "

上一轮交付了报告但 origin 上没有分支 ${branch}：本轮必须通过 push preflight 并 push 该分支。") | .stage=\"implement-pending\""
      else
        implement_nothing_escalate "$1" "implement pushed no branch $branch twice (report $(basename "$2"))${dirty:+; the worktree holds uncommitted edits but no local commit on the branch}" "$dirty"
      fi
      return 0
    fi
  fi
  size_admission_recheck "$1" "$dir" "$branch" "on $branch" "$head" || return 0
  title="$(unit_field "$1" .title)"
  base="$(unit_field "$1" '.stacked_on_branch // "main"')"
  scheduler_pr_open "$branch" "${title:-$1}${issue:+ (#$issue)}" "${issue:+Refs #$issue

}Implemented by the the product autopilot. Implementer report (first lines):

$(head -40 "$2")" "$base"
  pr="$SCHED_PR_NUM"; out="$SCHED_PR_OUT"
  if [[ ! "$pr" =~ ^[0-9]+$ ]]; then
    create_rc="${SCHED_PR_RC:-0}"
    if [[ "${SCHED_PR_CREATE_ATTEMPTED:-false}" == true ]] && pr_create_failure_transient "$out" "$create_rc"; then
      create_error="$out"
      [[ -n "$create_error" ]] || create_error="gh pr create exited with rc=$create_rc"
      if scheduler_pr_adopt_open "$branch" "$base" true; then
        pr="$SCHED_PR_NUM"
        say "unit $1 adopted PR#$pr after transient create failure on $branch"
      else
        adopt_rc=$?
        if (( adopt_rc == 2 )); then
          to_supervisor "$1" "could not adopt the open PR for $branch after a transient create failure: ${SCHED_PR_OUT:0:200}"
          return 0
        fi
      fi
      if [[ ! "$pr" =~ ^[0-9]+$ ]]; then
        retry_count="$(unit_retries "$1" pr-create-retry)"
        [[ "$retry_count" =~ ^[0-9]+$ ]] || retry_count=0
        retry_count=$((retry_count + 1))
        retry_limit="$(jqf -r '.pr_create_retry_limit // 3' <<<"$CFG")"
        [[ "$retry_limit" =~ ^[1-9][0-9]*$ ]] || retry_limit=3
        set_unit "$1" "$(hist pr-create-retry "$retry_count/$retry_limit: $create_error")"
        if (( retry_count >= retry_limit )); then
          to_supervisor "$1" "could not open a PR for $branch after $retry_count transient failures: ${create_error:0:200}"
        else
          say "unit $1 transient PR create failure ($retry_count/$retry_limit) on $branch; retry next tick"
        fi
        return 0
      fi
    else
      to_supervisor "$1" "could not open a PR for $branch: ${out:0:200}"
      return 0
    fi
  fi
  set_unit "$1" "$(hist pr-opened "PR#$pr $head") | .pr=$pr | .lane=\"pr\" | .stage=\"review-pending\"$([[ "$branch" =~ $GATED_BRANCH_RE ]] && printf ' | .gated=true')"
  say "unit $1 implemented on $branch -> PR#$pr review-pending"
  # SPLIT 交付（#4482）：尺寸契约在派发简报里前置后，worker 交第一个可独立交付切片 +
  # SPLIT 首行声明剩余范围；切片 PR 进评审的同时，剩余范围落成续作票（needs-triage，
  # 重新量尺寸），不再丢失也不再把原票整票重派。幂等：一个 unit 只建一张（.split_followup）。
  if [[ "$first" == SPLIT:* && -z "$(unit_field "$1" '.split_followup // empty')" ]]; then
    split_followup_issue "$1" "$issue" "$pr" "$first" "$2"
  fi
}

# SPLIT 交付的续作票（#4482）：worker 按尺寸准入只交付了第一个可独立交付切片，报告首行
# SPLIT: <剩余范围一句话>。剩余范围需要一张自己的票承载——生而 needs-triage，走正常分诊
# （含行数估算），不会再被整票派发。创建失败记 supervisor inbox，单元保持评审队列。
split_followup_issue() { # unit issue pr split-line report-path
  local unit="$1" issue="$2" pr="$3" first="$4" rep="$5" remainder body url num parent
  remainder="$(printf '%s' "$first" | sed -E 's/^SPLIT:[[:space:]]*//')"
  body="## Parent

由 #$issue 按尺寸准入拆分出的续作票：第一个可独立交付切片在 PR #$pr 送评审，本票承接剩余范围，会走正常的分诊流程（含行数估算），不跳过分诊。

## 剩余范围

$remainder

## 切片交付说明（worker 报告）

$(head -n 200 "$rep" 2>/dev/null)"
  # The follow-up is the parent's sibling: an open child makes the parent a roadmap container, which refuses awaiting-release.
  parent="$(gh api "repos/{owner}/{repo}/issues/$issue/parent" --jq '.number // empty' 2>/dev/null || true)"
  url="$(scheduler_auto_filed_issue_create --title "$(unit_field "$unit" .title)（续作自 #${issue}）" --body "$body" --label needs-triage ${parent:+--parent "$parent"} 2>/dev/null || true)"
  if [[ -n "$url" ]]; then
    num="${url##*/}"
    set_unit "$unit" "$(hist split-followup "issue #$num: $remainder") | .split_followup=$num"
    if ! scheduler_issue_transition "$issue" tracker "intake-parent:roadmap-container:split-delivery" '.tracker_parent = true'; then
      to_supervisor "$unit" "split remainder #$num filed but parent #$issue could not transition to tracker"
      return 0
    fi
    say "unit $unit split delivery: remainder #$num filed; slice in PR #$pr"
  else
    # 切片 PR 已在评审，失败只报 supervisor inbox，不把单元踢出评审队列；剩余范围仍在 worker 报告与 PR 描述里。
    ( source "$SCHEDULER_AGENT_LIB" && supervisor_inbox_append_once "split-followup-failed:$unit" "split 续作票创建失败 unit=$unit 原票 #$issue 切片 PR #${pr}：剩余范围见报告 $(basename "$rep")" ) >/dev/null 2>&1 \
      || say "unit $unit split followup create failed; remainder in $(basename "$rep")"
  fi
}
