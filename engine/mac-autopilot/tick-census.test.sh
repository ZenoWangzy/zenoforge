#!/usr/bin/env bash
set -euo pipefail
script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
scratch="$(mktemp -d "$script_dir/.tick-census-test.XXXXXX")"
trap 'rm -rf -- "$scratch"' EXIT
export HOME="$scratch"
source "$script_dir/test-env.sh"

fixture="$test_env_root/tick"
mkdir -p "$fixture/repo" "$fixture/sup/autopi"
cp "$script_dir/config.template.json" "$fixture/sup/autopi/config.json"
printf '{"units":[]}\n' > "$fixture/sup/autopi/units.json"
export MAC_AUTOPILOT_ROOT="$fixture/repo" MAC_AUTOPILOT_SUPERVISOR_DIR="$fixture/sup" MAC_AUTOPILOT_RUNTIME_DIR="$fixture/sup/autopi"
export REAL_GIT="$(command -v git)" TEST_GIT_CALLS="$fixture/git-calls" TEST_GIT_FAILED="$fixture/git-failed" TEST_GH_CALLS="$fixture/gh-calls" TEST_PRS="$fixture/prs.json"
cat > "$test_env_bin/git" <<'SH'
#!/usr/bin/env bash
if [[ " $* " == *' log '* ]]; then
  printf 'log\n' >> "$TEST_GIT_CALLS"
  if [[ "${TEST_GIT_FAIL_ONCE:-false}" == true && ! -e "$TEST_GIT_FAILED" ]]; then touch "$TEST_GIT_FAILED"; exit 1; fi
fi
exec "$REAL_GIT" "$@"
SH
cat > "$test_env_bin/gh" <<'SH'
#!/usr/bin/env bash
printf '%s %s\n' "${1:-}" "${2:-}" >> "$TEST_GH_CALLS"
case "${1:-} ${2:-}" in
  'pr list') cat "$TEST_PRS" ;;
  'pr view')
    case "$*" in
      *'--json state'*) printf 'CLOSED\n' ;;
      *'--json mergeable'*) printf 'UNKNOWN\n' ;;
      *) printf '%s\n' 0123456789012345678901234567890123456789 ;;
    esac ;;
  'api repos/{owner}/{repo}/statuses/'*) [[ "${TEST_GH_STATUS_FAIL:-false}" != true ]] ;;
  'pr close'|'api -X'|'run list') : ;;
  *) exit 1 ;;
esac
SH
chmod +x "$test_env_bin/git" "$test_env_bin/gh"
git init -q -b main "$fixture/repo"
git -C "$fixture/repo" config user.name Test
git -C "$fixture/repo" config user.email test@example.invalid
mkdir -p "$fixture/repo/pkg"
for n in 1 2; do
  printf '%s\n' "$n" > "$fixture/repo/pkg/a"
  printf '%s\n' "$n" > "$fixture/repo/pkg/hot"
  git -C "$fixture/repo" add pkg
  git -C "$fixture/repo" commit -qm "fixture $n"
done
export AUTOPI_TEST_LIBRARY_ONLY=true
source "$script_dir/scheduler.sh"
unset AUTOPI_TEST_LIBRARY_ONLY
SCHED_LOCK_HELD=true
fail() { printf 'tick-census.test.sh: %s\n' "$*" >&2; exit 1; }

test_census() {
  local sha=0123456789012345678901234567890123456789
  jq -n --arg sha "$sha" '[range(1;5) | {number:.,headRefOid:$sha,headRefName:("branch-" + tostring),baseRefName:"main",isDraft:false,title:"fixture",labels:[],body:"",statusCheckRollup:[],mergeable:"UNKNOWN"}]' > "$TEST_PRS"
  jq -n --arg sha "$sha" '{units:([range(1;5) | {id:("parent-" + tostring),issue:.,lane:"pr",pr:.,branch:("branch-" + tostring),stage:"ready-to-merge",approved_sha:$sha,reviewed_pr_head:$sha,history:[]}]
    + [range(1;5) | {id:("child-" + tostring),issue:(. + 10),lane:"pr",branch:("child-" + tostring),stage:"blocked-external",blocked_on:.,labels:["stack-pilot"],history:[]}])}' > "$UNITS"
  dep_states() { local dep; for dep in "$@"; do printf '%s\tOPEN\t\tOPEN\n' "$dep"; done; }
  stack_initial_branch() { return 0; }
  DEP_CHECK_SECONDS=0
  : > "$TEST_GH_CALLS"
  TICK_PRS=''
  phase release_dependency_blocks
  jq -e '[.units[] | select(.id | startswith("child-")) | .stage] == ["implement-pending","implement-pending","implement-pending","implement-pending"]' "$UNITS" >/dev/null || fail 'dependency phase did not release the four approved stacks'
  jq -n --arg sha "$sha" '{units:[range(1;5) | {id:("pr-" + tostring),pr:.,stage:"blocked-external",reviewed_sha:$sha,blocked_main_sha:$sha}]}' > "$UNITS"
  MAIN_HEAD="$sha"
  phase retry_blocked_units
  jq -n --arg sha "$sha" '{units:[range(1;5) | {id:("pr-" + tostring),pr:.,branch:("branch-" + tostring),lane:"pr",stage:"ready-to-merge",approved_sha:$sha,ci_wip_wait:$sha,product_paths:true,history:[]}]}' > "$UNITS"
  CFG="$(jq '.precheck=false' <<<"$CFG")"
  TICK_HOTFIX_ISSUES_LOADED=true
  TICK_HOTFIX_ISSUES='[]'
  TICK_UNFINISHED_LOADED=true
  TICK_UNFINISHED='[]'
  ci_pr_free_slots() { echo 4; }
  pr_behind_main() { return 0; }
  phase ci_admission
  jq -e '[.units[] | .history[-1].stage] == ["ci-wip-start","ci-wip-start","ci-wip-start","ci-wip-start"]' "$UNITS" >/dev/null || fail 'CI phase did not check all four PRs for a slot'
  local lists views
  lists="$(awk '$0 == "pr list" {n++} END {print n+0}' "$TEST_GH_CALLS")"
  views="$(awk '$0 == "pr view" {n++} END {print n+0}' "$TEST_GH_CALLS")"
  [[ "$lists" == 1 && "$views" == 0 ]] || fail "four PRs across dependency, merge prep, and CI: expected one list and no views, got $lists list(s), $views view(s)"
  [[ "$(tick_pr_state 99)" == CLOSED ]] || fail 'a PR outside the open census did not use the direct fallback'
  [[ "$(awk '$0 == "pr view" {n++} END {print n+0}' "$TEST_GH_CALLS")" == 1 ]] || fail 'missing PR did not make exactly one direct view'

  ci_update_branch 1 "$sha"
  [[ -z "$TICK_PRS" ]] || fail 'update-branch did not invalidate the census'
  jq 'map(if .number==1 then .headRefOid="abcdefabcdefabcdefabcdefabcdefabcdefabcd" else . end)' "$TEST_PRS" > "$TEST_PRS.tmp"
  mv "$TEST_PRS.tmp" "$TEST_PRS"
  tick_prs_prime
  [[ "$(tick_pr_head 1)" == abcdefabcdefabcdefabcdefabcdefabcdefabcd ]] || fail 'the changed PR head was not reloaded'
  release_scheduler_lock() { :; }
  acquire_scheduler_lock_wait() { :; }
  yield_fixture_change() {
    jq 'map(if .number==1 then .headRefOid="1111111111111111111111111111111111111111" else . end)' "$TEST_PRS" > "$TEST_PRS.tmp"
    mv "$TEST_PRS.tmp" "$TEST_PRS"
  }
  phase_yield_lock yield_fixture_change
  [[ -z "$TICK_PRS" ]] || fail 'a yielded scheduler lock retained the PR census'
  tick_prs_prime
  [[ "$(tick_pr_head 1)" == 1111111111111111111111111111111111111111 ]] || fail 'the PR change during the lock yield was not reloaded'
  TICK_PR_CHECK_CENSUS='{"1":{"draft":false}}'
  tick_prs_set_draft 1 true
  tick_prs_add_label 1 gated
  jq -e '.[0].isDraft == true and any(.[0].labels[]; .name == "gated")' <<<"$TICK_PRS" >/dev/null || fail 'draft and label changes were not mirrored'
  [[ -z "$TICK_PR_CHECK_CENSUS" ]] || fail 'a draft change retained the old normalized census'
  TICK_PR_STATE[99]=OPEN
  gated_status "$sha" success test/context test
  [[ -z "$TICK_PRS" && -z "${TICK_PR_STATE[99]:-}" ]] || fail 'a new commit status did not invalidate cached PR facts'
  tick_prs_prime
  aged_pr_close 1 branch-1 86400 1 obsolete fixture
  [[ -z "$TICK_PRS" ]] || fail 'closing an aged PR did not invalidate the census'
  tick_prs_prime
  if gated_demote_pr 1 branch-1 fixture; then fail 'the failed draft write unexpectedly succeeded'; fi
  [[ -z "$TICK_PRS" ]] || fail 'an unconfirmed draft write retained the census'
  tick_prs_prime
  if gated_flag_pr 1; then fail 'the failed label write unexpectedly succeeded'; fi
  [[ -z "$TICK_PRS" ]] || fail 'an unconfirmed label write retained the census'
  tick_prs_prime
  export TEST_GH_STATUS_FAIL=true
  if gated_status "$sha" success test/context test; then fail 'the failed status write unexpectedly succeeded'; fi
  unset TEST_GH_STATUS_FAIL
  [[ -z "$TICK_PRS" ]] || fail 'an unconfirmed status write retained the census'

  : > "$TEST_GH_CALLS"
  jq -n '{workers:[range(1;5) | {pid:(100000 + .),unit:("eval-" + tostring),type:"eval",report:"report",log:"log"}]}' > "$WORKERS"
  local HARVEST_HOOK_N=0
  alive() { return 1; }
  harvest_prompt_eval() {
    HARVEST_HOOK_N=$((HARVEST_HOOK_N + 1))
    [[ -n "$(tick_pr_head "$HARVEST_HOOK_N")" ]] || fail 'harvest could not read a PR head'
    [[ "$HARVEST_HOOK_N" != 1 ]] || gated_status "$sha" success test/context test
  }
  phase harvest_workers
  lists="$(awk '$0 == "pr list" {n++} END {print n+0}' "$TEST_GH_CALLS")"
  views="$(awk '$0 == "pr view" {n++} END {print n+0}' "$TEST_GH_CALLS")"
  [[ "$HARVEST_HOOK_N" == 4 && "$lists" == 2 && "$views" == 0 ]] || fail "harvest expected one census before and after a status write, got $lists list(s), $views view(s)"

  jq 'map(.headRefOid="2222222222222222222222222222222222222222")' "$TEST_PRS" > "$TEST_PRS.tmp"
  mv "$TEST_PRS.tmp" "$TEST_PRS"
  jq -n '{units:[range(1;5) | {id:("pr-" + tostring),pr:.,branch:("branch-" + tostring),lane:"pr",stage:"review-pending",history:[]}]}' > "$UNITS"
  : > "$TEST_GH_CALLS"
  local DISPATCH_HOOK_N=0
  advisor_harvest() { :; }
  room_for() { return 0; }
  pick() { return 0; }
  verify_handoff_delivery() {
    [[ "$4" == 2222222222222222222222222222222222222222 ]] || fail 'dispatch used a head cached before the phase'
    DISPATCH_HOOK_N=$((DISPATCH_HOOK_N + 1))
  }
  ensure_clone() { return 1; }
  phase dispatch_pending
  lists="$(awk '$0 == "pr list" {n++} END {print n+0}' "$TEST_GH_CALLS")"
  views="$(awk '$0 == "pr view" {n++} END {print n+0}' "$TEST_GH_CALLS")"
  [[ "$DISPATCH_HOOK_N" == 4 && "$lists" == 1 && "$views" == 0 ]] || fail "dispatch expected one fresh census for four PRs, got $lists list(s), $views view(s)"
}

test_footprint() {
  local blocked='{"id":"blocked","footprint":["pkg/a"]}' clear='{"id":"clear","footprint":["pkg/unrelated"]}'
  local expected actual logs
  TICK_ACTIVE_FOOTPRINTS='[{"id":"running","footprint":["pkg/hot"]}]'
  TICK_ACTIVE_FOOTPRINTS_VALID=true
  active_footprint_snapshot() { printf '%s\n' "$TICK_ACTIVE_FOOTPRINTS"; }
  footprint_wait_mark() { :; }
  expected="$(for unit in "$blocked" "$clear"; do ( unset HOTSPOT_LOG HOTSPOT_LOG_LOADED HOTSPOT_LOG_OK; id="$(jq -r .id <<<"$unit")"; if _footprint_room "$id" "$unit" true; then echo 0; else echo 1; fi ); done)"
  [[ "$expected" == $'1\n0' ]] || fail "uncached footprint verdicts were $expected"
  : > "$TEST_GIT_CALLS"
  unset HOTSPOT_LOG HOTSPOT_LOG_LOADED HOTSPOT_LOG_OK
  TICK_FOOTPRINT_CACHE=(); TICK_CHECK_SCOPE_SOURCE=(); TICK_CHECK_SCOPE=()
  actual="$(for unit in "$blocked" "$clear"; do id="$(jq -r .id <<<"$unit")"; if _footprint_room "$id" "$unit" true; then echo 0; else echo 1; fi; done)"
  logs="$(wc -l < "$TEST_GIT_CALLS")"
  [[ "$actual" == "$expected" && "$logs" == 1 ]] || fail "cached footprint verdicts $actual, git log calls $logs; expected $expected and one git log"

  jq -n --argjson blocked "$blocked" --argjson clear "$clear" '{units:[$blocked,$clear] | map(. + {stage:"implement-pending"})}' > "$UNITS"
  : > "$TEST_GIT_CALLS"
  unset HOTSPOT_LOG HOTSPOT_LOG_LOADED HOTSPOT_LOG_OK
  TICK_FOOTPRINT_CACHE=(); TICK_CHECK_SCOPE_SOURCE=(); TICK_CHECK_SCOPE=()
  TICK_FOOTPRINT_PREFLIGHT_STATUS=not-started
  local late='{"id":"late","footprint":["pkg/a"]}'
  actual="$(footprint_preflight_snapshot; for unit in "$blocked" "$clear"; do id="$(jq -r .id <<<"$unit")"; if _footprint_room "$id" "$unit" false; then echo 0; else echo 1; fi; done; if _footprint_room late "$late" true; then echo 0; else echo 1; fi)"
  logs="$(wc -l < "$TEST_GIT_CALLS")"
  [[ "$actual" == "$expected"$'\n1' && "$logs" == 1 ]] || fail "preflight and later footprint verdicts $actual, git log calls $logs; expected $expected, 1 and one git log"

  : > "$TEST_GIT_CALLS"
  unset HOTSPOT_LOG HOTSPOT_LOG_LOADED HOTSPOT_LOG_OK
  TICK_FOOTPRINT_CACHE=(); TICK_CHECK_SCOPE_SOURCE=(); TICK_CHECK_SCOPE=()
  export TEST_GIT_FAIL_ONCE=true
  actual="$(if _footprint_room blocked "$blocked" true; then echo 0; else echo 1; fi; if _footprint_room late "$late" true; then echo 0; else echo 1; fi)"
  unset TEST_GIT_FAIL_ONCE
  logs="$(wc -l < "$TEST_GIT_CALLS")"
  [[ "$actual" == $'0\n1' && "$logs" == 2 ]] || fail 'a failed git log was not retried for the next footprint decision'
}

case "${1:-all}" in
  census) test_census ;;
  footprint) test_footprint ;;
  all) test_census; test_footprint ;;
  *) fail "unknown test $1" ;;
esac
printf 'tick-census.test.sh: ok\n'
