
# 尺寸准入的计数：分支相对 PR 基线（普通 PR 为 main，堆叠 PR 为父分支）的代码加删行数；文档、生成物、锁文件与测试快照不计，
# 避免这些内容单独变大就触发重切。数不出来（clone 丢了、fetch 失败）返回空，不挡评审。
changed_lines_count() {
  awk -F'\t' '$3 !~ /(^|\/)(pnpm-lock\.yaml|package-lock\.json|yarn\.lock)$/ && $3 !~ /^(docs|lessons|\.trellis)\// && $3 !~ /(^|\/)[^/]+\.md$/ && $3 !~ /(^|\/)(__snapshots__|generated|dist|build|coverage)(\/|$)/ && $3 !~ /(^|\/)[^/]*\.generated\.[^/]+$/ && $3 !~ /\.snap$/ { n += $1 + $2 } END { print n }'
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

# 尺寸准入在 write-start、开 PR、派已有 PR 的 implement/repair 前和每次 repair/self-fix 交付后复查。
# repair-pending 的超线 PR 先走现有 needs-recut 通道，不占 worker；同一 head 已拒过或不能路由时转 supervisor。
# repair/self-fix 仍需复查新 head（#4482：PR #4396 从 611 增到 1090、#4403 从 796 增到 1063）。返回 1 = 已升级。
size_admission_reject() { # unit lines branch context head estimate actual checkpoint
  local issue
  issue="$(unit_field "$1" '.issue // empty')"
  if [[ "$5" =~ $SHA_RE && "$issue" =~ ^[0-9]+$ ]] \
    && ! jqf -e --arg id "$1" --arg head "$5" 'any(.units[] | select(.id==$id) | .history[]?; .stage=="size-recut" and (.result | contains("head="+$head)))' "$UNITS" >/dev/null \
    && scheduler_size_recut "$issue" "$2" "$SIZE_ADMISSION_LINES" "$1" "$3" "$5"; then
    set_unit "$1" "$(hist size-recut "issue #$issue: $2 lines exceed $SIZE_ADMISSION_LINES; head=$5") | .stage=\"blocked-external\" | .size_recut_pending=true"
    if [[ "$8" == write-start ]]; then
      say "size admission write-start unit=$1 issue=#$issue estimate=${6:-unknown} actual=${7:-unknown} limit=$SIZE_ADMISSION_LINES -> needs-recut"
    else
      say "unit $1 size admission routed issue #$issue to recut"
    fi
    return 1
  fi
  to_supervisor "$1" "size admission: ${2} changed lines $4 exceed the ${SIZE_ADMISSION_LINES}-line limit (documentation, generated files, lockfiles, and snapshots excluded): re-scope or split before review" \
    'Request recut or split before review' 'changed lines exceed the size admission limit' \
    "${2} changed lines $4 exceed ${SIZE_ADMISSION_LINES}-line limit" \
    '["Open PR for review without recutting"]'
  if [[ "$8" == write-start ]]; then
    say "size admission write-start unit=$1 issue=${issue:-none} estimate=${6:-unknown} actual=${7:-unknown} limit=$SIZE_ADMISSION_LINES -> supervisor-review"
  fi
  return 1
}
size_admission_recheck_impl() { # unit dir branch context [initial-head] [refs-current]
  local lines base_branch head="${5:-}" files pr
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
  (( lines > SIZE_ADMISSION_LINES )) || return 0
  size_admission_reject "$1" "$lines" "$3" "$4" "$head" "" "$lines" admission
}
size_admission_recheck() { # Keep the per-candidate diff+fetch visible inside dispatch_pending's phase total.
  local started=$SECONDS rc=0 elapsed
  size_admission_recheck_impl "$@" || rc=$?
  elapsed=$((SECONDS - started))
  (( elapsed < 2 )) || say "dispatch detail size_recheck unit=$1 secs=${elapsed}s"
  return "$rc"
}
size_admission_write_start() { # unit workdir unit-json → block before worker launch when estimate or current diff is oversized
  local issue estimate actual="" lines="" source="" branch base_branch head state
  issue="$(jqf -r '.issue // empty' <<<"$3")"
  estimate="$(jqf -r '.estimated_changed_lines // empty' <<<"$3")"
  if [[ ! "$estimate" =~ ^[0-9]+$ && "$issue" =~ ^[1-9][0-9]*$ ]]; then
    state="$(scheduler_issue_state "$issue" 2>/dev/null || true)"
    estimate="$(jqf -r '.estimated_changed_lines // empty' <<<"${state:-{}}")"
  fi
  branch="$(jqf -r '.branch // empty' <<<"$3")"
  base_branch="$(jqf -r 'if .stacked_on_released == true then "main" else .stacked_on_branch // "main" end' <<<"$3")"
  if [[ -n "$2" && -d "$2" ]]; then
    actual="$(changed_lines_in_checkout "$2" "$base_branch")"
  fi
  head="$(git -C "$2" rev-parse -q --verify HEAD 2>/dev/null || true)"
  if [[ "$estimate" =~ ^[0-9]+$ ]] && (( estimate > SIZE_ADMISSION_LINES )); then
    lines="$estimate"; source=estimate
  fi
  if [[ "$actual" =~ ^[0-9]+$ ]] && (( actual > SIZE_ADMISSION_LINES )) && (( actual > ${lines:-0} )); then
    lines="$actual"; source=diff
  fi
  [[ -n "$lines" ]] || return 0
  # The 30-second refill may start implement workers using local data only. It
  # defers an oversized ticket for the slow tick, which owns the existing recut
  # issue transition and records the decision once.
  [[ "${TICK_DISPATCH_LOCAL_REFILL:-false}" != true ]] || return 1
  size_admission_reject "$1" "$lines" "$branch" "write-start ($source)" "$head" "${estimate:-unknown}" "${actual:-unknown}" write-start
}
pre_dispatch_pr_admission() { # unit branch PR context → prepared clone; nonzero means defer or recut
  local id="$1" branch="$2" pr="$3" context="$4" head dir
  head="$(tick_pr_head "$pr")" || return 1
  dir="$(ensure_clone "$id" "$branch" 1 "$head")" || { say "$context unit=$id: PR branch unavailable"; return 1; }
  size_admission_recheck "$id" "$dir" "$branch" "$context" "$head" true || return 1
  printf '%s\n' "$dir"
}

# 产品 issue 的实现：worker 推分支，流水线开 PR（Refs #N）→ 进评审；OBSOLETE 直接结案。
harvest_pr_implement() { # unit report-path
  local first issue branch dir head title pr out base
  first="$(grep -m1 -v '^[[:space:]]*$' "$2" 2>/dev/null)"
  issue="$(unit_field "$1" .issue)"; branch="$(unit_field "$1" .branch)"; dir="$WT_ROOT/wt-$1"
  local dep; dep="$(blocked_on_of "$2")"
  [[ -n "$dep" ]] && { park_blocked "$1" "$dep"; return 0; }
  if [[ "$first" == OBSOLETE:* ]]; then
    [[ -n "$issue" ]] && gh issue close "$issue" --comment "Autopilot: no change needed on current main. ${first}" >/dev/null 2>&1
    set_unit "$1" "$(hist obsolete "$first") | .stage=\"closed\""
    say "unit $1 obsolete: $first"; return 0
  fi
  head="$(git -C "$dir" ls-remote origin "refs/heads/$branch" 2>/dev/null | awk 'NR==1 {print $1}')"
  if [[ ! "$head" =~ $SHA_RE ]]; then
    if [[ "$(unit_retries "$1" implement-no-push)" == 0 ]]; then
      set_unit "$1" "$(hist implement-no-push "$(basename "$2")") | .task += $(js "

上一轮交付了报告但 origin 上没有分支 ${branch}：本轮必须通过 push preflight 并 push 该分支（或按协议写 OBSOLETE:）。") | .stage=\"implement-pending\""
    else
      to_supervisor "$1" "implement pushed no branch $branch twice (report $(basename "$2"))"
    fi
    return 0
  fi
  size_admission_recheck "$1" "$dir" "$branch" "on $branch" "$head" || return 0
  title="$(unit_field "$1" .title)"
  base="$(unit_field "$1" '.stacked_on_branch // "main"')"
  scheduler_pr_open "$branch" "${title:-$1}${issue:+ (#$issue)}" "${issue:+Refs #$issue

}Implemented by the the product autopilot. Implementer report (first lines):

$(head -40 "$2")" "$base"
  pr="$SCHED_PR_NUM"; out="$SCHED_PR_OUT"
  if [[ ! "$pr" =~ ^[0-9]+$ ]]; then
    to_supervisor "$1" "could not open a PR for $branch: ${out:0:200}"; return 0
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
  local unit="$1" issue="$2" pr="$3" first="$4" rep="$5" remainder body url num
  remainder="$(printf '%s' "$first" | sed -E 's/^SPLIT:[[:space:]]*//')"
  body="## Parent

由 #$issue 按尺寸准入拆分出的续作票：第一个可独立交付切片在 PR #$pr 送评审，本票承接剩余范围，会走正常的分诊流程（含行数估算），不跳过分诊。

## 剩余范围

$remainder

## 切片交付说明（worker 报告）

$(head -n 200 "$rep" 2>/dev/null)"
  url="$(gh issue create --title "$(unit_field "$unit" .title)（续作自 #${issue}）" --body "$body" --label needs-triage --parent "$issue" 2>/dev/null || true)"
  if [[ -n "$url" ]]; then
    num="${url##*/}"
    set_unit "$unit" "$(hist split-followup "issue #$num: $remainder") | .split_followup=$num"
    say "unit $unit split delivery: remainder #$num filed; slice in PR #$pr"
  else
    # 切片 PR 已在评审，失败只报 supervisor inbox，不把单元踢出评审队列；剩余范围仍在 worker 报告与 PR 描述里。
    ( source "$SCHEDULER_AGENT_LIB" && supervisor_inbox_append_once "split-followup-failed:$unit" "split 续作票创建失败 unit=$unit 原票 #$issue 切片 PR #${pr}：剩余范围见报告 $(basename "$rep")" ) >/dev/null 2>&1 \
      || say "unit $unit split followup create failed; remainder in $(basename "$rep")"
  fi
}
