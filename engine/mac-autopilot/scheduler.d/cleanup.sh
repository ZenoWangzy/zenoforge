
# ---------- 3b. 完成清理：终态单元回收 clone，台账瘦身，日志轮转 ----------
rotate_logs() {
  local f
  for f in "$LOG" "$A"/alerts/*.md; do
    [[ -f "$f" ]] || continue
    (( $(wc -c < "$f") > 5242880 )) && mv -f "$f" "$f.1"
  done
  rotate_loop_out
  return 0
}
# Copy then truncate in place: the loop holds loop.out open with >> and only a restart would reopen it.
# Lines written between the copy and the truncate are lost. engine-canary's read_after_offset restarts
# from 0 when its offset is past the end of the file.
rotate_loop_out() {
  local f="$A/loop.out" limit="${AUTOPI_LOOP_OUT_MAX_BYTES:-104857600}"
  [[ -f "$f" ]] && (( $(wc -c < "$f") > limit )) || return 0
  gzip -c -- "$f" > "$f.tmp.gz" || { rm -f -- "$f.tmp.gz"; return 0; }
  [[ ! -e "$f.1.gz" ]] || mv -f -- "$f.1.gz" "$f.2.gz"
  mv -f -- "$f.tmp.gz" "$f.1.gz"
  : > "$f"
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

# A handoff cannot resume past a clone holding work, and only an inbox line used to follow. Move that work to rescued/ refs,
# which no workflow runs on (push triggers are main only) and which open no PR. Nothing in the clone changes until the
# remote has been read back, so any refusal leaves the work where it was. Work too large to read in passing stays for a person.
HANDOFF_RESCUE_MAX_FILES="${HANDOFF_RESCUE_MAX_FILES:-50}"
HANDOFF_RESCUE_MAX_FILE_KB="${HANDOFF_RESCUE_MAX_FILE_KB:-5120}"
rescue_push_verified() { # clone sha branch. The hook comes from the main checkout: rescued work could have edited or removed its own.
  local url remote
  [[ -x "$ROOT/scripts/hooks/pre-push" ]] || return 1
  # By URL: a push to the remote name moves origin/* at once, and that is what marks a head as safe to delete.
  url="$(git -C "$1" remote get-url origin)" || return 1
  timeout 60 git -C "$1" -c core.hooksPath="$ROOT/scripts/hooks" push -q "$url" "$2:refs/heads/$3" >/dev/null 2>&1 </dev/null || return 1
  remote="$(timeout 30 git -C "$1" ls-remote "$url" "refs/heads/$3" 2>/dev/null | awk 'NR==1{print $1}')"
  # Newer git moves origin/* on a push by URL too. That ref marks a head as safe to delete, so only the rescue writes it, once recorded.
  git -C "$1" update-ref -d "refs/remotes/origin/$3" "$2" 2>/dev/null || :
  [[ "$remote" == "$2" ]]
}
rescue_secret_scan() { # clone commit stash... -> 0 clean, 3 leak, else the scan did not happen
  local wt="$1" commit="$2" stream stash rc=0; shift 2
  command -v gitleaks >/dev/null || return 1
  # `gitleaks git` reports a clean exit when its git log fails, so the text is built here where every step can be checked.
  # --cc keeps a hand-resolved merge, and a stash's worktree edits live only in its merge commit, so each stash also goes as a diff.
  stream="$(mktemp)" || return 1
  git -C "$wt" log -p --cc --format= "$commit" "$@" --not --remotes > "$stream" 2>/dev/null || rc=1
  for stash in "$@"; do git -C "$wt" diff "$stash^1" "$stash" >> "$stream" 2>/dev/null || rc=1; done
  (( rc != 0 )) || timeout 120 gitleaks stdin --no-banner --redact --log-level error --exit-code 3 < "$stream" >/dev/null 2>&1 || rc=$?
  rm -f "$stream"
  return "$rc"
}
rescue_flagged_files_clean() { # clone -> 0 unless a flagged file hides an edit
  local wt="$1" entry path index rc=0
  local -a check=()
  # Sparse clones flag hundreds of absent files, which is normal: only an S entry that is gone from disk is passed over.
  while IFS= read -r -d '' entry; do
    path="${entry:2}"
    [[ "${entry:0:1}" == S && ! -e "$wt/$path" && ! -L "$wt/$path" ]] || check+=("$path")
  done < <(git -C "$wt" ls-files -v -z | grep -zE '^[a-zS] ')
  (( ${#check[@]} > 0 )) || return 0
  # Git itself compares them on a private index with the flags off, so content, mode, type and deletion all count.
  index="$(mktemp -u)"
  cp "$(git -C "$wt" rev-parse --absolute-git-dir)/index" "$index" || return 1
  printf '%s\0' "${check[@]}" | GIT_INDEX_FILE="$index" git -C "$wt" update-index -z --no-assume-unchanged --stdin 2>/dev/null \
    && printf '%s\0' "${check[@]}" | GIT_INDEX_FILE="$index" git -C "$wt" update-index -z --no-skip-worktree --stdin 2>/dev/null \
    && GIT_INDEX_FILE="$index" git -C "$wt" update-index -q --refresh >/dev/null 2>&1 \
    && GIT_INDEX_FILE="$index" git --literal-pathspecs -C "$wt" diff-files --quiet -- "${check[@]}" || rc=1
  rm -f "$index" "$index.lock"
  return "$rc"
}
rescue_handoff_clone() { # issue clone -> 0 once the clone holds nothing unrescued; else RESCUE_REFUSED says why
  local n="$1" wt="$2" status head commit tree raw index leftover ref="" stash stash_out stash_list="" scan=0 marker key objects sizes other path
  local -a stashes=()
  RESCUE_REFUSED=""; RESCUE_START_REF=""; RESCUE_START_SHA=""
  [[ -e "$wt/.git" ]] || { RESCUE_REFUSED="no clone"; return 1; }
  status="$(git -C "$wt" status --porcelain=v1 --untracked-files=all 2>/dev/null)" || { RESCUE_REFUSED="unreadable status"; return 1; }
  head="$(git -C "$wt" rev-parse --verify HEAD 2>/dev/null)" || { RESCUE_REFUSED="unreadable HEAD"; return 1; }
  stash_out="$(git -C "$wt" stash list --format=%H 2>/dev/null)" || { RESCUE_REFUSED="unreadable stash list"; return 1; }
  [[ -z "$stash_out" ]] || mapfile -t stashes <<<"$stash_out"
  for path in MERGE_HEAD CHERRY_PICK_HEAD REVERT_HEAD BISECT_LOG rebase-merge rebase-apply; do
    [[ ! -e "$(git -C "$wt" rev-parse --absolute-git-dir)/$path" ]] || { RESCUE_REFUSED="$path in progress"; return 1; }
  done
  # A leak does not go away by retrying: skip the scan until the clone changes.
  marker="$A/rescue-refused-$n"; key="$(printf '%s\n' "$head" "$status" "$stash_out" | sha256sum)"
  [[ "$(cat "$marker" 2>/dev/null)" != "$key" ]] || { RESCUE_REFUSED="secret scan refused an earlier pass"; return 1; }
  # Active handoff worktrees are owned by the current handoff, not unpublished work in the old clone.
  other="$(git -C "$wt" rev-list -n1 --exclude='hand/*' --branches --not --remotes "$head" 2>/dev/null)" || { RESCUE_REFUSED="unreadable branches"; return 1; }
  [[ -z "$other" ]] || { RESCUE_REFUSED="unpushed commits on another branch"; return 1; }
  # What the private index below cannot see: conflicted entries, flagged files, and a staged version later edited in the worktree.
  [[ -z "$(git -C "$wt" ls-files -u)" ]] || { RESCUE_REFUSED="unmerged index"; return 1; }
  rescue_flagged_files_clean "$wt" || { RESCUE_REFUSED="assume-unchanged or skip-worktree edit"; return 1; }
  [[ -z "$(comm -12 <(git -C "$wt" diff --cached --name-only | sort) <(git -C "$wt" diff --name-only | sort))" ]] || { RESCUE_REFUSED="staged content differs from the worktree"; return 1; }
  commit="$head"
  if [[ -n "$status" ]]; then
    # A private index and commit-tree: the clone's index, branch and files stay untouched until the push is proved.
    # A copy of the real index, not read-tree: only the flags in it stop add -A recording a sparse clone's absent files as deletions.
    index="$(mktemp -u)"
    tree="$(cp "$(git -C "$wt" rev-parse --absolute-git-dir)/index" "$index" && GIT_INDEX_FILE="$index" git -C "$wt" add -A 2>/dev/null && GIT_INDEX_FILE="$index" git -C "$wt" write-tree)" \
      || { rm -f "$index" "$index.lock"; RESCUE_REFUSED="could not build the rescue tree"; return 1; }
    leftover="$(GIT_INDEX_FILE="$index" git -C "$wt" status --porcelain=v1 --untracked-files=all 2>/dev/null)" \
      || { rm -f "$index" "$index.lock"; RESCUE_REFUSED="could not read the rescue tree"; return 1; }
    rm -f "$index"
    raw="$(git -C "$wt" diff-tree -r --no-commit-id --raw --no-abbrev "$head" "$tree")" || { RESCUE_REFUSED="could not read the rescue tree"; return 1; }
    (( $(grep -c . <<<"$raw") <= HANDOFF_RESCUE_MAX_FILES )) || { RESCUE_REFUSED="more than $HANDOFF_RESCUE_MAX_FILES changed files"; return 1; }
    # A nested repo becomes a gitlink: its files would not travel, yet the clone would look clean.
    ! awk '$2 == "160000"' <<<"$raw" | grep -q . || { RESCUE_REFUSED="nested repository or submodule change"; return 1; }
    # add -A skips paths outside the sparse patterns. Seen only after the push, each tick would leave another ref for a clone that stays blocked.
    ! grep -q '^.[^ ]' <<<"$leftover" || { RESCUE_REFUSED="files the rescue tree leaves out"; return 1; }
    commit="$(git -C "$wt" -c user.name=zenoforge-agent -c user.email=zenoforge-agent@users.noreply.github.com commit-tree "$tree" -p "$head" -m "rescue: uncommitted work from the clone of #$n")" \
      || { RESCUE_REFUSED="could not build the rescue commit"; return 1; }
  fi
  for stash in ${stashes[@]+"${stashes[@]}"}; do
    if git -C "$wt" rev-parse -q --verify "$stash^3" >/dev/null 2>&1 \
      && git -C "$wt" ls-tree -r --name-only "$stash^3" | git -C "$wt" check-ignore -q --no-index --stdin; then
      RESCUE_REFUSED="stash holds ignored files"; return 1
    fi
  done
  # Everything about to leave, stashes and unpushed commits too, not only the uncommitted files.
  objects="$(git -C "$wt" rev-list --objects "$commit" ${stashes[@]+"${stashes[@]}"} --not --remotes 2>/dev/null)" || { RESCUE_REFUSED="could not list outgoing objects"; return 1; }
  sizes="$(awk '{print $1}' <<<"$objects" | git -C "$wt" cat-file --batch-check='%(objecttype) %(objectsize)' 2>/dev/null)" || { RESCUE_REFUSED="could not size outgoing objects"; return 1; }
  [[ "$(awk -v max="$((HANDOFF_RESCUE_MAX_FILE_KB * 1024))" '$1 == "blob" && $2 > max {found = 1} END {print found + 0}' <<<"$sizes")" == 0 ]] || { RESCUE_REFUSED="file over ${HANDOFF_RESCUE_MAX_FILE_KB}KB"; return 1; }
  rescue_secret_scan "$wt" "$commit" ${stashes[@]+"${stashes[@]}"} || scan=$?
  if (( scan == 3 )); then printf '%s\n' "$key" > "$marker"; RESCUE_REFUSED="secret scan found a leak"; return 1; fi
  (( scan == 0 )) || { RESCUE_REFUSED="secret scan could not run"; return 1; }
  for stash in ${stashes[@]+"${stashes[@]}"}; do
    rescue_push_verified "$wt" "$stash" "rescued/stash-of-$n-$stash" || { RESCUE_REFUSED="stash push failed"; return 1; }
    stash_list+=" rescued/stash-of-$n-$stash"
  done
  if [[ -z "$(git -C "$wt" for-each-ref --contains "$commit" --format='%(refname)' refs/remotes 2>/dev/null)" ]]; then
    ref="rescued/agent-issue-$n-$commit"
    rescue_push_verified "$wt" "$commit" "$ref" || { RESCUE_REFUSED="rescue push failed"; return 1; }
    ( source "$SCHEDULER_AGENT_LIB"; state_merge "$n" ".scheduler_handoff.start_ref = $(js "$ref") | .scheduler_handoff.start_sha = $(js "$commit")" ) \
      || { RESCUE_REFUSED="could not record the rescue ref"; return 1; }
    git -C "$wt" update-ref "refs/remotes/origin/$ref" "$commit" || { RESCUE_REFUSED="could not record the rescue ref locally"; return 1; }
    RESCUE_START_REF="$ref"; RESCUE_START_SHA="$commit"
  fi
  [[ "$commit" == "$head" ]] || git -C "$wt" reset -q --mixed "$commit" || { RESCUE_REFUSED="could not move the clone to its rescue commit"; return 1; } # the files already match it
  (( ${#stashes[@]} == 0 )) || git -C "$wt" stash clear || { RESCUE_REFUSED="could not clear rescued stashes"; return 1; }
  rm -f "$marker"
  if worktree_cleanup_block_reason "$wt" >/dev/null; then RESCUE_REFUSED="clone still blocks after the rescue"; return 1; fi
  gh issue comment "$n" --body "Work from the preserved clone is saved on the remote.${ref:+ The handoff resumes from \`$ref\`.}${stash_list:+ Stashes, not applied:$stash_list.}" >/dev/null 2>&1 </dev/null \
    || say "handoff issue #$n: could not post the rescue refs: ${ref}${stash_list}"
}

# A refused clone left in place blocks its handoff for good (#5791 waited 11 h): set it aside, mode 700, and let the handoff start fresh.
# Keep scan refusals plus ignored stash data and unpushed branch commits out of scans and uploads. No sweep, scan or upload may read a *.preserved-* dir.
preserve_refused_clone() { # issue unit clone -> 0 once the clone is set aside; the inbox line names the unit and the path, never content
  local n="$1" id="$2" wt="$3" dest
  case "$RESCUE_REFUSED" in
    "secret scan found a leak"|"secret scan refused an earlier pass"|"stash holds ignored files"|"unpushed commits on another branch") ;;
    *) return 1 ;;
  esac
  dest="$WT_ROOT/wt-$id.preserved-$(date -u +%Y%m%dT%H%MZ)"
  [[ "$wt" == "$WT_ROOT/wt-$id" && ! -e "$dest" ]] && chmod 700 "$wt" && mv -- "$wt" "$dest" || return 1
  rm -f "$A/rescue-refused-$n"
  say "handoff issue #$n: rescue refused the clone of $id; moved to $dest (mode 700, never pushed or scanned again, deleted after 7 days)"
  (source "$SCHEDULER_AGENT_LIB"; supervisor_inbox_append_once "handoff-preserved-clone-aside:$n:$id:${dest##*.preserved-}" \
    "handoff-preserved-clone-aside unit=$id path=$dest") || say "handoff issue #$n: could not notify supervisor about $dest"
}
expire_preserved_clones() { # *.preserved-* dirs 7 days after the stamp in their name; only that exact name pattern under WT_ROOT is removed
  local d name epoch
  for d in "$WT_ROOT"/wt-*.preserved-*; do
    name="${d##*/}"
    [[ "$name" =~ ^wt-[A-Za-z0-9._-]+\.preserved-([0-9]{8})T([0-9]{2})([0-9]{2})Z$ && -d "$d" && ! -L "$d" ]] || continue
    epoch="$(date -u -d "${BASH_REMATCH[1]} ${BASH_REMATCH[2]}:${BASH_REMATCH[3]}" +%s 2>/dev/null)" || continue
    (( ${NOW_EPOCH:-$(date +%s)} - epoch > 604800 )) || continue
    remove_readonly_tree "$d" && say "cleanup preserved clone $d (older than 7 days)"
  done
}

# Engine version trees are read-only, and plain rm -rf cannot empty a read-only directory.
remove_readonly_tree() {
  find "$1" -type d ! -perm -u=w -exec chmod u+w -- {} + 2>/dev/null
  rm -rf -- "$1"
}

cleanup_unit_worktrees() { # id：终态单元的两个 worktree 位置；有可恢复 Git 工作时保留并说明
  local id="$1" wt block_reason
  declare -p PRESERVE_KEEP >/dev/null 2>&1 || local -A PRESERVE_SEEN=() PRESERVE_KEEP=() # a caller outside cleanup_tick keeps no verdicts
  for wt in "$WT_ROOT/wt-${id}" "/tmp/wt-${id}"; do
    [[ -d "$wt" ]] || continue
    # cleanup_tick's deadline (its locals, by dynamic scope): count what the walk leaves instead of walking on.
    if [[ -n "${CLEANUP_DEADLINE:-}" ]] && (( SECONDS >= CLEANUP_DEADLINE )); then
      CLEANUP_LEFT=$((CLEANUP_LEFT + 1)); [[ -z "${PRESERVE_SEEN[$wt]:-}" ]] || PRESERVE_KEEP[$wt]="${PRESERVE_SEEN[$wt]}" # not reached: its verdict stands
      continue
    fi
    # A kept worktree is kept again without the git walk until its verdict is AUTOPI_WORKTREE_PRESERVE_RECHECK_SECONDS old: the same 44 kept
    # worktrees cost 24 s of git status and for-each-ref per tick (2026-11-07 timing). Only a preserve verdict is reused, so a stale one keeps work, never deletes it.
    if [[ -n "${PRESERVE_SEEN[$wt]:-}" ]] && (( NOW_EPOCH - PRESERVE_SEEN[$wt] < ${AUTOPI_WORKTREE_PRESERVE_RECHECK_SECONDS:-3600} )); then
      PRESERVE_KEEP[$wt]="${PRESERVE_SEEN[$wt]}"
    elif block_reason="$(worktree_cleanup_block_reason "$wt")"; then
      say "preserve worktree $wt: $block_reason"
      PRESERVE_KEEP[$wt]="$NOW_EPOCH"
    else
      rm -rf -- "$wt"
      say "cleanup worktree $wt"
    fi
  done
}

cleanup_tick() {
  local id wt n_total b track r block_reason
  # 43 preserve lines under load ran the tick into its kill in this walk (2026-11-07): stop with time left for the end of the tick.
  local CLEANUP_DEADLINE=$(( ${AUTOPI_TICK_LIMIT_SECONDS:-1800} - 120 )) CLEANUP_LEFT=0
  local -A PRESERVE_SEEN=() PRESERVE_KEEP=() # path -> epoch of its preserve verdict; read and written by cleanup_unit_worktrees (dynamic scope)
  local preserve_file="$A/.worktree-preserved" preserve_epoch preserve_path
  if [[ -r "$preserve_file" ]]; then
    while IFS=$'\t' read -r preserve_epoch preserve_path; do
      [[ "$preserve_epoch" =~ ^[0-9]+$ && -n "$preserve_path" ]] && PRESERVE_SEEN["$preserve_path"]="$preserve_epoch"
    done < "$preserve_file"
  fi
  # eval 在途（pending/running）的单元保留 worktree：#4656 起 eval 并行跑，可能在单元 merged 之后才结束。
  for id in $(jqf -r '.units[] | select(.stage=="merged" or .stage=="landed" or .stage=="awaiting-live-event" or .stage=="done" or .stage=="wontfix" or .stage=="duplicate" or .stage=="closed") | select((.eval_gate.status // "") | IN("pending","running") | not) | .id' "$UNITS"); do
    cleanup_unit_worktrees "$id"
  done
  # 退休只移台账行不清磁盘：归档单元的 worktree 沿用同一保留/回收判定，不会因退休而泄漏或误删。
  if [[ -s "$UNITS_ARCHIVE" ]]; then
    while IFS= read -r id; do
      [[ -n "$id" ]] || continue
      cleanup_unit_worktrees "$id"
    done < <(jqf -r --slurpfile live "$UNITS" '.units[] | select((.eval_gate.status // "") | IN("pending","running") | not) | select(.id as $i | any($live[0].units[]; .id == $i) | not) | .id' "$UNITS_ARCHIVE" 2>/dev/null) # a restored unit is live again: its worktree is not cleanup's
  fi
  for preserve_path in "${!PRESERVE_KEEP[@]}"; do printf '%s\t%s\n' "${PRESERVE_KEEP[$preserve_path]}" "$preserve_path"; done > "$preserve_file.tmp" 2>/dev/null && mv -f -- "$preserve_file.tmp" "$preserve_file"
  (( SECONDS >= CLEANUP_DEADLINE )) || expire_preserved_clones
  (( CLEANUP_LEFT == 0 )) || say "cleanup worktree walk stopped at ${SECONDS}s: left $CLEANUP_LEFT worktrees for the next tick"
  n_total="$(jqf '.workers | length' "$WORKERS" 2>/dev/null || echo 0)"
  if (( n_total > 60 )); then
    # 未回收的 worker 一律保留，只裁剪已回收的旧记录。
    # The tick's tail runs without the ledger lock, so this one write takes it (set_unit's own-lock pattern).
    # 2026-11-08: a refill held the ledger lock and this wait ran the tick into its 1800 s kill. The wait is bounded; a busy lock skips the trim to the next tick.
    local own_lock=false t0=$SECONDS
    if [[ "${SCHED_LOCK_HELD:-false}" != true ]]; then acquire_scheduler_lock_wait 5 && own_lock=true; fi
    if [[ "${SCHED_LOCK_HELD:-false}" == true ]]; then
      jqf '{workers: ([.workers[] | select(.harvested != true)] + ([.workers[] | select(.harvested == true)] | sort_by(.started) | .[-60:]))}' "$WORKERS" | write_state "$WORKERS"
      say "trim workers ledger $n_total secs=$((SECONDS - t0))"
    else
      say "cleanup trim skipped at ${SECONDS}s: ledger lock busy"
    fi
    [[ "$own_lock" != true ]] || release_scheduler_lock
  fi
  # 只删一天无写入的超大日志：活 worker 的日志仍在写，不会被删。
  find "$SUP" -maxdepth 1 -name '*.worker.log' -size +4M -mmin +1440 -delete 2>/dev/null
  # worker-<unit>.pid (worker-scope.sh): drop a file whose worker is gone; a live worker keeps its file however old.
  local pf pf_pid
  for pf in "$SUP"/worker-*.pid; do
    [[ -e "$pf" ]] && read -r pf_pid < "$pf" 2>/dev/null && [[ "$pf_pid" =~ ^[1-9][0-9]*$ && ! -d "/proc/$pf_pid" ]] && rm -f -- "$pf"
  done
  # worker 临时目录（runtime-env.sh 的 AP_TMPDIR）：一天没动的条目回收。
  local tmp_entry
  if [[ -n "${AP_TMPDIR:-}" && -d "$AP_TMPDIR" ]]; then
    while IFS= read -r -d '' tmp_entry; do
      remove_readonly_tree "$tmp_entry" 2>/dev/null
    done < <(find "$AP_TMPDIR" -mindepth 1 -maxdepth 1 -mmin +1440 -print0 2>/dev/null)
  fi
  # worker 常把日志、构建直接写到 /tmp（不走 TMPDIR）：WSL 的 /tmp 是 3.9G tmpfs，10-21 18:4x 再次写满（L72）。
  # 只收本用户、里外都 6 小时没写过的顶层条目；Claude Code 自己的 claude-* 不动，在跑的构建有新写入不会被收。
  local sys_tmp="${AP_SYSTEM_TMP:-/tmp}" e
  if [[ "${AP_SYSTEM_TMP_FS:-$(stat -f -c %T "$sys_tmp" 2>/dev/null)}" == tmpfs ]]; then
    while IFS= read -r -d '' e; do
      [[ -z "$(find "$e" -mmin -360 -print -quit 2>/dev/null)" ]] && remove_readonly_tree "$e"
    done < <(find "$sys_tmp" -mindepth 1 -maxdepth 1 -user "$(id -u)" -mmin +360 ! -name 'claude-*' -print0 2>/dev/null)
  fi
  # 本地分支只在"曾跟踪的远端分支已删除（[gone]）"时清理；从未 push 的本地分支不动。每小时一次。
  if (( SECONDS < CLEANUP_DEADLINE )) && { [[ ! -f "$A/.branch-gc" ]] || [[ -n "$(find "$A/.branch-gc" -mmin +60 2>/dev/null)" ]]; }; then
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
