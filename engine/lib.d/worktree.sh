_AGENT_LIB_DIR="${_AGENT_LIB_DIR:-$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)}" # a module sourced without lib.sh (land snapshot) still finds the lib dir

agent_worktree_is_usable() {
  local repo="${1:-}" target="${2:-}" top repo_common worktree_common
  [ -d "$repo" ] && [ -d "$target" ] || return 1
  top="$(git -C "$target" rev-parse --show-toplevel 2>/dev/null)" || return 1
  top="$(realpath -e -- "$top" 2>/dev/null)" || return 1
  target="$(realpath -e -- "$target" 2>/dev/null)" || return 1
  [ "$top" = "$target" ] || return 1
  repo_common="$(git -C "$repo" rev-parse --path-format=absolute --git-common-dir 2>/dev/null)" || return 1
  worktree_common="$(git -C "$target" rev-parse --path-format=absolute --git-common-dir 2>/dev/null)" || return 1
  repo_common="$(realpath -e -- "$repo_common" 2>/dev/null)" || return 1
  worktree_common="$(realpath -e -- "$worktree_common" 2>/dev/null)" || return 1
  [ "$repo_common" = "$worktree_common" ]
}


agent_latest_worktree_for_hand() {
  local repo="${1:-}" name="${2:-}" registry="${3:-}" report="${4:-}" supplied="${5:-}" allow_queued_missing="${6:-0}"
  local repo_real candidate registry_path base queue="${DQ_QUEUE:-}" queue_row_state="" queue_worktree="" queue_record parent
  local -a candidates=() report_candidates=()
  [[ "$name" =~ ^[[:alnum:]_.-]+$ && "$name" != . && "$name" != .. ]] || return 1
  repo_real="$(realpath -e -- "$repo" 2>/dev/null)" || return 1
  if [[ -r "$report" ]]; then
    mapfile -t report_candidates < <(grep -i 'worktree' -- "$report" \
      | grep -oE '~?/[[:alnum:]_./-]+' \
      | sed -E 's/[.,;:!?)]*$//' \
      | tac || true)
    for candidate in "${report_candidates[@]}"; do
      base="${candidate%/}"; base="${base##*/}"
      [[ "$base" == "$name" || "$base" == "$name"-* || "$base" == "$name"_* ]] \
        && candidates+=("$candidate")
    done
  fi
  registry_path="$(jq -r '.worktree // empty' "$registry" 2>/dev/null || true)"
  candidates+=("$registry_path")
  if [[ "$allow_queued_missing" == 1 && ! -e "$registry" && ! -L "$registry" ]]; then
    queue="${queue:-${AGENT_HOME:-$HOME/.zenoforge}/night/supervisor-dispatch-queue.tsv}"
    if [[ -r "$queue" ]]; then
      queue_record="$(awk -F '\t' -v owner="$name" '$1 == owner {
        if (NF >= 5 && $2 != "") print "valid\t" $2
        else print "invalid\t-"
        exit
      }' "$queue" 2>/dev/null || true)"
      if [[ -n "$queue_record" ]]; then
        IFS=$'\t' read -r queue_row_state queue_worktree <<< "$queue_record"
        case "$queue_worktree" in "~/"*) queue_worktree="$HOME/${queue_worktree:2}" ;; esac
        if [[ "$queue_row_state" == valid && "$queue_worktree" == /* ]]; then
          queue_worktree="$(realpath -m -- "$queue_worktree" 2>/dev/null || true)"
          base="${queue_worktree%/}"; base="${base##*/}"
          [[ "$base" == "$name" || "$base" == "$name"-* || "$base" == "$name"_* ]] || queue_row_state=invalid
        else
          queue_row_state=invalid
        fi
        [[ "$queue_row_state" == valid ]] && candidates+=("$queue_worktree")
      fi
    fi
    # A malformed or stale row is authoritative too: do not substitute an unrecorded default path.
    [[ -z "$queue_row_state" ]] && candidates+=("$supplied")
  else
    candidates+=("$supplied")
  fi
  for candidate in "${candidates[@]}"; do
    [[ -n "$candidate" ]] || continue
    case "$candidate" in "~/"*) candidate="$HOME/${candidate:2}" ;; esac
    if [[ "$allow_queued_missing" == 1 && "$queue_row_state" == valid \
      && "$candidate" == "$queue_worktree" && ! -e "$candidate" && ! -L "$candidate" ]]; then
      parent="${candidate%/*}"
      [[ -d "$parent" && "$candidate" != "$repo_real" ]] || continue
      printf '%s\n' "$candidate"
      return 0
    fi
    candidate="$(realpath -e -- "$candidate" 2>/dev/null)" || continue
    [[ "$candidate" != "$repo_real" ]] || continue
    agent_worktree_is_usable "$repo_real" "$candidate" || continue
    printf '%s\n' "$candidate"
    return 0
  done
  return 1
}

# GNU date treats an empty -d value as today's midnight, so reject it before parsing.
agent_epoch() {
  local utc=0 timestamp="${1-}"
  if [[ "$timestamp" == -u ]]; then
    utc=1
    timestamp="${2-}"
  fi
  [[ -n "$timestamp" ]] || return 1
  if (( utc )); then date -u -d "$timestamp" +%s
  else date -d "$timestamp" +%s
  fi
}


# One safe exit rule for every worktree owner.
worktree_lifecycle_finish() {
  local wt="${1:-}" repo_dir="${2:-$REPO_DIR}" helper
  [ -n "$wt" ] || return 0
  helper="$(cd -- "$(dirname -- "$_AGENT_LIB_DIR/lib.sh")" && pwd -P)/worktree-lifecycle.sh"
  bash "$helper" finish "$repo_dir" "$wt" "$$"
}


worktree_lifecycle_manifest() {
  local action="$1" name="$2" head="$3" detail="${4:-}" repo_dir="${5:-$REPO_DIR}" helper
  helper="$(cd -- "$(dirname -- "$_AGENT_LIB_DIR/lib.sh")" && pwd -P)/worktree-lifecycle.sh"
  bash "$helper" record "$repo_dir" "$action" "$name" "$head" "$detail"
}


# advisor_ticket_lock_file <issue_number> -- same one-line-echo shape as
# state_file() near the top of this file, for the same reason: one place
# defines the path convention, every caller (and every test) derives it the
# same way instead of hand-building "$ADVISOR_LOCKS_DIR/issue-$n.lock" at
# each call site.
advisor_ticket_lock_file() { echo "$ADVISOR_LOCKS_DIR/issue-$1.lock"; }


# --- Per-run advisor worktree lifecycle -------------------------------------
# The concrete bug this replaces: run-advisor-batch.sh used to `rm -rf` and
# recreate ONE FIXED directory ($HOME/wt/advisor-batch) at the start of
# every run. Two runs that ever overlapped (a manual re-run started before
# the first finished, or ever will once a scheduler dispatches this
# automatically) would silently destroy whatever the other had checked out
# mid-flight. Worse, a crashed prior run's worktree -- exactly the kind of
# thing worth inspecting after a failure -- gets deleted by the NEXT run's
# own startup, before anyone gets to look at it. A unique, per-run directory
# makes "two runs never step on each other's checkout" true by construction
# instead of by luck of timing, the same shift LOCK_FILE-style mutexes make
# for concurrent access generally.
#
# advisor_owner_isolated_checkout <repo_dir> -> true only in a node-owner episode checkout.
advisor_owner_isolated_checkout() {
local repo_dir="${1:-$REPO_DIR}" branch
branch="$(git -C "$repo_dir" branch --show-current 2>/dev/null)" || return 1
[[ "$branch" == node-auto-owner/* ]]
}


# advisor_worktree_new <need_worktree> [ref] [repo_dir]
#   need_worktree: "1" to actually create one, anything else ("0", unset)
#   to skip -- prints nothing, returns 0, nothing to clean up either. A
#   pure pending-advisor-verdict resume (reading back an already-persisted
#   ruling, applying its GitHub side effects) needs no fresh source
#   checkout at all; only a NEW judgment pass does. This function does not
#   decide which one a given run is -- that decision belongs to the caller
#   (the resume-vs-fresh-pass logic lives in run-advisor.sh's own verdict
#   persistence, a parallel change to this one) -- it only takes the
#   decision as a precondition.
#
#   On success: prints the new worktree's absolute path on stdout, returns
#   0 (safe to capture via command substitution -- unlike the locks above,
#   `git worktree add`'s effect is on-disk/in `.git`, not an open fd tied
#   to this shell's own process, so nothing is lost across a subshell).
#   On `git worktree add` failure: prints nothing, returns 1 -- the caller
#   records its own env fault (record_env_fault), the same as the call
#   site this replaces already did; this function has no ticket/stage
#   context of its own to attach one.
#
#   Directory: $HOME/wt/advisor-run-<id>, never $HOME/wt/advisor-batch or
#   any other fixed name. <id> is $INVOCATION_ID (systemd sets this per
#   unit-start already, unique by construction) when running under
#   systemd, else a kernel-random id from /proc/sys/kernel/random/uuid --
#   deliberately NOT a hash of anything. CLAUDE.md's project-level rule
#   against computing/recording a hash for this kind of identifier exists
#   because of a real incident (scrub_git_object_ids()'s own comment above:
#   a Git commit id quoted straight into a published comment/email, twice,
#   undetected); a content hash would also just be the wrong tool here even
#   ignoring that rule -- two runs against the identical origin/main tip
#   would hash identically and collide on exactly the one property
#   ("distinguishes THIS run's directory from any other's") this id needs.
advisor_worktree_new() {
local need_worktree="${1:-0}" ref="${2:-origin/main}" repo_dir="${3:-$REPO_DIR}" id wt WT_ADD_OUTPUT origin_main_sha requested_sha
  [ "$need_worktree" = "1" ] || return 0
if advisor_owner_isolated_checkout "$repo_dir"; then
  origin_main_sha="$(git -C "$repo_dir" rev-parse --verify -q 'refs/remotes/origin/main^{commit}' 2>/dev/null || true)"
  requested_sha="$(git -C "$repo_dir" rev-parse --verify -q "$ref^{commit}" 2>/dev/null || true)"
  if [[ "$ref" == origin/main || ( -n "$origin_main_sha" && "$requested_sha" == "$origin_main_sha" ) ]]; then
    echo "advisor_worktree_new: refusing origin/main for node-owner checkout $repo_dir" >&2
    return 1
  fi
fi
  # 2026-09-20: $INVOCATION_ID alone is NOT unique per call -- systemd mints
  # one per UNIT START, so two calls inside one unit computed the same path
  # and the second `git worktree add` died with "already exists". It only
  # ever showed up on CI (the self-hosted runner runs under systemd, so the
  # variable is set there; an interactive shell has none), and it was
  # invisible for three runs because unlock_fd() had detached stderr by
  # then. Keep the invocation id as a PREFIX -- it is what ties a directory
  # back to the unit that made it -- and add a per-call component after it.
  id="$(cat /proc/sys/kernel/random/uuid 2>/dev/null || true)"
  [ -n "$id" ] || id="$$-$RANDOM-$(date -u +%s%N)"
  [ -z "${INVOCATION_ID:-}" ] || id="$INVOCATION_ID-$id"
  wt="${ZF_WORKTREE_ROOT:-$HOME/wt}/advisor-run-$id"
  if ! WT_ADD_OUTPUT="$(git -C "$repo_dir" worktree add "$wt" "$ref" 2>&1)"; then
    echo "advisor_worktree_new: git worktree add failed for $wt @ $ref: $WT_ADD_OUTPUT" >&2
    return 1
  fi
  echo "$wt"
}
