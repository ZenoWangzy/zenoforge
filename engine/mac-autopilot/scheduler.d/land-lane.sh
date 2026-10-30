
launch_land() { # id pr sha title report log workdir reviewed-pr-head [issue]
  local pid w
  (cd "$7" && exec setsid bash "$HERE/land-pr.sh" "$7" "$2" "$3" "$4" "$SUP/$5" "$8" "${9:-}") > "$SUP/$6" 2>&1 < /dev/null &
  pid=$!
  w="$(jqf -cn --argjson pid "$pid" --arg unit "$1" --arg log "$6" --arg report "$5" --arg at "$STAMP" --arg sha "$3" --arg pr_head "$8" --arg workdir "$7" \
    '{pid:$pid,unit:$unit,type:"land",log:$log,report:$report,started:$at,sha:$sha,pr_head:$pr_head,workdir:$workdir,model:"none"}')"
  jqf --argjson w "$w" '.workers += [$w]' "$WORKERS" | write_state "$WORKERS"
  say "dispatch land pid=$pid unit=$1 PR#${2:-none} sha=$3"
}
fast_land_lane() { # 一次只落一个；与产品合并门禁无关（land-direct-main 自带 focused 检查与锁）
  local u id pr approved target head candidate reviewed_pr_head title wt rep
  [[ "$(jqf -r .auto_merge <<<"$CFG")" == "true" ]] || return 0
  jqf -e 'any(.units[]; .stage=="landing")' "$UNITS" >/dev/null && return 0
  while read -r u; do
    id="$(jqf -r .id <<<"$u")"; pr="$(jqf -r '.pr // empty' <<<"$u")"; approved="$(jqf -r '.approved_sha // empty' <<<"$u")"
    [[ "$(ensure_lane "$id" "$pr")" == direct-main ]] || continue
    target="$(unit_review_target "$id" "$pr" direct-main "$(jqf -r '.branch // empty' <<<"$u")")" || {
      set_unit "$id" "$(hist approval-stale 'current PR head unavailable') | .approved_sha=null | .stage=\"rereview-pending\""
      continue
    }
    read -r head candidate <<<"$target"
    reviewed_pr_head="$(jqf -r '.reviewed_pr_head // empty' <<<"$u")"
    if [[ ! "$approved" =~ $SHA_RE || ! "$reviewed_pr_head" =~ $SHA_RE \
      || "$head" != "$reviewed_pr_head" || "$candidate" != "$approved" ]]; then
      set_unit "$id" "$(hist approval-stale "approved=${approved:-none} reviewed-pr-head=${reviewed_pr_head:-none} current-pr-head=$head candidate=$candidate") | .approved_sha=null | .stage=\"rereview-pending\""
      continue
    fi
    wt="$(ensure_clone "$id")" || { say "fast-land unit=$id: clone unavailable"; continue; }
    title="$(jqf -r '.title // ""' <<<"$u")"; rep="land-${pr:-$id}-${TAG}.md"
    launch_land "$id" "$pr" "$approved" "$title" "$rep" "${rep%.md}.worker.log" "$wt" "$reviewed_pr_head" "$(jqf -r '.issue // empty' <<<"$u")"
    set_unit "$id" "$(hist land-issued "${pr:+PR#$pr }$approved") | .stage=\"landing\""
    return 0
  done < <(fast_land_candidates)
}

# 无 PR 的直落实现：本地提交 → 评审本地提交 → 直落 main；OBSOLETE 直接结案，NEEDS-PR 转人工开 PR。
harvest_prless_implement() { # unit report-path [local-only]
  local first issue branch dir local_head
  first="$(grep -m1 -v '^[[:space:]]*$' "$2" 2>/dev/null)"
  issue="$(unit_field "$1" .issue)"; branch="$(unit_field "$1" .branch)"; dir="$WT_ROOT/wt-$1"
  local dep; dep="$(blocked_on_of "$2")"
  [[ -n "$dep" ]] && { park_blocked "$1" "$dep"; return 0; }
  case "$first" in
    OBSOLETE:*)
      [[ "${3:-false}" != true ]] || return 1
      [[ -n "$issue" ]] && gh issue close "$issue" --comment "Autopilot: no change needed on current main. ${first}" >/dev/null 2>&1
      set_unit "$1" "$(hist obsolete "$first") | .stage=\"closed\""
      say "unit $1 obsolete: $first"; return 0 ;;
    NEEDS-PR:*)
      # 要改产品或工作流路径：转 PR 车道重做（PR 车道可以改这些路径，CI 与评审照常把关）。
      set_unit "$1" "$(hist needs-pr "$first") | .lane=\"pr\" | .branch=\"agent/${issue:+issue-}${issue:-$1}\" | .task += ($(js "

上一轮在直落车道判断：${first}。本轮走 PR 车道，可以改产品/工作流路径。")) | .stage=\"implement-pending\""
      say "unit $1 needs a PR -> PR lane"; return 0 ;;
  esac
  local_head="$(git -C "$dir" rev-parse -q --verify "refs/heads/$branch" 2>/dev/null)"
  if [[ "$local_head" =~ $SHA_RE ]] && [[ -n "$(git -C "$dir" rev-list -n1 "refs/remotes/origin/main..$local_head" 2>/dev/null)" ]]; then
    set_unit "$1" "$(hist delivered "local commit $local_head") | .stage=\"review-pending\""
    say "unit $1 implemented locally at $local_head -> review-pending"
  elif [[ "$(unit_retries "$1" implement-no-commit)" == 0 ]]; then
    set_unit "$1" "$(hist implement-no-commit "$(basename "$2")") | .task += $(js "

上一轮交付了报告但分支 ${branch} 上没有本地提交：本轮必须在该分支提交改动（或按协议写 OBSOLETE:/NEEDS-PR:）。") | .stage=\"implement-pending\""
  else
    to_supervisor "$1" "implement delivered no local commit on $branch twice (report $(basename "$2"))"
  fi
}
