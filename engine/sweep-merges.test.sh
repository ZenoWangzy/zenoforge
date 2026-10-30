#!/usr/bin/env bash
# Regression test for the deploy-revert sweep. It runs the real script through
# its AGENT_DRY_RUN path: a dedicated revert PR merges only after green checks,
# a matching failure marker and the exact git-revert trailer.
set -euo pipefail
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/." && pwd -P)/test-env.sh"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SWEEP_SRC="$SCRIPT_DIR/sweep-merges.sh"

FAILED=0
assert_contains() {
  local desc="$1" haystack="$2" needle="$3"
  if [[ "$haystack" == *"$needle"* ]]; then
    echo "ok - $desc"
  else
    echo "not ok - $desc (expected to find [$needle])"
    FAILED=1
  fi
}
assert_not_contains() {
  local desc="$1" haystack="$2" needle="$3"
  if [[ "$haystack" != *"$needle"* ]]; then
    echo "ok - $desc"
  else
    echo "not ok - $desc (expected NOT to find [$needle])"
    FAILED=1
  fi
}

TEST_ROOT="$(mktemp -d)"
trap 'rm -rf "$TEST_ROOT"' EXIT
mkdir -p "$TEST_ROOT/state" "$TEST_ROOT/logs" "$TEST_ROOT/bin"
: > "$TEST_ROOT/gh-mutations.log"

# `gh` is a fake PATH executable: lib.sh defines its own gh(), which would
# overwrite an exported function of the same name inside the sweep subprocess.
cat > "$TEST_ROOT/bin/gh" <<'GH'
#!/usr/bin/env bash
q_expr="" prev=""
for arg in "$@"; do
  [ "$prev" = "-q" ] && q_expr="$arg"
  prev="$arg"
done
case "${1:-} ${2:-}" in
  "pr list") echo "$FAKE_PR_LIST_JSON" | jq -r "${q_expr:-.}" ;;
  "pr checks") echo "${FAKE_REVERT_CHECKS:-$FAKE_PASSING_CHECKS}" ;;
  api\ *)
    if [[ "${2:-}" == repos/*/git/commits/* ]]; then
      printf 'This reverts commit %s.\n' "${FAKE_CULPRIT_FOR_HEAD:-$FAKE_CULPRIT}"
    else
      echo '{"workflow_runs":[{"event":"push","status":"completed","conclusion":"'"${FAKE_MAIN_COMPLETED_CONCLUSION:-success}"'","head_sha":"'"${FAKE_MAIN_HEAD_SHA:-}"'","created_at":"2026-10-27T10:00:00Z"}]}' | jq -r "${q_expr:-.}"
    fi
    ;;
  *) printf 'gh %s\n' "$*" >> "$FAKE_GH_MUTATIONS" ;;
esac
GH
chmod +x "$TEST_ROOT/bin/gh"
cat > "$TEST_ROOT/bin/systemctl" <<'EOF2'
#!/usr/bin/env bash
case " $* " in *' list-units '*) exit 0 ;; esac
exit 3
EOF2
chmod +x "$TEST_ROOT/bin/systemctl"
export PATH="$TEST_ROOT/bin:$PATH"

export AGENT_HOME="$TEST_ROOT" ZF_REPO="test/repo" AGENT_DRY_RUN=1
export MERGE_LOCK_FILE="$TEST_ROOT/merge-lock"
export MERGE_LOCK_WAIT_SECONDS=0 POLL_INTERVAL_SECONDS=0
export FAKE_GH_MUTATIONS="$TEST_ROOT/gh-mutations.log"
export FAKE_PASSING_CHECKS='[{"name":"Enforce branch delivery policy","bucket":"pass"},{"name":"Required CI gates","bucket":"pass"},{"name":"Required contract gates","bucket":"pass"},{"name":"Postsubmit validate","bucket":"skipping"}]'
export FAKE_FAILING_CHECKS='[{"name":"Enforce branch delivery policy","bucket":"pass"},{"name":"Required CI gates","bucket":"fail"},{"name":"Required contract gates","bucket":"pass"}]'

# Repository auto-merge is disabled. The sweep merges a dedicated revert PR
# only after green checks, a matching failure marker and the exact git-revert
# trailer; the dry-run must never merge it merely for existing.
FAKE_CULPRIT="$(printf '%040d' 42)"
export FAKE_CULPRIT
FAKE_PR_LIST_JSON="$(jq -cn --arg culprit "$FAKE_CULPRIT" '[{number:1999,headRefName:("agent/revert-deploy-1702-" + $culprit[0:12]),headRefOid:"0000000000000000000000000000000000000007",mergeable:"MERGEABLE",mergeStateStatus:"CLEAN",isDraft:false}]')"
export FAKE_PR_LIST_JSON
REVERT_NO_MARKER="$(bash "$SWEEP_SRC" 2>&1)"
assert_not_contains "revert PR without matching marker cannot merge" "$REVERT_NO_MARKER" "gh pr merge 1999"
printf '%s\n' "$(printf '%040d' 99)" > "$TEST_ROOT/deploy-blocked-sha"
printf '%s %s\n' "$(printf '%040d' 99)" "$FAKE_CULPRIT" > "$TEST_ROOT/deploy-blocked-sha-culprit"
FAKE_REVERT_CHECKS="$FAKE_FAILING_CHECKS" bash "$SWEEP_SRC" > "$TEST_ROOT/revert-red.log" 2>&1
assert_not_contains "red revert PR stays open" "$(cat "$TEST_ROOT/revert-red.log")" "gh pr merge 1999"
REVERT_GREEN="$(bash "$SWEEP_SRC" 2>&1)"
assert_contains "green revert PR reaches shared guarded merge" "$REVERT_GREEN" "[dry-run] gh pr merge 1999"

# A main-red bisect revert PR (`agent/revert-main-*`, session at status
# revert-open) merges through the shared path once its checks are green and
# its exact selected head matches the session, while ordinary merges remain
# held by the red main verdict.
MAIN_CULPRIT="$(printf '%040d' 7)"
MAIN_REVERT_HEAD="0000000000000000000000000000000000000008"
mkdir -p "$TEST_ROOT/main-red"
jq -cn --arg red "$(printf '%040d' 99)" --arg culprit "$MAIN_CULPRIT" \
  --arg head "$MAIN_REVERT_HEAD" \
  '{red_sha:$red, status:"revert-open", culprit:$culprit, issue:1703, revert_pr:2001, revert_head:$head}' \
  > "$TEST_ROOT/main-red/$(printf '%040d' 99).json"
FAKE_PR_LIST_JSON="$(jq -cn --arg culprit "$MAIN_CULPRIT" \
  --arg head "$MAIN_REVERT_HEAD" \
  '[{number:2001,headRefName:("agent/revert-main-1703-" + $culprit[0:12]),headRefOid:$head,mergeable:"MERGEABLE",mergeStateStatus:"CLEAN",isDraft:false}]')"
FAKE_MAIN_COMPLETED_CONCLUSION=failure
FAKE_MAIN_HEAD_SHA="$(printf '%040d' 99)"
FAKE_CULPRIT_FOR_HEAD="$MAIN_CULPRIT"
export FAKE_PR_LIST_JSON FAKE_MAIN_COMPLETED_CONCLUSION FAKE_MAIN_HEAD_SHA FAKE_CULPRIT_FOR_HEAD
MAIN_RED_REVERT_GREEN="$(bash "$SWEEP_SRC" 2>&1)"
assert_contains "matching main-red revert passes its red-main exception" \
  "$MAIN_RED_REVERT_GREEN" "[dry-run] gh pr merge 2001"
# A different PR head cannot use the session's red-main exception.
jq -cn --arg red "$(printf '%040d' 99)" --arg culprit "$MAIN_CULPRIT" \
  '{red_sha:$red, status:"revert-open", culprit:$culprit, issue:1703, revert_pr:2001, revert_head:"0000000000000000000000000000000000000009"}' \
  > "$TEST_ROOT/main-red/$(printf '%040d' 99).json"
MAIN_RED_WRONG_HEAD="$(bash "$SWEEP_SRC" 2>&1)"
assert_not_contains "main-red exception refuses a head other than the selected revert SHA" \
  "$MAIN_RED_WRONG_HEAD" "[dry-run] gh pr merge 2001"
# Without the matching session the main-red exception is unavailable and
# the revert PR waits.
rm -rf "$TEST_ROOT/main-red"
MAIN_RED_NO_SESSION="$(bash "$SWEEP_SRC" 2>&1)"
assert_not_contains "a revert PR without its session cannot pass a red main" \
  "$MAIN_RED_NO_SESSION" "gh pr merge 2001"

if [ "$FAILED" -eq 1 ]; then
  echo "FAILED"
  exit 1
fi
echo "ALL PASS"
