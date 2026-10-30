#!/usr/bin/env bash
set -euo pipefail
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/test-env.sh"

test_root="${test_env_root:?}"
trap 'rm -rf -- "$test_root"' EXIT

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
REPO_DIR="$(cd -- "$SCRIPT_DIR/.." && pwd -P)"
REPO="test/repo"
export REPO REPO_DIR
DRY_RUN=0
AGENT_DRY_RUN=0
source "$SCRIPT_DIR/lib.sh"

assert_eq() {
  local label="$1" expected="$2" actual="$3"
  if [[ "$expected" != "$actual" ]]; then
    printf 'not ok - %s (expected [%s], got [%s])\n' "$label" "$expected" "$actual" >&2
    exit 1
  fi
  printf 'ok - %s\n' "$label"
}

pass_checks='[]'
for check_name in "${REQUIRED_PR_CHECKS[@]}"; do
  pass_checks="$(jq -c --arg name "$check_name" '. + [{name:$name,bucket:"pass"}]' <<<"$pass_checks")"
done
pass_checks="$(jq -c '. + [{name:"Touched packages PR gate",bucket:"pass"}]' <<<"$pass_checks")"
pending_checks="$(jq -c '. + [{name:"Touched packages PR gate",bucket:"pending"}]' <<<"$pass_checks")"
failed_checks="$(jq -c 'map(if .name == "Touched packages PR gate" then .bucket = "fail" else . end)' <<<"$pass_checks")"
capacity_checks="$(jq -c 'map(if .name == "Touched packages PR gate" or .name == "Required CI gates" then .bucket = "fail" | .link = "https://github.com/test/repo/actions/runs/990410/job/990411" else . end)' <<<"$pass_checks")"

CHECKS_SCENARIO=""
MERGE_CALLS=0
MERGE_HEAD_SEEN=""
READY_CALLS=0
FIX_FORWARD_SCENARIO=off
FIX_FORWARD_RESERVE_CALLS=0
FIX_FORWARD_COMMENT=""
FIX_FORWARD_MAIN_SHA=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
FIX_FORWARD_HEAD_SHA=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
FIX_FORWARD_CURRENT_HEAD_SHA="$FIX_FORWARD_HEAD_SHA"
FIX_FORWARD_BASE_SHA="$FIX_FORWARD_MAIN_SHA"
FIX_FORWARD_CARRIED_APPROVED=1
FIX_FORWARD_MAIN_RECOVERS=0
FIX_FORWARD_MAIN_READY_CALLS=0
FIX_FORWARD_REVIEW_VERDICT=READY
FIX_FORWARD_REVIEW_HEAD="$FIX_FORWARD_HEAD_SHA"
FIX_FORWARD_RUN_JSON='{"id":990401,"status":"completed","conclusion":"failure"}'
FIX_FORWARD_JOBS_JSON='{"total_count":1,"jobs":[{"name":"Postsubmit validate","conclusion":"failure"}]}'

main_merge_clear() {
  if [[ "$FIX_FORWARD_SCENARIO" == off ]]; then return 0; fi
  if [[ "$FIX_FORWARD_MAIN_RECOVERS" == 1 ]]; then
    FIX_FORWARD_MAIN_READY_CALLS=$((FIX_FORWARD_MAIN_READY_CALLS + 1))
    [[ "$FIX_FORWARD_MAIN_READY_CALLS" -ge 2 ]] && return 0
  fi
  MAIN_MERGE_CLEAR_REASON="latest completed push-triggered run on main concluded failure"
  return 1
}
stage_unit_active() { return 1; }
pr_mergeability_is_safe() { return 0; }
issue_on_hold_live() { return 1; }
risk_class_hits_for_paths() { printf '[]\n'; }
state_read() {
  jq -cn --arg head "$FIX_FORWARD_REVIEW_HEAD" --arg verdict "$FIX_FORWARD_REVIEW_VERDICT" \
    '{expected_packages:["fixture"],run:{evidence:{review_verdict:$verdict,reviewed_head_sha:$head}}}'
}
guarded_write() {
  if [[ "${1:-}" == gh && "${2:-}" == pr && "${3:-}" == ready ]]; then
    READY_CALLS=$((READY_CALLS + 1))
  elif [[ "${1:-}" == gh && "${2:-}" == issue && "${3:-}" == comment ]]; then
    FIX_FORWARD_COMMENT="$*"
  fi
  return 0
}
guarded_pr_merge() { MERGE_CALLS=$((MERGE_CALLS + 1)); MERGE_HEAD_SEEN="${4:-}"; return 0; }
main_fix_forward_reserve() { FIX_FORWARD_RESERVE_CALLS=$((FIX_FORWARD_RESERVE_CALLS + 1)); return 0; }
main_fix_forward_carried_capacity_check() { [[ "$CHECKS_SCENARIO" == capacity-only ]]; }
main_fix_forward_carried_pr_registered() { [[ "$FIX_FORWARD_CARRIED_APPROVED" == 1 ]]; }
main_fix_forward_carried_checks_still_valid() {
  [[ "$FIX_FORWARD_SCENARIO" == carried && "$CHECKS_SCENARIO" == capacity-only && "$FIX_FORWARD_CARRIED_APPROVED" == 1 ]]
}
main_fix_forward_prepare_for_pr() {
  local base_sha="$FIX_FORWARD_BASE_SHA" jobs_json="$FIX_FORWARD_JOBS_JSON" run_json="$FIX_FORWARD_RUN_JSON" assessment
  case "$FIX_FORWARD_SCENARIO" in
    stale) base_sha=cccccccccccccccccccccccccccccccccccccccc ;;
    uncovered) jobs_json='{"total_count":1,"jobs":[{"name":"Unmapped main job","conclusion":"failure"}]}' ;;
    pending) run_json='{"id":990401,"status":"in_progress","conclusion":null}' ;;
    carried)
      [[ "$CHECKS_SCENARIO" == capacity-only && "$FIX_FORWARD_CARRIED_APPROVED" == 1 ]] || return 1
      MAIN_FIX_FORWARD_CHECKS="$capacity_checks"
      ;;
  esac
  MAIN_FIX_FORWARD_PR_JSON="$(jq -cn --arg base "$base_sha" --arg head "$FIX_FORWARD_CURRENT_HEAD_SHA" \
    '{baseRefOid:$base,headRefOid:$head,mergeable:"MERGEABLE",mergeStateStatus:"CLEAN",updatedAt:"2026-10-10T00:00:00Z",files:[],isDraft:false}')"
  [[ "$FIX_FORWARD_SCENARIO" == carried ]] || MAIN_FIX_FORWARD_CHECKS="$pass_checks"
  if [[ "$FIX_FORWARD_SCENARIO" == carried ]]; then
    assessment="$(main_fix_forward_assess "$run_json" "$jobs_json" "$FIX_FORWARD_MAIN_SHA" "$base_sha" "$capacity_checks" "" 1 1)"
    MAIN_FIX_FORWARD_REASON="$(jq -r '.reason' <<< "$assessment")"
    jq -e '.eligible == true' <<< "$assessment" >/dev/null || return 1
    MAIN_FIX_FORWARD_RUN_ID="$(jq -r '.run_id' <<< "$assessment")"
    MAIN_FIX_FORWARD_MAIN_SHA="$FIX_FORWARD_MAIN_SHA"
    return 0
  fi
  assessment="$(main_fix_forward_assess "$run_json" "$jobs_json" "$FIX_FORWARD_MAIN_SHA" \
    "$base_sha" "$pass_checks" "")"
  MAIN_FIX_FORWARD_REASON="$(jq -r '.reason' <<< "$assessment")"
  if ! jq -e '.eligible == true' <<< "$assessment" >/dev/null; then return 1; fi
  MAIN_FIX_FORWARD_RUN_ID="$(jq -r '.run_id' <<< "$assessment")"
  MAIN_FIX_FORWARD_MAIN_SHA="$FIX_FORWARD_MAIN_SHA"
  return 0
}

gh() {
  if [[ "${1:-}" == "pr" && "${2:-}" == "view" ]]; then
    case "$*" in
      *"--json title -q .title"*) printf 'Fixture title\n' ;;
      *) jq -cn --arg head "$FIX_FORWARD_CURRENT_HEAD_SHA" \
        --arg base "${FIX_FORWARD_BASE_SHA:-aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa}" \
        '{mergeable:true,mergeStateStatus:"CLEAN",updatedAt:"2026-10-10T00:00:00Z",files:[],isDraft:false,headRefOid:$head,baseRefOid:$base}' ;;
    esac
    return 0
  fi
  if [[ "${1:-}" == "pr" && "${2:-}" == "checks" ]]; then
    case "$CHECKS_SCENARIO" in
      unreadable) return 1 ;;
      empty) return 0 ;;
      pending) printf '%s\n' "$pending_checks"; return 0 ;;
      failed) printf '%s\n' "$failed_checks"; return 0 ;;
      capacity-only) printf '%s\n' "$capacity_checks"; return 0 ;;
      pass) printf '%s\n' "$pass_checks"; return 0 ;;
    esac
  fi
  printf 'unexpected fake GitHub command\n' >&2
  return 97
}

run_case() {
  local scenario="$1" expected_status="$2" expected_outcome="$3" status=0
  CHECKS_SCENARIO="$scenario"
  MERGE_CALLS=0
  READY_CALLS=0
  if merge_agent_pr 760001 760002 "$FIX_FORWARD_HEAD_SHA" 1 0 "$test_root/merge-wait.log"; then
    status=0
  else
    status=$?
  fi
  assert_eq "$scenario returns the expected admission status" "$expected_status" "$status"
  assert_eq "$scenario is classified by the shared checks gate" "$expected_outcome" "$MERGE_GATE_FAILURE_KIND"
  assert_eq "$scenario never calls the merge mutation" 0 "$MERGE_CALLS"
  assert_eq "$scenario never marks the PR ready" 0 "$READY_CALLS"
}

run_case unreadable 1 checks
assert_eq "unreadable gh output has a concrete fail-closed reason" \
  "could not re-read the PR's required checks" "$MERGE_GATE_FAILURE_REASON"

run_case empty 1 checks
assert_eq "empty successful output fails for missing required rows" \
  "the PR's required checks are fail" "$MERGE_GATE_FAILURE_REASON"

run_case pending 1 checks
assert_eq "pending check output keeps the merge closed" \
  "the PR's required checks are pending" "$MERGE_GATE_FAILURE_REASON"

run_case failed 1 checks
assert_eq "failed required check keeps the merge closed" \
  "the PR's required checks are fail" "$MERGE_GATE_FAILURE_REASON"

CHECKS_SCENARIO=pass
MERGE_CALLS=0
READY_CALLS=0
if merge_agent_pr 760001 760002 "$FIX_FORWARD_HEAD_SHA" 1 0 "$test_root/merge-wait.log"; then
  status=0
else
  status=$?
fi
if [[ "$status" -ne 0 ]]; then
  printf 'passing scenario refused: kind=%s reason=%s\n' \
    "$MERGE_GATE_FAILURE_KIND" "$MERGE_GATE_FAILURE_REASON" >&2
fi
assert_eq "passing check rows admit the merge path" 0 "$status"
assert_eq "passing checks call the guarded merge exactly once" 1 "$MERGE_CALLS"
assert_eq "passing checks mark the PR ready exactly once" 1 "$READY_CALLS"

run_review_case() {
  local scenario="$1" verdict="$2" reviewed_head="$3" current_head="$4"
  local expected_kind="$5" expected_status="$6" expected_merges="$7" status=0
  FIX_FORWARD_SCENARIO=off
  CHECKS_SCENARIO=pass
  FIX_FORWARD_REVIEW_VERDICT="$verdict"
  FIX_FORWARD_REVIEW_HEAD="$reviewed_head"
  FIX_FORWARD_CURRENT_HEAD_SHA="$current_head"
  MERGE_CALLS=0
  MERGE_HEAD_SEEN=""
  READY_CALLS=0
  if merge_agent_pr 760001 760002 "$FIX_FORWARD_HEAD_SHA" 1 0 "$test_root/review-$scenario.log"; then
    status=0
  else
    status=$?
  fi
  assert_eq "$scenario review gate status" "$expected_status" "$status"
  assert_eq "$scenario review gate classification" "$expected_kind" "$MERGE_GATE_FAILURE_KIND"
  assert_eq "$scenario guarded merge count" "$expected_merges" "$MERGE_CALLS"
  if [[ "$expected_merges" == 0 ]]; then
    assert_eq "$scenario refuses before marking PR ready" 0 "$READY_CALLS"
  else
    assert_eq "$scenario pins the current PR head through guarded merge" "$current_head" "$MERGE_HEAD_SEEN"
  fi
}

run_review_case missing "" "$FIX_FORWARD_HEAD_SHA" "$FIX_FORWARD_HEAD_SHA" review 1 0
run_review_case non-ready NOT_READY "$FIX_FORWARD_HEAD_SHA" "$FIX_FORWARD_HEAD_SHA" review 1 0
run_review_case stale READY cccccccccccccccccccccccccccccccccccccccc "$FIX_FORWARD_HEAD_SHA" review 1 0
run_review_case current-head-moved READY "$FIX_FORWARD_HEAD_SHA" cccccccccccccccccccccccccccccccccccccccc pr-state 1 0
run_review_case current-ready READY "$FIX_FORWARD_HEAD_SHA" "$FIX_FORWARD_HEAD_SHA" "" 0 1

run_fix_forward_case() {
  local scenario="$1" expected_status="$2" expected_merges="$3" status=0
  FIX_FORWARD_SCENARIO="$scenario"
  CHECKS_SCENARIO=pass
  MERGE_CALLS=0
  READY_CALLS=0
  FIX_FORWARD_RESERVE_CALLS=0
  FIX_FORWARD_COMMENT=""
  if merge_agent_pr 760001 760002 \
    "$FIX_FORWARD_HEAD_SHA" 1 0 "$test_root/fix-forward-$scenario.log"; then status=0; else status=$?; fi
  assert_eq "$scenario fix-forward returns expected status" "$expected_status" "$status"
  assert_eq "$scenario fix-forward merge calls" "$expected_merges" "$MERGE_CALLS"
  if [[ "$scenario" == red-covered ]]; then
    assert_eq "covered current-base fix-forward reserves one run" 1 "$FIX_FORWARD_RESERVE_CALLS"
    grep -Fq 'fix-forward: main red on Postsubmit validate; PR checks green on Touched packages PR gate, Required CI gates' \
      "$test_root/fix-forward-$scenario.log"
    [[ "$FIX_FORWARD_COMMENT" == *'fix-forward: main red on Postsubmit validate; PR checks green on Touched packages PR gate, Required CI gates'* ]]
  else
    assert_eq "$scenario fix-forward does not reserve main" 0 "$FIX_FORWARD_RESERVE_CALLS"
  fi
}

run_carried_case() {
  local scenario="$1" expected_status="$2" expected_kind="$3" expected_merges="$4" status=0
  FIX_FORWARD_SCENARIO=carried
  CHECKS_SCENARIO=capacity-only
  FIX_FORWARD_CARRIED_APPROVED=1
  FIX_FORWARD_MAIN_RECOVERS=0
  FIX_FORWARD_MAIN_READY_CALLS=0
  FIX_FORWARD_CURRENT_HEAD_SHA="$FIX_FORWARD_HEAD_SHA"
  FIX_FORWARD_REVIEW_VERDICT=READY
  FIX_FORWARD_REVIEW_HEAD="$FIX_FORWARD_HEAD_SHA"
    case "$scenario" in
    unregistered) FIX_FORWARD_CARRIED_APPROVED=0 ;;
    own-check-failure) CHECKS_SCENARIO=failed ;;
    missing-review) FIX_FORWARD_REVIEW_VERDICT="" ;;
    changed-head) FIX_FORWARD_CURRENT_HEAD_SHA=cccccccccccccccccccccccccccccccccccccccc ;;
    main-recovered) FIX_FORWARD_MAIN_RECOVERS=1 ;;
  esac
  MERGE_CALLS=0
  READY_CALLS=0
  FIX_FORWARD_RESERVE_CALLS=0
  FIX_FORWARD_COMMENT=""
  if merge_agent_pr 760001 760002 "$FIX_FORWARD_HEAD_SHA" 1 0 "$test_root/carried-$scenario.log"; then status=0; else status=$?; fi
  assert_eq "$scenario carried path returns expected status" "$expected_status" "$status"
  assert_eq "$scenario carried path gate classification" "$expected_kind" "$MERGE_GATE_FAILURE_KIND"
  assert_eq "$scenario never merges outside expected gate" "$expected_merges" "$MERGE_CALLS"
  if [[ "$scenario" == eligible ]]; then
    assert_eq "eligible carried path reserves one red main run" 1 "$FIX_FORWARD_RESERVE_CALLS"
    grep -Fq 'carried-hotpatch: main red on Postsubmit validate' "$test_root/carried-$scenario.log"
    [[ "$FIX_FORWARD_COMMENT" == *"source validation did not run"* ]]
  elif [[ "$scenario" == main-recovered ]]; then
    assert_eq "recovered main does not reserve a red main run" 0 "$FIX_FORWARD_RESERVE_CALLS"
    assert_eq "recovered main refuses merge despite ready-state transition" 1 "$READY_CALLS"
  else
    assert_eq "$scenario does not reserve a red main run" 0 "$FIX_FORWARD_RESERVE_CALLS"
    assert_eq "$scenario never marks PR ready" 0 "$READY_CALLS"
  fi
}

run_fix_forward_case red-covered 0 1
run_fix_forward_case stale 1 0
run_fix_forward_case uncovered 1 0
run_fix_forward_case pending 1 0
run_carried_case eligible 0 "" 1
run_carried_case unregistered 1 main 0
run_carried_case own-check-failure 1 main 0
run_carried_case missing-review 1 review 0
run_carried_case changed-head 1 pr-state 0
run_carried_case main-recovered 1 checks 0
FIX_FORWARD_SCENARIO=off
printf '%s\n' 'ok - shared merge gate refuses unreadable, empty, pending, and failed checks'
