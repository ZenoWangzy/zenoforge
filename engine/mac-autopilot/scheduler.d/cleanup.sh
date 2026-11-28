
# ---------- 3b. 完成清理：终态单元回收 clone，台账瘦身，日志轮转 ----------
rotate_logs() {
  local f
  for f in "$LOG" "$A"/alerts/*.md; do
    [[ -f "$f" ]] || continue
    (( $(wc -c < "$f") > 5242880 )) && mv -f "$f" "$f.1"
  done
  if [[ -d "$AGENT_HOME/logs" ]]; then
    find "$AGENT_HOME/logs" -maxdepth 1 -type f -name 'triage-triage-batch-*.log' -mtime +7 -delete 2>/dev/null || :
  fi
  rotate_loop_out
  rotate_gh_measure
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

rotate_gh_measure() {
  local f="${ZF_GH_MEASURE_FILE:-${AGENT_HOME:-${ZF_HOME:-$HOME/.zenoforge}}/measure/gh-calls.tsv}"
  local limit="${ZF_GH_MEASURE_MAX_BYTES:-67108864}"
  [[ -f "$f" ]] && (( $(wc -c < "$f") > limit )) || return 0
  mv -f -- "$f" "$f.1"
}

worktree_cleanup_block_reason() { # dir -> reason when deleting it could lose recoverable Git work
  local wt="$1" status stash head remote_refs pushed_refs unpushed_commits
  [[ -e "$wt/.git" ]] || return 1
  if ! status="$(git -C "$wt" status --porcelain=v1 --untracked-files=normal 2>/dev/null)"; then
    printf 'could not inspect Git status'
    return 0
  fi
  [[ -z "$status" ]] || { printf 'uncommitted changes'; return 0; }
  if ! rescue_flagged_files_clean "$wt"; then
    printf 'flagged files may contain changes'
    return 0
  fi
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
  if ! unpushed_commits="$(git -C "$wt" rev-list --exclude='refs/heads/hand/*' --all --not --remotes -n 1 2>/dev/null)"; then
    printf 'could not inspect local commits'
    return 0
  fi
  [[ -z "$unpushed_commits" ]] || { printf 'local commits are not pushed'; return 0; }
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
# A merge whose owner died leaves MERGE_HEAD and blocks the handoff forever. A finished one (no unmerged path, no live owner,
# older than a tick) is saved as diffs and its unpushed commits are pushed to rescued/*, then it is aborted. A failed push keeps
# everything in place. Anything else stays, and its log line names the owner.
rescue_merge_head() { # clone -> 0 once no merge is in progress; else RESCUE_REFUSED says why
  local wt="$1" mh id sha unmerged owner tick once="$A/merge-head-once" key
  mh="$(git -C "$wt" rev-parse --absolute-git-dir)/MERGE_HEAD"
  [[ -e "$mh" ]] || return 0
  id="$(basename -- "$wt")"; id="${id#wt-}"
  sha="$(git -C "$wt" rev-parse -q --verify MERGE_HEAD 2>/dev/null)" || { RESCUE_REFUSED="unreadable MERGE_HEAD"; return 1; }
  unmerged="$(git -C "$wt" diff --name-only --diff-filter=U 2>/dev/null)" || { RESCUE_REFUSED="unreadable merge state"; return 1; }
  clone_worktree_owner_live "$id"; owner=$? # 0 live worker, 1 none, 3 unknown: the check clone_dirty_recovery uses for an open merge
  if [[ -n "$unmerged" ]]; then
    RESCUE_REFUSED="MERGE_HEAD with unmerged paths"; key="$id $sha"
    if ! grep -Fqx -- "$key" "$once" 2>/dev/null; then
      printf '%s\n' "$key" >> "$once"
      say "handoff rescue unit=$id MERGE_HEAD with unmerged paths; owner=$([[ $owner == 0 ]] && echo worker || echo head)"
    fi
    return 1
  fi
  tick="$(jq -r '.tick_seconds // 120' "$A/config.json" 2>/dev/null)"; [[ "$tick" =~ ^[0-9]+$ ]] || tick=120
  if (( owner != 1 )) || (( ${NOW_EPOCH:-$(date +%s)} - $(stat -c %Y "$mh") <= tick )); then
    RESCUE_REFUSED="MERGE_HEAD in progress"; return 1
  fi
  rescue_keep_dir "$id" || { RESCUE_REFUSED="could not save the merge"; return 1; }
  git -C "$wt" diff --cached --binary > "$RESCUE_DIR/staged.patch" && git -C "$wt" diff --binary > "$RESCUE_DIR/unstaged.patch" \
    && printf '%s\n' "$sha" > "$RESCUE_DIR/MERGE_HEAD" || { RESCUE_REFUSED="could not save the merge diffs"; return 1; }
  rescue_push_unpushed "$wt" "$id" "$RESCUE_DIR" || return 1 # the commits reach the remote before the merge is aborted
  git -C "$wt" merge --abort >/dev/null 2>&1 && [[ ! -e "$mh" ]] || { RESCUE_REFUSED="could not abort the finished merge"; return 1; }
  say "handoff rescue unit=$id merge aborted: saved $RESCUE_DIR"
}
# A local copy of a rescue lives in the unit's preserved dir, marked push-pending until its commits are on the remote (expire_preserved_clones
# keeps a marked dir). RESCUE_DIR is the dir: the unit's pending one when a push failed earlier, else a new one.
rescue_keep_dir() { # unit -> 0 with RESCUE_DIR set
  local id="$1" d
  RESCUE_DIR=""
  for d in "$WT_ROOT"/wt-"$id".preserved-*; do [[ -e "$d/push-pending" ]] && { RESCUE_DIR="$d"; break; }; done
  [[ -n "$RESCUE_DIR" ]] || RESCUE_DIR="$WT_ROOT/wt-$id.preserved-$(date -u +%Y%m%dT%H%MZ)"
  mkdir -p -m 700 -- "$RESCUE_DIR" 2>/dev/null && : > "$RESCUE_DIR/push-pending"
}
# Every commit no remote holds goes to rescued/<unit>-<stamp> (HEAD) or rescued/<unit>-<stamp>-<branch>, with a patch copy in dir.
# A failed push keeps dir and its push-pending mark, and refuses without touching stashes or merge state (rescue_push_failed reports it).
# rescue_push_failed: one log line and one supervisor inbox line per path+SHA; the once file (clones.sh pattern) gates both on every tick.
rescue_push_failed() { # unit dir sha
  local key="$2 $3" once="$A/rescue-push-failed.once"
  grep -Fqx -- "$key" "$once" 2>/dev/null && return 0
  printf '%s\n' "$key" >> "$once"
  say "handoff rescue unit=$1 push failed: kept $2; owner=head"
  (source "$SCHEDULER_AGENT_LIB"; supervisor_inbox_append_once "rescue-push-failed:$1:$3" "rescue-push-failed unit=$1 path=$2") \
    || say "handoff rescue unit=$1: could not notify supervisor about $2"
}
rescue_push_unpushed() { # clone unit dir -> 0 once all are on the remote; else RESCUE_REFUSED says why
  local wt="$1" id="$2" dir="$3" name sha ref unpushed head_sha head_branch i=0
  head_sha="$(git -C "$wt" rev-parse --verify HEAD 2>/dev/null)" || { RESCUE_REFUSED="unreadable HEAD"; return 1; }
  head_branch="$(git -C "$wt" symbolic-ref --quiet --short HEAD 2>/dev/null || true)"
  while read -r name sha; do
    unpushed="$(git -C "$wt" rev-list -n1 "$sha" --not --remotes 2>/dev/null)" || { RESCUE_REFUSED="unreadable branches"; return 1; }
    [[ -n "$unpushed" ]] || continue
    if [[ "$name" == HEAD ]]; then ref="rescued/$id-${dir##*.preserved-}"
    elif [[ "$sha" == "$head_sha" ]]; then continue
    else ref="rescued/$id-${dir##*.preserved-}-$name"; fi
    i=$((i + 1))
    git -C "$wt" format-patch -q -o "$dir/unpushed-$i" "$sha" --not --remotes >/dev/null 2>&1 || { RESCUE_REFUSED="could not copy the unpushed commits"; return 1; }
    rescue_push_verified "$wt" "$sha" "$ref" || { RESCUE_REFUSED="rescue push failed"; rescue_push_failed "$id" "$dir" "$sha"; return 1; }
  done < <({ [[ "$head_branch" == hand/* ]] || printf 'HEAD %s\n' "$head_sha"; git -C "$wt" for-each-ref --format='%(refname:short) %(objectname)' refs/heads; } | awk '$1 !~ /^hand\//')
  rm -f -- "$dir/push-pending"
}
# Unpushed commits on another branch block the handoff for good. With no live owner they are pushed first; the stash then goes
# through the normal rescued/stash-of-* push. A stash with untracked or ignored files still refuses (preserve_refused_clone takes it).
rescue_unpushed_local() { # clone -> 0 once every unpushed commit is on the remote; else RESCUE_REFUSED says why
  local wt="$1" id owner
  id="$(basename -- "$wt")"; id="${id#wt-}"
  clone_worktree_owner_live "$id"; owner=$?
  (( owner == 1 )) || { RESCUE_REFUSED="unpushed commits on another branch"; return 1; }
  rescue_keep_dir "$id" || { RESCUE_REFUSED="could not save the unpushed commits"; return 1; }
  rescue_push_unpushed "$wt" "$id" "$RESCUE_DIR" || return 1
  say "handoff rescue unit=$id stash/unpushed saved $RESCUE_DIR"
}
rescue_handoff_clone() { # issue clone -> 0 once the clone holds nothing unrescued; else RESCUE_REFUSED says why
  local n="$1" wt="$2" status head commit tree raw index leftover ref="" stash stash_out stash_list="" scan=0 marker key objects sizes other path
  local -a stashes=()
  RESCUE_REFUSED=""; RESCUE_START_REF=""; RESCUE_START_SHA=""
  [[ -e "$wt/.git" ]] || { RESCUE_REFUSED="no clone"; return 1; }
  rescue_merge_head "$wt" || return 1
  status="$(git -C "$wt" status --porcelain=v1 --untracked-files=all 2>/dev/null)" || { RESCUE_REFUSED="unreadable status"; return 1; }
  head="$(git -C "$wt" rev-parse --verify HEAD 2>/dev/null)" || { RESCUE_REFUSED="unreadable HEAD"; return 1; }
  stash_out="$(git -C "$wt" stash list --format=%H 2>/dev/null)" || { RESCUE_REFUSED="unreadable stash list"; return 1; }
  [[ -z "$stash_out" ]] || mapfile -t stashes <<<"$stash_out"
  for path in CHERRY_PICK_HEAD REVERT_HEAD BISECT_LOG rebase-merge rebase-apply; do
    [[ ! -e "$(git -C "$wt" rev-parse --absolute-git-dir)/$path" ]] || { RESCUE_REFUSED="$path in progress"; return 1; }
  done
  # A leak does not go away by retrying: skip the scan until the clone changes.
  marker="$A/rescue-refused-$n"; key="$(printf '%s\n' "$head" "$status" "$stash_out" | sha256sum)"
  [[ "$(cat "$marker" 2>/dev/null)" != "$key" ]] || { RESCUE_REFUSED="secret scan refused an earlier pass"; return 1; }
  # Active handoff worktrees are owned by the current handoff, not unpublished work in the old clone.
  other="$(git -C "$wt" rev-list -n1 --exclude='hand/*' --branches --not --remotes "$head" 2>/dev/null)" || { RESCUE_REFUSED="unreadable branches"; return 1; }
  if [[ -n "$other" ]]; then rescue_unpushed_local "$wt" || return 1; fi
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
    [[ ! -e "$d/push-pending" ]] || continue # its commits never reached the remote: kept until a push lands
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

clone_pool_sweep_advance() {
  local queue_dir="$1" batch_index="$2" batch_count="$3" current_index batch_name rc=0
  [[ "${SCHED_LOCK_HELD:-false}" != true ]] || return 1
  acquire_scheduler_lock_wait 5 || return 1
  if [[ -d "$queue_dir" ]]; then
    current_index="$(cat "$queue_dir/index" 2>/dev/null || printf '0')"
    [[ "$current_index" =~ ^[0-9]+$ ]] || current_index=0
    if (( current_index <= batch_index )); then
      current_index=$((batch_index + 1))
      printf '%s\n' "$current_index" > "$queue_dir/index.tmp.$$" \
        && mv -f -- "$queue_dir/index.tmp.$$" "$queue_dir/index" || rc=1
    fi
    printf -v batch_name '%06d' "$batch_index"
    rm -f -- "$queue_dir/$batch_name"
    (( current_index < batch_count )) || rm -rf -- "$queue_dir"
  fi
  release_scheduler_lock
  return "$rc"
}

clone_pool_file_identity() {
  [[ -e "$1" ]] || { printf 'missing'; return 0; }
  stat -c '%d:%i:%s:%y:%z' -- "$1" 2>/dev/null
}

clone_pool_coord_claimed() {
  local key="$1" rc
  if [[ "${ZF_COORD:-off}" != on && ! -e "$COORD_DIR/$key.json" ]]; then return 1; fi
  if coord_read "$key" >/dev/null 2>&1; then return 0; else rc=$?; fi
  (( rc == 1 )) && return 1
  return 0
}

clone_pool_owner_claimed() {
  local id="$1" issue="${2:-}" key rc
  if [[ "$issue" =~ ^[1-9][0-9]*$ ]]; then
    key="$(coord_issue_key "$issue")" || return 0
    if clone_pool_coord_claimed "$key"; then return 0; else rc=$?; fi
    (( rc == 1 )) || return 0
  fi
  key="$(coord_unit_key "$id")" || return 0
  clone_pool_coord_claimed "$key"
}

cleanup_stale_clones() {
  local queue_dir="$A/.clone-pool-sweep" last_sweep_file="$A/.clone-pool-sweep-at" build_dir="" own_lock=false lock_ready=false reap_path
  local path dir name index index_mtime index_identity root_identity id issue status ledger records worker_records record worker_unit worker_path worker_issue
  local batch_name batch_file batch_count=0 batch_index=0 batch_lines=0 candidate_json candidate_paths_json candidate_issues_json candidate_index candidate_identity coord_key
  local units_before units_after archive_before archive_after workers_before workers_after ledger_ok=true
  local now_epoch="${NOW_EPOCH:-$(date +%s)}" last_sweep=0 max_per_tick=50 max_age_seconds=604800 batch_complete=true
  local -A eval_pending=() candidate_issue=() worker_live=()
  local -a candidate_names=() candidate_ids=() candidate_roots=() candidate_issues=() safe_names=() safe_ids=() safe_roots=() safe_indexes=() reaped_paths=()
  [[ -d "$WT_ROOT" ]] || return 0
  if [[ ! -d "$queue_dir" ]]; then
    last_sweep="$(cat "$last_sweep_file" 2>/dev/null || true)"
    [[ "$last_sweep" =~ ^[0-9]+$ ]] || last_sweep=0
    (( now_epoch - last_sweep >= 21600 )) || return 0
    build_dir="$(mktemp -d "$A/.clone-pool-build.XXXXXX")" || return 0
    if ! find "$WT_ROOT" -mindepth 1 -maxdepth 1 -type d -name 'wt-*' \! -name 'wt-*.preserved-*' -print > "$build_dir/paths"; then
      rm -rf -- "$build_dir"
      return 0
    fi
    while IFS= read -r path; do
      [[ -n "$path" ]] || continue
      if (( batch_lines % max_per_tick == 0 )); then
        printf -v batch_name '%06d' "$batch_count"
        : > "$build_dir/$batch_name" || { rm -rf -- "$build_dir"; return 0; }
        batch_count=$((batch_count + 1))
      fi
      printf '%s\n' "${path##*/}" >> "$build_dir/$batch_name" || { rm -rf -- "$build_dir"; return 0; }
      batch_lines=$((batch_lines + 1))
    done < "$build_dir/paths"
    rm -f -- "$build_dir/paths"
    if (( batch_count == 0 )); then
      rm -rf -- "$build_dir"
      printf '%s\n' "$now_epoch" > "$last_sweep_file.tmp.$$" && mv -f -- "$last_sweep_file.tmp.$$" "$last_sweep_file"
      return 0
    fi
    printf '%s\n' "$batch_count" > "$build_dir/count" || { rm -rf -- "$build_dir"; return 0; }
    printf '0\n' > "$build_dir/index" || { rm -rf -- "$build_dir"; return 0; }
    mv -T -- "$build_dir" "$queue_dir" || { rm -rf -- "$build_dir"; return 0; }
    printf '%s\n' "$now_epoch" > "$last_sweep_file.tmp.$$" && mv -f -- "$last_sweep_file.tmp.$$" "$last_sweep_file"
  fi
  batch_count="$(cat "$queue_dir/count" 2>/dev/null || true)"
  [[ "$batch_count" =~ ^[1-9][0-9]*$ ]] || { rm -rf -- "$queue_dir"; return 0; }
  batch_index="$(cat "$queue_dir/index" 2>/dev/null || printf '0')"
  [[ "$batch_index" =~ ^[0-9]+$ ]] || batch_index=0
  if (( batch_index >= batch_count )); then
    rm -rf -- "$queue_dir"
    return 0
  fi
  printf -v batch_name '%06d' "$batch_index"
  batch_file="$queue_dir/$batch_name"
  if [[ ! -r "$batch_file" ]]; then
    clone_pool_sweep_advance "$queue_dir" "$batch_index" "$batch_count" || :
    return 0
  fi
  while IFS= read -r name; do
    if (( SECONDS >= CLEANUP_DEADLINE )); then
      batch_complete=false
      break
    fi
    [[ "$name" =~ ^wt-[A-Za-z0-9._-]+$ && "$name" != *'.preserved-'* ]] || continue
    reap_path="$WT_ROOT/.clone-pool-reap-$name"
    if [[ -d "$reap_path" && ! -L "$reap_path" ]]; then
      reaped_paths+=("$reap_path")
      continue
    fi
    dir="$WT_ROOT/$name"
    [[ -d "$dir" && ! -L "$dir" ]] || continue
    [[ -d "$dir/.git" && ! -L "$dir/.git" ]] || continue
    index="$dir/.git/index"
    [[ -f "$index" && ! -L "$index" ]] || continue
    index_mtime="$(ap_mtime_epoch "$index")" || continue
    [[ "$index_mtime" =~ ^[0-9]+$ ]] || continue
    (( now_epoch - index_mtime > max_age_seconds )) || continue
    root_identity="$(stat -c '%d:%i' -- "$dir" 2>/dev/null)" || continue
    [[ "$root_identity" =~ ^[0-9]+:[0-9]+$ ]] || continue
    candidate_names+=("$name")
    candidate_ids+=("${name#wt-}")
    candidate_roots+=("$root_identity")
  done < "$batch_file"
  if ((${#candidate_ids[@]})) && [[ "$batch_complete" == true ]]; then
    if candidate_json="$(printf '%s\n' "${candidate_ids[@]}" | jq -Rsc 'split("\n") | map(select(length > 0))')" \
      && candidate_paths_json="$(printf '%s\n' "${candidate_names[@]}" | jq -Rsc --arg root "$WT_ROOT" 'split("\n") | map(select(length > 0) | $root + "/" + .)')"; then
      units_before="$(clone_pool_file_identity "$UNITS")" || ledger_ok=false
      archive_before="$(clone_pool_file_identity "$UNITS_ARCHIVE")" || ledger_ok=false
      for ledger in "$UNITS" "$UNITS_ARCHIVE"; do
        [[ -s "$ledger" ]] || continue
        if records="$(jqf -r --argjson ids "$candidate_json" 'if type=="object" and (.units|type)=="array" and all(.units[]; (.id|type)=="string") then .units[] | select(.id as $id | ($ids | index($id)) != null) | [.id, ((.issue // "-") | tostring), (.eval_gate.status // "")] | @tsv else error("invalid units ledger") end' "$ledger" 2>/dev/null)"; then
          while IFS=$'\t' read -r id issue status; do
            [[ -n "$id" ]] || continue
            candidate_issue["$id"]="$issue"
            [[ "$status" != pending && "$status" != running ]] || eval_pending["$id"]=1
          done <<< "$records"
        else
          ledger_ok=false
          break
        fi
      done
      archive_after="$(clone_pool_file_identity "$UNITS_ARCHIVE")" || ledger_ok=false
      units_after="$(clone_pool_file_identity "$UNITS")" || ledger_ok=false
      [[ "$units_before" == "$units_after" && "$archive_before" == "$archive_after" ]] || ledger_ok=false
      for id in "${candidate_ids[@]}"; do
        issue="${candidate_issue[$id]:-}"
        [[ "$issue" =~ ^[1-9][0-9]*$ ]] && candidate_issues+=("$issue")
      done
      candidate_issues_json="$(printf '%s\n' "${candidate_issues[@]}" | jq -Rsc 'split("\n") | map(select(test("^[1-9][0-9]*$"))) | unique')" || ledger_ok=false
      workers_before="$(clone_pool_file_identity "$WORKERS")" || ledger_ok=false
      if [[ ! -s "$WORKERS" ]] || ! worker_records="$(jqf -c --argjson ids "$candidate_json" --argjson paths "$candidate_paths_json" --argjson issues "$candidate_issues_json" 'if type=="object" and (.workers|type)=="array" then .workers[] | select(.harvested != true and .lease_expired != true) | select((.unit as $unit | ($ids | index($unit)) != null) or (.workdir as $workdir | ($paths | index($workdir)) != null) or (((.issue // "") | tostring) as $issue | ($issues | index($issue)) != null)) else error("invalid workers ledger") end' "$WORKERS" 2>/dev/null)"; then
        ledger_ok=false
      else
        while IFS= read -r record; do
          [[ -n "$record" ]] || continue
          harvest_worker_alive "$record" || continue
          worker_unit="$(jqf -r '.unit // empty' <<< "$record")"
          worker_path="$(jqf -r '.workdir // empty' <<< "$record")"
          worker_issue="$(jqf -r '(.issue // "") | tostring' <<< "$record")"
          for ((candidate_index=0; candidate_index<${#candidate_ids[@]}; candidate_index++)); do
            id="${candidate_ids[$candidate_index]}"
            issue="${candidate_issue[$id]:-}"
            if [[ "$worker_unit" == "$id" || "$worker_path" == "$WT_ROOT/wt-$id" || ( "$issue" =~ ^[1-9][0-9]*$ && "$worker_issue" == "$issue" ) ]]; then
              worker_live["$id"]=1
            fi
          done
        done <<< "$worker_records"
      fi
      workers_after="$(clone_pool_file_identity "$WORKERS")" || ledger_ok=false
      [[ "$workers_before" == "$workers_after" ]] || ledger_ok=false
      if [[ "$ledger_ok" == true ]]; then
        for ((candidate_index=0; candidate_index<${#candidate_ids[@]}; candidate_index++)); do
          id="${candidate_ids[$candidate_index]}"
          issue="${candidate_issue[$id]:-}"
          [[ -z "${eval_pending[$id]:-}" && -z "${worker_live[$id]:-}" ]] || continue
          if clone_pool_owner_claimed "$id" "$issue"; then continue; fi
          dir="$WT_ROOT/${candidate_names[$candidate_index]}"
          [[ -d "$dir" && ! -L "$dir" ]] || continue
          [[ "$(stat -c '%d:%i' -- "$dir" 2>/dev/null)" == "${candidate_roots[$candidate_index]}" ]] || continue
          if worktree_cleanup_block_reason "$dir" >/dev/null; then continue; fi
          index="$dir/.git/index"
          [[ -f "$index" && ! -L "$index" ]] || continue
          index_identity="$(stat -c '%d:%i' -- "$index" 2>/dev/null)" || continue
          [[ "$index_identity" =~ ^[0-9]+:[0-9]+$ ]] || continue
          safe_names+=("${candidate_names[$candidate_index]}")
          safe_ids+=("$id")
          safe_roots+=("${candidate_roots[$candidate_index]}")
          safe_indexes+=("$index_identity")
        done
      else
        batch_complete=false
      fi
    else
      batch_complete=false
    fi
  fi
  if ((${#safe_ids[@]})) && [[ "$batch_complete" == true ]]; then
    if [[ "${SCHED_LOCK_HELD:-false}" != true ]] && acquire_scheduler_lock_wait 5; then
      own_lock=true
      lock_ready=true
    else
      batch_complete=false
    fi
    if [[ "$lock_ready" == true ]]; then
      units_after="$(clone_pool_file_identity "$UNITS")" || ledger_ok=false
      archive_after="$(clone_pool_file_identity "$UNITS_ARCHIVE")" || ledger_ok=false
      workers_after="$(clone_pool_file_identity "$WORKERS")" || ledger_ok=false
      if [[ "$ledger_ok" != true || "$units_before" != "$units_after" || "$archive_before" != "$archive_after" || "$workers_before" != "$workers_after" ]]; then
        batch_complete=false
      else
        for ((candidate_index=0; candidate_index<${#safe_ids[@]}; candidate_index++)); do
          id="${safe_ids[$candidate_index]}"
          issue="${candidate_issue[$id]:-}"
          [[ -z "${eval_pending[$id]:-}" && -z "${worker_live[$id]:-}" ]] || continue
          if clone_pool_owner_claimed "$id" "$issue"; then continue; fi
          dir="$WT_ROOT/${safe_names[$candidate_index]}"
          [[ -d "$dir" && ! -L "$dir" ]] || continue
          [[ "$(stat -c '%d:%i' -- "$dir" 2>/dev/null)" == "${safe_roots[$candidate_index]}" ]] || continue
          index="$dir/.git/index"
          [[ -f "$index" && ! -L "$index" ]] || continue
          candidate_identity="$(stat -c '%d:%i' -- "$index" 2>/dev/null)" || continue
          [[ "$candidate_identity" == "${safe_indexes[$candidate_index]}" ]] || continue
          reap_path="$WT_ROOT/.clone-pool-reap-${safe_names[$candidate_index]}"
          [[ ! -e "$reap_path" ]] || continue
          if mv -- "$dir" "$reap_path"; then reaped_paths+=("$reap_path"); fi
        done
      fi
      [[ "$own_lock" != true ]] || release_scheduler_lock
    fi
  fi
  for reap_path in "${reaped_paths[@]}"; do
    if remove_readonly_tree "$reap_path"; then
      say "cleanup stale clone ${reap_path##*/}"
    else
      batch_complete=false
    fi
  done
  if [[ "$batch_complete" == true ]]; then
    clone_pool_sweep_advance "$queue_dir" "$batch_index" "$batch_count" || :
  fi
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
  cleanup_stale_clones
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
    # Prepare the full-file jq result without the lock; commit only if no writer changed the input meanwhile.
    local own_lock=false t0=$SECONDS trim_snapshot="" trim_result=""
    trim_snapshot="$(mktemp "${WORKERS}.trim.XXXXXX")" || trim_snapshot=""
    trim_result="${trim_snapshot}.result"
    if [[ -n "$trim_snapshot" ]] && cp -- "$WORKERS" "$trim_snapshot" \
      && jqf '{workers: ([.workers[] | select(.harvested != true)] + ([.workers[] | select(.harvested == true)] | sort_by(.started) | .[-60:]))}' \
        "$trim_snapshot" > "$trim_result"; then
      if [[ "${SCHED_LOCK_HELD:-false}" != true ]]; then acquire_scheduler_lock_wait 5 && own_lock=true; fi
      if [[ "${SCHED_LOCK_HELD:-false}" == true ]]; then
        if cmp -s "$trim_snapshot" "$WORKERS"; then
          cat "$trim_result" | write_state "$WORKERS"
          say "trim workers ledger $n_total secs=$((SECONDS - t0))"
        else
          say "cleanup trim skipped at ${SECONDS}s: workers ledger changed during preparation"
        fi
      else
        say "cleanup trim skipped at ${SECONDS}s: ledger lock busy"
      fi
      [[ "$own_lock" != true ]] || release_scheduler_lock
    else
      say "cleanup trim skipped at ${SECONDS}s: workers snapshot unavailable"
    fi
    [[ -z "$trim_snapshot" ]] || rm -f -- "$trim_snapshot" "$trim_result"
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
  fi
}
