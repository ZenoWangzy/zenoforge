#!/usr/bin/env bash
set -euo pipefail
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/test-env.sh"
script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
trap 'rm -rf -- "$test_env_root"' EXIT
[[ "$test_env_root" != "$script_dir/"* ]] || { echo "tick-census.test.sh: scratch must be outside the source tree" >&2; exit 1; }

fixture="$test_env_root/tick"
mkdir -p "$fixture/repo" "$fixture/sup/autopi"
cp "$script_dir/config.template.json" "$fixture/sup/autopi/config.json"
printf '{"units":[]}\n' > "$fixture/sup/autopi/units.json"
export MAC_AUTOPILOT_ROOT="$fixture/repo" MAC_AUTOPILOT_SUPERVISOR_DIR="$fixture/sup" MAC_AUTOPILOT_RUNTIME_DIR="$fixture/sup/autopi"
export GH_TICK_CACHE_DIR="$fixture/sup/autopi/.gh-cache"
mkdir -p "$GH_TICK_CACHE_DIR"
export REAL_GIT="$(command -v git)" TEST_GIT_CALLS="$fixture/git-calls" TEST_GIT_FAILED="$fixture/git-failed" TEST_GH_CALLS="$fixture/gh-calls" TEST_GH_ARGS="$fixture/gh-args" TEST_PRS="$fixture/prs.json" TEST_PR_BODY="$fixture/pr-body"
printf 'fixture pr body\nRefs #77\n' > "$TEST_PR_BODY"
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
api_url=""
if [[ "${1:-}" == api ]]; then
  for arg in "$@"; do [[ "$arg" == repos/*/pulls* ]] && api_url="$arg"; done
  printf 'api %s\n' "$api_url" >> "$TEST_GH_CALLS"
else
  printf '%s %s\n' "${1:-}" "${2:-}" >> "$TEST_GH_CALLS"
fi
[[ "$1" != pr ]] || printf '%s\n' "$*" >> "$TEST_GH_ARGS"
[[ "$1" != api ]] || printf '%s\n' "$*" >> "$TEST_GH_ARGS"
case "${1:-} ${2:-}" in
  'api -i')
    [[ "${TEST_GH_OPEN_FAIL:-false}" != true || "$*" != *'pulls?state=open&per_page=100'* ]] || { printf 'gh stub: REST PR census refused\n' >&2; exit 1; }
    case "$*" in
      *'pulls?state=open&per_page=100'*)
        payload="$(jq -c --arg fallback "$(cat "$TEST_PR_BODY")" --arg include_mergeable "${TEST_GH_OPEN_INCLUDE_MERGEABLE:-false}" 'map(. as $p | {number, state:(.state // "open"), draft:(.isDraft // false), head:{sha:(.headRefOid // ""),ref:(.headRefName // "")}, base:{ref:(.baseRefName // "")}, title:(.title // ""), body:(.body // $fallback), labels:(.labels // []), created_at:.createdAt, updated_at:.updatedAt} + (if $include_mergeable == "true" then {mergeable:(if $p.mergeable == "MERGEABLE" then true elif $p.mergeable == "CONFLICTING" then false else null end)} else {} end))' "$TEST_PRS")" ;;
      *'pulls/7/reviews?per_page=100'*) payload='[{"state":"CHANGES_REQUESTED","submitted_at":"2026-11-11T00:00:00Z","user":{"login":"human-reviewer","type":"User"}}]' ;;
      *'pulls/7/files?per_page=100'*) payload='[{"filename":"src/a.ts","status":"added","additions":2,"deletions":0}]' ;;
      *'pulls/7/commits?per_page=100'*) payload='[{"sha":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","commit":{"message":"subject\n\nbody","author":{"email":"dev@example.invalid"}},"author":{"login":"dev"}}]' ;;
      *'pulls/'*)
        pr_number="$(sed -E 's#.*pulls/([0-9]+).*#\1#' <<<"$*")"
        payload="$(jq -c --argjson n "$pr_number" --arg fallback "$(cat "$TEST_PR_BODY")" '((first(.[] | select(.number == $n))) // {number:$n,state:"closed"}) | {number, state:(.state // "open"), draft:(.isDraft // false), head:{sha:(.headRefOid // ""),ref:(.headRefName // "")}, base:{ref:(.baseRefName // "")}, title:(.title // ""), body:(.body // $fallback), labels:(.labels // []), mergeable:(if .mergeable == "MERGEABLE" then true elif .mergeable == "CONFLICTING" then false else null end), created_at:.createdAt, updated_at:.updatedAt}' "$TEST_PRS")" ;;
      *) exit 1 ;;
    esac
    etag="$(printf '%s' "$payload" | sha256sum | cut -d' ' -f1)"
    printf 'HTTP/2 200 OK\r\nETag: "%s"\r\n\r\n%s\n' "$etag" "$payload"
    ;;
  'pr list') [[ "${TEST_GH_LIST_FAIL:-false}" != true ]] || { printf 'gh stub: pr list refused\n' >&2; exit 1; }; cat "$TEST_PRS" ;;
  'pr view')
    case "$*" in
      *'--json body'*) cat "$TEST_PR_BODY" ;;
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
open_calls() { awk 'index($0, "pulls?state=open&per_page=100") {n++} END {print n+0}' "$TEST_GH_CALLS"; }
detail_calls() { awk '$0 ~ /^api repos\/\{owner\}\/\{repo\}\/pulls\/[0-9]+([? ]|$)/ {n++} END {print n+0}' "$TEST_GH_CALLS"; }

test_census() {
  local sha=0123456789012345678901234567890123456789
  export TEST_GH_OPEN_INCLUDE_MERGEABLE=true
  jq -n --arg sha "$sha" '[range(1;5) | {number:.,headRefOid:$sha,headRefName:("branch-" + tostring),baseRefName:"main",isDraft:false,title:"fixture",labels:[],mergeable:"MERGEABLE"}]' > "$TEST_PRS"
  jq -n --arg sha "$sha" '{units:([range(1;5) | {id:("parent-" + tostring),issue:.,lane:"pr",pr:.,branch:("branch-" + tostring),stage:"ready-to-merge",approved_sha:$sha,reviewed_pr_head:$sha,history:[]}]
    + [range(1;5) | {id:("child-" + tostring),issue:(. + 10),lane:"pr",branch:("child-" + tostring),stage:"blocked-external",blocked_on:.,labels:["stack-pilot"],history:[]}])}' > "$UNITS"
  dep_states() { local dep; for dep in "$@"; do printf '%s\tOPEN\t\tOPEN\n' "$dep"; done; }
  stack_initial_branch() { return 0; }
  DEP_CHECK_SECONDS=0
  : > "$TEST_GH_CALLS"
  tick_prs_changed
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
  pr_behind_main() { return 1; }
  phase ci_admission
  jq -e '[.units[] | .history[-1].stage] == ["ci-wip-start","ci-wip-start","ci-wip-start","ci-wip-start"]' "$UNITS" >/dev/null || fail 'CI phase did not check all four PRs for a slot'
  local lists views
  lists="$(open_calls)"
  views="$(detail_calls)"
  [[ "$lists" == 1 && "$views" == 0 ]] || fail "four PRs across dependency, merge prep, and CI: expected one list and no views, got $lists list(s), $views view(s)"
  [[ "$(tick_pr_state 99)" == CLOSED ]] || fail 'a PR outside the open census did not use the direct fallback'
  [[ "$(detail_calls)" == 1 ]] || fail 'missing PR did not make exactly one direct REST read'
  tick_prs_changed
  : > "$TEST_GH_ARGS"
  [[ "$(tick_pr_state 99)" == CLOSED ]] || fail 'a repeated direct REST read changed state'
  awk '/pulls\/99/ && /If-None-Match/ {found=1} END {exit !found}' "$TEST_GH_ARGS" || fail 'the direct PR REST read did not send its ETag'

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
  tick_prs_set_draft 1 true
  tick_prs_add_label 1 gated
  jq -e '.[0].isDraft == true and any(.[0].labels[]; .name == "gated")' <<<"$TICK_PRS" >/dev/null || fail 'draft and label changes were not mirrored'
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
  lists="$(open_calls)"
  views="$(detail_calls)"
  [[ "$HARVEST_HOOK_N" == 4 && "$lists" == 2 && "$views" == 0 ]] || fail "harvest expected one census before and after a status write, got $lists list(s), $views view(s)"

  jq 'map(.headRefOid="2222222222222222222222222222222222222222")' "$TEST_PRS" > "$TEST_PRS.tmp"
  mv "$TEST_PRS.tmp" "$TEST_PRS"
  jq -n '{units:[range(1;5) | {id:("pr-" + tostring),pr:.,branch:("branch-" + tostring),lane:"pr",stage:"review-pending",history:[]}]}' > "$UNITS"
  : > "$TEST_GH_CALLS"
  local DISPATCH_HOOK_N=0
  advisor_harvest() { :; }
  room_for() { return 0; }
  pick() { return 0; }
  pick_review_for_unit() { PICK_MODEL=fixture-model; PICK_EFFORT=high; return 0; }
  verify_handoff_delivery() {
    [[ "$4" == 2222222222222222222222222222222222222222 ]] || fail 'dispatch used a head cached before the phase'
    DISPATCH_HOOK_N=$((DISPATCH_HOOK_N + 1))
  }
  ensure_clone() { return 1; }
  phase dispatch_pending
  lists="$(open_calls)"
  views="$(detail_calls)"
  [[ "$DISPATCH_HOOK_N" == 4 && "$lists" == 1 && "$views" == 0 ]] || fail "dispatch expected one fresh census for four PRs, got $lists list(s), $views view(s)"
  unset TEST_GH_OPEN_INCLUDE_MERGEABLE
}

test_adopt() { # #1038: the per-head PR lookup is answered from the loaded census
  local sha=0123456789012345678901234567890123456789 calls rc
  jq -n --arg sha "$sha" '[range(1;5) | {number:.,headRefOid:$sha,headRefName:("branch-" + tostring),baseRefName:"main",isDraft:(. == 2),title:"fixture",labels:[],mergeable:"UNKNOWN"}]' > "$TEST_PRS"
  tick_prs_changed; tick_prs_prime
  : > "$TEST_GH_CALLS"
  scheduler_pr_adopt_open branch-2 || fail 'a PR in the census was not adopted'
  [[ "$SCHED_PR_NUM" == 2 ]] || fail "adopted PR $SCHED_PR_NUM, expected 2"
  rc=0; scheduler_pr_adopt_open branch-9 || rc=$?
  [[ "$rc" == 1 && -z "$SCHED_PR_NUM" ]] || fail 'a head missing from a complete census was adopted'
  [[ ! -s "$TEST_GH_CALLS" ]] || fail "a loaded census still called gh: $(cat "$TEST_GH_CALLS")"
  tick_prs_changed
  rc=0; scheduler_pr_adopt_open branch-2 || rc=$?
  [[ "$(open_calls)" == 1 ]] || fail 'an empty census did not fetch the REST snapshot'
  jq -n --arg sha "$sha" '[range(1;301) | {number:.,headRefOid:$sha,headRefName:("branch-" + tostring),baseRefName:"main",isDraft:false,title:"fixture",labels:[],mergeable:"UNKNOWN"}]' > "$TEST_PRS"
  tick_prs_changed; tick_prs_prime
  : > "$TEST_GH_CALLS"
  scheduler_pr_adopt_open branch-300 || fail 'a PR in a full census was not adopted'
  [[ ! -s "$TEST_GH_CALLS" ]] || fail 'a hit in a full census called gh'
  rc=0; scheduler_pr_adopt_open branch-999 || rc=$?
  [[ "$(open_calls)" == 0 ]] || fail 'a miss in a complete REST census fetched another open snapshot'
}

test_footprint() {
  local blocked='{"id":"blocked","footprint":["pkg/a"]}' clear='{"id":"clear","footprint":["pkg/unrelated"]}'
  export ZF_FOOTPRINT_HOTSPOT_MIN=1 # this fixture's pkg/a link has a low co-change count; the verdict cache is what is under test.
  local expected actual logs TICK_FOOTPRINT_DEFER=true # the verdict is the walk's first pass; any other caller starts the unit
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

test_light_census() { # 轻量列表：字段不带 body/statusCheckRollup；60s 窗口文件跨进程复用；失败不落盘；正文按 PR 单取
  local sha=0123456789012345678901234567890123456789 lists
  TICK_PR_BODY_FETCHES=0 # the per-process body cap counts earlier cases of this shell
  jq -n --arg sha "$sha" '[{number:7,headRefOid:$sha,headRefName:"branch-7",baseRefName:"main",isDraft:false,title:"fixture",labels:[],mergeable:"MERGEABLE"}]' > "$TEST_PRS"
  tick_prs_changed
  : > "$TEST_GH_CALLS"; : > "$TEST_GH_ARGS"
  tick_prs_prime
  [[ -n "$TICK_PRS" ]] || fail 'the light list read failed'
  grep -Fq 'repos/{owner}/{repo}/pulls?state=open&per_page=100' "$TEST_GH_ARGS" \
    || fail "the open census did not use REST: $(cat "$TEST_GH_ARGS")"
  # the list call asks for the light fields only: no body, no statusCheckRollup
  grep -Fq 'repos/{owner}/{repo}/pulls?state=open&per_page=100' "$TEST_GH_ARGS" \
    || fail "the open census is not the REST endpoint: $(cat "$TEST_GH_ARGS")"
  [[ -s "$A/.tick-prs-census.json" ]] || fail 'a successful list wrote no cross-process cache file'
  jq -e '.[0].mergeable == null' <<<"$TICK_PRS" >/dev/null || fail "the REST list has no mergeable, the census must not invent one: $TICK_PRS"
  [[ "$(tick_pr_mergeable 7)" == MERGEABLE ]] || fail 'a census row without mergeable did not fall back to the single-PR read'
  : > "$TEST_GH_ARGS"
  view="$(gh pr view 7 --json number,state,headRefOid,headRefName,baseRefName,isDraft,mergeable,title,body,labels,mergeCommit,mergedAt)" \
    || fail 'the PR view adapter failed'
  jq -e '.number == 7 and .state == "OPEN" and .headRefName == "branch-7" and .mergeable == "MERGEABLE"' <<<"$view" >/dev/null \
    || fail "the PR view adapter changed the selected fields: $view"
  [[ ! -s "$TEST_GH_ARGS" ]] || fail 'the PR view adapter missed the cached REST detail read'
  files_commits="$(gh pr view 7 --json files,commits -q '.files[0].path + " " + .commits[0].messageBody')" \
    || fail 'the PR view adapter failed to map REST files and commits'
  [[ "$files_commits" == 'src/a.ts body' ]] || fail "REST files and commits changed shape: $files_commits"
  : > "$TEST_GH_ARGS"
  [[ "$(tick_pr_has_changes_requested 7)" == true ]] || fail 'the review census did not find a human changes-requested review'
  grep -Fq 'pulls/7/reviews?per_page=100' "$TEST_GH_ARGS" || fail 'the review census did not use the REST reviews endpoint'
  rm -f "$A/.tick-prs-census.json"
  (
    A= TICK_PRS='' TICK_PR_STATE=() TICK_PR_CHECK_RUNS=() TICK_PR_BODY=() TICK_PR_BODY_LOADED=()
    tick_prs_prime
    [[ -n "$TICK_PRS" ]] || exit 3
  ) || fail 'a second reader could not use the per-tick open-PR cache'
  [[ "$(open_calls)" == 1 ]] || fail "two readers of the same tick fetched the open census $(open_calls) times"
  # a second reader process inside the 60 s window reuses the file and makes no list call
  lists="$(open_calls)"
  (
    TICK_PRS='' TICK_PR_STATE=() TICK_PR_CHECK_RUNS=() TICK_PR_BODY=() TICK_PR_BODY_LOADED=()
    tick_prs_prime
    [[ -n "$TICK_PRS" ]] || exit 3
  ) || fail 'a second process could not read the shared census'
  [[ "$(open_calls)" == "$lists" ]] || fail 'a second process within 60 s fetched the open census again'
  # tick_prs_changed drops the file: the next reader lists again
  tick_prs_changed
  [[ ! -e "$A/.tick-prs-census.json" ]] || fail 'tick_prs_changed kept the cross-process cache file'
  tick_prs_prime
  [[ "$(open_calls)" == "$((lists + 1))" ]] || fail 'after tick_prs_changed no fresh REST census was made'
  # a failed read never writes the file
  export TEST_GH_OPEN_FAIL=true
  tick_prs_changed
  tick_prs_prime
  unset TEST_GH_OPEN_FAIL
  [[ -z "$TICK_PRS" ]] || fail 'a failed list still filled the census'
  [[ ! -e "$A/.tick-prs-census.json" ]] || fail 'a failed list wrote the cross-process cache file'
  tick_prs_changed; tick_prs_prime
  # a body reader still gets the body: one gh pr view per PR per process (the second
  # read in the same process hits the cache; $(...) would hide that in a subshell)
  : > "$TEST_GH_CALLS"
  tick_pr_body 7 > "$test_env_root/pr-body.out"
  tick_pr_body 7 > /dev/null
  [[ "$(cat "$test_env_root/pr-body.out")" == "$(cat "$TEST_PR_BODY")" ]] || fail 'the body reader did not get the PR body'
  [[ "$(detail_calls)" == 0 ]] || fail "the open snapshot triggered $(detail_calls) direct body reads"
  # the hotfix classifier reads the body of an unlabelled PR once per tick, however many times it runs in this shell
  tick_prs_changed; tick_prs_prime
  TICK_HOTFIX_ISSUES='[77]'; TICK_HOTFIX_ISSUES_LOADED=true
  : > "$TEST_GH_CALLS"
  ci_hotfix_branches > /dev/null; ci_hotfix_branches > /dev/null
  [[ "$(detail_calls)" == 0 ]] || fail "ci_hotfix_branches read a body outside the open snapshot $(detail_calls) times"
}

test_body_cache() { # 正文按 updatedAt 跨进程缓存；每进程上限；失败 census 的一行
  local sha=0123456789012345678901234567890123456789 path7 rc
  export LOG="$test_env_root/body-cache.log"; : > "$LOG"
  jq -n --arg sha "$sha" '[range(1;25) | {number:.,headRefOid:$sha,headRefName:("branch-" + tostring),baseRefName:"main",isDraft:false,title:"fixture",labels:[],mergeable:"UNKNOWN",updatedAt:"2026-11-22T03:00:00Z"}]' > "$TEST_PRS"
  # (a) two processes at the same updatedAt: one body fetch in total
  tick_prs_changed; tick_prs_prime
  TICK_PRS="$(jqf 'map(del(.body))' <<<"$TICK_PRS")"
  TICK_PR_BODY=(); TICK_PR_BODY_LOADED=(); TICK_PR_BODY_FETCHES=0
  : > "$TEST_GH_CALLS"
  tick_pr_body 7 >/dev/null || fail 'the first body read failed'
  (
    TICK_PRS='' TICK_PR_STATE=() TICK_PR_CHECK_RUNS=() TICK_PR_BODY=() TICK_PR_BODY_LOADED=()
    tick_prs_prime
    tick_pr_body 7 > "$test_env_root/body2.out" || exit 3
  ) || fail 'a second process could not read the cached body'
  [[ "$(detail_calls)" == 1 ]] || fail "two processes at one updatedAt fetched the body $(detail_calls) times"
  [[ "$(cat "$test_env_root/body2.out")" == "$(cat "$TEST_PR_BODY")" ]] || fail 'the second process got another body'
  # per tick: five PRs read by one process, then by the next process: the second tick makes no pr view
  for n in 1 2 3 4 5; do tick_pr_body "$n" >/dev/null || fail "PR $n body read failed"; done
  : > "$TEST_GH_CALLS"
  (
    TICK_PRS='' TICK_PR_STATE=() TICK_PR_CHECK_RUNS=() TICK_PR_BODY=() TICK_PR_BODY_LOADED=()
    tick_prs_prime
    for n in 1 2 3 4 5; do tick_pr_body "$n" >/dev/null || exit 3; done
  ) || fail 'the next tick could not read cached bodies'
  [[ "$(detail_calls)" == 0 ]] || fail "the next tick made $(detail_calls) direct REST reads for unchanged PRs"
  # (b) a changed updatedAt is a new key: the body is fetched again
  jq '(.[] | select(.number == 7) | .updatedAt) = "2026-11-22T04:00:00Z"' "$TEST_PRS" > "$test_env_root/prs-b.json" && mv "$test_env_root/prs-b.json" "$TEST_PRS"
  tick_prs_changed; tick_prs_prime
  TICK_PRS="$(jqf 'map(del(.body))' <<<"$TICK_PRS")"
  TICK_PR_BODY=(); TICK_PR_BODY_LOADED=()
  : > "$TEST_GH_CALLS"
  tick_pr_body 7 >/dev/null || fail 'a changed updatedAt did not fetch the body'
  [[ "$(detail_calls)" == 1 ]] || fail 'a changed updatedAt did not fetch the body once'
  # (c) the cap: 20 misses per process; the 21st is refused with no gh call, one cap line
  jq -n --arg sha "$sha" '[range(101;122) | {number:.,headRefOid:$sha,headRefName:("branch-" + tostring),baseRefName:"main",isDraft:false,title:"fixture",labels:[],mergeable:"UNKNOWN",updatedAt:"2026-11-22T05:00:00Z"}]' > "$TEST_PRS"
  tick_prs_changed; tick_prs_prime
  TICK_PRS="$(jqf 'map(del(.body))' <<<"$TICK_PRS")"
  TICK_PR_BODY=(); TICK_PR_BODY_LOADED=(); TICK_PR_BODY_FETCHES=0; TICK_PR_BODY_CAP_SAID=''
  for n in $(seq 101 120); do tick_pr_body "$n" >/dev/null || fail "PR $n under the cap was refused"; done
  : > "$TEST_GH_CALLS"
  rc=0; tick_pr_body 121 >/dev/null || rc=$?
  [[ "$rc" == 1 ]] || fail 'the 21st body fetch was not refused'
  rc=0; tick_pr_body 121 >/dev/null || rc=$?
  [[ ! -s "$TEST_GH_CALLS" ]] || fail "the refused body fetch called gh: $(cat "$TEST_GH_CALLS")"
  [[ "$(grep -c 'pr body fetch cap reached cap=20' "$LOG")" == 1 ]] || fail "expected one cap line, log has: $(grep -c 'pr body fetch cap reached' "$LOG")"
  # (d) A empty: no body file is written
  (
    A=; TICK_PRS='[{"number":31,"updatedAt":"2026-11-22T03:00:00Z"}]'; TICK_PR_BODY_FETCHES=0; TICK_PR_BODY_LOADED=(); TICK_PR_BODY=()
    tick_pr_body 31 >/dev/null
  ) || fail 'a body read with A empty failed'
  ! compgen -G "$fixture/sup/autopi/.pr-body/31-*" >/dev/null || fail 'A empty wrote a body file'
  # (e) a failed census: one line with the stub's first stderr line, however often it is asked
  export TEST_GH_OPEN_FAIL=true; TICK_CENSUS_ERR_SAID=''
  tick_prs_changed; : > "$LOG"
  tick_prs >/dev/null 2>&1 && fail 'a refused census was read'
  tick_prs >/dev/null 2>&1 || true
  unset TEST_GH_OPEN_FAIL
  [[ "$(grep -c 'tick census read failed' "$LOG")" == 1 ]] || fail "expected one census error line, log has: $(cat "$LOG")"
  grep -Fq 'tick census read failed rc=1' "$LOG" || fail "the census error line lacks the refusal: $(cat "$LOG")"
}

case "${1:-all}" in
  census) test_census ;;
  body) test_body_cache ;;
  adopt) test_adopt ;;
  footprint) test_footprint ;;
  light) test_light_census ;;
  all) test_census; test_adopt; test_footprint; test_light_census; test_body_cache ;;
  *) fail "unknown test $1" ;;
esac
printf 'tick-census.test.sh: ok\n'
