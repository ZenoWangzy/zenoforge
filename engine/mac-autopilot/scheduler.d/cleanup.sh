
# ---------- 3b. 完成清理：终态单元回收 clone，台账瘦身，日志轮转 ----------
rotate_logs() {
  local f
  for f in "$LOG" "$A"/alerts/*.md; do
    [[ -f "$f" ]] || continue
    (( $(wc -c < "$f") > 5242880 )) && mv -f "$f" "$f.1"
  done
  return 0
}

worktree_cleanup_block_reason() { # dir -> reason when deleting it could lose recoverable Git work
  local wt="$1" status stash head remote_refs pushed_refs
  [[ -e "$wt/.git" ]] || return 1
  if ! status="$(git -C "$wt" status --porcelain=v1 --untracked-files=all 2>/dev/null)"; then
    printf 'could not inspect Git status'
    return 0
  fi
  [[ -z "$status" ]] || { printf 'uncommitted changes'; return 0; }
  if ! stash="$(git -C "$wt" stash list -n 1 2>/dev/null)"; then
    printf 'could not inspect Git stashes'
    return 0
  fi
  [[ -z "$stash" ]] || { printf 'Git stash exists'; return 0; }
  if ! head="$(git -C "$wt" rev-parse --verify HEAD 2>/dev/null)"; then
    printf 'could not inspect HEAD'
    return 0
  fi
  if ! remote_refs="$(git -C "$wt" for-each-ref --format='%(refname)' refs/remotes 2>/dev/null)"; then
    printf 'could not inspect remote-tracking refs'
    return 0
  fi
  [[ -n "$remote_refs" ]] || { printf 'no remote-tracking refs to verify HEAD'; return 0; }
  if ! pushed_refs="$(git -C "$wt" for-each-ref --contains "$head" --format='%(refname)' refs/remotes 2>/dev/null)"; then
    printf 'could not verify whether HEAD was pushed'
    return 0
  fi
  [[ -n "$pushed_refs" ]] || { printf 'HEAD is not reachable from a remote-tracking ref'; return 0; }
  return 1
}

cleanup_tick() {
  local id wt n_total b track r block_reason
  # eval 在途（pending/running）的单元保留 worktree：#4656 起 eval 并行跑，可能在单元 merged 之后才结束。
  for id in $(jqf -r '.units[] | select(.stage=="merged" or .stage=="landed" or .stage=="awaiting-live-event" or .stage=="done" or .stage=="wontfix" or .stage=="duplicate" or .stage=="closed") | select((.eval_gate.status // "") | IN("pending","running") | not) | .id' "$UNITS"); do
    for wt in "$WT_ROOT/wt-${id}" "/tmp/wt-${id}"; do
      [[ -d "$wt" ]] || continue
      if block_reason="$(worktree_cleanup_block_reason "$wt")"; then
        say "preserve worktree $wt: $block_reason"
      else
        rm -rf -- "$wt"
        say "cleanup worktree $wt"
      fi
    done
  done
  n_total="$(jqf '.workers | length' "$WORKERS" 2>/dev/null || echo 0)"
  if (( n_total > 60 )); then
    # 未回收的 worker 一律保留，只裁剪已回收的旧记录。
    jqf '{workers: ([.workers[] | select(.harvested != true)] + ([.workers[] | select(.harvested == true)] | sort_by(.started) | .[-60:]))}' "$WORKERS" | write_state "$WORKERS"
    say "trim workers ledger $n_total"
  fi
  # 只删一天无写入的超大日志：活 worker 的日志仍在写，不会被删。
  find "$SUP" -maxdepth 1 -name '*.worker.log' -size +4M -mmin +1440 -delete 2>/dev/null
  # worker 临时目录（runtime-env.sh 的 AP_TMPDIR）：一天没动的条目回收。
  [[ -n "${AP_TMPDIR:-}" && -d "$AP_TMPDIR" ]] && find "$AP_TMPDIR" -mindepth 1 -maxdepth 1 -mmin +1440 -exec rm -rf -- {} + 2>/dev/null
  # worker 常把日志、构建直接写到 /tmp（不走 TMPDIR）：WSL 的 /tmp 是 3.9G tmpfs，10-21 18:4x 再次写满（L72）。
  # 只收本用户、里外都 6 小时没写过的顶层条目；Claude Code 自己的 claude-* 不动，在跑的构建有新写入不会被收。
  local sys_tmp="${AP_SYSTEM_TMP:-/tmp}" e
  if [[ "${AP_SYSTEM_TMP_FS:-$(stat -f -c %T "$sys_tmp" 2>/dev/null)}" == tmpfs ]]; then
    while IFS= read -r -d '' e; do
      [[ -z "$(find "$e" -mmin -360 -print -quit 2>/dev/null)" ]] && rm -rf -- "$e"
    done < <(find "$sys_tmp" -mindepth 1 -maxdepth 1 -user "$(id -u)" -mmin +360 ! -name 'claude-*' -print0 2>/dev/null)
  fi
  # 本地分支只在"曾跟踪的远端分支已删除（[gone]）"时清理；从未 push 的本地分支不动。每小时一次。
  if [[ ! -f "$A/.branch-gc" || -n "$(find "$A/.branch-gc" -mmin +60 2>/dev/null)" ]]; then
    touch "$A/.branch-gc"
    if git -C "$ROOT" fetch -q --prune origin 2>/dev/null; then
      while read -r b track; do
        [[ "$track" == "[gone]" ]] || continue
        git -C "$ROOT" branch -q -D "$b" 2>/dev/null && say "cleanup local branch $b (upstream gone)"
      done < <(git -C "$ROOT" for-each-ref --format='%(refname:short) %(upstream:track)' 'refs/heads/agent/' 'refs/heads/fix/' 2>/dev/null)
    fi
    # 远端 rescued/* 收尾：issue 已关闭或无 issue 号超龄的先进 bundle（${AGENT_ARCHIVE}）再删，逐条记 rescued-gc.log。
    if [[ -f "$HERE/rescued_gc.sh" ]]; then
      r="$(timeout 600 bash "$HERE/rescued_gc.sh" "$ROOT" "$A/rescued-gc.log" 2>&1 | tail -1)"
      [[ -n "$r" ]] && say "$r"
    fi
  fi
}
