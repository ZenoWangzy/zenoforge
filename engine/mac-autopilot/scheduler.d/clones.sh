product_lane_sparse() { # dir（git clone --sparse 之后）：工作树 = 全部文件 减去 .agents/skills/ 下不在固定清单里的技能（git 2.47 非 cone 模式）
  { printf '/*\n!/.agents/skills/*\n'; sed -n 's|^\(\.agents/skills/[^#[:space:]]*\)$|/\1/|p' "$PRODUCT_LANE_SKILLS"; } \
    | git -C "$1" sparse-checkout set --no-cone --stdin
}
# 半合并残留（issue-5064，2026-11-05）：repair worker 按提示 `git merge origin/main` 撞冲突后被
# stuck-kill，index 留下 unmerged 条目；`git stash push` 拒收这种 index，ensure_clone 从此每拍
# 失败（"PR branch unavailable"）。恢复只认四件事齐全：HEAD 恰好是远端 PR head、树上没有进行
# 中的 merge、没有活 worker/claim 占用、diff 先落档；untracked 永不触碰。条件不满足或核实不了就拒绝。
clone_worktree_owner_live() { # id → 0 live worker or claim holds the worktree / 1 none / 3 unknown
  local id="$1" issue="" rec="" key="" cr_unit=1 cr_issue=1
  [[ -r "$WORKERS" && -r "$UNITS" ]] || return 3
  jqf -e 'type=="object" and (.workers|type)=="array"' "$WORKERS" >/dev/null 2>&1 || return 3
  jqf -e 'type=="object" and (.units|type)=="array"' "$UNITS" >/dev/null 2>&1 || return 3
  issue="$(unit_field "$id" '.issue // empty')" || issue=""
  while IFS= read -r rec; do
    [[ -n "$rec" ]] || continue
    harvest_worker_alive "$rec" && return 0
  done < <(jqf -cr --arg unit "$id" --arg dir "$WT_ROOT/wt-$id" --arg issue "$issue" '
    .workers[] | select(.harvested != true and .lease_expired != true)
    | select(.unit == $unit or .workdir == $dir or ($issue != "" and (.issue // "") == $issue))' "$WORKERS" 2>/dev/null)
  key="$(coord_unit_key "$id" 2>/dev/null)" && { coord_read "$key" >/dev/null 2>&1; cr_unit=$?; }
  [[ "$issue" =~ ^[1-9][0-9]*$ ]] \
    && { coord_read "$(coord_issue_key "$issue")" >/dev/null 2>&1; cr_issue=$?; }
  # 调度器派 worker 先拿 claim 再登记 worker；两个都查过才敢说没人占用。
  (( cr_unit == 0 || cr_issue == 0 )) && return 0
  (( cr_unit == 3 || cr_issue == 3 )) && return 3
  return 1
}

clone_head_mismatch_alert() { # id dir head want；每个分叉 head 只升级一次，不随 refill 重复
  local id="$1" dir="$2" head="$3" want="$4" key="clone-head-mismatch:$id:$head" once="$A/clone-head-mismatch.once"
  grep -Fq -- "$key" "$once" 2>/dev/null && return 0
  printf '%s\n' "$key" >> "$once"
  (source "$SCHEDULER_AGENT_LIB"; supervisor_inbox_append_once "$key" \
    "clone-head-mismatch unit=$id: worktree HEAD $head is not the remote head $want; ensure_clone keeps refusing and will not reset $dir") \
    || say "clone mismatch unit=$id: escalation not delivered"
  say "clone mismatch unit=$id: HEAD $head != remote $want; refusing to reset $dir"
}

clone_dirty_recovery() { # id dir want → 0 走原有 stash / 2 已恢复（跳过 stash）/ 1 拒绝
  local id="$1" dir="$2" want="$3" head="" patch="" owner=1 merging=false
  # 还开着的 rebase 属于开它的人；绝不在这里 abort。开着的 merge 只有确认主人已死才回收：宕机杀掉 worker 后没人收尾。
  if [[ -d "$dir/.git/rebase-merge" || -d "$dir/.git/rebase-apply" \
     || -e "$dir/.git/CHERRY_PICK_HEAD" || -e "$dir/.git/REVERT_HEAD" ]]; then
    return 1
  fi
  [[ -e "$dir/.git/MERGE_HEAD" ]] && merging=true
  [[ "$want" =~ $SHA_RE ]] || { [[ "$merging" == false ]]; return; }
  [[ "$merging" == false ]] && git -C "$dir" diff --quiet HEAD -- >/dev/null 2>&1 && return 0 # 只有 untracked 的脏树走原 stash 路径
  head="$(git -C "$dir" rev-parse -q --verify HEAD 2>/dev/null)" || return 1
  if [[ "$head" != "$want" ]]; then
    [[ "$merging" == false ]] || return 1
    # 领先 origin（已提交未推送）的分支照旧走 stash+保留；reset 会丢未推送的提交。
    [[ -n "$(git -C "$dir" ls-files -u 2>/dev/null)" ]] || return 0
    clone_head_mismatch_alert "$id" "$dir" "$head" "$want"
    return 1
  fi
  clone_worktree_owner_live "$id"; owner=$?
  case "$owner" in
    0) [[ "$merging" == false ]]; return ;; # 活 worker/claim 还在写这棵树：不 reset（unmerged 树随后 stash 失败即拒绝）
    3) say "clone dirty unit=$id: worker/claim liveness unknown; refusing to reset"; return 1 ;;
  esac
  patch="$A/wt-$id-recovery-$TAG.patch"
  git -C "$dir" diff --binary HEAD > "$patch" 2>/dev/null || { rm -f -- "$patch"; return 1; }
  git -C "$dir" reset -q --hard "$head" >/dev/null 2>&1 || return 1 # reset --hard 不动 untracked
  say "clone recovery unit=$id: reset abandoned dirty tree at pushed head $head; diff saved to $patch"
  return 2
}

ensure_clone_impl() { # id [branch] [require_remote] [branch-head-sha] [base-branch] [base-sha] [local-only]
  local id="$1" branch="${2:-}" require_remote="${3:-0}" want="${4:-}" base_branch="${5:-}" base_sha="${6:-}" local_only="${7:-false}" dir="$WT_ROOT/wt-$1" origin_url fresh=0 base_ref branch_ref_ok=0 branch_head recovery=0
  origin_url="$(git -C "$ROOT" remote get-url origin 2>/dev/null)" || return 1
  if [[ ! -d "$dir/.git" ]]; then
    # 产品车道的新 clone 只留固定技能清单：技能列表占每次调用静态前缀的 16%，13-16 个技能之外从不被碰。
    # 只在创建时决定、之后绝不改动活 clone，续会话因此不会丢历史里点名的技能。
    local sparse=()
    [[ "$(unit_lane_class "$(jqf -c --arg id "$id" '.units[] | select(.id==$id)' "$UNITS" 2>/dev/null)")" == product ]] \
      && grep -q '^\.agents/skills/' "$PRODUCT_LANE_SKILLS" 2>/dev/null && sparse=(--sparse)
    mkdir -p "$WT_ROOT" && git clone -q ${sparse[@]+"${sparse[@]}"} "$ROOT" "$dir" && git -C "$dir" remote set-url origin "$origin_url" \
      && { [[ -z "${sparse[*]:-}" ]] || product_lane_sparse "$dir"; } \
      || { rm -rf -- "$dir"; return 1; }
    fresh=1
  fi
  # Claude workers may not run `git -c`, so an unset identity leaves their work uncommitted.
  local git_name git_email
  git_name="$(git -C "$ROOT" config user.name)" || git_name="${ZF_AGENT_GIT_USER_NAME:-zenoforge-agent}"
  git_email="$(git -C "$ROOT" config user.email)" || git_email="${ZF_AGENT_GIT_USER_EMAIL:-zenoforge-agent@users.noreply.github.com}"
  git -C "$dir" config user.name "$git_name" && git -C "$dir" config user.email "$git_email" || true
  # A shallow scheduler checkout makes a local worker clone unable to prove that the prior
  # reviewed head is an ancestor of the repaired head; targeted re-review then falls back to a
  # full review. Restore history only for shallow worker clones; if unavailable, full review is safe.
  if [[ "$(git -C "$dir" rev-parse --is-shallow-repository 2>/dev/null)" == true ]]; then
    git -C "$dir" fetch -q --unshallow "$ROOT" 2>/dev/null || true
    if [[ "$(git -C "$dir" rev-parse --is-shallow-repository 2>/dev/null)" == true ]]; then
      [[ "$local_only" != true ]] || return 1
      git -C "$dir" fetch -q --unshallow origin 2>/dev/null || true
    fi
  fi
  if [[ "$local_only" == true ]]; then
    fetch_local_first "$dir" refs/remotes/origin/main refs/remotes/origin/main "$MAIN_HEAD" || return 1
  else
    fetch_local_first "$dir" refs/remotes/origin/main refs/remotes/origin/main "$MAIN_HEAD" \
      || git -C "$dir" fetch -q origin main || return 1
  fi
  if (( ! fresh )) && [[ -n "$(git -C "$dir" status --porcelain 2>/dev/null)" ]]; then
    # 脏树先过恢复闸：满足条件就地备份+reset（rc=2，之后不再 stash）；不适用则维持原 stash 语义。
    clone_dirty_recovery "$id" "$dir" "$want" || recovery=$?
    (( recovery != 1 )) || return 1
    if (( recovery == 0 )); then
      git -C "$dir" stash push -u -q -m "autopilot: kept before redispatch $STAMP" || return 1
    fi
  fi
  if [[ -n "$base_branch" ]]; then
    [[ "$base_sha" =~ $SHA_RE ]] || return 1
    base_ref="refs/remotes/origin/$base_branch"
    if [[ "$local_only" == true ]]; then
      fetch_local_first "$dir" "$base_ref" "$base_ref" "$base_sha" || return 1
    else
      fetch_local_first "$dir" "$base_ref" "$base_ref" "$base_sha" \
        || git -C "$dir" fetch -q origin "+refs/heads/$base_branch:$base_ref" 2>/dev/null || return 1
    fi
    [[ "$(git -C "$dir" rev-parse -q --verify "$base_ref^{commit}" 2>/dev/null)" == "$base_sha" ]] || return 1
  fi
  if [[ -z "$branch" ]]; then
    git -C "$dir" checkout -q --detach refs/remotes/origin/main || return 1
  else
    if [[ "$local_only" == true ]]; then
      branch_head="$(git -C "$ROOT" rev-parse -q --verify "refs/remotes/origin/$branch^{commit}" 2>/dev/null || true)"
      if [[ "$branch_head" =~ $SHA_RE && ( -z "$want" || "$branch_head" == "$want" ) ]] \
        && fetch_local_first "$dir" "refs/remotes/origin/$branch" "refs/remotes/origin/$branch" "$branch_head"; then
        branch_ref_ok=1
      fi
    elif fetch_local_first "$dir" "refs/remotes/origin/$branch" "refs/remotes/origin/$branch" "$want" \
      || git -C "$dir" fetch -q origin "+refs/heads/$branch:refs/remotes/origin/$branch" 2>/dev/null; then
      branch_ref_ok=1
    fi
    if (( branch_ref_ok )); then
      # 本地分支领先 origin（上一轮已提交未推送）时保留它；分叉时先留备份 ref 再对齐 origin，提交不丢。
      if git -C "$dir" rev-parse -q --verify "refs/heads/$branch" >/dev/null \
        && git -C "$dir" merge-base --is-ancestor "refs/remotes/origin/$branch" "refs/heads/$branch"; then
        git -C "$dir" checkout -q "$branch" || return 1
      else
        git -C "$dir" rev-parse -q --verify "refs/heads/$branch" >/dev/null \
          && git -C "$dir" update-ref "refs/autopilot-kept/$branch-$TAG" "refs/heads/$branch"
        git -C "$dir" checkout -q -B "$branch" "refs/remotes/origin/$branch" || return 1
      fi
    elif [[ "$require_remote" == 1 ]]; then
      return 1
    elif git -C "$dir" rev-parse -q --verify "refs/heads/$branch" >/dev/null; then
      # 从未 push 的本地分支（无 PR 的直落单元）：保留它的本地提交，不重置回 main。
      git -C "$dir" checkout -q "$branch" || return 1
    elif [[ -n "$base_branch" ]]; then
      git -C "$dir" checkout -q -B "$branch" "$base_ref" || return 1
    else
      git -C "$dir" checkout -q -B "$branch" refs/remotes/origin/main || return 1
    fi
  fi
  printf '%s' "$dir"
}

ensure_clone() { # Keep clone preparation visible inside dispatch_pending's phase total.
  local started=$SECONDS id="${1:-unknown}" dir rc elapsed
  if dir="$(ensure_clone_impl "$@")"; then
    elapsed=$((SECONDS - started))
    (( elapsed < 2 )) || say "dispatch detail clone_prepare unit=$id secs=${elapsed}s"
    printf '%s' "$dir"
  else
    rc=$?
    elapsed=$((SECONDS - started))
    (( elapsed < 2 )) || say "dispatch detail clone_prepare unit=$id result=failed secs=${elapsed}s"
    return "$rc"
  fi
}

# Transfer the exited owner's committed and uncommitted work into the normal
# isolated scheduler clone; never mutate or remove the original worktree.
handoff_worktree_clone_impl() { # id branch old-worktree old-head dirty [require-remote] [rescued-ref] [rescued-sha] [stack-ref] [stack-sha]
  local id="$1" branch="$2" old_tree="$3" old_head="$4" dirty="$5" require_remote="${6:-0}" old_ref="${7:-}" rescue_sha="${8:-$4}" dir patch files current path handoff_head status=0
  local stack_ref="${9:-}" stack_sha="${10:-}"
  local heads=( "$old_head" )
  [[ "$old_head" =~ $SHA_RE ]] || return 1
  dir="$(ensure_clone "$id" "$branch" "$require_remote")" || return 1
  if [[ -n "$old_tree" || -z "$old_ref" || "$old_head" != "$rescue_sha" ]]; then
    git -C "$dir" fetch -q "$ROOT" "$old_head" || return 1
  fi
  if [[ -n "$old_ref" ]]; then
    [[ "$rescue_sha" =~ $SHA_RE ]] || return 1
    fetch_local_first "$dir" "refs/remotes/origin/$old_ref" "refs/remotes/origin/$old_ref" "$rescue_sha" \
      || git -C "$dir" fetch -q origin "+refs/heads/$old_ref:refs/remotes/origin/$old_ref" || return 1
    [[ "$(git -C "$dir" rev-parse --verify "refs/remotes/origin/$old_ref^{commit}")" == "$rescue_sha" ]] || return 1
    [[ "$rescue_sha" == "$old_head" ]] || heads+=( "$rescue_sha" )
  fi
  if [[ -n "$stack_ref" ]]; then
    [[ "$stack_sha" =~ $SHA_RE ]] || return 1
    fetch_local_first "$dir" "refs/remotes/origin/$stack_ref" "refs/remotes/origin/$stack_ref" "$stack_sha" \
      || git -C "$dir" fetch -q origin "+refs/heads/$stack_ref:refs/remotes/origin/$stack_ref" || return 1
    [[ "$(git -C "$dir" rev-parse --verify "refs/remotes/origin/$stack_ref^{commit}")" == "$stack_sha" ]] || return 1
    heads+=( "$stack_sha" )
  fi
  for handoff_head in "${heads[@]}"; do
    current="$(git -C "$dir" rev-parse --verify HEAD)" || return 1
    if git -C "$dir" merge-base --is-ancestor "$handoff_head" "$current"; then
      : # The branch already contains this handoff commit.
    elif git -C "$dir" merge-base --is-ancestor "$current" "$handoff_head"; then
      git -C "$dir" checkout -q -B "$branch" "$handoff_head" || return 1
    else
      # Keep the existing branch, owner commit and rescue when they diverge.
      if ! git -C "$dir" -c user.name=zenoforge-agent -c user.email=zenoforge-agent@users.noreply.github.com merge -q --no-edit "$handoff_head"; then
        git -C "$dir" merge --abort >/dev/null 2>&1 || true
        return 73
      fi
    fi
  done
  if [[ "$dirty" == true ]]; then
    [[ -d "$old_tree" && "$(git -C "$old_tree" rev-parse --verify HEAD 2>/dev/null)" == "$old_head" ]] || return 73
    patch="$(mktemp)" || return 1
    files="$(mktemp)" || { rm -f "$patch"; return 1; }
    git -C "$old_tree" diff --binary HEAD > "$patch" || status=$?
    if (( status == 0 )) && [[ -s "$patch" ]]; then git -C "$dir" apply --binary "$patch" || status=73; fi
    if (( status == 0 )); then git -C "$old_tree" ls-files --others --exclude-standard -z > "$files" || status=$?; fi
    if (( status == 0 )) && [[ -s "$files" ]]; then
      while IFS= read -r -d '' path; do
        if [[ -e "$dir/$path" || -L "$dir/$path" ]]; then
          say "handoff unit=$id: untracked owner file conflicts with $path in scheduler clone"
          status=73
          break
        fi
      done < "$files"
      if (( status == 0 )); then
        (set -o pipefail; tar -C "$old_tree" --null -T "$files" -cf - | tar -C "$dir" -xf -) || status=73
      fi
    fi
    # Anchor the exact dirty and untracked content in history before a worker
    # can report success. An unrelated push must not make it disappear.
    if (( status == 0 )); then git -C "$dir" add -u || status=$?; fi
    if (( status == 0 )) && [[ -s "$files" ]]; then
      git -C "$dir" --literal-pathspecs add -f --pathspec-from-file="$files" --pathspec-file-nul || status=$?
    fi
    rm -f "$patch" "$files"
    (( status == 0 )) || return "$status"
    if ! git -C "$dir" diff --cached --quiet; then
      git -C "$dir" -c user.name=zenoforge-agent -c user.email=zenoforge-agent@users.noreply.github.com \
        commit -q -m "preserve handoff work for $id" -m 'Co-Authored-By: Codex <codex@openai.com>' || return 1
    fi
  fi
  printf '%s' "$dir"
}
handoff_worktree_clone() { # Keep resume preparation visible inside dispatch_pending's phase total.
  local started=$SECONDS id="$1" dir rc elapsed
  if dir="$(handoff_worktree_clone_impl "$@")"; then
    elapsed=$((SECONDS - started))
    (( elapsed < 2 )) || say "dispatch detail resume_prepare unit=$id secs=${elapsed}s"
    printf '%s' "$dir"
  else
    rc=$?
    elapsed=$((SECONDS - started))
    (( elapsed < 2 )) || say "dispatch detail resume_prepare unit=$id result=failed secs=${elapsed}s"
    return "$rc"
  fi
}

record_handoff_integration() { # unit clone observed-PR-head
  local id="$1" dir="$2" original="$3" sha
  sha="$(git -C "$dir" rev-parse --verify HEAD)" || return 1
  [[ "$sha" =~ $SHA_RE ]] || return 1
  [[ -z "$original" || "$original" =~ $SHA_RE ]] || return 1
  set_unit "$id" ".handoff_integration_sha=$(js "$sha") | .handoff_original_pr_head=$(js "$original") | .handoff_delivery_verified_sha=null | if .handoff_worktree_sha != null then .handoff_worktree_applied=true else . end | if .handoff_start_ref != null then .handoff_start_applied=true else . end"
}

resume_handoff_integration() { # unit clone: preserve the recorded snapshot if the PR moved
  local id="$1" dir="$2" sha started=$SECONDS elapsed
  sha="$(unit_field "$id" '.handoff_integration_sha // empty')"
  [[ -n "$sha" ]] || return 0
  if git -C "$dir" merge-base --is-ancestor "$sha" HEAD 2>/dev/null; then
    elapsed=$((SECONDS - started))
    [[ "${TICK_DISPATCH_PENDING_ACTIVE:-false}" != true ]] || (( elapsed < 2 )) || say "dispatch detail resume_integration unit=$id secs=${elapsed}s"
    return 0
  fi
  if git -C "$dir" -c user.name=zenoforge-agent -c user.email=zenoforge-agent@users.noreply.github.com merge -q --no-edit "$sha"; then
    elapsed=$((SECONDS - started))
    [[ "${TICK_DISPATCH_PENDING_ACTIVE:-false}" != true ]] || (( elapsed < 2 )) || say "dispatch detail resume_integration unit=$id secs=${elapsed}s"
    return 0
  fi
  git -C "$dir" merge --abort >/dev/null 2>&1 || true
  to_supervisor "$id" "handoff snapshot conflicts with the updated branch; inspect the preserved work"
  elapsed=$((SECONDS - started))
  [[ "${TICK_DISPATCH_PENDING_ACTIVE:-false}" != true ]] || (( elapsed < 2 )) || say "dispatch detail resume_integration unit=$id result=failed secs=${elapsed}s"
  return 1
}

verify_handoff_delivery() { # unit PR branch reviewed-candidate
  local id="$1" pr="$2" branch="$3" candidate="$4" integrated original dirty dir
  integrated="$(unit_field "$id" '.handoff_integration_sha // empty')"
  [[ -n "$integrated" ]] || return 0
  [[ "$(unit_field "$id" '.handoff_delivery_verified_sha // empty')" != "$candidate" ]] || return 0
  original="$(unit_field "$id" '.handoff_original_pr_head // empty')"
  dirty="$(unit_field "$id" '.handoff_worktree_dirty // false')"
  dir="$WT_ROOT/wt-$id"
  if [[ "$dirty" == true && -n "$original" && "$candidate" == "$original" ]]; then
    to_supervisor "$id" "handoff repair did not deliver the preserved uncommitted work"
    return 1
  fi
  if [[ "$pr" =~ ^[0-9]+$ ]]; then
    git -C "$dir" fetch -q origin "+refs/heads/$branch:refs/remotes/origin/$branch" 2>/dev/null || return 1
  fi
  if ! git -C "$dir" merge-base --is-ancestor "$integrated" "$candidate" 2>/dev/null; then
    to_supervisor "$id" "handoff repair did not deliver the preserved commit history"
    return 1
  fi
  set_unit "$id" ".handoff_delivery_verified_sha=$(js "$candidate")"
}

# 评审 clone 检出被评审的 PR head：评审读的就是要合并的代码，diff 走本地 git，不依赖网络 API。
checkout_pr_head() { # dir pr candidate-sha observed-pr-head（candidate 可以是该 head 的本地修复后代）
  [[ -z "$2" ]] && { git -C "$1" checkout -q --detach "$3"; return; }
  local fetched_head
  git -C "$1" fetch -q origin "refs/pull/$2/head" \
    && fetched_head="$(git -C "$1" rev-parse --verify 'FETCH_HEAD^{commit}' 2>/dev/null)" \
    && [[ "$fetched_head" == "$4" ]] \
    && git -C "$1" checkout -q --detach "$3"
}
