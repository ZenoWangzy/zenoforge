#!/usr/bin/env bash
set -euo pipefail
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/." && pwd -P)/test-env.sh"

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
SCRIPT="$SCRIPT_DIR/worktree-lifecycle.sh"
ROOT="$(mktemp -d)"
REPO="$ROOT/repo"
REMOTE="$ROOT/origin.git"
NIGHT="$ROOT/night"
BIN="$ROOT/bin"
REAL_JQ="$(command -v jq)"
REAL_FIND="$(command -v find)"
REAL_GIT="$(command -v git)"
REAL_SED="$(command -v sed)"
export REAL_FIND
CWD_PID=""
WATCHER_PID=""
cleanup() {
  if [ -n "$CWD_PID" ]; then
    kill "$CWD_PID" 2>/dev/null || true
    wait "$CWD_PID" 2>/dev/null || true
  fi
  if [ -n "$WATCHER_PID" ]; then
    kill "$WATCHER_PID" 2>/dev/null || true
    wait "$WATCHER_PID" 2>/dev/null || true
  fi
  rm -rf -- "$ROOT"
}
trap cleanup EXIT
mkdir -p "$NIGHT" "$BIN" "$ROOT/wt-root"
git init -q --bare "$REMOTE"
git --git-dir="$REMOTE" symbolic-ref HEAD refs/heads/main
git init -q -b main "$REPO"
git -C "$REPO" config user.name fixture
git -C "$REPO" config user.email fixture@example.invalid
git -C "$REPO" commit --allow-empty -qm base
git -C "$REPO" remote add origin "$REMOTE"
git -C "$REPO" push -qu origin main
git -C "$REPO" fetch -q origin

# The watcher now continues into bounded eligible intake after actual cleanup.
# This fixture repository has no eligible products or pipeline implementation.
mkdir -p "$REPO/engine"
cat > "$REPO/engine/issue-pipeline.sh" <<'EOF'
#!/usr/bin/env bash
[ "$*" = '--stage ready-refill' ] || exit 2
exit 0
EOF

# Detached worktrees at origin/main are clean and removable too.
DETACHED="$ROOT/wt-detached"
git -C "$REPO" worktree add -q --detach "$DETACHED" main

cat >"$BIN/gh" <<'EOF'
#!/usr/bin/env bash
if [ "${1:-}" = api ]; then
  [ -z "${FAKE_GH_LOG:-}" ] || printf '%s\n' "$*" >> "$FAKE_GH_LOG"
  if [ "${FAKE_GH_STALL_PULLS:-0}" = 1 ] && [[ " $* " == *"/pulls"* ]]; then
    exec sleep "${FAKE_GH_STALL_SECONDS:-60}"
  fi
  if [[ " $* " == *"/pulls"* ]] && [[ " $* " == *"head="* ]]; then
    pr_head=""
    for arg in "$@"; do
      case "$arg" in *head=*) pr_head="${arg##*head=}"; pr_head="${pr_head%%&*}" ;; esac
    done
    pr_branch="${pr_head#*:}"
    if [ "${FAKE_GH_FAIL_PR_BRANCH:-}" = "$pr_branch" ]; then
      printf 'simulated unreadable PR state for %s\n' "$pr_branch" >&2
      exit 37
    fi
    if [ "${FAKE_GH_OPEN_PR_BRANCH:-}" = "$pr_branch" ]; then
      printf '7\t2026-10-12T00:00:00Z\t%s\t%s\tmain\topen\t\t\n' "$pr_branch" "${FAKE_PR_BRANCH_HEAD:-abc}"
    fi
    exit 0
  fi
  if [[ " $* " == *"/commits/"*"/pulls?"* ]]; then
    printf '%s' "${FAKE_PR_COMMIT_ROWS:-}"
    exit 0
  fi
  if [[ " $* " == *"/pulls?state=all"* ]] && [[ " $* " != *"head="* ]] \
    && [ "${FAKE_GH_FAIL_PULLS:-0}" = 1 ]; then
    printf 'simulated unreadable PR list\n' >&2
    exit 37
  fi
  if [ "${FAKE_GH_STALL_ISSUES:-0}" = 1 ] && [[ " $* " == *"issues?state=all"* ]]; then
    exec sleep "${FAKE_GH_STALL_SECONDS:-60}"
  fi
  if [ "${FAKE_GH_FAIL_ISSUES:-0}" = 1 ] && [[ " $* " == *"issues?state=all"* ]]; then
    exit 37
  fi
  if [[ " $* " == *"/issues?state=all"* ]]; then
    issue_rows="${FAKE_ISSUE_ROWS_RAW:-}"
    if [ -z "$issue_rows" ]; then
      for state_var in ${!FAKE_ISSUE_STATE_@}; do
        issue_id="${state_var#FAKE_ISSUE_STATE_}"
        issue_rows+="$issue_id"$'\t'"2026-10-10T00:00:00Z"$'\t'"${!state_var}"$'\n'
      done
    fi
    page_rows=""
    case "$*" in
      *--paginate*|*'&page=1 '*) page_rows="$issue_rows" ;;
      *'&page=1') page_rows="$issue_rows" ;;
      *'&page=2 '*) page_rows="${FAKE_ISSUE_ROWS_PAGE2:-}" ;;
    esac
    if [ -n "$page_rows" ]; then
      page_json="$(printf '%s\n' "$page_rows" | "$REAL_JQ" -R 'split("\t") | select(length == 3) | {number:(.[0] | tonumber),updated_at:.[1],state:.[2]}' | "$REAL_JQ" -s .)" || exit 38
    else
      page_json='[]'
    fi
    jq_filter=""
    previous_arg=""
    for arg in "$@"; do
      if [ "$previous_arg" = --jq ]; then jq_filter="$arg"; break; fi
      previous_arg="$arg"
    done
    if [ -n "$jq_filter" ]; then
      printf '%s\n' "$page_json" | "$REAL_JQ" -r "$jq_filter" || exit 38
    else
      printf '%s\n' "$page_json"
    fi
    exit 0
  fi
  issue_id=""
  for arg in "$@"; do
    case "$arg" in repos/*/issues/[0-9]*) issue_id="${arg##*/}" ;; esac
  done
  if [ -n "$issue_id" ]; then
    if [ "${FAKE_GH_FAIL_ISSUE:-}" = "$issue_id" ]; then
      printf 'simulated unreadable issue state\n' >&2
      exit 37
    fi
    state_var="FAKE_ISSUE_STATE_$issue_id"
    printf '%s\n' "${!state_var:-open}"
    exit 0
  fi
  # Rows carry number and updated_at first, as the real --jq emits them.
  if [ -n "${FAKE_PR_ROWS_RAW:-}" ]; then
    case "$*" in
      *--paginate*|*'&page=1 '*|*'&page=1') printf '%s\n' "$FAKE_PR_ROWS_RAW" ;;
      *'&page=2 '*|*'&page=2') printf '%s\n' "${FAKE_PR_ROWS_PAGE2:-}" ;;
    esac
    exit 0
  fi
  page=0
  if [[ "${2:-}" =~ [\?\&]page=([0-9]+) ]]; then page="${BASH_REMATCH[1]}"; fi
  [ -z "${FAKE_PR_ROWS:-}" ] || printf '%s\n' "$FAKE_PR_ROWS" | awk -v OFS='\t' -v page="$page" \
    'page == 0 || (NR > (page - 1) * 100 && NR <= page * 100) {print NR, "2026-01-01T00:00:00Z", $0}'
  exit 0
fi
if [ "${1:-}" = pr ]; then
  echo 'unexpected per-branch GitHub lookup' >&2
  exit 99
fi
printf '[]\n'
EOF
cat >"$BIN/systemctl" <<'EOF'
#!/usr/bin/env bash
[ -z "${FAKE_SYSTEMCTL_LOG:-}" ] || printf '%s\n' "$*" >> "$FAKE_SYSTEMCTL_LOG"
if [[ " $* " == *' show '* ]]; then
  printf '%s\n' "${FAKE_SYSTEMCTL_SHOW_PIDS:-${FAKE_MAIN_PID:-0}}"
  exit 0
fi
if [ -n "${FAKE_ACTIVE_UNITS:-}" ]; then
  while IFS= read -r unit; do
    [ -n "$unit" ] && printf '%s loaded active running fixture\n' "$unit"
  done <<< "$FAKE_ACTIVE_UNITS"
elif [ -n "${FAKE_ACTIVE_UNIT:-}" ]; then
  printf '%s loaded active running fixture\n' "$FAKE_ACTIVE_UNIT"
fi
exit 0
EOF
cat >"$BIN/ps" <<'EOF'
#!/usr/bin/env bash
if [ -n "${FAKE_PS_OUTPUT:-}" ]; then
  printf '%s\n' "$FAKE_PS_OUTPUT"
else
  exec /bin/ps "$@"
fi
EOF
cat >"$BIN/jq" <<'EOF'
#!/usr/bin/env bash
[ -z "${FAKE_JQ_LOG:-}" ] || printf 'call\n' >> "$FAKE_JQ_LOG"
exec "$REAL_JQ" "$@"
EOF
cat >"$BIN/find" <<'EOF'
#!/usr/bin/env bash
[ -z "${FAKE_FIND_LOG:-}" ] || printf 'call\n' >> "$FAKE_FIND_LOG"
if [ "${FAKE_PROC_CWDS_EMPTY:-0}" = 1 ] && [[ "${1:-}" == /proc/*/cwd ]]; then
  exit 0
fi
exec "$REAL_FIND" "$@"
EOF
cat >"$BIN/sed" <<'EOF'
#!/usr/bin/env bash
for arg in "$@"; do
  case "$arg" in
    */.hand-owner-*) [ -z "${FAKE_HAND_OWNER_READ_LOG:-}" ] || printf '%s\n' "$arg" >> "$FAKE_HAND_OWNER_READ_LOG" ;;
  esac
done
exec "$REAL_SED" "$@"
EOF
cat >"$BIN/git" <<'EOF'
#!/usr/bin/env bash
if [ -n "${FAKE_GIT_STATUS_LOG:-}" ] && [ "${1:-}" = -C ] && [ "${3:-}" = status ]; then
  printf '%s\n' "$2" >> "$FAKE_GIT_STATUS_LOG"
fi
if [ -n "${FAKE_GIT_STATUS_SLEEP_PATH:-}" ] && [ "${1:-}" = -C ] \
  && [ "${3:-}" = status ] && [ "$2" = "$FAKE_GIT_STATUS_SLEEP_PATH" ]; then
  # Exercise the existing forced-kill grace, not a cooperative one-second sleep.
  trap '' TERM
  exec sleep "${FAKE_GIT_STATUS_SLEEP_SECONDS:-60}"
fi
if [ -n "${FAKE_GIT_WORKTREE_LIST_LOG:-}" ] && [ "${1:-}" = -C ] \
  && [ "${3:-}" = worktree ] && [ "${4:-}" = list ]; then
  printf '%s\n' "$2" >> "$FAKE_GIT_WORKTREE_LIST_LOG"
fi
if [ -n "${FAKE_RESCUE_REF_DATE_LOG:-}" ] && [ "${1:-}" = -C ] \
  && [ "${3:-}" = show ] && [[ " $* " == *" --format=%ct "* ]]; then
  printf 'lookup\n' >> "$FAKE_RESCUE_REF_DATE_LOG"
fi
if [ -n "${FAKE_RESCUE_PATCH_SCAN_LOG:-}" ] && [ "${1:-}" = -C ] \
  && { [ "${3:-}" = cherry ] || [ "${3:-}" = diff ]; }; then
  printf '%s\n' "$3" >> "$FAKE_RESCUE_PATCH_SCAN_LOG"
fi
if [ -n "${FAKE_RESCUE_PATCH_BATCH_LOG:-}" ] && [ "${1:-}" = -C ] \
  && [ "${3:-}" = show ] && [[ " $* " == *'--format=commit %H'* ]]; then
  operand_count=0
  for arg in "$@"; do [[ "$arg" =~ ^[0-9a-f]{40,64}$ ]] && ((operand_count+=1)); done
  (( operand_count > 0 )) && printf '%s\n' "$operand_count" >> "$FAKE_RESCUE_PATCH_BATCH_LOG"
fi
if [ -n "${FAKE_RESCUE_METADATA_LOG:-}" ] && [ "${1:-}" = -C ] \
  && [ "${3:-}" = show ] && [[ " $* " == *'--format=%H%x09%T%x09%P'* ]]; then
  printf 'metadata\n' >> "$FAKE_RESCUE_METADATA_LOG"
fi
if [ -n "${FAKE_RESCUE_PATCH_SCAN_SLEEP:-}" ] && [ "${1:-}" = -C ] && [ "${3:-}" = diff ]; then
  sleep "$FAKE_RESCUE_PATCH_SCAN_SLEEP"
fi
if [ "${1:-}" = -C ] && [[ " $* " == *" --binary "* ]]; then
  case "${3:-}" in
    log) [ -z "${FAKE_PATCH_SCAN_SLEEP:-}" ] || sleep "$FAKE_PATCH_SCAN_SLEEP" ;;
    show) [ -z "${FAKE_PATCH_BATCH_SLEEP:-}" ] || sleep "$FAKE_PATCH_BATCH_SLEEP" ;;
    format-patch)
      [ -z "${FAKE_FORMAT_PATCH_LOG:-}" ] || printf 'format-patch\n' >> "$FAKE_FORMAT_PATCH_LOG"
      [ -z "${FAKE_FORMAT_PATCH_SLEEP:-}" ] || sleep "$FAKE_FORMAT_PATCH_SLEEP"
      ;;
  esac
fi
if [ -n "${FAKE_RESCUE_PATCH_CHECK_LOG:-}" ] && [ "${1:-}" = -C ] \
  && [ "${3:-}" = diff ] && [[ " $* " == *" --binary --no-ext-diff "* ]]; then
  printf 'patch-id-fallback\n' >> "$FAKE_RESCUE_PATCH_CHECK_LOG"
fi
if [ -n "${FAKE_RESCUE_PATCH_EQUIV_SHA:-}" ] && [ -n "${FAKE_RESCUE_PATCH_EQUIV_SLEEP:-}" ] \
  && [ "${1:-}" = -C ] && [ "${3:-}" = show ]; then
  for arg in "$@"; do
    if [ "$arg" = "$FAKE_RESCUE_PATCH_EQUIV_SHA" ]; then
      sleep "$FAKE_RESCUE_PATCH_EQUIV_SLEEP"
      break
    fi
  done
fi
if [ "${1:-}" = -C ] && [ "${3:-}" = fetch ] && [ -n "${FAKE_GIT_FETCH_LOG:-}" ]; then
  printf 'fetch\n' >> "$FAKE_GIT_FETCH_LOG"
  fetch_count="$(wc -l < "$FAKE_GIT_FETCH_LOG")"
  fail_fetch=0
  case "${FAKE_GIT_FETCH_FAILURE_MODE:-}" in
    always|timeout-always|killed-always) fail_fetch=1 ;;
    once|timeout-once|killed-once) [ "$fetch_count" -eq 1 ] && fail_fetch=1 ;;
  esac
  if [ "${fail_fetch:-0}" = 1 ]; then
    printf 'fatal: simulated origin fetch failure\n' >&2
    case "${FAKE_GIT_FETCH_FAILURE_MODE:-}" in timeout-*) exit 124 ;; esac
    case "${FAKE_GIT_FETCH_FAILURE_MODE:-}" in killed-*) exit 137 ;; esac
    exit 1
  fi
fi
exec "$REAL_GIT" "$@"
EOF
chmod +x "$BIN/gh" "$BIN/systemctl" "$BIN/ps" "$BIN/jq"
chmod +x "$BIN/find" "$BIN/sed" "$BIN/git"

run_lifecycle() {
  local -a lifecycle_command=(bash "$SCRIPT" "$@")
  if [ -n "${LIFECYCLE_OUTER_TIMEOUT_SECONDS:-}" ]; then
    lifecycle_command=(timeout -k "${LIFECYCLE_OUTER_TIMEOUT_KILL_SECONDS:-1}" \
      "$LIFECYCLE_OUTER_TIMEOUT_SECONDS" "${lifecycle_command[@]}")
  fi
  AGENT_HOME="$ROOT/home/.zenoforge" \
  ZF_NIGHT_DIR="$NIGHT" \
  ZF_WORKTREE_ROOT="$ROOT/wt-root" \
  ZF_PRIMARY_REPO_DIR="${ZF_PRIMARY_REPO_DIR:-$REPO}" \
  ZF_WORKTREE_CLEANUP_MANIFEST="$NIGHT/worktree-cleanup-manifest.txt" \
  ZF_WORKTREE_REAP_TIMEOUT_SECONDS="${ZF_WORKTREE_REAP_TIMEOUT_SECONDS-180}" \
  ZF_GH_REPO=test/repo \
  WORKTREE_PR_ROWS_CACHE="${WORKTREE_PR_ROWS_CACHE-}" \
  WORKTREE_REAP_BUDGET_SECONDS="${WORKTREE_REAP_BUDGET_SECONDS-0}" \
  REAL_JQ="$REAL_JQ" \
  REAL_SED="$REAL_SED" \
  REAL_GIT="$REAL_GIT" \
  PATH="$BIN:$PATH" \
    "${lifecycle_command[@]}"
}
fail() { printf 'not ok - %s\n' "$*" >&2; exit 1; }

create_rescue_ref() {
  local prefix="$1" issue="$2" label="$3" age="$4"
  local wt="$ROOT/rescue-$issue-$label" branch="topic/rescue-$issue-$label" stamp head
  git -C "$REPO" worktree add -q -b "$branch" "$wt" main
  printf '%s\n' "$issue-$label" >"$wt/$issue-$label.txt"
  git -C "$wt" add -- "$issue-$label.txt"
  stamp="$(date -u -d "$age ago" '+%Y-%m-%dT%H:%M:%SZ')"
  GIT_AUTHOR_DATE="$stamp" GIT_COMMITTER_DATE="$stamp" git -C "$wt" commit -qm "$issue-$label"
  head="$(git -C "$wt" rev-parse HEAD)"
  git -C "$REPO" push -qu origin "$head:refs/heads/rescued/$prefix$issue-$label"
  git -C "$REPO" worktree remove "$wt"
  git -C "$REPO" branch -D "$branch" >/dev/null
  printf '%s\n' "$head"
}

write_hand_owner() {
  local pid="$1" target="$2" report="$3" started_at_ns="$4" branch
  branch="$(git -C "$target" branch --show-current)"
  printf '%s\n%s\n%s\n%s\n%s\n' "$target" "$ROOT/hand-prompt.md" "$branch" "$report" "$started_at_ns" \
    > "$NIGHT/.hand-owner-$pid"
}

write_hand_roster() {
  local pid="$1" target="$2" report="$3" started_at_ns="$4" attempt="${5:-0}"
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
    "$pid" hand-2131 gpt-6-luna max "$target" "$ROOT/hand-brief.md" "$report" "$ROOT/hand.log" \
    "$attempt" "$started_at_ns" work 1 '' '' > "$NIGHT/agents.txt"
}

# Run issue fixtures before the slower legacy suite so each regression can be
# checked alone. The default path below still runs the complete suite.
if [ "${WORKTREE_LIFECYCLE_CASE:-all}" != all ]; then
  case "$WORKTREE_LIFECYCLE_CASE" in
    origin-fetch-bad-local-ref)
      bad_oid=9999999999999999999999999999999999999999
      bad_ref="$REPO/.git/refs/heads/hand/3603"
      mkdir -p "$(dirname -- "$bad_ref")"
      printf '%s\n' "$bad_oid" > "$bad_ref"
      if git -C "$REPO" fetch --quiet --no-tags --prune origin > "$ROOT/bad-ref-fetch.log" 2>&1; then
        fail "broken local branch ref unexpectedly allowed fetch"
      fi
      grep -Fq 'fatal: bad object refs/heads/hand/3603' "$ROOT/bad-ref-fetch.log" \
        || fail "fixture did not reproduce missing-object branch ref failure"

      if ! run_lifecycle reap "$REPO" > "$ROOT/bad-ref-reap.log" 2>&1; then
        tail -n 20 "$ROOT/bad-ref-reap.log" >&2
        fail "reaper did not recover from an unattached missing-object branch ref"
      fi
      [ ! -e "$bad_ref" ] || fail "missing-object branch ref was not quarantined"
      grep -Fq "quarantined-broken-ref"$'\t'"refs/heads/hand/3603"$'\t'"$bad_oid"$'\t''missing-commit-object before origin fetch' \
        "$NIGHT/worktree-cleanup-manifest.txt" \
        || fail "manifest omitted quarantined branch ref and object id"

      attached="$ROOT/wt-bad-ref-attached"
      git -C "$REPO" worktree add -q -b hand/3604 "$attached" main
      attached_ref="$REPO/.git/refs/heads/hand/3604"
      printf '%s\n' "$bad_oid" > "$attached_ref"
      if run_lifecycle reap "$REPO" > "$ROOT/bad-attached-ref-reap.log" 2>&1; then
        fail "reaper quarantined a missing-object branch checked out by a worktree"
      fi
      grep -Fq 'broken local branch refs/heads/hand/3604 is checked out' "$ROOT/bad-attached-ref-reap.log" \
        || fail "attached broken branch ref was not reported clearly"
      [ -d "$attached" ] || fail "attached worktree was removed after broken ref refusal"
      [ "$(cat "$attached_ref")" = "$bad_oid" ] || fail "attached broken branch ref was changed"
      echo 'ok - missing-object local branch refs recover only when unattached; attached refs stay protected'
      exit 0
      ;;
    origin-fetch-retry)
      fetch_log="$ROOT/origin-fetch-calls.log"
      : > "$fetch_log"
      if ! FAKE_GIT_FETCH_FAILURE_MODE=once FAKE_GIT_FETCH_LOG="$fetch_log" \
        run_lifecycle reap "$REPO" > "$ROOT/origin-fetch-retry.log" 2>&1; then
        tail -n 20 "$ROOT/origin-fetch-retry.log" >&2
        fail "one transient origin fetch failure did not recover"
      fi
      [ "$(wc -l < "$fetch_log")" -eq 2 ] \
        || fail "transient origin fetch was not retried exactly once"

      fetch_log="$ROOT/origin-fetch-timeout-retry-calls.log"
      : > "$fetch_log"
      if ! FAKE_GIT_FETCH_FAILURE_MODE=timeout-once FAKE_GIT_FETCH_LOG="$fetch_log" \
        run_lifecycle reap "$REPO" > "$ROOT/origin-fetch-timeout-retry.log" 2>&1; then
        tail -n 20 "$ROOT/origin-fetch-timeout-retry.log" >&2
        fail "one timed out origin fetch did not recover"
      fi
      [ "$(wc -l < "$fetch_log")" -eq 2 ] \
        || fail "timed out origin fetch was not retried exactly once"

      protected="$ROOT/wt-origin-fetch-protected"
      git -C "$REPO" worktree add -q -b topic/origin-fetch-protected "$protected" main
      fetch_log="$ROOT/origin-fetch-fail-calls.log"
      : > "$fetch_log"
      if FAKE_GIT_FETCH_FAILURE_MODE=always FAKE_GIT_FETCH_LOG="$fetch_log" \
        run_lifecycle reap "$REPO" > "$ROOT/origin-fetch-fail.log" 2>&1; then
        fail "persistent origin fetch failure passed the reaper gate"
      fi
      [ "$(wc -l < "$fetch_log")" -eq 2 ] \
        || fail "persistent origin fetch did not stop after two attempts"
      grep -Fq 'origin fetch failed after 2 attempt(s) (exit 1)' "$ROOT/origin-fetch-fail.log" \
        || fail "persistent origin fetch failure was not reported with retry count"
      [ -d "$protected" ] || fail "persistent origin fetch failure allowed worktree removal"

      fetch_log="$ROOT/origin-fetch-timeout-fail-calls.log"
      : > "$fetch_log"
      if FAKE_GIT_FETCH_FAILURE_MODE=timeout-always FAKE_GIT_FETCH_LOG="$fetch_log" \
        run_lifecycle reap "$REPO" > "$ROOT/origin-fetch-timeout-fail.log" 2>&1; then
        fail "persistent origin fetch timeout passed the reaper gate"
      fi
      [ "$(wc -l < "$fetch_log")" -eq 2 ] \
        || fail "persistent origin fetch timeout did not stop after two attempts"
      grep -Fq 'origin fetch failed after 2 attempt(s) (exit 124)' "$ROOT/origin-fetch-timeout-fail.log" \
        || fail "persistent origin fetch timeout was not reported with retry count"
      [ -d "$protected" ] || fail "persistent origin fetch timeout allowed worktree removal"

      fetch_log="$ROOT/origin-fetch-killed-calls.log"
      : > "$fetch_log"
      if FAKE_GIT_FETCH_FAILURE_MODE=killed-always FAKE_GIT_FETCH_LOG="$fetch_log" \
        run_lifecycle reap "$REPO" > "$ROOT/origin-fetch-killed.log" 2>&1; then
        fail "origin fetch requiring forced kill passed the reaper gate"
      fi
      [ "$(wc -l < "$fetch_log")" -eq 1 ] \
        || fail "origin fetch requiring forced kill was retried"
      grep -Fq 'origin fetch failed after 1 attempt(s) (exit 137)' "$ROOT/origin-fetch-killed.log" \
        || fail "forced-kill origin fetch failure was not reported immediately"
      [ -d "$protected" ] || fail "forced-kill origin fetch failure allowed worktree removal"
      echo 'ok - transient failures and timeouts retry once; persistent failures and forced kills remain fail-closed'
      exit 0
      ;;
    rescue-ref-sweep-scale)
      grep -Fq 'if [ "${#parent_ids[@]}" -eq 1 ]; then' "$SCRIPT" \
        || fail "patch-equivalence cache no longer excludes multi-parent commits"
      grep -Fq 'merge-base --is-ancestor "$parent" "$main_head"' "$SCRIPT" \
        || fail "patch-equivalence cache no longer requires a main-reachable parent"
      grep -Fq 'cache_key="$parent:$rescue_tree"' "$SCRIPT" \
        || fail "patch-equivalence cache key no longer includes parent and tree"
      rescue_head="$(create_rescue_ref issue- 4251 sweep-seed '8 days')"
      local_count=777
      issue_count=459
      issue_rows=$'4251\t2026-10-10T00:00:00Z\topen'
      rescue_tree="$(git -C "$REPO" rev-parse "$rescue_head^{tree}")"
      rescue_parent="$(git -C "$REPO" rev-parse "$rescue_head^")"
      rescue_refspecs=()
      for ((i=1; i<issue_count; i++)); do
        issue=$((4251 + i))
        head="$(git -C "$REPO" -c user.name=fixture -c user.email=fixture@example.invalid \
          commit-tree "$rescue_tree" -p "$rescue_parent" -m "issue-sweep-$issue")"
        rescue_refspecs+=("$head:refs/heads/rescued/issue-$issue-sweep")
        issue_rows+=$'\n'"$issue"$'\t2026-10-10T00:00:00Z\topen'
      done
      for ((i=issue_count; i<local_count; i++)); do
        head="$(git -C "$REPO" -c user.name=fixture -c user.email=fixture@example.invalid \
          commit-tree "$rescue_tree" -p "$rescue_parent" -m "legacy-sweep-$i")"
        rescue_refspecs+=("$head:refs/heads/rescued/legacy-sweep-$i")
      done
      git -C "$REPO" push -q origin "${rescue_refspecs[@]}"
      date_lookup_log="$ROOT/rescue-ref-date-lookups.log"
      patch_batch_log="$ROOT/rescue-patch-batches.log"
      : > "$patch_batch_log"
      if ! FAKE_ISSUE_ROWS_RAW="$issue_rows" FAKE_RESCUE_REF_DATE_LOG="$date_lookup_log" \
        FAKE_RESCUE_PATCH_BATCH_LOG="$patch_batch_log" \
        run_lifecycle reap "$REPO" > "$ROOT/rescue-ref-sweep.log" 2>&1; then
        tail -n 20 "$ROOT/rescue-ref-sweep.log" >&2
        fail "777-ref rescue sweep failed"
      fi
      grep -Fq 'phase=worktree-reap:rescue-ref-sweep' "$ROOT/rescue-ref-sweep.log" \
        || fail "777-ref rescue sweep omitted the rescue-ref-sweep phase marker"
      [ ! -s "$date_lookup_log" ] \
        || fail "rescue sweep launched one git show per ref ($(wc -l < "$date_lookup_log") date lookups)"
      batch_count="$(wc -l < "$patch_batch_log")"
      checked_heads="$(awk '{sum += $1} END {print sum+0}' "$patch_batch_log")"
      # One batch indexes fixture main's base commit; one checks rescue pair representative.
      [ "$batch_count" -eq 2 ] && [ "$checked_heads" -eq 2 ] \
        || fail "rescue sweep repeated patch checks for identical parent/tree pairs (batches=$batch_count heads=$checked_heads)"
      remote_ref_count="$(git --git-dir="$REMOTE" for-each-ref --format='%(refname)' refs/heads/rescued/ | wc -l)"
      [ "$remote_ref_count" -eq "$local_count" ] \
        || fail "open latest rescue refs were not all retained ($remote_ref_count/$local_count)"
      unique_head_count="$(git --git-dir="$REMOTE" for-each-ref --format='%(objectname)' refs/heads/rescued/ | sort -u | wc -l)"
      [ "$unique_head_count" -eq "$local_count" ] \
        || fail "scale fixture did not create unique rescue heads ($unique_head_count/$local_count)"
      echo 'ok - 777-ref rescue sweep checks identical parent/tree pairs once'
      exit 0
      ;;
    rescue-ref-sweep-diverse-scale)
      rescue_parent="$(git -C "$REPO" rev-parse main)"
      local_count="${FAKE_DIVERSE_RESCUE_COUNT:-871}"
      rescue_refspecs=()
      for ((i=0; i<local_count; i++)); do
        printf -v rescue_path 'change-%04d.txt' "$i"
        blob="$(printf 'diverse rescue patch %s\n' "$i" | git -C "$REPO" hash-object -w --stdin)"
        tree="$(printf '100644 blob %s\t%s\n' "$blob" "$rescue_path" | git -C "$REPO" mktree)"
        head="$(git -C "$REPO" -c user.name=fixture -c user.email=fixture@example.invalid \
          commit-tree "$tree" -p "$rescue_parent" -m "rescue-diverse-$i")"
        rescue_refspecs+=("$head:refs/heads/rescued/legacy-diverse-$i")
      done
      git -C "$REPO" push -q origin "${rescue_refspecs[@]}"
      patch_scan_log="$ROOT/rescue-patch-scans.log"
      patch_batch_log="$ROOT/rescue-patch-batches.log"
      metadata_log="$ROOT/rescue-metadata.log"
      : > "$patch_scan_log"
      : > "$patch_batch_log"
      : > "$metadata_log"
      started_ns="$(date +%s%N)"
      if ! FAKE_RESCUE_PATCH_SCAN_LOG="$patch_scan_log" FAKE_RESCUE_PATCH_BATCH_LOG="$patch_batch_log" \
        FAKE_RESCUE_METADATA_LOG="$metadata_log" \
        run_lifecycle reap "$REPO" > "$ROOT/rescue-diverse-sweep.log" 2>&1; then
        tail -n 20 "$ROOT/rescue-diverse-sweep.log" >&2
        fail "871-ref diverse rescue sweep failed"
      fi
      elapsed_ms=$((($(date +%s%N) - started_ns) / 1000000))
      individual_scans="$(wc -l < "$patch_scan_log" | tr -d ' ')"
      batch_scans="$(wc -l < "$patch_batch_log" | tr -d ' ')"
      batched_heads="$(awk '{sum += $1} END {print sum+0}' "$patch_batch_log")"
      metadata_batches="$(wc -l < "$metadata_log" | tr -d ' ')"
      expected_batches=$((1 + (local_count + 63) / 64))
      expected_heads=$((local_count + 1))
      [ "$individual_scans" -eq 0 ] && [ "$batch_scans" -eq "$expected_batches" ] && [ "$batched_heads" -eq "$expected_heads" ] && [ "$metadata_batches" -eq 1 ] \
        || { tail -n 12 "$ROOT/rescue-diverse-sweep.log" >&2; fail "$local_count distinct rescue patches were not checked in bounded batches (individual=$individual_scans batches=$batch_scans heads=$batched_heads metadata=$metadata_batches elapsed_ms=$elapsed_ms)"; }
      remote_ref_count="$(git --git-dir="$REMOTE" for-each-ref --format='%(refname)' refs/heads/rescued/ | wc -l)"
      [ "$remote_ref_count" -eq "$local_count" ] \
        || fail "non-equivalent rescue refs were not all retained ($remote_ref_count/$local_count)"
      echo "ok - $local_count diverse rescue refs use $expected_batches patch batches and finish in ${elapsed_ms}ms"
      exit 0
      ;;
    rescue-ref-sweep-off-main-scale)
      local_count="${FAKE_OFF_MAIN_RESCUE_COUNT:-96}"
      main_head="$(git -C "$REPO" rev-parse main)"
      base_blob="$(printf 'off-main shared patch\n' | git -C "$REPO" hash-object -w --stdin)"
      base_tree="$(printf '100644 blob %s\tshared-base.txt\n' "$base_blob" | git -C "$REPO" mktree)"
      rescue_parent="$(git -C "$REPO" -c user.name=fixture -c user.email=fixture@example.invalid \
        commit-tree "$base_tree" -p "$main_head" -m rescue-off-main-base)"
      rescue_refspecs=()
      for ((i=0; i<local_count; i++)); do
        printf -v suffix '%04d' "$i"
        printf -v rescue_path 'off-main-%04d.txt' "$i"
        blob="$(printf 'off-main rescue patch %s\n' "$i" | git -C "$REPO" hash-object -w --stdin)"
        tree="$(printf '100644 blob %s\tshared-base.txt\n100644 blob %s\t%s\n' \
          "$base_blob" "$blob" "$rescue_path" | git -C "$REPO" mktree)"
        head="$(git -C "$REPO" -c user.name=fixture -c user.email=fixture@example.invalid \
          commit-tree "$tree" -p "$rescue_parent" -m "rescue-off-main-$i")"
        rescue_refspecs+=("$head:refs/heads/rescued/legacy-off-main-$suffix")
      done
      git -C "$REPO" push -q origin "${rescue_refspecs[@]}"
      patch_scan_log="$ROOT/rescue-off-main-patch-scans.log"
      patch_batch_log="$ROOT/rescue-off-main-patch-batches.log"
      metadata_log="$ROOT/rescue-off-main-metadata.log"
      : > "$patch_scan_log"
      : > "$patch_batch_log"
      : > "$metadata_log"
      if ! FAKE_RESCUE_PATCH_SCAN_LOG="$patch_scan_log" \
        FAKE_RESCUE_PATCH_BATCH_LOG="$patch_batch_log" \
        FAKE_RESCUE_METADATA_LOG="$metadata_log" \
        run_lifecycle reap "$REPO" > "$ROOT/rescue-off-main-sweep.log" 2>&1; then
        tail -n 20 "$ROOT/rescue-off-main-sweep.log" >&2
        fail "off-main rescue sweep failed"
      fi
      individual_scans="$(wc -l < "$patch_scan_log" | tr -d ' ')"
      batch_scans="$(wc -l < "$patch_batch_log" | tr -d ' ')"
      batched_heads="$(awk '{sum += $1} END {print sum+0}' "$patch_batch_log")"
      metadata_batches="$(wc -l < "$metadata_log" | tr -d ' ')"
      rescue_commits=$((local_count + 1))
      expected_batches=$((1 + (rescue_commits + 63) / 64))
      expected_heads=$((rescue_commits + 1))
      [ "$individual_scans" -eq 0 ] && [ "$batch_scans" -eq "$expected_batches" ] \
        && [ "$batched_heads" -eq "$expected_heads" ] && [ "$metadata_batches" -eq 1 ] \
        || { tail -n 12 "$ROOT/rescue-off-main-sweep.log" 2>/dev/null >&2; \
          fail "off-main rescue history was not batch-checked (individual=$individual_scans batches=$batch_scans heads=$batched_heads metadata=$metadata_batches)"; }
      remote_ref_count="$(git --git-dir="$REMOTE" for-each-ref --format='%(refname)' refs/heads/rescued/ | wc -l)"
      [ "$remote_ref_count" -eq "$local_count" ] \
        || fail "off-main non-equivalent rescues were not retained ($remote_ref_count/$local_count)"
      echo "ok - $local_count off-main rescue histories use $expected_batches patch batches and stay retained"
      exit 0
      ;;
    rescue-patch-equivalent)
      rescue_wt="$ROOT/wt-rescue-patch-equivalent"
      git -C "$REPO" worktree add -q -b topic/rescue-patch-equivalent "$rescue_wt" main
      printf 'same patch\n' > "$rescue_wt/equivalent.txt"
      git -C "$rescue_wt" add equivalent.txt
      git -C "$rescue_wt" commit -qm rescue-patch-equivalent
      rescue_head="$(git -C "$rescue_wt" rev-parse HEAD)"
      git -C "$REPO" push -qu origin "$rescue_head:refs/heads/rescued/legacy-equivalent"
      git -C "$REPO" worktree remove "$rescue_wt"
      git -C "$REPO" branch -D topic/rescue-patch-equivalent >/dev/null
      printf 'same patch\n' > "$REPO/equivalent.txt"
      git -C "$REPO" add equivalent.txt
      git -C "$REPO" commit -qm main-patch-equivalent
      git -C "$REPO" push -qu origin main
      equivalent_output="$(run_lifecycle reap "$REPO" 2>&1)" \
        || fail "equivalent rescue sweep failed: $equivalent_output"
      ! git --git-dir="$REMOTE" show-ref --verify --quiet refs/heads/rescued/legacy-equivalent \
        || fail "single-commit patch-equivalent rescue remained: $equivalent_output"
      [ -f "$NIGHT/cleanup-archive/rescued-legacy-equivalent-${rescue_head:0:12}.patch" ] \
        || fail "single-commit equivalent rescue was deleted without archiving: $equivalent_output"
      echo 'ok - single-commit patch-equivalent rescue remains archivable and removable'
      exit 0
      ;;
    rescue-patch-multi-equivalent)
      rescue_wt="$ROOT/wt-rescue-patch-multi-equivalent"
      git -C "$REPO" worktree add -q -b topic/rescue-patch-multi-equivalent "$rescue_wt" main
      base_head="$(git -C "$rescue_wt" rev-parse HEAD)"
      printf 'first shared patch\n' > "$rescue_wt/multi-first.txt"
      git -C "$rescue_wt" add multi-first.txt
      git -C "$rescue_wt" commit -qm rescue-multi-first
      printf 'second shared patch\n' > "$rescue_wt/multi-second.txt"
      git -C "$rescue_wt" add multi-second.txt
      git -C "$rescue_wt" commit -qm rescue-multi-second
      rescue_head="$(git -C "$rescue_wt" rev-parse HEAD)"
      git -C "$REPO" push -qu origin "$rescue_head:refs/heads/rescued/legacy-multi-equivalent"
      git -C "$REPO" worktree remove "$rescue_wt"
      git -C "$REPO" branch -D topic/rescue-patch-multi-equivalent >/dev/null

      non_equivalent_wt="$ROOT/wt-rescue-patch-multi-non-equivalent"
      git -C "$REPO" worktree add -q -b topic/rescue-patch-multi-non-equivalent "$non_equivalent_wt" main
      printf 'first shared patch\n' > "$non_equivalent_wt/multi-first.txt"
      git -C "$non_equivalent_wt" add multi-first.txt
      git -C "$non_equivalent_wt" commit -qm rescue-multi-shared
      printf 'unmatched rescue patch\n' > "$non_equivalent_wt/multi-unmatched.txt"
      git -C "$non_equivalent_wt" add multi-unmatched.txt
      git -C "$non_equivalent_wt" commit -qm rescue-multi-unmatched
      non_equivalent_head="$(git -C "$non_equivalent_wt" rev-parse HEAD)"
      git -C "$REPO" push -qu origin "$non_equivalent_head:refs/heads/rescued/legacy-multi-non-equivalent"
      git -C "$REPO" worktree remove "$non_equivalent_wt"
      git -C "$REPO" branch -D topic/rescue-patch-multi-non-equivalent >/dev/null

      printf 'first shared patch\n' > "$REPO/multi-first.txt"
      git -C "$REPO" add multi-first.txt
      git -C "$REPO" commit -qm main-multi-first
      printf 'second shared patch\n' > "$REPO/multi-second.txt"
      git -C "$REPO" add multi-second.txt
      git -C "$REPO" commit -qm main-multi-second
      printf 'main-only change\n' > "$REPO/multi-main-only.txt"
      git -C "$REPO" add multi-main-only.txt
      git -C "$REPO" commit -qm main-multi-extra
      git -C "$REPO" push -qu origin main

      main_tree="$(git -C "$REPO" rev-parse main^{tree})"
      rescue_tree="$(git -C "$REPO" rev-parse "$rescue_head^{tree}")"
      [ "$main_tree" != "$rescue_tree" ] \
        || fail 'multi-commit fixture unexpectedly has same tree as main'
      main_patch_ids="$(git -C "$REPO" log --no-merges --format='%H' main \
        | while read -r commit; do
            git -C "$REPO" show --binary --no-ext-diff --format="commit %H" -p "$commit"
          done | git -C "$REPO" patch-id --stable | awk '{print $1}')"
      rescue_patch_ids="$(git -C "$REPO" rev-list --no-merges --reverse "$base_head..$rescue_head" \
        | while read -r commit; do
            git -C "$REPO" show --binary --no-ext-diff --format="commit %H" -p "$commit"
          done | git -C "$REPO" patch-id --stable | awk '{print $1}')"
      while read -r patch_id; do
        [ -n "$patch_id" ] || continue
        grep -Fxq -- "$patch_id" <<< "$main_patch_ids" \
          || fail "multi-commit fixture patch is missing from main: $patch_id"
      done <<< "$rescue_patch_ids"
      [ "$(wc -l <<< "$rescue_patch_ids" | tr -d '[:space:]')" = 2 ] \
        || fail 'multi-commit fixture did not create two non-empty rescue patches'
      mapfile -t non_equivalent_patch_ids < <(git -C "$REPO" rev-list --no-merges --reverse \
        "$(git -C "$REPO" merge-base main "$non_equivalent_head")..$non_equivalent_head" \
        | while read -r commit; do
            git -C "$REPO" show --binary --no-ext-diff --format="commit %H" -p "$commit"
          done | git -C "$REPO" patch-id --stable | awk '{print $1}')
      [ "${#non_equivalent_patch_ids[@]}" = 2 ] \
        || fail 'non-equivalent fixture did not create two non-empty rescue patches'
      grep -Fxq -- "${non_equivalent_patch_ids[0]}" <<< "$main_patch_ids" \
        || fail 'non-equivalent fixture shared patch is missing from main'
      if grep -Fxq -- "${non_equivalent_patch_ids[1]}" <<< "$main_patch_ids"; then
        fail 'non-equivalent fixture unmatched patch unexpectedly appears in main'
      fi
      cumulative_patch_id="$(git -C "$REPO" diff --binary --no-ext-diff "main...$rescue_head" \
        | git -C "$REPO" patch-id --stable | awk 'NR == 1 {print $1}')"
      if grep -Fxq -- "$cumulative_patch_id" <<< "$main_patch_ids"; then
        fail 'multi-commit fixture cumulative patch unexpectedly matches a main commit'
      fi

      timeout_output="$(FAKE_RESCUE_PATCH_EQUIV_SHA="$rescue_head" FAKE_RESCUE_PATCH_EQUIV_SLEEP=3 \
        WORKTREE_REAP_GIT_TIMEOUT_SECONDS=1 run_lifecycle reap "$REPO" 2>&1)" \
        || fail "timed-out multi-commit patch check blocked reap: $timeout_output"
      [ "$(git --git-dir="$REMOTE" rev-parse refs/heads/rescued/legacy-multi-equivalent 2>/dev/null || true)" = "$rescue_head" ] \
        || fail "multi-commit rescue was deleted after patch-check timeout: $timeout_output"
      grep -Fq $'kept-remote-rescue\trescued/legacy-multi-equivalent\t'"$rescue_head"$'\tpatch-check-failed' \
        "$NIGHT/worktree-cleanup-manifest.txt" \
        || fail "multi-commit timeout was not recorded as retained: $timeout_output"

      multi_output="$(run_lifecycle reap "$REPO" 2>&1)" \
        || fail "multi-commit equivalent rescue sweep failed: $multi_output"
      ! git --git-dir="$REMOTE" show-ref --verify --quiet refs/heads/rescued/legacy-multi-equivalent \
        || fail "multi-commit patch-equivalent rescue remained: $multi_output"
      [ -f "$NIGHT/cleanup-archive/rescued-legacy-multi-equivalent-${rescue_head:0:12}.patch" ] \
        || fail "multi-commit equivalent rescue was deleted without archiving: $multi_output"
      [ "$(git --git-dir="$REMOTE" rev-parse refs/heads/rescued/legacy-multi-non-equivalent 2>/dev/null || true)" = "$non_equivalent_head" ] \
        || fail "non-equivalent multi-commit rescue was deleted: $multi_output"
      echo 'ok - multi-commit equivalent rescue archives before removal; non-equivalent and timed-out refs stay'
      exit 0
      ;;
    rescue-patch-scan-timeout)
      rescue_wt="$ROOT/wt-rescue-patch-scan-timeout"
      git -C "$REPO" worktree add -q -b topic/rescue-patch-scan-timeout "$rescue_wt" main
      printf 'preserve on scan timeout\n' > "$rescue_wt/scan-timeout.txt"
      git -C "$rescue_wt" add scan-timeout.txt
      git -C "$rescue_wt" commit -qm rescue-patch-scan-timeout
      rescue_head="$(git -C "$rescue_wt" rev-parse HEAD)"
      git -C "$REPO" push -qu origin "$rescue_head:refs/heads/rescued/legacy-scan-timeout"
      git -C "$REPO" worktree remove "$rescue_wt"
      git -C "$REPO" branch -D topic/rescue-patch-scan-timeout >/dev/null
      warm_output="$(run_lifecycle reap "$REPO" 2>&1)" \
        || fail "could not warm main patch index for batch timeout: $warm_output"
      [ "$(git --git-dir="$REMOTE" rev-parse refs/heads/rescued/legacy-scan-timeout 2>/dev/null || true)" = "$rescue_head" ] \
        || fail "rescue ref was not retained while warming the main patch index: $warm_output"
      scan_output="$(FAKE_PATCH_BATCH_SLEEP=3 WORKTREE_REAP_GIT_TIMEOUT_SECONDS=1 \
        run_lifecycle reap "$REPO" 2>&1)" \
        || fail "timed-out rescue patch check blocked reap: $scan_output"
      [ "$(git --git-dir="$REMOTE" rev-parse refs/heads/rescued/legacy-scan-timeout 2>/dev/null || true)" = "$rescue_head" ] \
        || fail "rescue ref was deleted after a timed-out patch check: $scan_output"
      grep -Fq $'kept-remote-rescue\trescued/legacy-scan-timeout\t'"$rescue_head"$'\tpatch-check-failed' \
        "$NIGHT/worktree-cleanup-manifest.txt" \
        || fail "timed-out patch check was not recorded as a retained rescue: $scan_output"
      echo 'ok - timed-out rescue patch scan is bounded and keeps ref'
      exit 0
      ;;
    rescue-patch-archive-timeout)
      rescue_head="$(create_rescue_ref issue- 4250 old-archive '8 days')"
      warm_output="$(FAKE_ISSUE_STATE_4250=open run_lifecycle reap "$REPO" 2>&1)" \
        || fail "could not warm the completed main patch index: $warm_output"
      [ "$(git --git-dir="$REMOTE" rev-parse refs/heads/rescued/issue-4250-old-archive 2>/dev/null || true)" = "$rescue_head" ] \
        || fail "open rescue was not retained while warming the patch index: $warm_output"
      format_patch_log="$ROOT/format-patch.log"
      set +e
      archive_output="$(FAKE_ISSUE_STATE_4250=closed FAKE_FORMAT_PATCH_SLEEP=2 \
        FAKE_FORMAT_PATCH_LOG="$format_patch_log" WORKTREE_REAP_GIT_TIMEOUT_SECONDS=1 \
        ZF_WORKTREE_REAP_TIMEOUT_SECONDS=14 \
        run_lifecycle reap "$REPO" 2>&1)"
      archive_status=$?
      set -e
      [ ! -s "$format_patch_log" ] || fail "reaper started an archive without time for its bound and lease/readback reserve: $archive_output"
      [ "$archive_status" -eq 0 ] || fail "reaper failed to defer rescue archival safely: $archive_status $archive_output"
      [ "$(git --git-dir="$REMOTE" rev-parse refs/heads/rescued/issue-4250-old-archive 2>/dev/null || true)" = "$rescue_head" ] \
        || fail "rescue ref was deleted without a completed archive: $archive_output"
      ! find "$NIGHT/cleanup-archive" -maxdepth 1 -type f -name '*.tmp.*' -print -quit 2>/dev/null \
        | grep -q . || fail "timed-out archive left a partial file: $archive_output"

      : > "$format_patch_log"
      set +e
      archive_output="$(FAKE_ISSUE_STATE_4250=closed FAKE_FORMAT_PATCH_SLEEP=2 \
        FAKE_FORMAT_PATCH_LOG="$format_patch_log" WORKTREE_REAP_GIT_TIMEOUT_SECONDS=1 \
        run_lifecycle reap "$REPO" 2>&1)"
      archive_status=$?
      set -e
      [ "$archive_status" -eq 0 ] || fail "bounded archive timeout blocked the whole reaper: $archive_status $archive_output"
      [ -s "$format_patch_log" ] || fail "archive timeout path was not exercised: $archive_output"
      [ "$(git --git-dir="$REMOTE" rev-parse refs/heads/rescued/issue-4250-old-archive 2>/dev/null || true)" = "$rescue_head" ] \
        || fail "rescue ref was deleted after a timed-out archive: $archive_output"
      grep -Fq $'kept-remote-rescue\trescued/issue-4250-old-archive\t'"$rescue_head"$'\tarchive-failed' "$NIGHT/worktree-cleanup-manifest.txt" \
        || fail "archive timeout was not recorded while retaining the rescue: $archive_output"
      ! find "$NIGHT/cleanup-archive" -maxdepth 1 -type f -name '*.tmp.*' -print -quit 2>/dev/null \
        | grep -q . || fail "timed-out archive left a partial file: $archive_output"

      recovery_output="$(FAKE_ISSUE_STATE_4250=closed run_lifecycle reap "$REPO" 2>&1)" \
        || fail "rescue archive did not recover on retry: $recovery_output"
      ! git --git-dir="$REMOTE" show-ref --verify --quiet refs/heads/rescued/issue-4250-old-archive \
        || fail "recovered rescue was not deleted after archiving: $recovery_output"
      find "$NIGHT/cleanup-archive" -maxdepth 1 -type f \
        -name 'rescued-issue-4250-old-archive-*.patch' -print -quit | grep -q . \
        || fail "recovered rescue patch was not archived: $recovery_output"
      echo 'ok - timed-out rescue archive is bounded, retained, cleaned, and retryable'
      exit 0
      ;;
    rescue-ref-sweep-batch)
      local_count=8
      for ((i=0; i<local_count; i++)); do
        printf -v suffix '%02d' "$i"
        create_rescue_ref issue- 4251 "sweep-$suffix" '8 days' >/dev/null
      done
      worktree_list_log="$ROOT/rescue-worktree-list.log"
      systemctl_log="$ROOT/rescue-systemctl.log"
      sweep_output="$(FAKE_ISSUE_STATE_4251=closed \
        FAKE_GIT_WORKTREE_LIST_LOG="$worktree_list_log" \
        FAKE_SYSTEMCTL_LOG="$systemctl_log" run_lifecycle reap "$REPO" 2>&1)" \
        || fail "multi-ref rescue sweep failed: $sweep_output"
      live_state_reads="$(awk '$1 == "--user" && $2 == "list-units" { n++ } END { print n+0 }' "$systemctl_log")"
      worktree_list_reads="$(wc -l < "$worktree_list_log")"
      [ "$live_state_reads" -le 5 ] \
        || fail "rescue sweep reloaded full live state per ref ($live_state_reads reads; $worktree_list_reads worktree scans): $sweep_output"
      [ "$worktree_list_reads" -le 9 ] \
        || fail "rescue sweep rescanned worktrees per ref ($worktree_list_reads reads): $sweep_output"
      awk '/phase=worktree-reap:rescue-patch-archive/ { archived=1 } \
        archived && /phase=worktree-reap:rescue-ref-sweep/ { found=1 } \
        END { exit !found }' <<< "$sweep_output" \
        || fail "phase marker stayed on archive after returning to rescue checks: $sweep_output"
      for ((i=0; i<local_count; i++)); do
        printf -v suffix '%02d' "$i"
        ! git --git-dir="$REMOTE" show-ref --verify --quiet \
          "refs/heads/rescued/issue-4251-sweep-$suffix" \
          || fail "closed issue rescue remained after archive: sweep-$suffix"
      done
      echo 'ok - large rescue sweep reuses live-state and worktree snapshots'
      exit 0
      ;;
    remote-branch-sweep-scale)
      base_head="$(git -C "$REPO" rev-parse main)"
      remote_ref_updates="$ROOT/remote-branch-refs"
      for ((i=0; i<20; i++)); do
        printf -v suffix '%03d' "$i"
        printf 'update refs/heads/fixture/remote-%s %s\n' "$suffix" "$base_head" >> "$remote_ref_updates"
      done
      printf 'update refs/heads/fixture/remote-open %s\n' "$base_head" >> "$remote_ref_updates"
      printf 'update refs/heads/fixture/remote-live %s\n' "$base_head" >> "$remote_ref_updates"
      git --git-dir="$REMOTE" update-ref --stdin < "$remote_ref_updates"

      owner_count=6
      for ((i=0; i<owner_count; i++)); do
        printf -v suffix '%03d' "$i"
        printf '%s\n%s\n%s\n%s\n%s\n' \
          "$ROOT/other-worktree-$suffix" "$ROOT/brief.md" "fixture/unrelated-$suffix" \
          "$ROOT/report-$suffix.txt" 1 > "$NIGHT/.hand-owner-$((990000000 + i))"
      done
      owner_count=$((owner_count + 1))
      printf '%s\n%s\n%s\n%s\n%s\n' \
        "$ROOT/live-owner-worktree" "$ROOT/live-owner-brief.md" "fixture/remote-live" \
        "$ROOT/live-owner-report.txt" 1 > "$NIGHT/.hand-owner-$$"

      pr_rows="$ROOT/remote-branch-pr-rows"
      for ((i=0; i<240; i++)); do
        printf -v suffix '%03d' "$i"
        printf 'fixture/unrelated-%s\t%s\tmain\tclosed\t\t\n' \
          "$suffix" "$base_head" >> "$pr_rows"
      done
      printf 'fixture/remote-open\t%s\tmain\topen\t\t\n' "$base_head" >> "$pr_rows"
      owner_reads="$ROOT/remote-branch-owner-reads.log"
      remote_sweep_output="$(FAKE_PR_ROWS="$(cat -- "$pr_rows")" \
        FAKE_HAND_OWNER_READ_LOG="$owner_reads" run_lifecycle reap "$REPO" 2>&1)" \
        || fail "remote branch sweep fixture failed: $remote_sweep_output"
      owner_read_count="$(wc -l < "$owner_reads" | tr -d '[:space:]')"
      [ "$owner_read_count" -le "$((owner_count * 2))" ] \
        || fail "remote branch sweep rescanned hand-owner files per ref ($owner_read_count reads for $owner_count owners): $remote_sweep_output"
      ! git --git-dir="$REMOTE" show-ref --verify --quiet refs/heads/fixture/remote-000 \
        || fail "safe remote branch remained after sweep: $remote_sweep_output"
      git --git-dir="$REMOTE" show-ref --verify --quiet refs/heads/fixture/remote-open \
        || fail "remote branch with open PR was removed: $remote_sweep_output"
      git --git-dir="$REMOTE" show-ref --verify --quiet refs/heads/fixture/remote-live \
        || fail "remote branch with live owner was removed: $remote_sweep_output"
      echo 'ok - remote branch sweep reuses hand-owner snapshot and preserves open/live branches'
      exit 0
      ;;
    rescue-query-timeout-phase)
      rescue_wt="$ROOT/wt-rescue-query-timeout"
      git -C "$REPO" worktree add -q -b topic/issue-4244-query-timeout "$rescue_wt" main
      printf 'unreadable rescue candidate\n' > "$rescue_wt/query-timeout.txt"
      git -C "$rescue_wt" add query-timeout.txt
      git -C "$rescue_wt" commit -qm 'old unreadable rescue candidate'
      rescue_head="$(git -C "$rescue_wt" rev-parse HEAD)"
      git -C "$REPO" push -qu origin "$rescue_head:refs/heads/rescued/issue-4244-query-timeout"
      git -C "$REPO" worktree remove "$rescue_wt"
      git -C "$REPO" branch -D topic/issue-4244-query-timeout >/dev/null
      pr_rows_cache="$ROOT/pr-rows-cache"
      printf '7\t2026-10-10T00:00:00Z\tfixture/cached\tabc\tmain\topen\t\t\n' > "$pr_rows_cache"
      set +e
      stalled_output="$(FAKE_GH_STALL_PULLS=1 FAKE_GH_STALL_SECONDS=60 FAKE_ISSUE_STATE_4244=closed \
        WORKTREE_PR_ROWS_CACHE="$pr_rows_cache" WORKTREE_REAP_GH_TIMEOUT_SECONDS=1 \
        run_lifecycle reap "$REPO" 2>&1)"
      stalled_status=$?
      set -e
      [ "$stalled_status" -eq 1 ] || fail "stalled PR-state query was not a fail-closed error: $stalled_status $stalled_output"
      [[ "$stalled_output" == *'phase=worktree-reap:pr-list-query'* ]] \
        || fail "stalled query did not retain its phase marker: $stalled_output"
      [[ "$stalled_output" == *'all PR item states unreadable'* \
        && "$stalled_output" == *'GitHub PR state unreadable for commit'* ]] \
        || fail "stalled query did not isolate unreadable PR item state: $stalled_output"
      [ "$(git --git-dir="$REMOTE" rev-parse refs/heads/rescued/issue-4244-query-timeout 2>/dev/null || true)" = "$rescue_head" ] \
        || fail "rescue candidate changed after PR-state timeout: $stalled_output"

      issue_timeout_ref=refs/heads/rescued/issue-4246-query-timeout
      git -C "$REPO" push -qu origin "main:$issue_timeout_ref"
      issue_timeout_head="$(git --git-dir="$REMOTE" rev-parse "$issue_timeout_ref")"
      issue_rows_cache="$ROOT/issue-state-cache"
      printf '4246\t2026-10-10T00:00:00Z\tclosed\n' > "$issue_rows_cache"
      set +e
      issue_timeout_output="$(FAKE_GH_STALL_ISSUES=1 FAKE_GH_FAIL_ISSUE=4246 FAKE_GH_STALL_SECONDS=60 \
        WORKTREE_PR_ROWS_CACHE="$pr_rows_cache" WORKTREE_ISSUE_ROWS_CACHE="$issue_rows_cache" \
        WORKTREE_REAP_GH_TIMEOUT_SECONDS=1 run_lifecycle reap "$REPO" 2>&1)"
      issue_timeout_status=$?
      set -e
      [ "$issue_timeout_status" -eq 0 ] \
        || fail "one failed issue lookup aborted readable issue cleanup: $issue_timeout_status $issue_timeout_output"
      [[ "$issue_timeout_output" == *'phase=worktree-reap:rescue-issue-query'* ]] \
        || fail "stalled issue-state query omitted its phase: $issue_timeout_output"
      grep -Fq 'SLOW reaped=1 skipped-unreadable=1' <<< "$issue_timeout_output" \
        || fail "stalled lookup did not report one kept unreadable issue: $issue_timeout_output"
      [ "$(git --git-dir="$REMOTE" rev-parse "$issue_timeout_ref" 2>/dev/null || true)" = "$issue_timeout_head" ] \
        || fail "issue-state timeout deleted dependent rescue ref: $issue_timeout_output"

      issue_expiry_head="$(create_rescue_ref '' 4245 expired '8 days')"
      git --git-dir="$REMOTE" update-ref -d "$issue_timeout_ref" "$issue_timeout_head"
      git --git-dir="$REMOTE" update-ref -d refs/heads/rescued/issue-4244-query-timeout "$rescue_head"
      printf '4245\t2026-10-10T00:00:00Z\tclosed\n' > "$issue_rows_cache"
      set +e
      issue_failure_output="$(FAKE_GH_FAIL_ISSUES=1 FAKE_GH_FAIL_ISSUE=4245 WORKTREE_PR_ROWS_CACHE="$pr_rows_cache" \
        WORKTREE_ISSUE_ROWS_CACHE="$issue_rows_cache" run_lifecycle reap "$REPO" 2>&1)"
      issue_failure_status=$?
      set -e
      [ "$issue_failure_status" -eq 1 ] \
        || fail "failed issue-state query did not abort expired-rescue cleanup: $issue_failure_status $issue_failure_output"
      [[ "$issue_failure_output" == *'phase=worktree-reap:rescue-issue-query'* \
        && "$issue_failure_output" == *'all rescue issue states unreadable'* ]] \
        || fail "failed issue-state query omitted phase/reason: $issue_failure_output"
      [ "$(git --git-dir="$REMOTE" rev-parse refs/heads/rescued/4245-expired 2>/dev/null || true)" = "$issue_expiry_head" ] \
        || fail "failed issue-state query deleted expired rescue ref: $issue_failure_output"
      echo 'ok - all unreadable PR items fail closed; unreadable issue states stay per-item'
      exit 0
      ;;
    rescue-issue-query-fallback-budget)
      issue_log="$ROOT/issue-fallback-budget.log"
      defer_log="$ROOT/issue-fallback-deferred.log"
      : > "$issue_log"
      : > "$defer_log"
      issue_lookup_body="$(sed -n '/^rescue_issue_is_closed() {/,/^}/p' "$SCRIPT")"
      grep -Fq 'reap_budget_remaining_seconds' <<< "$issue_lookup_body" \
        && grep -Fq 'reap_remote_batch_reserve_seconds' <<< "$issue_lookup_body" \
        && grep -Fq 'remaining <= reserve + issue_timeout' <<< "$issue_lookup_body" \
        || fail 'issue point-read source lost remaining-budget or reserve guard'
      (
        source "$SCRIPT"
        REAP_OUTER_BUDGET_SECONDS=50
        LIFECYCLE_GIT_TIMEOUT_SECONDS=12
        LIFECYCLE_GIT_KILL_AFTER_SECONDS=2
        RESCUE_ISSUE_STATES_LOADED=1
        RESCUE_ISSUE_STATES=()
        RESCUE_ISSUE_POINT_LOOKED_UP=()
        RESCUE_ISSUE_COUNTED=()
        RESCUE_ISSUE_TOTAL=0
        RESCUE_ISSUE_READABLE=0
        RESCUE_ISSUE_UNREADABLE=0
        export PATH="$BIN:$PATH" FAKE_GH_LOG="$issue_log"
        SECONDS=1
        for issue_id in $(seq 4300 4359); do
          set +e
          rescue_issue_is_closed "$issue_id" >/dev/null 2>>"$defer_log"
          issue_status=$?
          set -e
          [ "$issue_status" -eq 2 ] \
            || { echo "issue $issue_id lookup was not deferred (status=$issue_status)" >&2; exit 1; }
        done
        [ "$RESCUE_ISSUE_TOTAL" -eq 60 ] && [ "$RESCUE_ISSUE_UNREADABLE" -eq 60 ] \
          || { echo "issue cohort accounting was wrong: total=$RESCUE_ISSUE_TOTAL unreadable=$RESCUE_ISSUE_UNREADABLE" >&2; exit 1; }
      ) || fail 'low-budget issue fallback cohort was not safely deferred'
      [ "$(grep -c 'issue state lookup deferred' "$defer_log")" -eq 60 ] \
        || fail "deferred cohort omitted per-item reason: $(cat "$defer_log")"
      [ ! -s "$issue_log" ] || fail "deferred issue fallback still called GitHub: $(cat "$issue_log")"
      echo 'ok - issue fallback preserves reserve and defers low-budget reads'
      exit 0
      ;;
    pr-list-partial)
      git -C "$REPO" branch fixture/readable main
      git -C "$REPO" branch fixture/unreadable main
      git -C "$REPO" branch fixture/open main
      git -C "$REPO" push -qu origin main:refs/heads/remote-readable
      git -C "$REPO" fetch -q origin
      gh_log="$ROOT/pr-partial-gh-calls"
      : > "$gh_log"
      set +e
      partial_output="$(FAKE_GH_LOG="$gh_log" FAKE_GH_FAIL_PULLS=1 \
        FAKE_GH_FAIL_PR_BRANCH=fixture/unreadable FAKE_GH_OPEN_PR_BRANCH=fixture/open \
        run_lifecycle reap "$REPO" 2>&1)"
      partial_status=$?
      set -e
      [ "$partial_status" -eq 0 ] || fail "one unreadable PR branch blocked other reap items: $partial_status $partial_output"
      [[ "$partial_output" == *'PR page 1 failed (exit 37): simulated unreadable PR list'* ]] \
        || fail "bulk PR failure omitted its cause: $partial_output"
      grep -Fq 'GitHub PR state unreadable for branch fixture/unreadable' <<< "$partial_output" \
        || fail "unreadable branch did not report its point-read cause: $partial_output"
      grep -Fq 'SLOW reaped=' <<< "$partial_output" \
        && grep -Fq 'skipped-unreadable=1' <<< "$partial_output" \
        || fail "partial PR reads did not report SLOW counts: $partial_output"
      ! git -C "$REPO" show-ref --verify --quiet refs/heads/fixture/readable \
        || fail "readable local branch was not reaped: $partial_output"
      git -C "$REPO" show-ref --verify --quiet refs/heads/fixture/unreadable \
        || fail "unreadable local branch was deleted: $partial_output"
      git -C "$REPO" show-ref --verify --quiet refs/heads/fixture/open \
        || fail "readable open-PR branch was deleted: $partial_output"
      ! git --git-dir="$REMOTE" show-ref --verify --quiet refs/heads/remote-readable \
        || fail "readable remote branch was not reaped: $partial_output"
      [ "$(grep -c 'head=' "$gh_log")" -eq 4 ] \
        || fail "PR fallback did not read each branch separately: $(cat "$gh_log")"
      echo 'ok - unreadable PR branch stays while readable branches are reaped'
      exit 0
      ;;
    rescue-issue-partial)
      create_rescue_ref issue- 4245 closed '2 hours' >/dev/null
      create_rescue_ref agent-issue- 4246 old '2 hours' >/dev/null
      newest_open_head="$(create_rescue_ref agent-issue- 4246 newest '1 hour')"
      unreadable_head="$(create_rescue_ref issue- 4247 unreadable '2 hours')"
      issue_rows_cache="$ROOT/issue-rows-partial"
      issue_log="$ROOT/issue-lookup-partial.log"
      : > "$issue_log"
      set +e
      partial_output="$(FAKE_GH_LOG="$issue_log" FAKE_GH_FAIL_ISSUE=4247 \
        FAKE_ISSUE_ROWS_RAW=$'4245\t2026-10-10T00:00:00Z\tclosed\n4246\t2026-10-10T00:00:00Z\topen' \
        WORKTREE_ISSUE_ROWS_CACHE="$issue_rows_cache" run_lifecycle reap "$REPO" 2>&1)"
      partial_status=$?
      set -e
      [ "$partial_status" -eq 0 ] || fail "one unreadable issue aborted readable rescue cleanup: $partial_status $partial_output"
      ! git --git-dir="$REMOTE" show-ref --verify --quiet refs/heads/rescued/issue-4245-closed \
        || fail "closed issue rescue remained after partial read: $partial_output"
      ! git --git-dir="$REMOTE" show-ref --verify --quiet refs/heads/rescued/agent-issue-4246-old \
        || fail "superseded rescue remained after partial read: $partial_output"
      [ "$(git --git-dir="$REMOTE" rev-parse refs/heads/rescued/agent-issue-4246-newest 2>/dev/null || true)" = "$newest_open_head" ] \
        || fail "readable newest open rescue was not kept: $partial_output"
      [ "$(git --git-dir="$REMOTE" rev-parse refs/heads/rescued/issue-4247-unreadable 2>/dev/null || true)" = "$unreadable_head" ] \
        || fail "unreadable issue rescue was deleted: $partial_output"
      grep -Fq 'SLOW reaped=3 skipped-unreadable=1' <<< "$partial_output" \
        || fail "partial issue read did not report SLOW counts: $partial_output"
      grep -Fq 'repos/test/repo/issues/4247' "$issue_log" \
        || fail "missing issue row did not fall back to per-issue lookup: $(cat "$issue_log")"
      [ "$(grep -cE 'issues/[0-9]+' "$issue_log")" -eq 1 ] \
        || fail "readable issue rows did not stay batched: $(cat "$issue_log")"
      [ "$(grep -c 'issues?state=all' "$issue_log")" -eq 1 ] \
        || fail "issue-state fetch did not stay page-bounded: $(cat "$issue_log")"
      grep -Fq 'per_page=100&page=1' "$issue_log" \
        && ! grep -q -- '--paginate.*issues?state=all' "$issue_log" \
        || fail "issue-state fetch carried unbounded pagination: $(cat "$issue_log")"
      echo 'ok - unreadable issue stays while readable rescue items are reaped'
      exit 0
      ;;
    rescue-issue-cache)
      create_rescue_ref issue- 4245 closed '2 hours' >/dev/null
      create_rescue_ref agent-issue- 4246 old '2 hours' >/dev/null
      open_new="$(create_rescue_ref agent-issue- 4246 newest '1 hour')"
      cache="$ROOT/issue-rows-cache" gh_log="$ROOT/issue-gh-calls"
      : > "$gh_log"
      set +e
      first_output="$(FAKE_GH_LOG="$gh_log" WORKTREE_ISSUE_ROWS_CACHE="$cache" \
        FAKE_ISSUE_ROWS_RAW=$'4245\t2026-10-10T00:00:00Z\tclosed\n4246\t2026-10-10T00:00:00Z\topen' \
        run_lifecycle reap "$REPO" 2>&1)"
      first_status=$?
      set -e
      [ "$first_status" -eq 0 ] || fail "batch issue-state fetch failed: $first_output"
      ! git --git-dir="$REMOTE" show-ref --verify --quiet refs/heads/rescued/issue-4245-closed \
        || fail "closed-issue rescue remained: $first_output"
      [ "$(git --git-dir="$REMOTE" rev-parse refs/heads/rescued/agent-issue-4246-newest 2>/dev/null || true)" = "$open_new" ] \
        || fail "newest open-issue rescue was not retained: $first_output"
      ! git --git-dir="$REMOTE" show-ref --verify --quiet refs/heads/rescued/agent-issue-4246-old \
        || fail "superseded open-issue rescue remained: $first_output"
      [ "$(grep -c 'issues?state=all' "$gh_log")" = 1 ] \
        || fail "issue states were not fetched in one batch: $(cat "$gh_log")"
      ! grep -qE 'issues/[0-9]+' "$gh_log" || fail "reaper queried issue states one at a time: $(cat "$gh_log")"
      grep -q $'^4245\t2026-10-10T00:00:00Z\tclosed$' "$cache" \
        && grep -q $'^4246\t2026-10-10T00:00:00Z\topen$' "$cache" \
        || fail "issue state cache omitted rows: $(cat "$cache")"

      : > "$gh_log"
      set +e
      second_output="$(FAKE_GH_LOG="$gh_log" WORKTREE_ISSUE_ROWS_CACHE="$cache" \
        FAKE_ISSUE_ROWS_RAW=$'4246\t2026-10-11T00:00:00Z\tclosed' \
        run_lifecycle reap "$REPO" 2>&1)"
      second_status=$?
      set -e
      [ "$second_status" -eq 0 ] || fail "incremental issue-state refresh failed: $second_output"
      ! git --git-dir="$REMOTE" show-ref --verify --quiet refs/heads/rescued/agent-issue-4246-newest \
        || fail "newest rescue remained after issue closed: $second_output"
      [ "$(grep -c 'issues?state=all' "$gh_log")" = 1 ] \
        || fail "issue cache did not refresh with one incremental query: $(cat "$gh_log")"
      ! grep -qE -- '--paginate.*issues\?state=all' "$gh_log" || fail 'issue cache refresh seeded full list again'
      grep -q $'^4246\t2026-10-11T00:00:00Z\tclosed$' "$cache" \
        && [ "$(grep -c $'^4246\t' "$cache")" = 1 ] \
        || fail "incremental issue refresh kept stale state: $(cat "$cache")"
      echo 'ok - rescue issue states batch and refresh incrementally'
      exit 0
      ;;
    main-patch-progress)
      # This case tests patch indexing, not host-wide CWD owner discovery.
      git -C "$REPO" worktree remove "$DETACHED"
      # Build a history longer than the index batch count. The fake git delay
      # makes the timeout boundary deterministic while real Git creates IDs.
      base_head="$(git -C "$REPO" rev-parse main)"
      for n in $(seq 1 65); do
        git -C "$REPO" commit --allow-empty -qm "patch-index-history-$n"
      done
      git -C "$REPO" push -qu origin main
      git -C "$REPO" fetch -q origin

      ordinary_head="$(git -C "$REPO" rev-parse main)"
      git -C "$REPO" push -qu origin "$ordinary_head:refs/heads/ordinary-clean"

      rescue_wt="$ROOT/wt-rescue-binary-squash"
      git -C "$REPO" worktree add -q -b topic/rescue-binary-squash "$rescue_wt" main
      printf 'text portion\n' >"$rescue_wt/rescue-text.txt"
      git -C "$rescue_wt" add rescue-text.txt
      git -C "$rescue_wt" commit -qm rescue-text
      printf 'binary\000payload\377\n' >"$rescue_wt/rescue-binary.bin"
      git -C "$rescue_wt" add rescue-binary.bin
      git -C "$rescue_wt" commit -qm rescue-binary
      rescue_head="$(git -C "$rescue_wt" rev-parse HEAD)"
      git -C "$REPO" push -qu origin "$rescue_head:refs/heads/rescued/squash-binary-fixture"
      git -C "$REPO" diff --binary main...topic/rescue-binary-squash \
        | git -C "$REPO" apply --binary
      git -C "$REPO" add rescue-text.txt rescue-binary.bin
      git -C "$REPO" commit -qm squash-binary-rescue
      printf 'separate main change\n' >"$REPO/unrelated-main-after-squash.txt"
      git -C "$REPO" add unrelated-main-after-squash.txt
      git -C "$REPO" commit -qm unrelated-main-after-squash
      git -C "$REPO" push -qu origin main
      git -C "$REPO" fetch -q origin
      git -C "$REPO" worktree remove "$rescue_wt"
      git -C "$REPO" branch -D topic/rescue-binary-squash >/dev/null

      WORKTREE_REAP_GIT_TIMEOUT_SECONDS=8
      patch_batch_log="$ROOT/main-patch-batches.log"
      set +e
      # Exceed the per-batch timeout so the checkpoint stays resumable on fast hosts too.
      first_output="$(ZF_WORKTREE_REAP_TIMEOUT_SECONDS=80 WORKTREE_REAP_GIT_TIMEOUT_SECONDS="$WORKTREE_REAP_GIT_TIMEOUT_SECONDS" \
        FAKE_RESCUE_PATCH_BATCH_LOG="$patch_batch_log" FAKE_PATCH_BATCH_SLEEP="$((WORKTREE_REAP_GIT_TIMEOUT_SECONDS + 2))" \
        run_lifecycle reap "$REPO" 2>&1)"
      first_status=$?
      set -e
      unset WORKTREE_REAP_GIT_TIMEOUT_SECONDS
      [ "$first_status" -eq 3 ] || fail "bounded patch index did not return resumable status: $first_status $first_output"
      [ "$(cat "$patch_batch_log" 2>/dev/null)" = 64 ] \
        || fail "main patch index did not reach the fake Git batch: $first_output"
      [[ "$first_output" == *"patch-id batch timed out or failed at 0/"*"(status=124)"* ]] \
        || fail "main patch index deferred without the forced batch timeout: $first_output"
      progress_line="$(grep '^progress=main-patch-index ' <<< "$first_output" || true)"
      [[ "$progress_line" =~ pending=([0-9a-f]{40,64})[[:space:]]cursor=([0-9]+)[[:space:]]total=([0-9]+) ]] \
        || fail "patch index did not report a numeric resumable cursor: $first_output"
      progress_pending="${BASH_REMATCH[1]}"
      progress_cursor="${BASH_REMATCH[2]}"
      progress_total="${BASH_REMATCH[3]}"
      (( progress_cursor < progress_total )) \
        || fail "patch index cursor did not stay inside pending snapshot: $first_output"
      patch_index_state="$(find "$NIGHT/worktree-reap" -mindepth 2 -maxdepth 2 -type f -name state -print -quit)"
      [ -s "$patch_index_state" ] && [ -s "${patch_index_state%/state}/commits" ] \
        || fail "patch index did not persist its pending snapshot: $first_output"
      mapfile -t patch_index_state_lines < "$patch_index_state"
      [[ "${patch_index_state_lines[2]:-}" == "$progress_pending" \
        && "${patch_index_state_lines[3]:-}" == "$progress_cursor" ]] \
        || fail "patch index state did not persist the reported pending cursor: $first_output"
      [[ "$first_output" == *"removed remote branch ordinary-clean"* ]] \
        || fail "ordinary remote candidate lacked successful lease/readback before index deferral: $first_output"
      grep -Fq $'removed-remote-branch\tordinary-clean\t' "$NIGHT/worktree-cleanup-manifest.txt" \
        || fail 'ordinary remote deletion readback was not recorded'
      ! git --git-dir="$REMOTE" show-ref --verify --quiet refs/heads/ordinary-clean \
        || fail "ordinary remote candidate was not deleted/read back before index deferral: $first_output"
      [ "$(git --git-dir="$REMOTE" rev-parse refs/heads/rescued/squash-binary-fixture 2>/dev/null || true)" = "$rescue_head" ] \
        || fail "rescue ref changed while patch index was incomplete: $first_output"
      ! find "$NIGHT/cleanup-archive" -maxdepth 1 -type f -name 'rescued-squash-binary-fixture-*.patch' -print -quit 2>/dev/null \
        | grep -q . || fail 'rescue patch was archived before the index completed'

      # Move main while the original snapshot is partial. The next run must
      # finish that snapshot and append this verified ancestor delta.
      git -C "$REPO" commit --allow-empty -qm advance-main-during-index
      git -C "$REPO" push -qu origin main
      patch_fallback_log="$ROOT/rescue-patch-fallback.log"
      resumed_output="$(ZF_WORKTREE_REAP_TIMEOUT_SECONDS=180 FAKE_RESCUE_PATCH_CHECK_LOG="$patch_fallback_log" \
        run_lifecycle reap "$REPO" 2>&1)" \
        || fail "resumed patch index failed: $resumed_output"
      [ -s "$patch_fallback_log" ] || fail 'binary/squash rescue did not exercise patch-id equivalence fallback'
      ! git --git-dir="$REMOTE" show-ref --verify --quiet refs/heads/rescued/squash-binary-fixture \
        || fail "completed binary/squash-equivalent rescue remained: $resumed_output"
      find "$NIGHT/cleanup-archive" -maxdepth 1 -type f \
        -name 'rescued-squash-binary-fixture-*.patch' -print -quit | grep -q . \
        || fail "completed rescue was not archived: $resumed_output"
      [[ "$resumed_output" != *"progress=main-patch-index"* ]] \
        || fail "ancestor main advance reset or starved the patch index: $resumed_output"

      # A non-ancestor force update invalidates the completed cache and must
      # defer rescue decisions rather than reuse IDs from the old history.
      rewrite_wt="$ROOT/wt-rescue-rewrite-cache"
      git -C "$REPO" worktree add -q -b topic/rescue-rewrite-cache "$rewrite_wt" main
      printf 'only in prior main\n' >"$rewrite_wt/rewrite-cache.txt"
      git -C "$rewrite_wt" add rewrite-cache.txt
      git -C "$rewrite_wt" commit -qm rescue-rewrite-cache
      rewrite_rescue_head="$(git -C "$rewrite_wt" rev-parse HEAD)"
      git -C "$REPO" push -qu origin "$rewrite_rescue_head:refs/heads/rescued/squash-rewrite-cache"
      git -C "$REPO" diff --binary main...topic/rescue-rewrite-cache \
        | git -C "$REPO" apply --binary
      git -C "$REPO" add rewrite-cache.txt
      git -C "$REPO" commit -qm squash-rewrite-cache
      git -C "$REPO" push -qu origin main
      git -C "$REPO" fetch -q origin
      git -C "$REPO" worktree remove "$rewrite_wt"
      git -C "$REPO" branch -D topic/rescue-rewrite-cache >/dev/null
      git -C "$REPO" reset --hard "$base_head" >/dev/null
      printf 'replacement history\n' >"$REPO/replacement-history.txt"
      git -C "$REPO" add replacement-history.txt
      git -C "$REPO" commit -qm replacement-main-after-rewrite
      git -C "$REPO" push -qf origin main
      set +e
      rewrite_output="$(ZF_WORKTREE_REAP_TIMEOUT_SECONDS=85 run_lifecycle reap "$REPO" 2>&1)"
      rewrite_status=$?
      set -e
      [ "$rewrite_status" -eq 3 ] && [[ "$rewrite_output" == *"state=rewritten"* ]] \
        || fail "non-ancestor main did not invalidate and defer the cached index: $rewrite_status $rewrite_output"
      [ "$(git --git-dir="$REMOTE" rev-parse refs/heads/rescued/squash-rewrite-cache 2>/dev/null || true)" = "$rewrite_rescue_head" ] \
        || fail "rescue ref was deleted using an index from rewritten main: $rewrite_output"
      ! find "$NIGHT/cleanup-archive" -maxdepth 1 -type f -name 'rescued-squash-rewrite-cache-*.patch' -print -quit 2>/dev/null \
        | grep -q . || fail 'rescue patch was archived after index invalidation'
      echo 'ok - patch index resumes across main advances and keeps binary squash-rescue semantics'
      exit 0
      ;;
    locks)
      DEAD_LOCK="$ROOT/wt-dead-lock"
      git -C "$REPO" worktree add -q "$DEAD_LOCK" -b topic/dead-lock main
      dead_lock_head="$(git -C "$DEAD_LOCK" rev-parse HEAD)"
      git -C "$REPO" worktree lock --reason 'fixture:owner_pid=999999999 owner_start_ticks=1 unit=dead-fixture' "$DEAD_LOCK"
      LIVE_LOCK="$ROOT/wt-live-lock"
      git -C "$REPO" worktree add -q "$LIVE_LOCK" -b topic/live-lock main
      live_lock_ticks="$(awk '{print $22}' "/proc/$$/stat")"
      git -C "$REPO" worktree lock --reason "fixture:owner_pid=$$ owner_start_ticks=$live_lock_ticks" "$LIVE_LOCK"
      dead_lock_output="$(run_lifecycle reap "$REPO" 2>&1)"
      [ ! -e "$DEAD_LOCK" ] || fail "dead-owner locked worktree remained: $dead_lock_output"
      ! git -C "$REPO" show-ref --verify --quiet refs/heads/topic/dead-lock || fail "dead-owner locked local branch remained: $dead_lock_output"
      [ -d "$LIVE_LOCK" ] || fail "live-owner locked worktree was removed: $dead_lock_output"
      [[ "$dead_lock_output" == *"skip live worktree lock owner $LIVE_LOCK"* ]] || fail "live-owner lock was not reported live: $dead_lock_output"
      [ "$dead_lock_head" = "$(git -C "$REPO" rev-parse main)" ] || fail "dead-lock fixture was not a clean merged head"
      ;;
    lock-unit)
      ACTIVE_CHAIN="$ROOT/wt-active-chain"
      git -C "$REPO" worktree add -q "$ACTIVE_CHAIN" -b topic/active-chain main
      git -C "$REPO" worktree lock --reason 'legacy lock without owner' "$ACTIVE_CHAIN"
      active_chain_lock="$(git -C "$ACTIVE_CHAIN" rev-parse --git-path locked)"
      touch -d '2 days ago' "$active_chain_lock"
      active_chain_output="$(FAKE_ACTIVE_UNITS='sup-land-fixture.service' \
        FAKE_SYSTEMCTL_SHOW_PIDS="$$" \
        FAKE_PS_OUTPUT="$$ /usr/bin/bash engine/land-seq.sh $ACTIVE_CHAIN" \
        run_lifecycle reap "$REPO" 2>&1)"
      [ -d "$ACTIVE_CHAIN" ] || fail "active landing-unit worktree was removed: $active_chain_output"
      [[ "$active_chain_output" == *"skip live worktree $ACTIVE_CHAIN"* ]] || fail "active unit command line did not pin its worktree: $active_chain_output"
      run_lifecycle finish "$REPO" "$ACTIVE_CHAIN" >/dev/null

      DISPATCHING="$ROOT/wt-dispatching"
      git -C "$REPO" worktree add -q "$DISPATCHING" -b topic/dispatching main
      dispatching_output="$(FAKE_PS_OUTPUT="$$ /usr/bin/bash engine/night/dispatch.sh $DISPATCHING /tmp/brief" \
        run_lifecycle reap "$REPO" 2>&1)"
      [ -d "$DISPATCHING" ] || fail "live hand dispatcher worktree was removed: $dispatching_output"
      [[ "$dispatching_output" == *"skip live worktree $DISPATCHING"* ]] || fail "live hand dispatcher PID did not pin its worktree: $dispatching_output"
      run_lifecycle finish "$REPO" "$DISPATCHING" >/dev/null

      UNIT_LOCK="$ROOT/wt-unit-lock"
      git -C "$REPO" worktree add -q "$UNIT_LOCK" -b topic/unit-lock main
      git -C "$REPO" worktree lock --reason 'fixture:unit=sup-land-owner' "$UNIT_LOCK"
      unit_lock_output="$(FAKE_ACTIVE_UNIT=sup-land-owner.service FAKE_SYSTEMCTL_SHOW_PIDS="$$" \
        FAKE_PS_OUTPUT="$$ /usr/bin/true" run_lifecycle reap "$REPO" 2>&1)"
      [ -d "$UNIT_LOCK" ] || fail "active unit lock was removed: $unit_lock_output"
      [[ "$unit_lock_output" == *"skip live worktree lock owner $UNIT_LOCK"* ]] || fail "active unit lock was not reported live: $unit_lock_output"
      FAKE_ACTIVE_UNIT=sup-land-owner.service FAKE_SYSTEMCTL_SHOW_PIDS="$$" \
        FAKE_PS_OUTPUT="$$ /usr/bin/true" run_lifecycle owner-live "$REPO" "$UNIT_LOCK" \
        || fail "owner-live missed the active lock unit"

      UNKNOWN_LOCK="$ROOT/wt-unknown-lock"
      git -C "$REPO" worktree add -q "$UNKNOWN_LOCK" -b topic/unknown-lock main
      git -C "$REPO" worktree lock --reason 'legacy lock without owner' "$UNKNOWN_LOCK"
      set +e
      run_lifecycle owner-live "$REPO" "$UNKNOWN_LOCK" >/dev/null 2>&1
      unknown_lock_status=$?
      set -e
      [ "$unknown_lock_status" -eq 2 ] || fail "owner-live did not fail closed for a young legacy lock (status=$unknown_lock_status)"
      ;;
    owner-live-hand-lock)
      DEAD_HAND_LOCK="$ROOT/wt-dead-hand-owner"
      git -C "$REPO" worktree add -q "$DEAD_HAND_LOCK" -b hand/dead-owner main
      git -C "$REPO" worktree lock --reason 'hand-agent:owner_pid=999999999 owner_start_ticks=1 unit=zf-hand-dead-owner' "$DEAD_HAND_LOCK"
      watcher_pid="$$"
      set +e
      dead_hand_output="$(FAKE_ACTIVE_UNITS="zf-worktree-cleanup-$watcher_pid.service" \
        FAKE_SYSTEMCTL_SHOW_PIDS="$watcher_pid" \
        FAKE_PS_OUTPUT="$watcher_pid /usr/bin/bash $SCRIPT watch $REPO $DEAD_HAND_LOCK 999999999 1" \
        run_lifecycle owner-live "$REPO" "$DEAD_HAND_LOCK" 2>&1)"
      dead_hand_status=$?
      set -e
      [ "$dead_hand_status" -eq 1 ] || fail "owner-live treated cleanup watcher as dead hand owner's liveness (status=$dead_hand_status): $dead_hand_output"

      LIVE_HAND_LOCK="$ROOT/wt-live-hand-owner"
      git -C "$REPO" worktree add -q "$LIVE_HAND_LOCK" -b hand/live-owner main
      live_hand_ticks="$(awk '{print $22}' "/proc/$$/stat")"
      git -C "$REPO" worktree lock --reason "hand-agent:owner_pid=$$ owner_start_ticks=$live_hand_ticks unit=zf-hand-live-owner" "$LIVE_HAND_LOCK"
      run_lifecycle owner-live "$REPO" "$LIVE_HAND_LOCK" \
        || fail "owner-live missed the live owner recorded in the hand lock"

      LIVE_UNIT_LOCK="$ROOT/wt-live-hand-unit"
      git -C "$REPO" worktree add -q "$LIVE_UNIT_LOCK" -b hand/live-owner-unit main
      git -C "$REPO" worktree lock --reason 'hand-agent:owner_pid=999999999 owner_start_ticks=1 unit=zf-hand-recorded-live' "$LIVE_UNIT_LOCK"
      FAKE_ACTIVE_UNITS='zf-hand-recorded-live.service' FAKE_SYSTEMCTL_SHOW_PIDS="$$" \
        run_lifecycle owner-live "$REPO" "$LIVE_UNIT_LOCK" "$$" \
        || fail "owner-live let caller identity override the active hand unit recorded in the lock"
      ;;
    owner-live-broad-scan)
      LEGACY_LOCK="$ROOT/wt-legacy-live-scan"
      git -C "$REPO" worktree add -q "$LEGACY_LOCK" -b topic/legacy-live-scan main
      CALLER_PID="$$"
      sleep 60 &
      WATCHER_PID=$!
      git -C "$REPO" worktree lock --reason "legacy lock with watcher unit=zf-worktree-cleanup-$WATCHER_PID" "$LEGACY_LOCK"
      active_units="zf-hand-dispatch-$CALLER_PID.service
zf-worktree-cleanup-$WATCHER_PID.service"
      active_pids="$CALLER_PID
$WATCHER_PID"
      ps_rows="$CALLER_PID /usr/bin/bash engine/night/dispatch.sh $LEGACY_LOCK /tmp/brief
$WATCHER_PID /usr/bin/bash $SCRIPT watch $REPO $LEGACY_LOCK 999999999 1"
      set +e
      broad_scan_output="$(FAKE_ACTIVE_UNITS="$active_units" \
        FAKE_SYSTEMCTL_SHOW_PIDS="$active_pids" FAKE_PS_OUTPUT="$ps_rows" \
        run_lifecycle owner-live "$REPO" "$LEGACY_LOCK" "$CALLER_PID" 2>&1)"
      broad_scan_status=$?
      set -e
      [ "$broad_scan_status" -eq 2 ] || fail "owner-live counted dispatcher or cleanup watcher as an owner (status=$broad_scan_status): $broad_scan_output"
      [[ "$broad_scan_output" != *"usage:"* ]] || fail "owner-live rejected caller PID argument: $broad_scan_output"
      ;;
    cwd-owner-batch)
      cwd_target="$ROOT/cwd-owner"
      find_log="$ROOT/find.log"
      ready_fifo="$ROOT/cwd-owner-ready"
      mkdir -p "$cwd_target"
      mkfifo "$ready_fifo"
      (cd "$cwd_target" && printf 'ready\n' > "$ready_fifo" && exec tail -f /dev/null) &
      CWD_PID=$!
      IFS= read -r cwd_ready < "$ready_fifo"
      [ "$cwd_ready" = ready ] || fail "CWD fixture did not enter its worktree: $cwd_ready"
      : > "$find_log"
      FAKE_FIND_LOG="$find_log" run_lifecycle owner-live "$REPO" "$cwd_target" \
        || fail 'owner-live missed process whose cwd is inside candidate path'
      [ "$(wc -l < "$find_log")" -eq 1 ] \
        || fail "process cwd scan was not batched into one find call: $(wc -l < "$find_log")"
      echo 'ok - owner liveness batches /proc cwd lookup and still protects live cwd owners'
      exit 0
      ;;
    stale-registration)
      MISSING_LOCK="$ROOT/wt-missing-lock"
      git -C "$REPO" worktree add -q "$MISSING_LOCK" -b topic/missing-lock main
      git -C "$REPO" worktree lock --reason 'legacy lock' "$MISSING_LOCK"
      rm -rf -- "$MISSING_LOCK"
      LIVE_REGISTRATION="$ROOT/wt-live-registration"
      git -C "$REPO" worktree add -q "$LIVE_REGISTRATION" -b topic/live-registration main
      live_registration_ticks="$(awk '{print $22}' "/proc/$$/stat")"
      git -C "$REPO" worktree lock --reason "fixture:owner_pid=$$ owner_start_ticks=$live_registration_ticks" "$LIVE_REGISTRATION"
      stale_registration_output="$(run_lifecycle reap "$REPO" 2>&1)"
      ! git -C "$REPO" worktree list --porcelain | grep -Fq "worktree $MISSING_LOCK" || fail "missing locked registration remained: $stale_registration_output"
      [ -d "$LIVE_REGISTRATION" ] || fail "live locked registration was removed: $stale_registration_output"
      ;;
    reap-large-resume)
      printf 'tracked stash base\n' > "$REPO/reap-stash-base.txt"
      git -C "$REPO" add reap-stash-base.txt
      git -C "$REPO" commit -qm 'reap fixture base'
      git -C "$REPO" push -qu origin main
      git -C "$REPO" fetch -q origin
      base_head="$(git -C "$REPO" rev-parse main)"
      fixture_root="$ROOT/large-reap"
      mkdir -p "$fixture_root"
      LIVE="$fixture_root/issue-7001"
      DIRTY="$fixture_root/wt-dirty"
      OPEN="$fixture_root/wt-open"
      AMBIGUOUS="$fixture_root/wt-ambiguous"
      UNIQUE="$fixture_root/wt-unique"
      git -C "$REPO" worktree add -q -b agent/issue-7001 "$LIVE" main
      git -C "$REPO" worktree add -q -b fixture/dirty "$DIRTY" main
      printf 'linked stash content\n' >> "$DIRTY/reap-stash-base.txt"
      git -C "$DIRTY" stash push -qm 'preserve linked worktree stash'
      linked_stash_head="$(git -C "$REPO" rev-parse refs/stash)"
      printf 'uncommitted\n' > "$DIRTY/dirty.txt"
      git -C "$REPO" worktree add -q -b fixture/open "$OPEN" main
      git -C "$REPO" worktree add -q -b fixture/ambiguous "$AMBIGUOUS" main
      printf 'ambiguous unique content\n' > "$AMBIGUOUS/ambiguous.txt"
      git -C "$AMBIGUOUS" add ambiguous.txt
      git -C "$AMBIGUOUS" commit -qm 'ambiguous unique head'
      ambiguous_head="$(git -C "$AMBIGUOUS" rev-parse HEAD)"
      ambiguous_index="$(git -C "$AMBIGUOUS" rev-parse --path-format=absolute --git-path index)"
      touch -d '2 days ago' "$AMBIGUOUS/.git" "$ambiguous_index"
      git -C "$REPO" worktree add -q -b fixture/closed "$UNIQUE" main
      printf 'closed PR unique content\n' > "$UNIQUE/unique.txt"
      git -C "$UNIQUE" add unique.txt
      git -C "$UNIQUE" commit -qm 'closed PR unique head'
      unique_head="$(git -C "$UNIQUE" rev-parse HEAD)"
      for ((i=0; i<45; i++)); do
        printf -v suffix '%03d' "$i"
        safe_path="$fixture_root/wt-safe-$suffix"
        git -C "$REPO" worktree add -q -b "fixture/safe-$suffix" "$safe_path" main
        touch -d '2 days ago' "$safe_path/.git"
      done

      git -C "$REPO" push -qu origin "$ambiguous_head:refs/heads/fixture/ambiguous"
      {
        printf 'update refs/heads/fixture/open %s\n' "$base_head"
        printf 'update refs/heads/fixture/ambiguous %s\n' "$ambiguous_head"
        for ((i=0; i<30; i++)); do
          printf -v suffix '%03d' "$i"
          printf 'update refs/heads/bulk-%s %s\n' "$suffix" "$base_head"
        done
      } | git --git-dir="$REMOTE" update-ref --stdin
      PR_ROWS="$(printf 'fixture/open\t%s\tmain\topen\t\t\nfixture/closed\t%s\tmain\tclosed\t\t' "$base_head" "$unique_head")"
      initial_stats="$(run_lifecycle stats "$REPO")"
      [[ "$initial_stats" == *'stale_over_24h=46' ]] || fail "large fixture did not start above stale threshold: $initial_stats"
      status_log="$ROOT/reap-large-status.log"
      worktree_list_log="$ROOT/reap-large-worktree-list.log"
      : > "$status_log"
      : > "$worktree_list_log"
      set +e
      first_output="$(WORKTREE_REAP_MAX_PER_RUN=20 FAKE_GIT_STATUS_LOG="$status_log" \
        FAKE_GIT_WORKTREE_LIST_LOG="$worktree_list_log" \
        FAKE_ACTIVE_UNITS=zf-implement-7001.service FAKE_PR_ROWS="$PR_ROWS" \
        run_lifecycle reap "$REPO" 2>&1)"
      first_status=$?
      set -e
      [ "$first_status" -eq 3 ] || fail "large reaper did not checkpoint first worktree batch (status=$first_status): $first_output"
      [[ "$first_output" == *'reap progress phase=worktrees'* ]] || fail "large reaper omitted resumable progress: $first_output"
      first_status_paths="$ROOT/reap-large-first-paths"
      sort -u "$status_log" > "$first_status_paths"
      first_status_log_lines="$(wc -l < "$status_log" | tr -d '[:space:]')"
      [ -s "$first_status_paths" ] || fail 'large reaper did not inspect first batch worktrees'
      first_inventory_scans="$(wc -l < "$worktree_list_log" | tr -d '[:space:]')"
      [ "$first_inventory_scans" -le 4 ] || fail "first batch repeated full worktree inventory $first_inventory_scans times"

      set +e
      second_output="$(WORKTREE_REAP_MAX_PER_RUN=20 FAKE_GIT_STATUS_LOG="$status_log" \
        FAKE_GIT_WORKTREE_LIST_LOG="$worktree_list_log" \
        FAKE_ACTIVE_UNITS=zf-implement-7001.service FAKE_PR_ROWS="$PR_ROWS" \
        run_lifecycle reap "$REPO" 2>&1)"
      second_status=$?
      set -e
      [ "$second_status" -eq 3 ] || fail "large reaper did not checkpoint second worktree batch (status=$second_status): $second_output"
      [[ "$second_output" == *'reap resumed worktree sweep'* ]] || fail "large reaper did not resume from saved cursor: $second_output"
      tail -n +"$((first_status_log_lines + 1))" "$status_log" | while IFS= read -r checked_path; do
        ! grep -Fxq -- "$checked_path" "$first_status_paths" || fail "retry rescanned completed worktree $checked_path"
      done

      final_output=''
      final_status=0
      for ((attempt=0; attempt<8; attempt++)); do
        set +e
        final_output="$(WORKTREE_REAP_MAX_PER_RUN=20 FAKE_ACTIVE_UNITS=zf-implement-7001.service \
          FAKE_PR_ROWS="$PR_ROWS" run_lifecycle reap "$REPO" 2>&1)"
        final_status=$?
        set -e
        [ "$final_status" -ne 3 ] && break
      done
      [ "$final_status" -eq 0 ] || fail "large reaper did not finish after resumable batches (status=$final_status): $final_output"
      audit_output="$first_output"$'\n'"$second_output"$'\n'"$final_output"
      audit_count="$(grep -c '^worktree-lifecycle: reap-path type=worktree ' <<< "$audit_output")"
      [ "$audit_count" -eq 46 ] || fail "large reaper did not record every stale worktree path: $audit_count"
      [[ "$audit_output" == *"reap-path type=worktree path=$AMBIGUOUS owner=not-live dirty=no stash=shared-present pr=NONE ancestry=off-main disposition=kept recoverable=$AMBIGUOUS reason=ambiguous-unmerged head=$ambiguous_head age-over-24h=yes"* ]] \
        || fail "large reaper omitted stale ambiguous path classification: $audit_output"
      [ -d "$LIVE" ] || fail "large reaper removed live worktree: $final_output"
      [ -d "$DIRTY" ] || fail "large reaper removed dirty worktree: $final_output"
      [ "$(git -C "$REPO" rev-parse refs/stash)" = "$linked_stash_head" ] || fail 'large reaper lost linked-worktree stash ref'
      git -C "$REPO" stash show -p "$linked_stash_head" | grep -Fq 'linked stash content' || fail 'large reaper lost linked-worktree stash content'
      [ -d "$OPEN" ] || fail "large reaper removed open-PR worktree: $final_output"
      [ -d "$AMBIGUOUS" ] || fail "large reaper removed ambiguous worktree: $final_output"
      final_stats="$(run_lifecycle stats "$REPO")"
      [[ "$final_stats" == *'stale_over_24h=1' ]] || fail "large reaper did not reduce only safe stale paths: $final_stats"
      grep -Fq "$ambiguous_head" "$NIGHT/worktree-cleanup-manifest.txt" \
        || fail "large reaper did not record stale unmerged worktree retention: $final_output"
      for ((i=0; i<45; i++)); do
        printf -v suffix '%03d' "$i"
        [ ! -e "$fixture_root/wt-safe-$suffix" ] || fail "safe worktree remained after retries: $suffix; $final_output"
      done
      [ ! -e "$UNIQUE" ] || fail "closed-PR unique worktree remained: $final_output"
      [ "$(git --git-dir="$REMOTE" rev-parse refs/heads/rescued/fixture-closed 2>/dev/null || true)" = "$unique_head" ] \
        || fail "closed-PR unique commit was not rescued: $final_output"
      git --git-dir="$REMOTE" show refs/heads/rescued/fixture-closed:unique.txt | grep -Fxq 'closed PR unique content' \
        || fail 'rescued unique commit lost its file content'
      [ "$(git --git-dir="$REMOTE" rev-parse refs/heads/fixture/ambiguous)" = "$ambiguous_head" ] \
        || fail 'ambiguous unique commit ref was not preserved'
      git --git-dir="$REMOTE" show-ref --verify --quiet refs/heads/fixture/open \
        || fail 'open-PR remote branch was removed'
      [ "$(git --git-dir="$REMOTE" for-each-ref --format='%(refname)' refs/heads/bulk- | wc -l | tr -d '[:space:]')" = 0 ] \
        || fail "large reaper left safe remote refs: $final_output"
      echo 'ok - large worktree and remote-ref cleanup resumes without rescanning completed worktrees'
      exit 0
      ;;
    primary-session-worktrees)
      PRIMARY="$ROOT/primary"
      git clone -q "$REMOTE" "$PRIMARY"
      git -C "$PRIMARY" config user.name fixture
      git -C "$PRIMARY" config user.email fixture@example.invalid
      SESSION_OLD="$PRIMARY/.claude/worktrees/agent-old"
      SESSION_YOUNG="$PRIMARY/.claude/worktrees/agent-young"
      mkdir -p "$PRIMARY/.claude/worktrees"
      git -C "$PRIMARY" worktree add -q -b hand/claude-old "$SESSION_OLD" origin/main
      printf 'old session work\n' >"$SESSION_OLD/old-session.txt"
      git -C "$SESSION_OLD" add old-session.txt
      session_old_date="$(date -u -d '2 days ago' '+%Y-%m-%dT%H:%M:%SZ')"
      GIT_AUTHOR_DATE="$session_old_date" GIT_COMMITTER_DATE="$session_old_date" git -C "$SESSION_OLD" commit -qm old-session-work
      session_old_head="$(git -C "$SESSION_OLD" rev-parse HEAD)"
      git -C "$PRIMARY" worktree add -q -b hand/claude-young "$SESSION_YOUNG" origin/main
      printf 'young session work\n' >"$SESSION_YOUNG/young-session.txt"
      git -C "$SESSION_YOUNG" add young-session.txt
      session_young_date="$(date -u -d '1 hour ago' '+%Y-%m-%dT%H:%M:%SZ')"
      GIT_AUTHOR_DATE="$session_young_date" GIT_COMMITTER_DATE="$session_young_date" git -C "$SESSION_YOUNG" commit -qm young-session-work
      session_young_head="$(git -C "$SESSION_YOUNG" rev-parse HEAD)"
      session_pr_rows="$(printf 'hand/claude-old\t%s\tmain\tclosed\t\t\nhand/claude-young\t%s\tmain\tclosed\t\t' "$session_old_head" "$session_young_head")"
      session_reap_output="$(ZF_PRIMARY_REPO_DIR="$PRIMARY" FAKE_PR_ROWS="$session_pr_rows" run_lifecycle reap "$REPO" 2>&1)"
      [ ! -e "$SESSION_OLD" ] || fail "old closed session-agent worktree remained: $session_reap_output"
      [ -d "$SESSION_YOUNG" ] || fail "recent session-agent worktree was removed: $session_reap_output"
      [ "$(git --git-dir="$REMOTE" rev-parse refs/heads/rescued/hand-claude-old 2>/dev/null || true)" = "$session_old_head" ] || fail "closed session-agent head was not rescued: $session_reap_output"
      [[ "$session_reap_output" == *"skip recent session-agent worktree $SESSION_YOUNG"* ]] || fail "recent session-agent retention was not reported: $session_reap_output"
      ;;
    rescue-retention)
      open_oldest="$(create_rescue_ref agent-issue- 4245 oldest '8 hours')"
      open_middle="$(create_rescue_ref agent-issue- 4245 middle '4 hours')"
      open_newest="$(create_rescue_ref agent-issue- 4245 newest '1 hour')"
      closed_old="$(create_rescue_ref issue- 4246 old '6 hours')"
      closed_new="$(create_rescue_ref issue- 4246 new '1 hour')"
      rescue_retention_output="$(FAKE_ISSUE_STATE_4245=open FAKE_ISSUE_STATE_4246=closed run_lifecycle reap "$REPO" 2>&1)"
      [ "$(git --git-dir="$REMOTE" rev-parse refs/heads/rescued/agent-issue-4245-newest 2>/dev/null || true)" = "$open_newest" ] || fail "newest open-issue rescue was not retained: $rescue_retention_output"
      ! git --git-dir="$REMOTE" show-ref --verify --quiet refs/heads/rescued/agent-issue-4245-oldest || fail "oldest open-issue rescue remained: $rescue_retention_output"
      ! git --git-dir="$REMOTE" show-ref --verify --quiet refs/heads/rescued/agent-issue-4245-middle || fail "middle open-issue rescue remained: $rescue_retention_output"
      ! git --git-dir="$REMOTE" show-ref --verify --quiet refs/heads/rescued/issue-4246-old || fail "closed-issue rescue remained: $rescue_retention_output"
      ! git --git-dir="$REMOTE" show-ref --verify --quiet refs/heads/rescued/issue-4246-new || fail "newest closed-issue rescue remained: $rescue_retention_output"
      [ -f "$NIGHT/cleanup-archive/rescued-agent-issue-4245-oldest-${open_oldest:0:12}.patch" ] || fail "superseded open rescue was not archived before deletion"
      [ -f "$NIGHT/cleanup-archive/rescued-agent-issue-4245-middle-${open_middle:0:12}.patch" ] || fail "superseded middle rescue was not archived before deletion"
      [ -f "$NIGHT/cleanup-archive/rescued-issue-4246-old-${closed_old:0:12}.patch" ] || fail "closed rescue was not archived before deletion"
      [ -f "$NIGHT/cleanup-archive/rescued-issue-4246-new-${closed_new:0:12}.patch" ] || fail "newest closed rescue was not archived before deletion"
      ;;
    resume-checkpoint)
      pipeline_issue=4247
      repair_issue=4248
      state_dir="$ROOT/home/.zenoforge/state"
      mkdir -p "$state_dir"
      base_sha="$(git -C "$REPO" rev-parse main)"
      printf '{"attempts":2,"pipeline_system":{"enabled":true,"resume_artifact_sha":"%s","resume_artifact_attempt":1}}\n' "$base_sha" \
        > "$state_dir/$pipeline_issue.json"
      printf '{"attempts":3,"model_policy":{"repair_resume":{"head_sha":"%s"}}}\n' "$base_sha" \
        > "$state_dir/$repair_issue.json"
      PIPELINE_WT="$ROOT/wt-pipeline-resume"
      REPAIR_WT="$ROOT/wt-repair-resume"
      git -C "$REPO" worktree add -q -b "agent/issue-$pipeline_issue" "$PIPELINE_WT" main
      printf 'pipeline rescue\n' > "$PIPELINE_WT/pipeline-work.txt"
      git -C "$PIPELINE_WT" add pipeline-work.txt
      git -C "$PIPELINE_WT" commit -qm 'pipeline resume checkpoint'
      pipeline_head="$(git -C "$PIPELINE_WT" rev-parse HEAD)"
      git -C "$REPO" worktree add -q -b "agent/issue-$repair_issue" "$REPAIR_WT" main
      printf 'repair rescue\n' > "$REPAIR_WT/repair-work.txt"
      git -C "$REPAIR_WT" add repair-work.txt
      git -C "$REPAIR_WT" commit -qm 'repair resume checkpoint'
      repair_head="$(git -C "$REPAIR_WT" rev-parse HEAD)"
      resume_pr_rows="$(printf 'agent/issue-%s\t%s\tmain\tclosed\t\t\nagent/issue-%s\t%s\tmain\tclosed\t\t' \
        "$pipeline_issue" "$pipeline_head" "$repair_issue" "$repair_head")"
      resume_reap_output="$(FAKE_PR_ROWS="$resume_pr_rows" REAP_STALE_SECONDS=0 run_lifecycle reap "$REPO" 2>&1)"
      [ ! -e "$PIPELINE_WT" ] || fail "pipeline rescue worktree remained: $resume_reap_output"
      [ ! -e "$REPAIR_WT" ] || fail "repair rescue worktree remained: $resume_reap_output"
      pipeline_sha="$(jq -r '.pipeline_system.resume_artifact_sha' "$state_dir/$pipeline_issue.json")"
      pipeline_attempt="$(jq -r '.pipeline_system.resume_artifact_attempt' "$state_dir/$pipeline_issue.json")"
      repair_sha="$(jq -r '.model_policy.repair_resume.head_sha' "$state_dir/$repair_issue.json")"
      [ "$pipeline_sha" != "$base_sha" ] || fail "pipeline checkpoint kept old HEAD: $resume_reap_output"
      [ "$pipeline_attempt" = 2 ] || fail "pipeline checkpoint attempt was not aligned: $resume_reap_output"
      [ "$repair_sha" != "$base_sha" ] || fail "repair checkpoint kept old HEAD: $resume_reap_output"
      [ "$(git --git-dir="$REMOTE" rev-parse "refs/heads/rescued/agent-issue-$pipeline_issue-$pipeline_sha")" = "$pipeline_sha" ] \
        || fail "pipeline checkpoint was not saved at a reachable rescue ref: $resume_reap_output"
      [ "$(git --git-dir="$REMOTE" rev-parse "refs/heads/rescued/agent-issue-$repair_issue-$repair_sha")" = "$repair_sha" ] \
        || fail "repair checkpoint was not saved at a reachable rescue ref: $resume_reap_output"
      ;;
    hand-resume-blocked)
      HAND_WT="$ROOT/wt-hand-blocked"
      HAND_REPORT="$NIGHT/hand-2131-report.md"
      HAND_PID=999999999
      git -C "$REPO" worktree add -q "$HAND_WT" -b hand/hand-blocked main
      hand_started_at_ns="$(date +%s%N)"
      sleep 0.01
      printf 'STATUS: BLOCKED-ON spinning (watchdog stopped pid=42 after 1 tokens, 20 min without progress)\n' > "$HAND_REPORT"
      write_hand_owner "$HAND_PID" "$HAND_WT" "$HAND_REPORT" "$hand_started_at_ns"
      write_hand_roster "$HAND_PID" "$HAND_WT" "$HAND_REPORT" "$hand_started_at_ns" 1
      git -C "$REPO" worktree lock --reason "hand-agent:owner_pid=$HAND_PID owner_start_ticks=1 unit=zf-hand-test" "$HAND_WT"
      blocked_watch_output="$(run_lifecycle watch "$REPO" "$HAND_WT" "$HAND_PID" 1 2>&1)"
      [ -d "$HAND_WT" ] || fail "watch removed BLOCKED-ON hand worktree: $blocked_watch_output"
      [ ! -s "$NIGHT/agents.txt" ] || fail "watch did not drop exited hand roster row"
      [ -f "$NIGHT/.hand-owner-$HAND_PID" ] || fail "watch dropped resume metadata for BLOCKED-ON hand worktree"
      blocked_reap_output="$(run_lifecycle reap "$REPO" 2>&1)"
      [ -d "$HAND_WT" ] || fail "reaper removed BLOCKED-ON hand worktree: $blocked_reap_output"
      [[ "$blocked_reap_output" == *"resume-pending worktree $HAND_WT"* ]] || fail "reaper did not report pending hand resume: $blocked_reap_output"
      grep -Fq 'reason=resume-pending:BLOCKED-ON spinning (watchdog stopped pid=42 after 1 tokens, 20 min without progress)' "$NIGHT/worktree-cleanup-manifest.txt" \
        || fail "manifest omitted BLOCKED-ON resume reason"
      ;;
    hand-resume-no-report)
      HAND_WT="$ROOT/wt-hand-no-report"
      HAND_REPORT="$NIGHT/missing-hand-report.md"
      HAND_PID=999999999
      git -C "$REPO" worktree add -q "$HAND_WT" -b hand/hand-no-report main
      hand_started_at_ns="$(date +%s%N)"
      write_hand_owner "$HAND_PID" "$HAND_WT" "$HAND_REPORT" "$hand_started_at_ns"
      write_hand_roster "$HAND_PID" "$HAND_WT" "$HAND_REPORT" "$hand_started_at_ns" 1
      no_report_watch_output="$(run_lifecycle watch "$REPO" "$HAND_WT" "$HAND_PID" 1 2>&1)"
      [ -d "$HAND_WT" ] || fail "watch removed hand worktree with no report: $no_report_watch_output"
      no_report_reap_output="$(run_lifecycle reap "$REPO" 2>&1)"
      [ -d "$HAND_WT" ] || fail "reaper removed hand worktree with no report: $no_report_reap_output"
      grep -Fq 'reason=resume-pending:none' "$NIGHT/worktree-cleanup-manifest.txt" \
        || fail "manifest omitted missing-report resume reason"
      ;;
    hand-resume-blocked-then-followup)
      HAND_WT="$ROOT/wt-hand-blocked-followup"
      HAND_REPORT="$NIGHT/hand-blocked-followup-report.md"
      HAND_PID=999999999
      git -C "$REPO" worktree add -q "$HAND_WT" -b hand/hand-blocked-followup main
      hand_started_at_ns="$(date +%s%N)"
      sleep 0.01
      printf 'STATUS: BLOCKED-ON issue 1\nwaiting on issue 1\nSTATUS: FOLLOWUP(1)\n' > "$HAND_REPORT"
      write_hand_owner "$HAND_PID" "$HAND_WT" "$HAND_REPORT" "$hand_started_at_ns"
      write_hand_roster "$HAND_PID" "$HAND_WT" "$HAND_REPORT" "$hand_started_at_ns" 1
      run_lifecycle watch "$REPO" "$HAND_WT" "$HAND_PID" 1 >/dev/null 2>&1
      [ -d "$HAND_WT" ] || fail "watch read the last STATUS line and removed a BLOCKED-ON hand worktree"
      grep -Fq 'reason=resume-pending:BLOCKED-ON issue 1' "$NIGHT/worktree-cleanup-manifest.txt" \
        || fail "manifest did not record the first STATUS line as the resume reason"
      ;;
    hand-resume-done)
      HAND_WT="$ROOT/wt-hand-done"
      HAND_REPORT="$NIGHT/hand-done-report.md"
      HAND_PID=999999999
      git -C "$REPO" worktree add -q "$HAND_WT" -b hand/hand-done main
      hand_started_at_ns="$(date +%s%N)"
      sleep 0.01
      printf 'work complete\nSTATUS: DONE\n' > "$HAND_REPORT"
      write_hand_owner "$HAND_PID" "$HAND_WT" "$HAND_REPORT" "$hand_started_at_ns"
      write_hand_roster "$HAND_PID" "$HAND_WT" "$HAND_REPORT" "$hand_started_at_ns" 1
      FAKE_SYSTEMCTL_LOG="$ROOT/systemctl-done.log" ZF_HAND_UNIT=zf-hand-hand-done-1.scope \
        run_lifecycle watch "$REPO" "$HAND_WT" "$HAND_PID" 1 >/dev/null 2>&1
      [ ! -e "$HAND_WT" ] || fail "watch kept terminal DONE hand worktree"
      grep -qx -- '--user stop zf-hand-hand-done-1.scope' "$ROOT/systemctl-done.log" \
        || fail "watch left the exited hand agent's scope running"
      ;;
    hand-resume-expired)
      HAND_WT="$ROOT/wt-hand-expired"
      HAND_REPORT="$NIGHT/hand-expired-report.md"
      HAND_PID=999999999
      git -C "$REPO" worktree add -q "$HAND_WT" -b hand/hand-expired main
      printf 'unique hand work\n' > "$HAND_WT/unique.txt"
      git -C "$HAND_WT" add unique.txt
      git -C "$HAND_WT" commit -qm 'unique hand work'
      hand_expired_head="$(git -C "$HAND_WT" rev-parse HEAD)"
      printf 'STATUS: BLOCKED-ON issue 1\n' > "$HAND_REPORT"
      touch -d '2 days ago' "$HAND_REPORT"
      hand_started_at_ns="$(($(date -d '2 days ago' +%s) * 1000000000))"
      write_hand_owner "$HAND_PID" "$HAND_WT" "$HAND_REPORT" "$hand_started_at_ns"
      expired_pr_row="$(printf 'hand/hand-expired\t%s\tmain\tclosed\t2026-10-13T00:00:00Z\t' "$hand_expired_head")"
      expired_reap_output="$(FAKE_PR_ROWS="$expired_pr_row" run_lifecycle reap "$REPO" 2>&1)"
      [ ! -e "$HAND_WT" ] || fail "reaper kept expired hand resume worktree: $expired_reap_output"
      [ "$(git --git-dir="$REMOTE" rev-parse refs/heads/rescued/hand-hand-expired 2>/dev/null || true)" = "$hand_expired_head" ] \
        || fail "expired hand work was not rescued before removal: $expired_reap_output"
      ;;
    pr-rows-cache)
      cache="$ROOT/pr-rows-cache" gh_log="$ROOT/gh-calls"
      : > "$gh_log"
      # Seed and refresh read one bounded page at a time, cached with number and updated_at.
      FAKE_GH_LOG="$gh_log" WORKTREE_PR_ROWS_CACHE="$cache" \
        FAKE_PR_ROWS_RAW=$'7\t2026-10-01T00:00:00Z\tfixture/seed\tabc\tmain\topen\t\t\n8\t2026-10-02T00:00:00Z\tfixture/other\tdef\tmain\tclosed\t\t' \
        run_lifecycle reap "$REPO" >/dev/null 2>&1 || true
      grep -q 'per_page=100&page=1' "$gh_log" && ! grep -q -- '--paginate' "$gh_log" \
        || fail "seed did not use a bounded PR page: $(cat "$gh_log")"
      [ "$(cut -f1 "$cache" | sort | tr '\n' ' ')" = '7 8 ' ] || fail "seed cached wrong rows: $(cat "$cache")"
      : > "$gh_log"
      # Refresh: one newest-first page; PR 7's new state replaces its cached row and PR 8 is kept.
      FAKE_GH_LOG="$gh_log" WORKTREE_PR_ROWS_CACHE="$cache" \
        FAKE_PR_ROWS_RAW=$'7\t2026-10-03T00:00:00Z\tfixture/seed\tabc\tmain\tclosed\t2026-10-03T00:00:00Z\tm1' \
        run_lifecycle reap "$REPO" >/dev/null 2>&1 || true
      if grep -q -- '--paginate' "$gh_log"; then fail 'refresh refetched the full PR list'; fi
      [ "$(grep -c 'sort=updated&direction=desc&per_page=100&page=1' "$gh_log")" = 1 ] && [ "$(grep -c pulls "$gh_log")" = 1 ] \
        || fail "refresh did not fetch exactly one newest-updated page: $(cat "$gh_log")"
      grep -qxF $'7\t2026-10-03T00:00:00Z\tfixture/seed\tabc\tmain\tclosed\t2026-10-03T00:00:00Z\tm1' "$cache" \
        && [ "$(grep -c $'^7\t' "$cache")" = 1 ] && grep -q $'^8\t' "$cache" || fail "refresh merged wrong rows: $(cat "$cache")"
      : > "$gh_log"
      # A full page still newer than the cache asks for the next page, and stops at the first older row.
      FAKE_GH_LOG="$gh_log" WORKTREE_PR_ROWS_CACHE="$cache" \
        FAKE_PR_ROWS_RAW="$(for n in $(seq 100 199); do printf '%s\t2026-10-04T00:00:00Z\tfixture/p%s\th%s\tmain\topen\t\t\n' "$n" "$n" "$n"; done)" \
        FAKE_PR_ROWS_PAGE2=$'9\t2026-09-30T00:00:00Z\tfixture/old\tghi\tmain\tclosed\t\t' \
        run_lifecycle reap "$REPO" >/dev/null 2>&1 || true
      grep -q '&page=2' "$gh_log" && ! grep -q '&page=3' "$gh_log" || fail "paging did not stop after the older row: $(cat "$gh_log")"
      [ "$(grep -c . "$cache")" = 103 ] || fail "paged refresh cached $(grep -c . "$cache") rows; expected 103"
      echo 'ok - PR rows refresh incrementally from the reap cache'
      ;;
    dispatch-refused-load)
      HAND_WT="$ROOT/wt-hand-refused"
      git -C "$REPO" worktree add -q "$HAND_WT" -b hand/hand-refused main
      git -C "$REPO" worktree lock --reason 'fixture:preserve this lock' "$HAND_WT"
      printf 'brief\nReport: %s\n' "$NIGHT/hand-dispatch-report.md" > "$ROOT/hand-dispatch-brief.md"
      printf '%s\n' 'MemAvailable: 8388608 kB' > "$ROOT/hand-meminfo"
      printf '%s\n' '20.01 20.00 19.00 1/1 100' > "$ROOT/hand-loadavg"
      printf '#!/usr/bin/env bash\nprintf "9\\n"\n' > "$BIN/nproc"
      chmod +x "$BIN/nproc"
      cat > "$BIN/codex" <<'EOF'
#!/usr/bin/env bash
[[ "$*" == 'features list' ]]
EOF
      chmod +x "$BIN/codex"
      git -C "$REPO" worktree list --porcelain > "$ROOT/worktrees-before-refusal"
      set +e
      AGENT_HOME="$ROOT/home/.zenoforge" \
      ZF_NIGHT_DIR="$NIGHT/dispatch" \
      ZF_REPO_DIR="$REPO" REPO_DIR="$REPO" ZF_CODE_INTELLIGENCE_ROOT="$REPO" \
      ZF_WORKTREE_ROOT="$ROOT/wt-root" ZF_GH_REPO=test/repo \
      AGENT_DISPATCH_MEMINFO_FILE="$ROOT/hand-meminfo" \
      AGENT_DISPATCH_LOADAVG_FILE="$ROOT/hand-loadavg" REAL_JQ="$REAL_JQ" REAL_GIT="$REAL_GIT" PATH="$BIN:$PATH" \
        bash "$SCRIPT_DIR/night/dispatch.sh" "$HAND_WT" "$ROOT/hand-dispatch-brief.md" hand-refused work \
          "$NIGHT/hand-dispatch-report.md" 0 > "$ROOT/hand-dispatch-refusal.log" 2>&1
      dispatch_status=$?
      set -e
      [ "$dispatch_status" -eq 1 ] || fail "load gate did not refuse hand dispatch: $(cat "$ROOT/hand-dispatch-refusal.log")"
      grep -Fq 'refusing: 1-min load 20.01 exceeds 2x nproc (9; limit 18)' "$ROOT/hand-dispatch-refusal.log" \
        || fail "dispatch did not refuse on load gate"
      git -C "$REPO" worktree list --porcelain > "$ROOT/worktrees-after-refusal"
      cmp -s "$ROOT/worktrees-before-refusal" "$ROOT/worktrees-after-refusal" \
        || fail "refused dispatch changed worktree or lock state"
      ;;
    finish-offline)
      # Run-end cleanup must not need the network (2026-10-21/22: a fetch-first gate kept 287 trees).
      fetch_log="$ROOT/finish-offline-fetches.log"
      : > "$fetch_log"
      export FAKE_GIT_FETCH_FAILURE_MODE=always FAKE_GIT_FETCH_LOG="$fetch_log"
      TRIAGE_WT="$ROOT/wt-root/triage-77"
      git -C "$REPO" worktree add -q --detach "$TRIAGE_WT" origin/main
      run_lifecycle finish "$REPO" "$TRIAGE_WT" >/dev/null 2>&1 || fail "offline finish refused a tree at origin/main"
      [ ! -e "$TRIAGE_WT" ] || fail "offline finish kept a detached tree at origin/main"
      HAND_WT="$ROOT/wt-root/hand-78"
      git -C "$REPO" worktree add -q -b hand-78 "$HAND_WT" origin/main
      run_lifecycle finish "$REPO" "$HAND_WT" >/dev/null 2>&1 || fail "offline finish refused a pushed hand branch"
      [ ! -e "$HAND_WT" ] || fail "offline finish kept a pushed hand tree"
      ! git -C "$REPO" show-ref --verify --quiet refs/heads/hand-78 || fail "offline finish kept the pushed hand branch"
      [ ! -s "$fetch_log" ] || fail "finish fetched origin although local refs prove the heads: $(wc -l < "$fetch_log") fetches"

      # Unique commits stay, with the reason, when origin cannot be reached; nothing is force-deleted.
      UNIQUE_WT="$ROOT/wt-root/hand-79"
      git -C "$REPO" worktree add -q -b hand-79 "$UNIQUE_WT" origin/main
      printf 'only here\n' > "$UNIQUE_WT/only.txt"
      git -C "$UNIQUE_WT" add only.txt
      git -C "$UNIQUE_WT" commit -qm unique-offline
      unique_head="$(git -C "$UNIQUE_WT" rev-parse HEAD)"
      if run_lifecycle finish "$REPO" "$UNIQUE_WT" > "$ROOT/finish-offline-unique.log" 2>&1; then
        fail "offline finish removed a tree with unique commits"
      fi
      [ -d "$UNIQUE_WT" ] && [ "$(git -C "$REPO" rev-parse refs/heads/hand-79)" = "$unique_head" ] \
        || fail "offline finish lost a tree or branch with unique commits"
      grep -Fq "has commits no local origin ref holds and origin fetch failed" "$ROOT/finish-offline-unique.log" \
        || fail "kept unique tree without saying why: $(cat "$ROOT/finish-offline-unique.log")"
      grep -Fq $'kept-worktree\thand-79\t'"$unique_head"$'\tpath='"$UNIQUE_WT"';reason=unique-commits-origin-unreachable' \
        "$NIGHT/worktree-cleanup-manifest.txt" || fail "manifest omitted the unique-commit keep reason"

      # Every exit path of a runner frees its tree: a failing exit and a systemd-style stop (SIGTERM to the group).
      : > "$fetch_log"
      cat > "$ROOT/runner.sh" <<'RUNNER'
#!/usr/bin/env bash
set -euo pipefail
WT="$1" MODE="$2"
git -C "$RUNNER_REPO" worktree add -q --detach "$WT" origin/main
cleanup() { bash "$RUNNER_SCRIPT" finish "$RUNNER_REPO" "$WT" "$$" || true; }
trap cleanup EXIT
case "$MODE" in
  fail) false ;;
  stop) tail -f /dev/null & echo started > "$WT.ready"; wait ;;
esac
RUNNER
      runner_env=(env AGENT_HOME="$ROOT/home/.zenoforge" ZF_NIGHT_DIR="$NIGHT" ZF_WORKTREE_ROOT="$ROOT/wt-root"
        ZF_WORKTREE_CLEANUP_MANIFEST="$NIGHT/worktree-cleanup-manifest.txt"
        ZF_GH_REPO=test/repo REAL_JQ="$REAL_JQ" REAL_SED="$REAL_SED" REAL_GIT="$REAL_GIT" PATH="$BIN:$PATH"
        RUNNER_REPO="$REPO" RUNNER_SCRIPT="$SCRIPT")
      FAIL_WT="$ROOT/wt-root/triage-batch-run-fail"
      if "${runner_env[@]}" bash "$ROOT/runner.sh" "$FAIL_WT" fail 2>"$ROOT/runner-fail.log"; then
        fail "failing runner fixture exited 0"
      fi
      [ ! -e "$FAIL_WT" ] || fail "failed run kept its tree: $(cat "$ROOT/runner-fail.log")"
      STOP_WT="$ROOT/wt-root/advisor-run-stop"
      mkfifo "$STOP_WT.ready"
      setsid "${runner_env[@]}" bash "$ROOT/runner.sh" "$STOP_WT" stop 2>"$ROOT/runner-stop.log" &
      runner_pid=$!
      # The runner starts its blocking child before it writes the FIFO, so the group TERM always reaches that child.
      IFS= read -r -t 30 ready < "$STOP_WT.ready" || ready=""
      [ "$ready" = started ] || fail "stop runner fixture did not start: $(cat "$ROOT/runner-stop.log")"
      kill -TERM -- "-$runner_pid"
      wait "$runner_pid" || true
      # A bash child forked for `tail &` but not yet exec'd swallows the group TERM and then execs a live tail, which
      # keeps this suite's stdout pipe open after the suite ends. Follow TERM with KILL, as a systemd stop does.
      kill -KILL -- "-$runner_pid" 2>/dev/null || true
      [ ! -e "$STOP_WT" ] || fail "stopped run kept its tree: $(cat "$ROOT/runner-stop.log")"
      [ ! -s "$fetch_log" ] || fail "runner cleanup fetched origin: $(cat "$ROOT/runner-fail.log" "$ROOT/runner-stop.log")"
      echo 'ok - run-end cleanup removes pushed trees offline, keeps unique commits with a reason, and runs on failure and stop'
      ;;
    advisor-run-owner)
      # Only the invocation that made an advisor-run tree owns it; another live batch does not.
      old_invocation=0123456789abcdef0123456789abcdef
      live_invocation=fedcba9876543210fedcba9876543210
      OLD_RUN="$ROOT/wt-root/advisor-run-$old_invocation-1b2c"
      LIVE_RUN="$ROOT/wt-root/advisor-run-$live_invocation-3d4e"
      git -C "$REPO" worktree add -q --detach "$OLD_RUN" origin/main
      git -C "$REPO" worktree add -q --detach "$LIVE_RUN" origin/main
      FAKE_ACTIVE_UNIT=zf-advisor-batch.service FAKE_SYSTEMCTL_SHOW_PIDS="$live_invocation" \
        run_lifecycle finish "$REPO" "$LIVE_RUN" >/dev/null 2>&1 && fail "live invocation's advisor tree was removed"
      [ -d "$LIVE_RUN" ] || fail "live invocation's advisor tree is gone"
      FAKE_ACTIVE_UNIT=zf-advisor-batch.service FAKE_SYSTEMCTL_SHOW_PIDS="$live_invocation" \
        run_lifecycle finish "$REPO" "$OLD_RUN" >/dev/null 2>&1 || fail "an earlier invocation's advisor tree was held by the live batch"
      [ ! -e "$OLD_RUN" ] || fail "an earlier invocation's advisor tree remained"
      ;;
    release-cleanup)
      fetch_log="$ROOT/release-cleanup-fetches.log"
      : > "$fetch_log"
      export FAKE_GIT_FETCH_FAILURE_MODE=always FAKE_GIT_FETCH_LOG="$fetch_log"
      # Released implement tree and a leftover fix branch: commits on origin/main.
      IMPL_WT="$ROOT/wt-root/issue-90"
      git -C "$REPO" worktree add -q -b agent/issue-90 "$IMPL_WT" main
      printf 'fix 90\n' > "$IMPL_WT/fix90.txt"
      git -C "$IMPL_WT" add fix90.txt
      git -C "$IMPL_WT" commit -qm 'fix #90'
      git -C "$REPO" push -q origin "agent/issue-90:main"
      FAKE_GIT_FETCH_FAILURE_MODE='' git -C "$REPO" fetch -q origin
      git -C "$REPO" branch -q agent/fix-90-20261022 origin/main
      release="$(git -C "$REPO" rev-parse origin/main)"
      # Hand tree with a commit that is neither on main nor in the release: kept.
      HAND90="$ROOT/wt-root/hand-90"
      git -C "$REPO" worktree add -q -b hand-90 "$HAND90" origin/main
      printf 'unreleased\n' > "$HAND90/later.txt"
      git -C "$HAND90" add later.txt
      git -C "$HAND90" commit -qm later
      hand90_head="$(git -C "$HAND90" rev-parse HEAD)"
      # Another issue's tree is not touched.
      OTHER_WT="$ROOT/wt-root/issue-91"
      git -C "$REPO" worktree add -q -b agent/issue-91 "$OTHER_WT" origin/main
      run_lifecycle release-cleanup "$REPO" 90 "$release" > "$ROOT/release-cleanup.log" 2>&1 \
        || fail "release-cleanup failed: $(cat "$ROOT/release-cleanup.log")"
      [ ! -e "$IMPL_WT" ] || fail "released implement tree remained"
      ! git -C "$REPO" show-ref --verify --quiet refs/heads/agent/issue-90 || fail "released implement branch remained"
      ! git -C "$REPO" show-ref --verify --quiet refs/heads/agent/fix-90-20261022 || fail "released fix branch remained"
      [ -d "$HAND90" ] && [ "$(git -C "$REPO" rev-parse refs/heads/hand-90)" = "$hand90_head" ] \
        || fail "release-cleanup removed a tree with unreleased commits"
      grep -Fq "kept $HAND90; $hand90_head has commits outside origin/main and release" "$ROOT/release-cleanup.log" \
        || fail "release-cleanup did not say why it kept the hand tree: $(cat "$ROOT/release-cleanup.log")"
      [ -d "$OTHER_WT" ] || fail "release-cleanup touched another issue's tree"
      grep -Fq "release-cleanup #90 release=$release removed=2 kept=1" "$ROOT/release-cleanup.log" \
        || fail "release-cleanup summary wrong: $(cat "$ROOT/release-cleanup.log")"
      [ ! -s "$fetch_log" ] || fail "release-cleanup fetched origin"
      run_lifecycle release-cleanup "$REPO" 90 0000000000000000000000000000000000000001 >/dev/null 2>&1 \
        && fail "release-cleanup accepted an unknown release SHA"
      [ -d "$HAND90" ] || fail "unknown release SHA removed a tree"
      ;;
    backlog-sweep)
      fetch_log="$ROOT/backlog-sweep-fetches.log"
      : > "$fetch_log"
      export FAKE_GIT_FETCH_FAILURE_MODE=always FAKE_GIT_FETCH_LOG="$fetch_log"
      git -C "$REPO" worktree remove "$DETACHED"
      OLD_CLEAN="$ROOT/wt-root/triage-501"
      OLD_DIRTY="$ROOT/wt-root/hand-502"
      OLD_UNIQUE="$ROOT/wt-root/hand-503"
      YOUNG="$ROOT/wt-root/triage-504"
      git -C "$REPO" worktree add -q --detach "$OLD_CLEAN" origin/main
      git -C "$REPO" worktree add -q -b hand-502 "$OLD_DIRTY" origin/main
      printf 'draft\n' > "$OLD_DIRTY/draft.txt"
      git -C "$REPO" worktree add -q -b hand-503 "$OLD_UNIQUE" origin/main
      printf 'unique\n' > "$OLD_UNIQUE/unique.txt"
      git -C "$OLD_UNIQUE" add unique.txt
      git -C "$OLD_UNIQUE" commit -qm unique-sweep
      unique_head="$(git -C "$OLD_UNIQUE" rev-parse HEAD)"
      git -C "$REPO" worktree add -q --detach "$YOUNG" origin/main
      touch -d '3 hours ago' "$OLD_CLEAN/.git" "$OLD_DIRTY/.git" "$OLD_UNIQUE/.git"
      SCRIPT="$SCRIPT_DIR/worktree-backlog-sweep.sh" run_lifecycle "$REPO" > "$ROOT/sweep.out" 2> "$ROOT/sweep.err" \
        || fail "backlog sweep failed: $(cat "$ROOT/sweep.err")"
      [ ! -e "$OLD_CLEAN" ] || fail "sweep kept an old clean tree: $(cat "$ROOT/sweep.out")"
      grep -Fq $'removed\t'"$OLD_CLEAN"$'\tdetached' "$ROOT/sweep.out" || fail "sweep did not report the removal"
      [ -f "$OLD_DIRTY/draft.txt" ] || fail "sweep lost untracked material"
      grep -Fq $'kept\t'"$OLD_DIRTY"$'\tuncommitted or untracked files remain' "$ROOT/sweep.out" \
        || fail "sweep did not report the dirty keep: $(cat "$ROOT/sweep.out")"
      [ -d "$OLD_UNIQUE" ] && [ "$(git -C "$REPO" rev-parse refs/heads/hand-503)" = "$unique_head" ] \
        || fail "sweep removed a tree with unique commits"
      bundle="$ROOT/home/.zenoforge/archive/worktree-hand-503-${unique_head:0:12}.bundle"
      git -C "$REPO" bundle list-heads "$bundle" | grep -Fq "$unique_head refs/heads/hand-503" \
        || fail "unique commits were not archived to $bundle"
      grep -Fq $'kept\t'"$OLD_UNIQUE"$'\tunique-commits: archived to '"$bundle" "$ROOT/sweep.out" \
        || fail "sweep did not report the archive: $(cat "$ROOT/sweep.out")"
      [ -d "$YOUNG" ] || fail "sweep removed a tree younger than the age bound"
      grep -Fq 'summary' "$ROOT/sweep.out" || fail "sweep printed no summary"
      [ ! -s "$fetch_log" ] || fail "sweep fetched origin"
      ;;
    *) fail "unknown WORKTREE_LIFECYCLE_CASE: $WORKTREE_LIFECYCLE_CASE" ;;
  esac
  printf 'ok - %s\n' "$WORKTREE_LIFECYCLE_CASE"
  exit 0
fi

# Detached clean trees also leave at unit end.
run_lifecycle finish "$REPO" "$DETACHED" >/dev/null
[ ! -e "$DETACHED" ] || fail "detached clean worktree remained"

# Unit end removes a clean tree and its local branch when its head is on main.
CLEAN="$ROOT/wt-clean"
git -C "$REPO" worktree add -q "$CLEAN" -b topic/clean main
clean_head="$(git -C "$CLEAN" rev-parse HEAD)"
run_lifecycle finish "$REPO" "$CLEAN" >/dev/null
[ ! -e "$CLEAN" ] || fail "clean worktree remained"
! git -C "$REPO" show-ref --verify --quiet refs/heads/topic/clean || fail "clean local branch remained"
grep -Fq $'removed-worktree\t'"$(basename "$CLEAN")"$'\t'"$clean_head" "$NIGHT/worktree-cleanup-manifest.txt" \
  || fail "manifest omitted removed clean tree and head"

# Unpushed commits get a verified rescue ref before tree and local branch go.
UNPUSHED="$ROOT/wt-unpushed"
git -C "$REPO" worktree add -q "$UNPUSHED" -b topic/unpushed main
printf 'keep me\n' >"$UNPUSHED/material.txt"
git -C "$UNPUSHED" add material.txt
git -C "$UNPUSHED" commit -qm unique
unique_head="$(git -C "$UNPUSHED" rev-parse HEAD)"
run_lifecycle finish "$REPO" "$UNPUSHED" >/dev/null
[ ! -e "$UNPUSHED" ] || fail "rescued worktree remained"
! git -C "$REPO" show-ref --verify --quiet refs/heads/topic/unpushed || fail "rescued local branch remained"
rescue_ref="$(git --git-dir="$REMOTE" for-each-ref --format='%(refname)' refs/heads/rescued | head -1)"
[ -n "$rescue_ref" ] || fail "unique work has no rescue ref"
[ "$(git --git-dir="$REMOTE" rev-parse "$rescue_ref")" = "$unique_head" ] || fail "rescue ref does not point at unique head"
grep -Fq $'rescued\ttopic/unpushed\t'"$unique_head" "$NIGHT/worktree-cleanup-manifest.txt" \
  || fail "manifest omitted rescue ref and head"

# Pipeline issue branches use a full-SHA rescue ref the next attempt can resolve exactly.
ISSUE_RESCUE="$ROOT/wt-issue-rescue"
git -C "$REPO" worktree add -q "$ISSUE_RESCUE" -b agent/issue-2011 main
printf 'issue work\n' >"$ISSUE_RESCUE/issue-note.txt"
git -C "$ISSUE_RESCUE" add issue-note.txt
git -C "$ISSUE_RESCUE" commit -qm issue-rescue
issue_rescue_head="$(git -C "$ISSUE_RESCUE" rev-parse HEAD)"
run_lifecycle finish "$REPO" "$ISSUE_RESCUE" >/dev/null
[ ! -e "$ISSUE_RESCUE" ] || fail "issue rescue worktree remained"
issue_rescue_ref="refs/heads/rescued/agent-issue-2011-$issue_rescue_head"
[ "$(git --git-dir="$REMOTE" rev-parse "$issue_rescue_ref")" = "$issue_rescue_head" ] \
  || fail "issue rescue ref did not preserve full SHA"

# A conflicting exact ref must keep the issue worktree and original commit intact.
ISSUE_RESCUE_CONFLICT="$ROOT/wt-issue-rescue-conflict"
git -C "$REPO" worktree add -q "$ISSUE_RESCUE_CONFLICT" -b agent/issue-2012 main
printf 'conflict work\n' >"$ISSUE_RESCUE_CONFLICT/conflict-note.txt"
git -C "$ISSUE_RESCUE_CONFLICT" add conflict-note.txt
git -C "$ISSUE_RESCUE_CONFLICT" commit -qm issue-rescue-conflict
issue_conflict_head="$(git -C "$ISSUE_RESCUE_CONFLICT" rev-parse HEAD)"
issue_conflict_ref="refs/heads/rescued/agent-issue-2012-$issue_conflict_head"
issue_conflict_old_head="$(git -C "$REPO" rev-parse main)"
git -C "$REPO" push -qu origin "$issue_conflict_old_head:$issue_conflict_ref"
set +e
issue_conflict_output="$(run_lifecycle finish "$REPO" "$ISSUE_RESCUE_CONFLICT" 2>&1)"
issue_conflict_status=$?
set -e
[ "$issue_conflict_status" -ne 0 ] || fail "conflicting issue rescue ref was accepted"
[ -d "$ISSUE_RESCUE_CONFLICT" ] || fail "conflicting issue rescue removed its worktree"
git -C "$REPO" show-ref --verify --quiet refs/heads/agent/issue-2012 \
  || fail "conflicting issue rescue removed its local branch"
[ "$(git --git-dir="$REMOTE" rev-parse "$issue_conflict_ref")" = "$issue_conflict_old_head" ] \
  || fail "conflicting issue rescue overwrote the existing remote ref"
[[ "$issue_conflict_output" == *"issue rescue ref already points elsewhere"* ]] \
  || fail "conflicting issue rescue did not report the collision"
grep -Fq $'kept-unrescued\tagent/issue-2012\t'"$issue_conflict_head"$'\trescue-ref-head-mismatch:'"$issue_conflict_ref" "$NIGHT/worktree-cleanup-manifest.txt" \
  || fail "manifest omitted conflicting issue rescue evidence"

# Dirty work stays intact and keeps its branch.
DIRTY="$ROOT/wt-dirty"
git -C "$REPO" worktree add -q "$DIRTY" -b topic/dirty main
printf 'untracked material\n' >"$DIRTY/untracked.txt"
set +e
run_lifecycle finish "$REPO" "$DIRTY" >/dev/null 2>&1
dirty_status=$?
set -e
[ "$dirty_status" -ne 0 ] || fail "dirty worktree unexpectedly finished"
[ -f "$DIRTY/untracked.txt" ] || fail "untracked material was lost"
git -C "$REPO" show-ref --verify --quiet refs/heads/topic/dirty || fail "dirty branch was deleted"
dirty_head="$(git -C "$DIRTY" rev-parse HEAD)"
grep -Fq $'kept-worktree\twt-dirty\t'"$dirty_head"$'\t' "$NIGHT/worktree-cleanup-manifest.txt" \
  || fail "manifest omitted dirty worktree head and keep reason"

# Reaper skips roster, active-unit, command-line and CWD evidence.
LIVE="$ROOT/wt-live"
git -C "$REPO" worktree add -q "$LIVE" -b agent/issue-777 main
printf '%s\tfixture-live\t%s\t%s\t%s\t-\t-\t-\t0\n' "$$" "$MODEL_POLICY_TEST_WORK_MODEL" "$MODEL_POLICY_TEST_WORK_EFFORT" "$LIVE" >"$NIGHT/agents.txt"
LIVE_UNIT="$ROOT/wt-live-unit"
git -C "$REPO" worktree add -q "$LIVE_UNIT" -b triage-888 main
LIVE_PROCESS="$ROOT/wt-live-process"
git -C "$REPO" worktree add -q "$LIVE_PROCESS" -b fix/hand-889 main
LIVE_CWD="$ROOT/wt-live-cwd"
git -C "$REPO" worktree add -q "$LIVE_CWD" -b fix/cwd-890 main
CWD_RELEASE="$ROOT/cwd-release"
(cd "$LIVE_CWD" && exec bash -c 'while [[ ! -e "$1" ]]; do sleep 0.05; done' _ "$CWD_RELEASE") &
CWD_PID=$!
for _ in {1..1500}; do
  [ "$(readlink -- "/proc/$CWD_PID/cwd" 2>/dev/null || true)" = "$LIVE_CWD" ] && break
  sleep 0.02
done
[ "$(readlink -- "/proc/$CWD_PID/cwd" 2>/dev/null || true)" = "$LIVE_CWD" ] || fail "CWD fixture did not enter its worktree"
reap_output="$(FAKE_ACTIVE_UNIT=zf-triage-888.service FAKE_PS_OUTPUT="   $$ /usr/bin/codex exec --cd $LIVE_PROCESS -m $MODEL_POLICY_TEST_WORK_MODEL" run_lifecycle reap "$REPO" 2>&1)"
[[ "$reap_output" == *"skip live worktree $LIVE"* ]] || fail "reaper did not report live owner"
[[ "$reap_output" == *"skip live worktree $LIVE_UNIT"* ]] || fail "reaper did not report active pipeline unit"
[[ "$reap_output" == *"skip live worktree $LIVE_PROCESS"* ]] || fail "reaper did not report --cd process owner"
[[ "$reap_output" == *"skip live worktree $LIVE_CWD"* ]] || fail "reaper did not report live process CWD"
[ -d "$LIVE" ] || fail "reaper removed live worktree"
[ -d "$LIVE_UNIT" ] || fail "reaper removed active unit worktree"
[ -d "$LIVE_PROCESS" ] || fail "reaper removed live --cd process worktree"
[ -d "$LIVE_CWD" ] || fail "reaper removed live CWD worktree"
git -C "$REPO" show-ref --verify --quiet refs/heads/agent/issue-777 || fail "reaper removed live branch"
git -C "$REPO" show-ref --verify --quiet refs/heads/triage-888 || fail "reaper removed active unit branch"

# A stage may safely close its own worktree during EXIT while preserving
# protection from another main PID in the same stage unit.
SELF_CLEAN="$ROOT/issue-990"
git -C "$REPO" worktree add -q "$SELF_CLEAN" -b agent/issue-990 main
FAKE_ACTIVE_UNIT=zf-implement-990.service FAKE_MAIN_PID="$$" \
  run_lifecycle finish "$REPO" "$SELF_CLEAN" "$$" >/dev/null
[ ! -e "$SELF_CLEAN" ] || fail "current stage unit could not close its own clean worktree"

LIVE_OTHER="$ROOT/issue-991"
git -C "$REPO" worktree add -q "$LIVE_OTHER" -b agent/issue-991 main
set +e
FAKE_ACTIVE_UNIT=zf-implement-991.service FAKE_MAIN_PID=999999 \
  run_lifecycle finish "$REPO" "$LIVE_OTHER" "$$" >/dev/null 2>&1
live_other_status=$?
set -e
[ "$live_other_status" -ne 0 ] || fail "cleanup ignored a different active unit owner"
[ -d "$LIVE_OTHER" ] || fail "cleanup removed a different active unit owner's worktree"
run_lifecycle finish "$REPO" "$LIVE_OTHER" >/dev/null

touch -d '2 days ago' "$DIRTY/.git" "$LIVE_CWD/.git"
stats="$(FAKE_ACTIVE_UNIT='' FAKE_PS_OUTPUT='' run_lifecycle stats "$REPO")"
[[ "$stats" == worktrees=7\ local_branches=7\ remote_branches=4\ stale_over_24h=1 ]] \
  || fail "unexpected inventory: $stats"
touch "$CWD_RELEASE"
wait "$CWD_PID"
CWD_PID=""

# Clean fixture trees through the same non-force end rule.
rm -f -- "$DIRTY/untracked.txt"
rm -f -- "$NIGHT/agents.txt"
kill "$CWD_PID" 2>/dev/null || true
wait "$CWD_PID" 2>/dev/null || true
CWD_PID=""
run_lifecycle finish "$REPO" "$DIRTY" >/dev/null
run_lifecycle finish "$REPO" "$LIVE" >/dev/null
run_lifecycle finish "$REPO" "$LIVE_UNIT" >/dev/null
run_lifecycle finish "$REPO" "$LIVE_PROCESS" >/dev/null
run_lifecycle finish "$REPO" "$LIVE_CWD" >/dev/null

# Unrelated standalone Git clones under WORKTREE_ROOT are outside this cleanup owner.
UNRELATED_CLONE="$ROOT/wt-root/clone-unrelated"
git clone -q "$REMOTE" "$UNRELATED_CLONE"
unrelated_output="$(run_lifecycle reap "$REPO" 2>&1)"
[[ "$unrelated_output" != *"removed clone $UNRELATED_CLONE"* ]] || fail "reaper removed unrelated clone"
[ -d "$UNRELATED_CLONE" ] || fail "reaper removed unrelated clone"

# Merged squash PRs use one preloaded PR snapshot; batched deletion preserves any refused head.
SQUASHED="$ROOT/wt-squashed"
git -C "$REPO" worktree add -q "$SQUASHED" -b agent/issue-901 main
git -C "$SQUASHED" commit --allow-empty -qm unique-squashed-head
squashed_head="$(git -C "$SQUASHED" rev-parse HEAD)"
SQUASHED_REFUSED="$ROOT/wt-squashed-refused"
git -C "$REPO" worktree add -q "$SQUASHED_REFUSED" -b agent/issue-902 main
git -C "$SQUASHED_REFUSED" commit --allow-empty -qm unique-squashed-head-refused
squashed_refused_head="$(git -C "$SQUASHED_REFUSED" rev-parse HEAD)"
git -C "$REPO" push -qu origin agent/issue-901 agent/issue-902
git -C "$REPO" commit --allow-empty -qm squash-merged-pr
squash_merge="$(git -C "$REPO" rev-parse HEAD)"
git -C "$REPO" push -qu origin main
git -C "$REPO" fetch -q origin
cat >"$REMOTE/hooks/update" <<'EOF'
#!/usr/bin/env bash
[ "${1:-}" != refs/heads/agent/issue-902 ] || [ "${3:-}" != 0000000000000000000000000000000000000000 ]
EOF
chmod +x "$REMOTE/hooks/update"
squashed_rows="$(printf 'agent/issue-901\t%s\tmain\tclosed\t2026-09-24T00:00:00Z\t%s\nagent/issue-902\t%s\tmain\tclosed\t2026-09-24T00:00:00Z\t%s' \
  "$squashed_head" "$squash_merge" "$squashed_refused_head" "$squash_merge")"
FAKE_PR_ROWS="$squashed_rows" run_lifecycle reap "$REPO" >/dev/null 2>&1
[ ! -e "$SQUASHED" ] || fail "merged squash worktree remained"
[ ! -e "$SQUASHED_REFUSED" ] || fail "refused merged squash worktree remained"
! git -C "$REPO" show-ref --verify --quiet refs/heads/agent/issue-901 || fail "merged squash local branch remained"
! git -C "$REPO" show-ref --verify --quiet refs/heads/agent/issue-902 || fail "refused merged squash local branch remained"
! git --git-dir="$REMOTE" show-ref --verify --quiet refs/heads/agent/issue-901 || fail "merged squash remote branch remained"
[ "$(git --git-dir="$REMOTE" rev-parse refs/heads/agent/issue-902)" = "$squashed_refused_head" ] \
  || fail "reaper did not preserve remotely refused branch"
grep -Fq $'kept-remote-branch\tagent/issue-902\t'"$squashed_refused_head" "$NIGHT/worktree-cleanup-manifest.txt" \
  || fail "manifest omitted remotely refused branch: $(cat "$NIGHT/worktree-cleanup-manifest.txt")"

# A linked worktree's stash is repository-wide; it must not pin clean trees.
printf 'base\n' >"$REPO/stash-target.txt"
git -C "$REPO" add stash-target.txt
git -C "$REPO" commit -qm stash-base
git -C "$REPO" push -qu origin main
git -C "$REPO" fetch -q origin
STASH_SOURCE="$ROOT/wt-stash-source"
git -C "$REPO" worktree add -q "$STASH_SOURCE" -b topic/stash-source main
printf 'held by shared stash\n' >>"$STASH_SOURCE/stash-target.txt"
git -C "$STASH_SOURCE" stash push -qm shared-worktree-stash
stash_head="$(git -C "$REPO" rev-parse refs/stash)"
SHARED_STASH_CLEAN="$ROOT/wt-shared-stash-clean"
git -C "$REPO" worktree add -q "$SHARED_STASH_CLEAN" -b topic/shared-stash-clean main
shared_stash_output="$(run_lifecycle reap "$REPO" 2>&1)"
[[ "$shared_stash_output" == *"removed worktree $SHARED_STASH_CLEAN"* ]] \
  || fail "shared stash incorrectly pinned a clean worktree"
[ ! -e "$SHARED_STASH_CLEAN" ] || fail "clean worktree remained because another tree had a stash"
[ "$(git -C "$REPO" rev-parse refs/stash)" = "$stash_head" ] || fail "removing clean tree lost shared stash ref"
git -C "$REPO" stash show -p "$stash_head" | grep -Fq 'held by shared stash' \
  || fail "removing clean tree lost stashed work"

# A stale dirty tree is snapshotted before ambiguous off-main work is preserved.
STALE_DIRTY="$ROOT/wt-stale-dirty"
git -C "$REPO" worktree add -q "$STALE_DIRTY" -b topic/stale-dirty main
printf 'unsaved\n' >"$STALE_DIRTY/stale-note.txt"
git -C "$STALE_DIRTY" add stale-note.txt
touch -d '3 days ago' "$(git -C "$STALE_DIRTY" rev-parse --path-format=absolute --git-path index)"
stale_output="$(run_lifecycle reap "$REPO" 2>&1)"
[ -d "$STALE_DIRTY" ] || fail "stale ambiguous worktree was removed: $stale_output"
stale_head="$(git -C "$STALE_DIRTY" rev-parse HEAD)"
git -C "$STALE_DIRTY" show HEAD:stale-note.txt | grep -Fq unsaved \
  || fail "stale dirty material was not snapshotted before preservation: $stale_output"
[[ "$stale_output" == *"snapshotted stale dirty worktree $STALE_DIRTY at $stale_head"* \
  && "$stale_output" == *"skip ambiguous unmerged worktree $STALE_DIRTY head=$stale_head pr=NONE ancestry=off-main recoverable=$STALE_DIRTY"* ]] \
  || fail "stale ambiguous worktree preservation lacked evidence: $stale_output"
grep -Fq "$stale_head" "$NIGHT/worktree-cleanup-manifest.txt" \
  || fail "stale ambiguous worktree retention was not recorded: $stale_output"

# One scheduled reap covers both the pipeline checkout and the primary clone.
PRIMARY="$ROOT/primary"
PRIMARY_TREE="$ROOT/primary-stale"
git clone -q "$REMOTE" "$PRIMARY"
git -C "$PRIMARY" worktree add -q --detach "$PRIMARY_TREE" origin/main
dual_repo_output="$(ZF_PRIMARY_REPO_DIR="$PRIMARY" run_lifecycle reap "$REPO" 2>&1)"
[ ! -e "$PRIMARY_TREE" ] || fail "reaper ignored primary-repo worktree: $dual_repo_output"

# A live agent head pins its rescue ref, even if it is otherwise safe to reap.
LIVE_RESCUE="$ROOT/wt-live-rescue"
git -C "$REPO" worktree add -q "$LIVE_RESCUE" -b topic/live-rescue main
printf 'live material\n' >"$LIVE_RESCUE/live-note.txt"
git -C "$LIVE_RESCUE" add live-note.txt
git -C "$LIVE_RESCUE" commit -qm live-rescue
live_rescue_head="$(git -C "$LIVE_RESCUE" rev-parse HEAD)"
git -C "$REPO" push -qu origin "$live_rescue_head:refs/heads/rescued/agent-issue-4244-live"
git -C "$REPO" diff main...topic/live-rescue | git -C "$REPO" apply
git -C "$REPO" add live-note.txt
git -C "$REPO" commit -qm squash-live-rescue
git -C "$REPO" push -qu origin main
git -C "$REPO" fetch -q origin
printf '%s\tfixture-live-rescue\t%s\t%s\t%s\t-\t-\t-\t0\n' "$$" "$MODEL_POLICY_TEST_WORK_MODEL" "$MODEL_POLICY_TEST_WORK_EFFORT" "$LIVE_RESCUE" >"$NIGHT/agents.txt"
live_rescue_output="$(run_lifecycle reap "$REPO" 2>&1)"
[ "$(git --git-dir="$REMOTE" rev-parse refs/heads/rescued/agent-issue-4244-live)" = "$live_rescue_head" ] \
  || fail "reaper deleted live rescue ref: $live_rescue_output"
grep -Fq $'kept-remote-rescue\trescued/agent-issue-4244-live\t'"$live_rescue_head"$'\tlive-worktree' "$NIGHT/worktree-cleanup-manifest.txt" \
  || fail "reaper did not record live rescue pin: $live_rescue_output"
rm -f -- "$NIGHT/agents.txt"
run_lifecycle finish "$REPO" "$LIVE_RESCUE" >/dev/null

# A multi-commit rescue already squash-merged into main is patch-equivalent.
SQUASH_WORKTREE="$ROOT/wt-rescue-squash"
git -C "$REPO" worktree add -q -b topic/rescue-squash "$SQUASH_WORKTREE" main
printf 'first\n' >"$SQUASH_WORKTREE/rescue-squash.txt"
git -C "$SQUASH_WORKTREE" add rescue-squash.txt
git -C "$SQUASH_WORKTREE" commit -qm first-squash-part
printf 'second\n' >>"$SQUASH_WORKTREE/rescue-squash.txt"
git -C "$SQUASH_WORKTREE" commit -qam second-squash-part
squash_rescue_head="$(git -C "$SQUASH_WORKTREE" rev-parse HEAD)"
git -C "$REPO" push -qu origin "$squash_rescue_head:refs/heads/rescued/squash-test"
git -C "$REPO" diff main...topic/rescue-squash | git -C "$REPO" apply
git -C "$REPO" add rescue-squash.txt
git -C "$REPO" commit -qm squash-rescue-test
git -C "$REPO" push -qu origin main
git -C "$REPO" fetch -q origin
git -C "$REPO" worktree remove "$SQUASH_WORKTREE"
git -C "$REPO" branch -D topic/rescue-squash >/dev/null
rescue_sweep_output="$(run_lifecycle reap "$REPO" 2>&1)"
! git --git-dir="$REMOTE" show-ref --verify --quiet refs/heads/rescued/squash-test \
  || fail "squash-equivalent rescue ref remained: $rescue_sweep_output"
find "$NIGHT/cleanup-archive" -maxdepth 1 -type f -name 'rescued-squash-test-*.patch' -print -quit | grep -q . \
  || fail "squash-equivalent rescue patch was not archived"

# Old rescue with a closed issue expires only after its recovery patch is archived.
OLD_WORKTREE="$ROOT/wt-rescue-old-closed"
git -C "$REPO" worktree add -q -b topic/issue-4242-old "$OLD_WORKTREE" main
printf 'closed issue material\n' >"$OLD_WORKTREE/closed-issue.txt"
git -C "$OLD_WORKTREE" add closed-issue.txt
old_date="$(date -u -d '8 days ago' '+%Y-%m-%dT%H:%M:%SZ')"
GIT_AUTHOR_DATE="$old_date" GIT_COMMITTER_DATE="$old_date" git -C "$OLD_WORKTREE" commit -qm old-closed-issue
old_closed_head="$(git -C "$OLD_WORKTREE" rev-parse HEAD)"
git -C "$REPO" push -qu origin "$old_closed_head:refs/heads/rescued/issue-4242-stale"
git -C "$REPO" worktree remove "$OLD_WORKTREE"
git -C "$REPO" branch -D topic/issue-4242-old >/dev/null

# Same age without a closed issue is not enough to delete a rescue.
OLD_OPEN_WORKTREE="$ROOT/wt-rescue-old-open"
git -C "$REPO" worktree add -q -b topic/issue-4243-old "$OLD_OPEN_WORKTREE" main
printf 'open issue material\n' >"$OLD_OPEN_WORKTREE/open-issue.txt"
git -C "$OLD_OPEN_WORKTREE" add open-issue.txt
GIT_AUTHOR_DATE="$old_date" GIT_COMMITTER_DATE="$old_date" git -C "$OLD_OPEN_WORKTREE" commit -qm old-open-issue
old_open_head="$(git -C "$OLD_OPEN_WORKTREE" rev-parse HEAD)"
git -C "$REPO" push -qu origin "$old_open_head:refs/heads/rescued/issue-4243-stale"
git -C "$REPO" worktree remove "$OLD_OPEN_WORKTREE"
git -C "$REPO" branch -D topic/issue-4243-old >/dev/null
rescue_sweep_output="$(FAKE_ISSUE_STATE_4242=closed FAKE_ISSUE_STATE_4243=open run_lifecycle reap "$REPO" 2>&1)"
! git --git-dir="$REMOTE" show-ref --verify --quiet refs/heads/rescued/issue-4242-stale \
  || fail "expired closed-issue rescue remained: $rescue_sweep_output"
[ "$(git --git-dir="$REMOTE" rev-parse refs/heads/rescued/issue-4243-stale)" = "$old_open_head" ] \
  || fail "old rescue with open issue was deleted: $rescue_sweep_output"
find "$NIGHT/cleanup-archive" -maxdepth 1 -type f -name 'rescued-issue-4242-stale-*.patch' -print -quit | grep -q . \
  || fail "expired closed-issue rescue patch was not archived"

for regression_case in finish-offline advisor-run-owner release-cleanup backlog-sweep origin-fetch-retry main-patch-progress rescue-patch-archive-timeout rescue-ref-sweep-scale rescue-ref-sweep-diverse-scale rescue-ref-sweep-off-main-scale rescue-patch-equivalent rescue-patch-multi-equivalent rescue-patch-scan-timeout rescue-ref-sweep-batch remote-branch-sweep-scale rescue-query-timeout-phase rescue-issue-query-fallback-budget pr-list-partial rescue-issue-partial rescue-issue-cache locks lock-unit owner-live-hand-lock owner-live-broad-scan cwd-owner-batch stale-registration primary-session-worktrees rescue-retention resume-checkpoint \
  hand-resume-blocked hand-resume-blocked-then-followup hand-resume-no-report hand-resume-done hand-resume-expired dispatch-refused-load pr-rows-cache; do
  WORKTREE_LIFECYCLE_CASE="$regression_case" bash "$0"
done

printf 'ok - both repos reaped; live and open-issue rescues kept; squash/closed rescues archived\n'
