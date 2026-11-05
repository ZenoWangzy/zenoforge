#!/usr/bin/env bash
set -euo pipefail
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/test-env.sh"

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
PIPELINE_SRC="$SCRIPT_DIR/issue-pipeline.sh"
test_root="$(mktemp -d)"
trap 'rm -rf -- "$test_root"' EXIT
export AGENT_HOME="$test_root/agent"
mkdir -p "$AGENT_HOME/night"
source "$SCRIPT_DIR/roadmap.sh"
eval "$(sed -n '/^roadmap_parent_tree_ready_for_tick() {/,/^}/p; /^roadmap_release_placement_failure_log_once() {/,/^}/p; /^ensure_issue_roadmap_parent_for_dispatch() {/,/^}/p; /^select_release_batch() {/,/^}/p' "$PIPELINE_SRC")"

assert_eq() {
  local name="$1" expected="$2" actual="$3"
  if [[ "$actual" != "$expected" ]]; then
    printf 'not ok - %s\nexpected: %s\nactual:   %s\n' "$name" "$expected" "$actual" >&2
    exit 1
  fi
  printf 'ok - %s\n' "$name"
}

ROADMAP_ORDER_ENABLED=true
REPO=test/zenoforge
ZF_ROADMAP_TREE_CACHE_FILE="$AGENT_HOME/night/roadmap-tree.json"
export ZF_ROADMAP_TREE_CACHE_FILE
ROADMAP_TREE_READY=0
ROADMAP_TREE_JSON=""
ROADMAP_PARENT_TREE_FETCH_ATTEMPTED=0
ROADMAP_RELEASE_PLACEMENT_FAILURE_LOGGED=0
ROADMAP_TEST_FETCHES=0
ROADMAP_TEST_PLACEMENTS=0
roadmap_fetch_for_admission() {
  ROADMAP_TEST_FETCHES=$((ROADMAP_TEST_FETCHES + 1))
  echo 'GraphQL: Resource limits for this query exceeded' >&2
  return 1
}
roadmap_ensure_issue_parent() {
  ROADMAP_TEST_PLACEMENTS=$((ROADMAP_TEST_PLACEMENTS + 1))
  return 1
}
for issue in $(seq 1 93); do
  ensure_issue_roadmap_parent_for_dispatch "$issue" awaiting-release 2>/dev/null || :
done
assert_eq 'failed roadmap tree is fetched once for 93 issue placements' 1 "$ROADMAP_TEST_FETCHES"
assert_eq 'failed tree does not start 93 independent placement attempts' 0 "$ROADMAP_TEST_PLACEMENTS"

LOCAL_MAIN_SHA=0123456789abcdef0123456789abcdef01234567
REPO=test/zenoforge
REPO_DIR="$test_root/repo"
RELEASE_CAP=100
UNIT_PREFIX_TRANSIENT=zf
PIPELINE_SYSTEM_LABELS_JSON='[]'
ROADMAP_TREE_READY=0
ROADMAP_TREE_JSON=""
ROADMAP_PARENT_TREE_FETCH_ATTEMPTED=0
ROADMAP_RELEASE_PLACEMENT_FAILURE_LOGGED=0
ROADMAP_TEST_FETCHES=0
ROADMAP_TEST_PLACEMENTS=0
RELEASE_DECISIONS="$test_root/release-decisions.log"
RELEASE_DISPATCHES="$test_root/release-dispatches.log"
RELEASE_ERR="$test_root/release-errors.log"
: > "$RELEASE_DECISIONS"
: > "$RELEASE_DISPATCHES"
: > "$RELEASE_ERR"
gh() {
  [[ "$1 $2" == 'issue list' ]] || { echo "unexpected gh call: $*" >&2; return 2; }
  jq -cn '[range(5001;5094) as $n | {number:$n,labels:[]}]'
}
state_read() {
  jq -cn --argjson pr "$(( $1 + 10000 ))" \
    '{state:"awaiting-release",deploy_state:"pending",run:{outcome:"merged",evidence:{pr_number:$pr}}}'
}
git() {
  case "$*" in
    *'rev-parse origin/main'*) printf '%s\n' "$LOCAL_MAIN_SHA" ;;
    *'merge-base --is-ancestor'*) return 0 ;;
    *) echo "unexpected git call: $*" >&2; return 2 ;;
  esac
}
merged_pr_for_issue() { printf '%s\t%s\n' "$(( $1 + 10000 ))" "$LOCAL_MAIN_SHA"; }
has_label() { return 1; }
cap_slots_remaining() { printf '%s\n' "$1"; }
stage_unit_count() { printf '0\n'; }
release_batch_cadence_open() { return 0; }
deploy_is_blocked() { return 1; }
stage_unit_active() { return 1; }
stage_dispatch_allowed() { return 0; }
agent_memory_floor_allows() { return 0; }
dispatch_release_batch() { printf '%s\n' "$*" >> "$RELEASE_DISPATCHES"; return 0; }
record_release_decision() { printf '%s\n' "$*" >> "$RELEASE_DECISIONS"; }
roadmap_fetch_for_admission() {
  ROADMAP_TEST_FETCHES=$((ROADMAP_TEST_FETCHES + 1))
  echo 'GraphQL: Resource limits for this query exceeded' >&2
  return 1
}
roadmap_ensure_issue_parent() {
  ROADMAP_TEST_PLACEMENTS=$((ROADMAP_TEST_PLACEMENTS + 1))
  return 1
}
select_release_batch 2> "$RELEASE_ERR"
assert_eq 'merged issues remain in the release batch when roadmap reads exceed resources' 93 \
  "$(wc -l < "$RELEASE_DECISIONS" | tr -d '[:space:]')"
assert_eq 'placement failure does not become a roadmap-parent release skip' 0 \
  "$(grep -c 'skipped roadmap-parent' "$RELEASE_DECISIONS" || true)"
assert_eq 'release tick logs placement failure once for the cohort' 1 \
  "$(grep -c 'roadmap parent placement unavailable for release' "$RELEASE_ERR" || true)"
assert_eq 'release cohort shares one failed tree read across 93 issues' 1 "$ROADMAP_TEST_FETCHES"
assert_eq 'release cohort dispatches a merged issue' 1 "$(wc -l < "$RELEASE_DISPATCHES" | tr -d '[:space:]')"

ROADMAP_TREE_READY=0
ROADMAP_TREE_JSON=""
ROADMAP_PARENT_TREE_FETCH_ATTEMPTED=0
ROADMAP_RELEASE_PLACEMENT_FAILURE_LOGGED=0
ROADMAP_TEST_FETCHES=0
ROADMAP_TEST_PLACEMENTS=0
rm -f "$ZF_ROADMAP_TREE_CACHE_FILE"
roadmap_fetch_for_admission() {
  ROADMAP_TEST_FETCHES=$((ROADMAP_TEST_FETCHES + 1))
  printf '%s\n' '{"roots":[]}' > "$1"
  return 0
}
roadmap_ensure_issue_parent() {
  ROADMAP_TEST_PLACEMENTS=$((ROADMAP_TEST_PLACEMENTS + 1))
  return 0
}
placement_status=0
for issue in $(seq 5200 5292); do
  if ! ensure_issue_roadmap_parent_for_dispatch "$issue" awaiting-release 2>> "$test_root/placement-success.err"; then
    placement_status=1
    break
  fi
done
assert_eq 'successful tree and placement stubs allow release metadata placement' 0 "$placement_status"
assert_eq 'successful placement uses one shared tree fetch' 1 "$ROADMAP_TEST_FETCHES"
assert_eq 'successful placement calls the parent writer for all 93 issues' 93 "$ROADMAP_TEST_PLACEMENTS"
assert_eq 'successful placement emits no failure warning' 0 "$(wc -l < "$test_root/placement-success.err" | tr -d '[:space:]')"

printf '%s\n' 'roadmap-release.test.sh: PASS'
