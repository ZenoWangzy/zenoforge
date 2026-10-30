
# =============================================================================
# Advisor execution claims + per-run worktree lifecycle (2026-09-20)
#
# Kept in a separate section from advisor verdict handling so the per-ticket
# claim lifecycle stays easy to find and review.
#
# The gap this closes: nothing today actually stops the automated per-tick
# dispatch (issue-pipeline.sh's `zf-advisor-$n` unit), a manual
# `run-advisor.sh <N>`, and a manual `run-advisor-batch.sh` sweep from all
# working advisor judgment at once. `stage_unit_active advisor "$n"`
# (existing, used by run-advisor-batch.sh's own candidate loop above) only
# catches a systemd-dispatched run currently alive for that ONE ticket -- it
# has no opinion on a hand-run `run-advisor.sh`/`run-advisor-batch.sh`
# invoked directly from a shell, and a GitHub label is not a mutex either
# (can lag, get raced, get read stale). These primitives are wired into the
# two advisor entry points below; every stage exit uses worktree_lifecycle_finish().
#
# --- Per-ticket claim -------------------------------------------------------
# One lock per issue (locks/issue-N.lock), acquired right after a ticket is
# selected and right before its judgment snapshot is read, released as soon
# as that ticket's processing for this round is done. Claims are independent
# across tickets; this is the only advisor execution lock now.
#
# Both non-blocking (try once, skip on failure -- "someone else already has
# it" is not an error, is not charged as an attempt, and must not create a
# worktree).
#
# --- Reuse check performed before writing this ------------------------------
# grepped this whole directory for `flock`/lock-helper functions first, per
# the design review's own instruction to reuse rather than invent. Found
# two: issue-pipeline.sh's own tick-decision lock (`exec 9>"$LOCK_FILE";
# flock -n 9 || exit 0`, inlined there, not a function) and this file's
# acquire_merge_lock()/release_merge_lock() above (blocking with a bound,
# one FIXED fd (8), one FIXED lock file (MERGE_LOCK_FILE), built for
# one shared merge API mutation -- `gh pr merge` itself). Neither fits here unmodified: both assume a
# single hardcoded fd for a singleton lock, but advisor batch callers can
# hold one claim per ticket in the same process. try_lock_nonblocking()
# below is the reusable helper; it still
# shares acquire_merge_lock()'s fundamental flock discipline (fd closes ->
# lock releases, even on the holder's own unclean exit, no hand-rolled
# "touch a marker file" cleanup needed) instead of reinventing it.
#
# try_lock_nonblocking <lock_file> <out_fd_var>
#   Non-blocking flock acquire on a FRESHLY, dynamically allocated fd
#   (bash's `exec {fd}>file` form -- picks a free descriptor itself, never
#   a fixed number the way LOCK_FILE's fd 9 / MERGE_LOCK_FILE's fd 8 above
#   are, both true singletons by design). On success, the fd number is
#   written into the CALLER's variable named by <out_fd_var> (via
#   `printf -v`, not echoed) and this returns 0. On failure (already held
#   elsewhere) it closes what it opened, writes nothing, and returns 1 --
#   the caller never even sees an fd number to leak.
#
#   MUST be called as a bare statement (`try_lock_nonblocking ... FDVAR` or
#   `if try_lock_nonblocking ... FDVAR; then`), NEVER via command
#   substitution (`x=$(try_lock_nonblocking ...)`). Command substitution
#   forks a subshell; the open, locked fd this function creates lives only
#   in that subshell's own process, which is already gone by the time the
#   substitution finishes capturing output -- the caller would be left
#   holding a "lock" that was silently released the instant it was
#   acquired. Proven live while building this: an earlier draft did exactly
#   that and a second, independent lock attempt against the same file
#   succeeded immediately afterward, when it should have blocked. (Same
#   reason acquire_merge_lock() above is always called bare, never
#   `x=$(acquire_merge_lock)`.)
try_lock_nonblocking() {
  local lock_file="$1" __out_fd_var="$2" __fd
  # Bash resolves printf -v targets through this function's locals first.
  # Reject every local name, so an out-variable can never be shadowed here
  # and leave a lock fd stranded in this helper instead of its caller.
  case "$__out_fd_var" in
    lock_file|__out_fd_var|__fd)
      echo "try_lock_nonblocking: output variable $__out_fd_var is reserved" >&2
      return 2
      ;;
  esac
  mkdir -p -- "$(dirname -- "$lock_file")"
  exec {__fd}>"$lock_file"
  if flock -n "$__fd"; then
    printf -v "$__out_fd_var" '%s' "$__fd"
    return 0
  fi
  exec {__fd}>&-
  return 1
}


# unlock_fd <fd> -- releases a try_lock_nonblocking() lock and closes its
# fd. An empty fd is a quiet cleanup-trap no-op; a non-empty fd that cannot
# unlock or close must fail loudly, or a leaked lease becomes invisible.
# Keep stderr attached: a bare `exec` redirection permanently changes the
# caller's descriptor.
unlock_fd() {
  local __fd="${1:-}"
  [ -n "$__fd" ] || return 0
  if ! flock -u "$__fd"; then
    echo "unlock_fd: failed to unlock fd $__fd" >&2
    return 1
  fi
  if ! exec {__fd}>&-; then
    echo "unlock_fd: failed to close fd $__fd" >&2
    return 1
  fi
}


# run_with_fd_closed <fd...> -- <command...>
#   File-descriptor hygiene for exactly one shape of bug: a long-running
#   child started WHILE a try_lock_nonblocking() lock is held (a long-running
#   model invocation, in particular) inherits open fds by
#   default in bash (`exec N>file`-opened fds carry no close-on-exec flag
#   unless told to). flock's lock lives on the OPEN FILE DESCRIPTION, not
#   on the process that created it -- released only once EVERY fd
#   referencing it, in EVERY process, is closed. A model call spawned
#   without this would keep its own inherited copy of the fd open for as
#   long as the model runs, holding the lock long after this run's own
#   unlock_fd() call, even though the run that "released" it has moved on.
#   This is not hypothetical for this codebase: the 2026-09-15 #1204
#   incident (gh()/git_fetch_bounded()'s own comment, near the top of this
#   file) was precisely a hung CHILD process holding a lock fd its parent
#   no longer controlled, for 2h25m, invisible to every non-blocking probe
#   after it.
#
#   Runs <command...> in a subshell with every listed fd closed FIRST -- the
#   subshell's own fd table is a copy of the parent's, so closing it there
#   never touches the parent's still-open, still-locked fd (proven live:
#   a fresh in-process fd opened against the same lock file right after a
#   run_with_fd_closed() call still blocks, confirming the parent's hold
#   survives). The parent must still call unlock_fd() itself when done.
run_with_fd_closed() {
  local -a fds=()
  local fd
  while [ "$#" -gt 0 ] && [ "${1:-}" != "--" ]; do
    fds+=("$1")
    shift
  done
  [ "${1:-}" = "--" ] && shift
  (
    for fd in "${fds[@]}"; do
      { exec {fd}>&-; } 2>/dev/null
    done
    "$@"
  )
}


try_acquire_web_session_lease() {
  local __out_fd_var="$1" lock_file="${WEB_SESSION_LEASE_FILE:-$AGENT_HOME/cdp-browser.lock}"
  try_lock_nonblocking "$lock_file" "$__out_fd_var"
}


acquire_web_session_lease() {
  local __out_fd_var="$1" wait_seconds="${2:-${WEB_SESSION_LEASE_WAIT_SECONDS:-$MERGE_LOCK_WAIT_SECONDS}}" \
    lock_file="${WEB_SESSION_LEASE_FILE:-$AGENT_HOME/cdp-browser.lock}" fd
  mkdir -p -- "$(dirname -- "$lock_file")"
  exec {fd}>"$lock_file"
  if flock -w "$wait_seconds" "$fd"; then
    printf -v "$__out_fd_var" '%s' "$fd"
    return 0
  fi
  exec {fd}>&-
  return 1
}


web_session_lease_available() {
  # Dispatch checks honor a timed operator reservation; direct lease users,
  # including a waiting lease holder, still contend only on the flock.
  local fd="" reserved_until="" reserved_by="" reservation_file="$AGENT_HOME/locks/web-session-reserved-until"
  if [ -r "$reservation_file" ] \
    && IFS=' ' read -r reserved_until reserved_by < "$reservation_file" \
    && [[ "$reserved_until" =~ ^[0-9]+$ && -n "$reserved_by" ]] \
    && (( 10#$reserved_until > $(date +%s) )); then
    return 1
  fi
  try_acquire_web_session_lease fd || return 1
  unlock_fd "$fd"
}
