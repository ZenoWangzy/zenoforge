dead_park_guarded_push() { ( source "$SCHEDULER_AGENT_LIB" && guarded_write git -C "$1" push -q origin "$2:refs/heads/$3" ); }

dead_park_salvage_worktree() { # unit-id worktree -> comma-separated refs; push failures go to stderr
  local id="$1" wt="$2" stamp base remote_branches status stash_list stash_ref stash_index sha ref err tmp_index snapshot_rc
  local -a refs=()
  stamp="$(date -u +%Y%m%dT%H%M%SZ)" || return 1
  base="salvage/$id-$stamp"
  if git -C "$wt" remote get-url origin >/dev/null 2>&1; then
    remote_branches="$(git -C "$wt" fetch -q --prune origin 2>&1)" || { printf 'could not refresh origin refs: %s\n' "$remote_branches" >&2; return 1; }
  fi
  remote_branches="$(git -C "$wt" branch -r --contains HEAD 2>&1)" || { printf 'could not inspect remote branches: %s\n' "$remote_branches" >&2; return 1; }
  if [[ -z "$remote_branches" ]]; then
    sha="$(git -C "$wt" rev-parse HEAD 2>&1)" || { printf 'could not read HEAD: %s\n' "$sha" >&2; return 1; }
    ref="$base"
    err="$(dead_park_guarded_push "$wt" "$sha" "$ref" 2>&1)" || { printf 'push refs/heads/%s failed: %s\n' "$ref" "${err:-git push failed}" >&2; return 1; }
    refs+=("refs/heads/$ref")
  fi
  status="$(git -C "$wt" status --porcelain 2>&1)" || { printf 'could not inspect worktree status: %s\n' "$status" >&2; return 1; }
  if [[ -n "$status" ]]; then
    tmp_index="$(mktemp)" || { printf 'could not create temporary index for dirty worktree\n' >&2; return 1; }
    sha="$(GIT_INDEX_FILE="$tmp_index" git -C "$wt" read-tree HEAD 2>&1 && GIT_INDEX_FILE="$tmp_index" git -C "$wt" add -A 2>&1 && GIT_INDEX_FILE="$tmp_index" git -C "$wt" stash create 2>&1)"
    snapshot_rc=$?
    rm -f "$tmp_index"
    (( snapshot_rc == 0 )) || { printf 'git stash create failed: %s\n' "$sha" >&2; return 1; }
    if [[ ! "$sha" =~ ^[[:xdigit:]]{40,64}$ ]]; then
      printf 'git stash create did not produce a commit for dirty worktree\n' >&2
      return 1
    fi
    ref="$base-dirty"
    err="$(dead_park_guarded_push "$wt" "$sha" "$ref" 2>&1)" || { printf 'push refs/heads/%s failed: %s\n' "$ref" "${err:-git push failed}" >&2; return 1; }
    refs+=("refs/heads/$ref")
  fi
  stash_list="$(git -C "$wt" stash list --format='%gd' 2>&1)" || { printf 'could not list stashes: %s\n' "$stash_list" >&2; return 1; }
  while IFS= read -r stash_ref; do
    [[ -n "$stash_ref" ]] || continue
    stash_index="${stash_ref#stash@\{}"; stash_index="${stash_index%\}}"
    sha="$(git -C "$wt" rev-parse "$stash_ref" 2>&1)" || { printf 'could not read %s: %s\n' "$stash_ref" "$sha" >&2; return 1; }
    ref="$base-stash$stash_index"
    err="$(dead_park_guarded_push "$wt" "$sha" "$ref" 2>&1)" || { printf 'push refs/heads/%s failed: %s\n' "$ref" "${err:-git push failed}" >&2; return 1; }
    refs+=("refs/heads/$ref")
  done <<<"$stash_list"
  ((${#refs[@]} > 0)) || { printf 'no salvage ref was required for unpushed worktree\n' >&2; return 1; }
  local IFS=,
  printf '%s\n' "${refs[*]}"
}

dead_park_salvage_notice() { # unit-id comma-separated refs
  local id="$1" refs="$2"
  say "dead-park salvage unit=$id refs=$refs"
  ( source "$SCHEDULER_AGENT_LIB" && supervisor_inbox_append_once "dead-park-salvage:$id" "dead-park-salvage unit=$id refs=$refs" ) >/dev/null 2>&1 || true
}
