#!/usr/bin/env bash
# Optimistic merge gate (#4356): a PR does not wait for main HEAD's
# Postsubmit; any completed red holds ordinary merges until a later green
# verdict. The merge lock wraps only the gh pr merge API call. Two PRs merge
# back-to-back while the tip has no completed verdict. The gh calls run through
# engine/gh-shim with a fake real CLI, so the guard chain is the live
# one.
set -euo pipefail
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/." && pwd -P)/test-env.sh"

test_root="${test_env_root:?}"
trap 'rm -rf -- "$test_root"' EXIT

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
REPO="test/repo"
export REPO REPO_DIR
DRY_RUN=1
AGENT_DRY_RUN=1
export DRY_RUN AGENT_DRY_RUN

FAILED=0
assert_contains() {
  local desc="$1" haystack="$2" needle="$3"
  if [[ "$haystack" == *"$needle"* ]]; then
    printf 'ok - %s\n' "$desc"
  else
    printf 'not ok - %s (expected to find [%s])\n' "$desc" "$needle" >&2
    FAILED=1
  fi
}
assert_not_contains() {
  local desc="$1" haystack="$2" needle="$3"
  if [[ "$haystack" != *"$needle"* ]]; then
    printf 'ok - %s\n' "$desc"
  else
    printf 'not ok - %s (expected NOT to find [%s])\n' "$desc" "$needle" >&2
    FAILED=1
  fi
}
assert_eq() {
  local desc="$1" expected="$2" actual="$3"
  if [[ "$expected" == "$actual" ]]; then
    printf 'ok - %s\n' "$desc"
  else
    printf 'not ok - %s (expected [%s], got [%s])\n' "$desc" "$expected" "$actual" >&2
    FAILED=1
  fi
}

# The fake real CLI gh-shim execs. Every command records itself; the Actions
# list answers come from files the scenarios rewrite between merges.
FAKE_BIN="$test_root/fake-bin"
mkdir -p "$FAKE_BIN" "$test_root/gh-state"
cat > "$FAKE_BIN/gh" <<'GH'
#!/usr/bin/env bash
state="${FAKE_GH_STATE:?}"
printf '%s\n' "$*" >> "$state/calls.log"
# `gh api -H ... -H ... <path>` puts the path after the header flags.
api_path=""
if [ "${1:-}" = api ]; then
  for arg in "$@"; do
    case "$arg" in repos/*) api_path="$arg"; break ;; esac
  done
fi
case "${1:-} ${2:-}" in
  "pr view")
    case "$*" in
      *"--json title -q .title"*) printf 'Fixture title %s\n' "$3" ;;
      *"--json baseRefOid,headRefOid,mergeable,mergeStateStatus,updatedAt,files,isDraft"*)
        jq -cn --arg head "$FAKE_PR_HEAD" --arg base "$FAKE_PR_BASE" \
          '{baseRefOid:$base,headRefOid:$head,mergeable:"MERGEABLE",mergeStateStatus:"CLEAN",updatedAt:"2026-10-10T00:00:00Z",files:[],isDraft:false}' ;;
      *) printf '{"mergeable":"MERGEABLE","mergeStateStatus":"CLEAN"}\n' ;;
    esac
    exit 0
    ;;
  "pr checks") printf '[]\n' ;;
  "pr merge")
    if flock -n "$MERGE_LOCK_FILE" -c true; then
      printf 'merge API ran without the merge lock\n' >&2
      exit 91
    fi
    : > "$FAKE_MERGE_STATE_FILE"
    printf 'merge API observed lock\n' >> "$state/lock.log"
    exit 0
    ;;
esac
if [ "${1:-}" = api ]; then
  case "$api_path" in
    repos/*/actions/workflows/ci.yml/runs?*) cat "$state/completed-runs.json" ;;
    repos/*/actions/runs/*/jobs*) printf '{"total_count":1,"jobs":[{"name":"Postsubmit validate","conclusion":"failure"}]}\n' ;;
    repos/*/commits?sha=main*) printf '[{"sha":"%s"}]\n' "${FAKE_MAIN_HEAD:?}" ;;
    *) printf '{}\n' ;;
  esac
  exit 0
fi
exit 0
GH
chmod +x "$FAKE_BIN/gh"
export FAKE_GH_STATE="$test_root/gh-state"
export PATH="$SCRIPT_DIR/gh-shim:$FAKE_BIN:$PATH"
export ZF_GH_REAL_CLI="$FAKE_BIN/gh"

HEAD_A=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
HEAD_B=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
RED_SHA=cccccccccccccccccccccccccccccccccccccccc
export FAKE_PR_HEAD="$HEAD_A" FAKE_PR_BASE="$(printf '%040d' 1)" FAKE_MAIN_HEAD="$RED_SHA"

# No completed push verdict at all: the tip's Postsubmit runs are still
# queued. Under the pre-#4356 gate this refused with "no push-triggered
# ci.yml run found on main yet"; now it merges.
printf '{"workflow_runs":[]}\n' > "$FAKE_GH_STATE/completed-runs.json"

source "$SCRIPT_DIR/lib.sh"

issue_on_hold_live() { return 1; }

run_merge() { # <issue> <pr> <head>
  MERGE_GATE_FAILURE_KIND="" MERGE_GATE_FAILURE_REASON=""
  if merge_agent_pr "$1" "$2" "$3" 0 0 "$test_root/merge-$2.log" 2>"$test_root/merge-$2.err"; then
    printf 'ok\n'
  else
    printf 'refused:%s\n' "$MERGE_GATE_FAILURE_KIND"
  fi
}

: > "$FAKE_GH_STATE/calls.log"
OUT_A="$(FAKE_PR_HEAD="$HEAD_A" run_merge 710001 710002 "$HEAD_A")"
OUT_B="$(FAKE_PR_HEAD="$HEAD_B" run_merge 710002 710003 "$HEAD_B")"
assert_eq "first PR merges while the tip Postsubmit has no verdict yet" ok "$OUT_A"
assert_eq "second PR merges back-to-back with no serial Postsubmit wait" ok "$OUT_B"
assert_contains "first merge reached the guarded merge call" "$(cat "$test_root/merge-710002.err")" "gh pr merge 710002"
assert_contains "second merge reached the guarded merge call" "$(cat "$test_root/merge-710003.err")" "gh pr merge 710003"

# A completed red verdict with no session holds ordinary merges.
jq -cn --arg sha "$RED_SHA" '{workflow_runs:[{id:501,head_sha:$sha,head_branch:"main",event:"push",status:"completed",conclusion:"failure",created_at:"2026-10-27T10:00:00Z"}]}' \
  > "$FAKE_GH_STATE/completed-runs.json"
OUT_RED="$(FAKE_PR_HEAD="$HEAD_A" run_merge 710003 710004 "$HEAD_A")"
assert_eq "red main refuses an ordinary merge" refused:main "$OUT_RED"
assert_not_contains "red main never reaches the merge call" "$(cat "$test_root/merge-710004.err")" "gh pr merge 710004"
assert_contains "refusal names the red verdict" "$(cat "$test_root/merge-710004.log")" \
  "concluded failure"

# Naming a culprit does not release ordinary merges before the revert's
# Postsubmit goes green.
mkdir -p "$AGENT_HOME/main-red"
jq -cn --arg sha "$RED_SHA" '{red_sha:$sha,status:"revert-open",culprit:"d1d1d1d1d1d1d1d1d1d1d1d1d1d1d1d1d1d1d1d1",issue:710099,revert_pr:6001}' \
  > "$AGENT_HOME/main-red/$RED_SHA.json"
OUT_EXPLAINED="$(FAKE_PR_HEAD="$HEAD_A" run_merge 710004 710005 "$HEAD_A")"
assert_eq "named culprit keeps the ordinary merge held" refused:main "$OUT_EXPLAINED"
assert_not_contains "ordinary merge remains outside the guarded merge call" "$(cat "$test_root/merge-710005.err")" "gh pr merge 710005"
rm -f "$AGENT_HOME/main-red/$RED_SHA.json"

# A pending tip run over an older green verdict keeps the gate open (pending
# work does not erase a verdict, and no wait is imposed for it).
jq -cn --arg sha "$RED_SHA" '{workflow_runs:[{id:499,head_sha:$sha,head_branch:"main",event:"push",status:"completed",conclusion:"success",created_at:"2026-10-27T09:00:00Z"}]}' \
  > "$FAKE_GH_STATE/completed-runs.json"
OUT_GREEN="$(FAKE_PR_HEAD="$HEAD_A" run_merge 710005 710006 "$HEAD_A")"
assert_eq "latest completed green keeps the gate open without waiting" ok "$OUT_GREEN"

# Exercise the real flock placement around the shared GitHub mutation. Both
# merge-state reads can acquire the file lock; only the gh pr merge command
# observes it held, and the caller can acquire it again after the command.
DRY_RUN=0 AGENT_DRY_RUN=0
export DRY_RUN AGENT_DRY_RUN
MERGE_LOCK_FILE="$test_root/merge.lock"
MERGE_LOCK_WAIT_SECONDS=1
FAKE_MERGE_STATE_FILE="$test_root/merge-state"
LOCK_READS="$test_root/lock-reads.log"
export MERGE_LOCK_FILE MERGE_LOCK_WAIT_SECONDS FAKE_MERGE_STATE_FILE
LOCK_HEAD=eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee
LOCK_COMMIT=ffffffffffffffffffffffffffffffffffffffff
pr_merge_delivery_row() {
  if ! flock -n "$MERGE_LOCK_FILE" -c true; then
    printf 'state read ran while the lock was held\n' >> "$LOCK_READS"
    return 1
  fi
  printf 'unlocked state read\n' >> "$LOCK_READS"
  if [ -e "$FAKE_MERGE_STATE_FILE" ]; then
    printf 'MERGED\t%s\t%s\n' "$LOCK_HEAD" "$LOCK_COMMIT"
  else
    printf 'OPEN\t%s\t\n' "$LOCK_HEAD"
  fi
}
body_file="$test_root/merge-body"
printf 'fixture body\n' > "$body_file"
: > "$LOCK_READS"
: > "$FAKE_GH_STATE/lock.log"
if merge_pr_and_reconcile 710007 'fixture merge' "$body_file" "$LOCK_HEAD"; then
  LOCK_RESULT=merged
else
  LOCK_RESULT=refused
fi
assert_eq "shared merge API succeeds" merged "$LOCK_RESULT"
assert_eq "merge-state reads run outside the mutex" 2 "$(wc -l < "$LOCK_READS")"
assert_eq "only the merge API observes the mutex held" 'merge API observed lock' "$(cat "$FAKE_GH_STATE/lock.log")"
if flock -n "$MERGE_LOCK_FILE" -c true; then LOCK_RELEASED=yes; else LOCK_RELEASED=no; fi
assert_eq "merge mutex is released after the API call" yes "$LOCK_RELEASED"

if [ "$FAILED" -eq 1 ]; then
  printf 'FAILED\n' >&2
  exit 1
fi
printf 'ALL PASS\n'
