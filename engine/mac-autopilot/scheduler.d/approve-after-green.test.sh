#!/usr/bin/env bash
set -euo pipefail
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)/test-env.sh"

d="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
mac="$d/.."
fixture="$test_env_root/approve-after-green"
sup="$fixture/supervisor"
mkdir -p "$sup/autopi/alerts" "$fixture/repo/.zenoforge/mac-autopilot"
jq '.auto_merge=true | .advisor=false | .precheck=false' "$mac/config.template.json" > "$sup/autopi/config.json"
printf '%s\n' '{"units":[]}' > "$sup/autopi/units.json"
printf '%s\n' '{"workers":[]}' > "$sup/autopi/workers.json"
printf '%s\n' '{"required":["Touched packages PR gate"],"current_regression":"","legacy_regression":[]}' > "$fixture/required-pr-checks.json"
export MAC_AUTOPILOT_ROOT="$fixture/repo" MAC_AUTOPILOT_SUPERVISOR_DIR="$sup" MAC_AUTOPILOT_RUNTIME_DIR="$sup/autopi"
export CODEX_SESSIONS_DIR="$fixture/sessions" LUNA_SLOTS="$fixture/luna-slots"
export REQUIRED_PR_CHECKS_FILE="$fixture/required-pr-checks.json" AUTOPI_TEST_LIBRARY_ONLY=true
mkdir -p "$LUNA_SLOTS"
source "$mac/scheduler.sh"
unset AUTOPI_TEST_LIBRARY_ONLY
SCHED_LOCK_HELD=true

H1=1111111111111111111111111111111111111111
RED=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
NOW_EPOCH=1793600000
STAMP=2026-11-02T22:54:48Z
GH_PARALLEL=1
CI_MAIN_RED_TESTS_CACHE=()
DISPATCHED=()
RERUNS=0
MIXED_IDENTITIES=0
MIXED_ASSERTIONS=0
MIXED_SAME_FILE_ASSERTIONS=0

failures=0
fail() { printf 'approve-after-green.test.sh: FAIL %s\n' "$1" >&2; failures=$((failures + 1)); }
field() { jqf -r --arg id "$1" ".units[] | select(.id==\$id) | $2" "$UNITS"; }
tick_prs() {
  if [[ -z "$TICK_PRS" ]]; then TICK_PRS="$(cat "$fixture/prs.json")"; fi
  printf '%s' "$TICK_PRS"
}
alive() { return 1; }
session_usage_for_id() { printf 'null\n'; }
decision_eval_stages() { printf '\n'; }
dispatch_if_room() { DISPATCHED+=("$1:$2"); return 0; }
gh() {
  if [[ "$1" == run && "$2" == list && "$3" == --commit && "$4" == "$H1" && "$*" == *'select(.conclusion=="failure")'* ]]; then
    printf '777\n'
    return 0
  fi
  if [[ "$1" == run && "$2" == rerun && "$3" == 777 && "$4" == --failed ]]; then
    RERUNS=$((RERUNS + 1))
    # GitHub's accepted rerun updates the latest candidate checks before the next scheduler pass.
    set_pr_rows COMPLETED SUCCESS "$H1"
    return 0
  fi
  case "$*" in
    'api repos/{owner}/{repo}/commits/'"$RED"'/check-runs?per_page=100')
      printf '{"check_runs":[{"name":"Postsubmit validate","conclusion":"failure"}]}\n' ;;
    'run list --commit '"$RED"' --limit 100 --json databaseId,conclusion,event,headBranch')
      printf '[{"databaseId":901,"conclusion":"failure","event":"push","headBranch":"main"}]\n' ;;
    'api repos/{owner}/{repo}/actions/runs/901/jobs?per_page=100')
      printf '{"jobs":[{"id":903,"name":"Postsubmit validate","conclusion":"failure","started_at":"2026-11-02T22:54:00Z","html_url":"https://github.com/example/repo/actions/runs/901/job/903"}]}\n' ;;
    'api --allow-escape-sequences repos/{owner}/{repo}/actions/jobs/902/logs'|\
    'api --allow-escape-sequences repos/{owner}/{repo}/actions/jobs/903/logs')
      if [[ "$MIXED_IDENTITIES" == 1 ]]; then
        printf ' FAIL  tests/shared-membership.test.ts > rejects removed membership\nnot ok 1 - another test without a file identity\n'
      elif [[ "$MIXED_SAME_FILE_ASSERTIONS" == 1 ]]; then
        printf ' FAIL  tests/shared-membership.test.ts > rejects removed membership\nAssertionError: expected false to be true\n ❯ tests/shared-membership.test.ts:14:5\nAssertionError: another test in the same file\n ❯ tests/shared-membership.test.ts:33:5\n'
      elif [[ "$MIXED_ASSERTIONS" == 1 ]]; then
        printf ' FAIL  tests/shared-membership.test.ts > rejects removed membership\nAssertionError: expected false to be true\n ❯ tests/shared-membership.test.ts:14:5\nAssertionError: another failure without a test identity\n'
      else
        printf ' FAIL  tests/shared-membership.test.ts > rejects removed membership\nAssertionError: expected false to be true\n ❯ tests/shared-membership.test.ts:14:5\n'
      fi ;;
    'api repos/{owner}/{repo}/actions/jobs/902/logs'|\
    'api repos/{owner}/{repo}/actions/jobs/903/logs')
      if [[ "$MIXED_IDENTITIES" == 1 ]]; then
        printf ' FAIL  tests/shared-membership.test.ts > rejects removed membership\nnot ok 1 - another test without a file identity\n'
      elif [[ "$MIXED_SAME_FILE_ASSERTIONS" == 1 ]]; then
        printf ' FAIL  tests/shared-membership.test.ts > rejects removed membership\nAssertionError: expected false to be true\n ❯ tests/shared-membership.test.ts:14:5\nAssertionError: another test in the same file\n ❯ tests/shared-membership.test.ts:33:5\n'
      elif [[ "$MIXED_ASSERTIONS" == 1 ]]; then
        printf ' FAIL  tests/shared-membership.test.ts > rejects removed membership\nAssertionError: expected false to be true\n ❯ tests/shared-membership.test.ts:14:5\nAssertionError: another failure without a test identity\n'
      else
        printf ' FAIL  tests/shared-membership.test.ts > rejects removed membership\nAssertionError: expected false to be true\n ❯ tests/shared-membership.test.ts:14:5\n'
      fi ;;
    'api repos/{owner}/{repo}/statuses/'*) return 0 ;;
    'api repos/{owner}/{repo}/commits/'*'/status') printf '0\n' ;;
    *) return 0 ;;
  esac
}

pr_rows() { # status conclusion head
  jqf -cn --arg head "$3" --arg status "$1" --arg conclusion "$2" '[{
    number:4994,headRefOid:$head,headRefName:"agent/issue-3237",baseRefName:"main",isDraft:true,
    statusCheckRollup:[{__typename:"CheckRun",name:"Touched packages PR gate",status:$status,
      conclusion:(if $conclusion=="" then null else $conclusion end),startedAt:"2026-11-02T22:55:00Z",
      detailsUrl:"https://github.com/example/repo/actions/runs/900/job/902?check_suite_focus=true"}]
  }]'
}
set_pr_rows() {
  pr_rows "$1" "$2" "$3" > "$fixture/prs.json"
  TICK_PRS=""; TICK_PR_CHECK_CENSUS=""; TICK_PR_STATE=()
}
set_units() {
  printf '%s\n' "$1" > "$UNITS"
  printf '%s\n' '{"workers":[]}' > "$WORKERS"
}

# Replay #3237: approval is recorded while its gated PR is still waiting for the ready event.
# When that exact candidate later turns red, it must stay in CI waiting and never enter repair.
set_pr_rows IN_PROGRESS "" "$H1"
printf 'VERDICT: READY\n' > "$sup/review-3237.md"
printf '\n' > "$sup/review-3237.worker.log"
set_units "$(jqf -cn --arg sha "$H1" '{units:[{id:"issue-3237",issue:3237,pr:4994,lane:"pr",branch:"agent/issue-3237",gated:true,stage:"review",history:[]}]}')"
jqf -cn --arg sha "$H1" '{workers:[{pid:999999,unit:"issue-3237",type:"review",log:"review-3237.worker.log",report:"review-3237.md",sha:$sha,pr_head:$sha}]}' > "$WORKERS"
if [[ "${1:-}" == --plant-old ]]; then
  ci_approved_gate() {
    set_unit "$1" '.stage="ready-to-merge" | .ci_green_sha=null'
  }
fi
harvest_workers || :
if [[ "$(field issue-3237 .stage)" == ci-pending && "$(field issue-3237 .approved_sha)" == "$H1" \
    && "$(field issue-3237 '.ci_green_sha // empty')" == "" ]]; then
  printf 'PASS: review approval stayed in CI waiting until its candidate gate completed\n'
else
  fail "approval entered $(field issue-3237 .stage) before its candidate gate completed"
fi
set_unit issue-3237 '.ci_ready_sha="1111111111111111111111111111111111111111" | .ci_ready_at="2026-11-02T22:55:00Z"'
set_pr_rows COMPLETED FAILURE "$H1"
ci_approved_watch
if [[ "$(field issue-3237 .stage)" == ci-pending && "$(field issue-3237 .approved_sha)" == "$H1" \
    && "$(field issue-3237 '.ci_green_sha // empty')" == "" \
    && "$(field issue-3237 '.history | any(.[]; .stage=="review-approve")')" == true && "$RERUNS" == 1 ]]; then
  printf 'PASS: approval stayed in CI waiting and requested a same-SHA retry after its candidate check failed\n'
else
  fail "red candidate after approval entered $(field issue-3237 .stage), lost approval, or retained green evidence"
fi
dispatch_pending || :
if [[ "$(jqf '[.workers[]? | select(.type=="repair" and .unit=="issue-3237")] | length' "$WORKERS")" == 0 \
    && ${#DISPATCHED[@]} == 0 ]]; then
  printf 'PASS: red candidate created no repair worker or repair dispatch\n'
else
  fail 'red candidate created repair work while its required gate was red'
fi
ci_approved_watch
if [[ "$(field issue-3237 .stage)" == ready-to-merge && "$(field issue-3237 .ci_green_sha)" == "$H1" ]]; then
  printf 'PASS: candidate became ready only after the required gate passed on the same SHA\n'
else
  fail 'candidate did not become ready after its required gate passed on the same SHA'
fi

# The no-PR direct-main lane already ran its focused local gate and must keep its delivery path.
printf 'VERDICT: READY\n' > "$sup/review-direct-main.md"
printf '\n' > "$sup/review-direct-main.worker.log"
set_units "$(jqf -cn '{units:[{id:"direct-main-approval",lane:"direct-main",stage:"review",history:[]}]}')"
jqf -cn --arg sha "$H1" '{workers:[{pid:999999,unit:"direct-main-approval",type:"review",log:"review-direct-main.worker.log",report:"review-direct-main.md",sha:$sha,pr_head:$sha}]}' > "$WORKERS"
harvest_workers || :
if [[ "$(field direct-main-approval .stage)" == ready-to-merge \
    && "$(field direct-main-approval .approved_sha)" == "$H1" \
    && "$(field direct-main-approval '.ci_gate_required // false')" == false \
    && "$(field direct-main-approval '.ci_green_sha // empty')" == "" ]]; then
  printf 'PASS: direct-main approval kept its focused-gate delivery path without PR CI evidence\n'
else
  fail 'direct-main approval was incorrectly held behind PR candidate CI'
fi

# A repeated same-SHA red may use the existing repair route, and that terminal transition must survive the watcher.
set_pr_rows COMPLETED FAILURE "$H1"
set_units "$(jqf -cn --arg sha "$H1" '{units:[{id:"repeat-red",pr:4994,lane:"pr",branch:"agent/issue-3237",gated:true,
  stage:"ready-to-merge",approved_sha:$sha,ci_gate_required:true,ci_green_sha:$sha,ci_rerun_sha:$sha,
  ci_ready_sha:$sha,ci_ready_at:"2026-11-02T22:55:00Z",history:[]}]}')"
ci_approved_gate repeat-red
if [[ "$(field repeat-red .stage)" == repair-pending && "$(field repeat-red '.approved_sha // empty')" == "" ]]; then
  printf 'PASS: a repeated same-SHA red preserved the existing repair escalation\n'
else
  fail "repeated red lost its terminal transition (stage=$(field repeat-red .stage), approval=$(field repeat-red '.approved_sha // empty'))"
fi

# A clean carried approval may move to a new candidate SHA, but its old green proof cannot follow it.
H2=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
approval_carries() { return 0; }
set_pr_rows IN_PROGRESS "" "$H2"
set_units "$(jqf -cn --arg sha "$H1" '{units:[{id:"head-change",pr:4994,lane:"pr",branch:"agent/issue-3237",gated:true,
  stage:"ready-to-merge",approved_sha:$sha,ci_gate_required:true,ci_green_sha:$sha,ci_ready_sha:$sha,
  ci_ready_at:"2026-11-02T22:55:00Z",history:[]}]}')"
ci_approved_watch
if [[ "$(field head-change .stage)" == ci-pending && "$(field head-change .approved_sha)" == "$H2" \
    && "$(field head-change '.ci_green_sha // empty')" == "" ]]; then
  printf 'PASS: a carried approval lost its old-SHA green proof and returned to ci-pending\n'
else
  fail 'head change kept stale green evidence or escaped CI waiting'
fi

# The main and PR jobs use different check names but fail the same test identity.
set_pr_rows COMPLETED FAILURE "$H1"
set_units "$(jqf -cn --arg sha "$H1" --arg red "$RED" '{units:[
  {id:"candidate",pr:4994,lane:"pr",branch:"agent/issue-3237",gated:true,stage:"ready-to-merge",approved_sha:$sha,ci_green_sha:$sha,ci_ready_sha:$sha,ci_ready_at:"2026-11-02T22:55:00Z",history:[]},
  {id:"main-red",main_red:true,ci_sha:$red,stage:"implement-pending",history:[]}
]}')"
candidate_checks="$(repair_check_rows 4994)"
if [[ "${1:-}" == --plant-old ]]; then
  park_ci_red_for_main_red() {
    local failed main
    failed="$(jqf -c '[.[] | select(.bucket=="fail") | .name] | unique' <<<"$4")"
    main='["Postsubmit validate"]'
    jqf -e --argjson failed "$failed" --argjson main "$main" \
      '($failed|length)>0 and all($failed[]; . as $name | ($main|index($name))!=null)' >/dev/null 2>&1 || return 1
    set_unit "$1" '.stage="parked" | .parked_reason="main-red"'
  }
fi
park_ci_red_for_main_red candidate 4994 "$H1" "$candidate_checks" || :
if [[ "$(field candidate .stage)" == parked && "$(field candidate .parked_reason)" == main-red \
    && "$(field candidate '.parked_test_ids[0] | "\(.file)|\(.name)"')" == 'tests/shared-membership.test.ts|rejects removed membership' ]]; then
  printf 'PASS: shared test identity quarantined across different check names\n'
else
  fail "shared failing test was not quarantined across check names (stage=$(field candidate .stage))"
fi

# One supported shared Vitest identity is insufficient when the same candidate log also has an unidentifiable failure.
MIXED_IDENTITIES=1
set_units "$(jqf -cn --arg sha "$H1" --arg red "$RED" '{units:[
  {id:"mixed-candidate",pr:4994,lane:"pr",branch:"agent/issue-3237",gated:true,stage:"ready-to-merge",approved_sha:$sha,
    ci_green_sha:$sha,ci_ready_sha:$sha,ci_ready_at:"2026-11-02T22:55:00Z",history:[]},
  {id:"main-red",main_red:true,ci_sha:$red,stage:"implement-pending",history:[]}
]}')"
candidate_checks="$(repair_check_rows 4994)"
park_ci_red_for_main_red mixed-candidate 4994 "$H1" "$candidate_checks" || :
if [[ "$(field mixed-candidate .stage)" == ready-to-merge && "$(field mixed-candidate '.parked_test_ids // empty')" == "" ]]; then
  printf 'PASS: an unidentifiable mixed-log failure prevented main-red quarantine\n'
else
  fail 'mixed parsed and unparsed failures were incorrectly quarantined'
fi
MIXED_IDENTITIES=0

# An assertion-only workflow step remains unidentifiable even when another step has a parsed failure.
MIXED_ASSERTIONS=1
set_units "$(jqf -cn --arg sha "$H1" --arg red "$RED" '{units:[
  {id:"mixed-assertion-candidate",pr:4994,lane:"pr",branch:"agent/issue-3237",gated:true,stage:"ready-to-merge",approved_sha:$sha,
    ci_green_sha:$sha,ci_ready_sha:$sha,ci_ready_at:"2026-11-02T22:55:00Z",history:[]},
  {id:"main-red",main_red:true,ci_sha:$red,stage:"implement-pending",history:[]}
]}')"
candidate_checks="$(repair_check_rows 4994)"
park_ci_red_for_main_red mixed-assertion-candidate 4994 "$H1" "$candidate_checks" || :
if [[ "$(field mixed-assertion-candidate .stage)" == ready-to-merge && "$(field mixed-assertion-candidate '.parked_test_ids // empty')" == "" ]]; then
  printf 'PASS: an extra unparsed assertion failure prevented main-red quarantine\n'
else
  fail 'an unparsed assertion failure was incorrectly quarantined'
fi
MIXED_ASSERTIONS=0

# A second exception in the same reporter section can belong to another test in the same file.
MIXED_SAME_FILE_ASSERTIONS=1
set_units "$(jqf -cn --arg sha "$H1" --arg red "$RED" '{units:[
  {id:"same-file-candidate",pr:4994,lane:"pr",branch:"agent/issue-3237",gated:true,stage:"ready-to-merge",approved_sha:$sha,
    ci_green_sha:$sha,ci_ready_sha:$sha,ci_ready_at:"2026-11-02T22:55:00Z",history:[]},
  {id:"main-red",main_red:true,ci_sha:$red,stage:"implement-pending",history:[]}
]}')"
candidate_checks="$(repair_check_rows 4994)"
park_ci_red_for_main_red same-file-candidate 4994 "$H1" "$candidate_checks" || :
if [[ "$(field same-file-candidate .stage)" == ready-to-merge && "$(field same-file-candidate '.parked_test_ids // empty')" == "" ]]; then
  printf 'PASS: a second same-file assertion without another test summary prevented main-red quarantine\n'
else
  fail 'a second same-file assertion was attributed to the first parsed test and quarantined'
fi
MIXED_SAME_FILE_ASSERTIONS=0

if (( failures > 0 )); then exit 1; fi
printf 'approve-after-green.test.sh: PASS (approval waits on candidate SHA; shared test quarantines across check names)\n'
