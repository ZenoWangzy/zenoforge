#!/usr/bin/env bash
set -euo pipefail
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/test-env.sh"
source "$(dirname -- "${BASH_SOURCE[0]}")/test-scheduler-gates-fixture.sh"
fail() { echo "scheduler-gates.test.sh: $*" >&2; exit 1; }
units() { printf '%s\n' "$1" > "$UNITS"; echo '{"workers":[]}' > "$WORKERS"; }
field() { jq -r --arg id "$1" ".units[] | select(.id==\$id) | $2" "$UNITS"; }
H1=1111111111111111111111111111111111111111
H2=2222222222222222222222222222222222222222
M1=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
M2=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
M3=cccccccccccccccccccccccccccccccccccccccc
source "$script_dir/test-scheduler-gates-gh-fixture.sh"
MAIN_HEAD="$M1"
gate_eval_sha() { printf '%s' "$M1"; }
git() {
  if [[ " $* " == *" ls-remote "* ]]; then printf '%s\trefs/heads/main\n' "$MAIN_HEAD"
  elif [[ "${1:-}" == -C && "${3:-}" == fetch && ( "${!#}" == refs/pull/*/head || "${!#}" == +refs/pull/*/head:refs/autopi/merge-candidates/* ) ]]; then return 0
  elif [[ "${1:-}" == -C && "${3:-}" == rev-parse && ( "${5:-}" == FETCH_HEAD* || "${5:-}" == refs/autopi/merge-candidates/* ) ]]; then echo "$GH_HEAD"
  else command git "$@"; fi
}
mkdir -p "$ROOT/engine"
printf '#!/usr/bin/env bash\nprintf "rule-lane: decision=pass actor=unit touched=0\\n"\n' > "$ROOT/engine/rule-lane.sh"
GH_RUNS="[{\"headSha\":\"$M1\",\"conclusion\":\"success\",\"status\":\"completed\",\"createdAt\":\"2026-10-19T00:00:00Z\",\"databaseId\":7}]"
GH_MERGE_SHA="$M2"
ensure_clone() { printf '%s' "$fixture/wt-$1"; }
checkout_pr_head() { :; }
alive() { [[ " ${ALIVE_PIDS:-} " == *" $1 "* ]]; }
gh_merge_stub="$(declare -f gh)"
# L77：PR CI 名额不再是配置的 ci_wip，而是在线 PR runner 减去这些 runner 上在跑的 job（60ba960cf）。
# 等名额的单元（.ci_wip_wait 绑定 head）按 main-red > opt > normal、同级 ready_since 补进空槽，
# 只补被取消的 job；热修不占名额。没等到名额的排队 run 取消并留在 .ci_wip_wait；
# 等名额的单元只有取消、没有失败时合并车道不重启；名额空出后按就绪先后补跑被取消的 job。
wr="$fixture/wip-root"; mkdir -p "$wr/engine/night"
printf '#!/usr/bin/env bash\necho "$2" >> "%s/cancelled"\necho "${ZF_CANCEL_REASON-unset}" >> "%s/reasons"\n' "$wr" "$wr" > "$wr/engine/night/main-ci-recovery.sh"
CFG_SAVED="$CFG"; CFG="$(jq '.precheck=false' <<<"$CFG")"; GH_RERUNS=()
# 默认 runner 桩：1 个在线 PR runner、无在跑 job → 1 个空槽
units "{\"units\":[{\"id\":\"pr-30\",\"pr\":30,\"stage\":\"ready-to-merge\",\"branch\":\"a\",\"approved_sha\":\"$H2\",\"ci_adopt_head\":\"$H2\",\"ci_adopt_at\":\"2026-10-29T00:00:00Z\",\"ci_wip_wait\":\"$H2\",\"ready_since\":1,\"history\":[]},{\"id\":\"pr-31\",\"pr\":31,\"stage\":\"ready-to-merge\",\"branch\":\"b\",\"approved_sha\":\"$H1\",\"ci_adopt_head\":\"$H1\",\"ci_adopt_at\":\"2026-10-29T00:00:00Z\",\"ci_wip_wait\":\"$H1\",\"ready_since\":2,\"history\":[]},{\"id\":\"pr-32\",\"pr\":32,\"stage\":\"ready-to-merge\",\"hotpatch\":true,\"branch\":\"hp\",\"approved_sha\":\"$H2\",\"ci_adopt_head\":\"$H2\",\"ci_adopt_at\":\"2026-10-29T00:00:00Z\",\"ready_since\":3,\"history\":[]}]}"
TICK_UNFINISHED="[{\"databaseId\":81,\"status\":\"queued\",\"event\":\"pull_request\",\"headBranch\":\"b\"},{\"databaseId\":83,\"status\":\"queued\",\"event\":\"pull_request\",\"headBranch\":\"hp\"}]"
GH_RUN_JSON='[{"databaseId":82,"conclusion":"cancelled"}]'
root_saved="$ROOT"; ROOT="$wr"; ci_wip_gate_test; ROOT="$root_saved"
[[ "$(field pr-30 '.history[-1].stage'):$(field pr-30 '.history[-1].result')" == "ci-wip-start:slot 1/1" \
  && "${GH_RERUNS[*]:-}" == "run rerun 82 --failed" && "$(field pr-30 '.ci_wip_wait // "none"')" == none ]] \
  || fail "the oldest waiting unit did not take the free runner slot (${GH_RERUNS[*]:-none})"
[[ "$(cat "$wr/cancelled" 2>/dev/null)" == 81 && "$(field pr-31 .ci_wip_wait)" == "$H1" && "$(field pr-32 '.ci_wip_wait // "none"')" == none ]] \
  || fail "WIP gate held the wrong runs ($(tr '\n' ' ' < "$wr/cancelled" 2>/dev/null))"
[[ "$(sort -u "$wr/reasons")" == "ci wip" ]] || fail "WIP gate cancel did not carry its reason ($(tr '\n' ',' < "$wr/reasons"))"
grep -q 'ci wip: 1 free PR runner slot(s)' "$LOG" || fail 'slot count was not sized from the online PR runners'
GH_CHECKS='[{"name":"suites","bucket":"cancel"}]'
run_merge_lane || :
grep -q 'merge skipped PR#31 (CI waits for a WIP slot)' "$LOG" && [[ "$(field pr-31 '.ci_cancel_reruns // 0')" == 0 ]] || fail 'merge lane restarted CI of a unit waiting for a WIP slot'
draft_saved_units="$(cat "$UNITS")"; draft_saved_workers="$(cat "$WORKERS")"
(
  GH_PR_TABLE="$fixture/draft-approval.json"; echo '[]' > "$GH_PR_TABLE"
  GH_HEAD="$H2"; approval_carries() { return 1; }
  gh_pr_open 86 "$H2" true MERGEABLE agent/issue-86 '[]'
  units "$(jq -cn --arg approved "$H1" '{units:[{id:"draft-stale",pr:86,branch:"agent/issue-86",stage:"ready-to-merge",approved_sha:$approved,gated:true,history:[]}]}' )"
  tick_prs_changed; GH_MERGES=(); : > "$LOG"
  run_merge_lane || :
  [[ "$(field draft-stale .stage)" == rereview-pending \
    && "$(field draft-stale '.history[-1].stage')" == approval-stale \
    && ${#GH_MERGES[@]} == 0 ]] || fail 'a draft with a stale, non-carried approval did not return to rereview after one pass'

  echo '[]' > "$GH_PR_TABLE"; gh_pr_open 86 "$H1" true MERGEABLE agent/issue-86 '[]'
  GH_HEAD="$H1"
  units "$(jq -cn --arg approved "$H1" '{units:[{id:"draft-current",pr:86,branch:"agent/issue-86",stage:"ready-to-merge",approved_sha:$approved,gated:true,history:[]}]}' )"
  tick_prs_changed; GH_MERGES=(); : > "$LOG"
  run_merge_lane || :
  [[ "$(field draft-current .stage)" == ready-to-merge && ${#GH_MERGES[@]} == 0 ]] \
    || fail 'a draft approved at its current head did not remain ready while waiting for its CI slot'
  grep -Fq 'merge skipped PR#86 (draft, waiting for its CI slot)' "$LOG" \
    || fail 'a draft approved at its current head did not log the CI slot wait'
)
printf '%s\n' "$draft_saved_units" > "$UNITS"; printf '%s\n' "$draft_saved_workers" > "$WORKERS"
set_unit pr-30 '.stage="merged"'; set_unit pr-31 '.ci_cancel_reruns=2'; TICK_UNFINISHED='[]'; GH_RERUNS=()
GH_RUN_JSON='[{"databaseId":99,"conclusion":"cancelled"}]'
root_saved="$ROOT"; ROOT="$wr"; ci_wip_gate_test; ROOT="$root_saved"
[[ "${GH_RERUNS[*]:-}" == *"rerun 99 --failed"* && "$(field pr-31 '.ci_wip_wait // "none"')" == none ]] || fail "freed runner slot did not start the next unit's CI (${GH_RERUNS[*]:-none})"
[[ "$(field pr-31 '.ci_cancel_reruns // "none"')" == none ]] || fail 'WIP start kept the cancel-restart count from the WIP wait (L78)'
# 非产品 PR 不排 CI 名额；同级先按 ready_since，依赖只在 readiness 相同时作 tie-break（maintainer 10-22：非产品尽快）
CFG="$(jq '.precheck=false' <<<"$CFG_SAVED")"; : > "$wr/cancelled"; GH_RUN_JSON='[]'
units "{\"units\":[{\"id\":\"pr-40\",\"pr\":40,\"stage\":\"ready-to-merge\",\"branch\":\"c\",\"approved_sha\":\"$H1\",\"ci_wip_wait\":\"$H1\",\"ready_since\":1,\"history\":[]},{\"id\":\"pr-41\",\"pr\":41,\"stage\":\"ready-to-merge\",\"branch\":\"agent/issue-77\",\"approved_sha\":\"$H1\",\"ci_wip_wait\":\"$H1\",\"ready_since\":2,\"history\":[]},{\"id\":\"pr-42\",\"pr\":42,\"stage\":\"ready-to-merge\",\"branch\":\"ci/x\",\"approved_sha\":\"$H1\",\"ready_since\":0,\"history\":[]},{\"id\":\"issue-78\",\"issue\":78,\"stage\":\"blocked-external\",\"blocked_on\":77,\"history\":[]}]}"
gh() {
  if [[ "$1 $2" == "api graphql" ]]; then
    printf '%s\n' '{"data":{"repository":{"pr_40":{"files":{"nodes":[{"path":"packages/shared/a.ts"},{"path":"scripts/b.sh"}]}},"pr_42":{"files":{"nodes":[{"path":".github/workflows/ci.yml"},{"path":"scripts/agent/x.sh"},{"path":"README.md"}]}}}}}'
  elif [[ "$1 $2" == "pr view" && "$*" == *files* ]]; then
    case "$3" in 42) printf '.github/workflows/ci.yml\nscripts/agent/x.sh\nREADME.md\n' ;; *) printf 'packages/shared/a.ts\nscripts/b.sh\n' ;; esac
  else
    eval "${gh_merge_stub/gh ()/gh_m ()}"; gh_m "$@"
  fi
}
TICK_UNFINISHED="[{\"databaseId\":91,\"status\":\"queued\",\"event\":\"pull_request\",\"headBranch\":\"c\"},{\"databaseId\":92,\"status\":\"queued\",\"event\":\"pull_request\",\"headBranch\":\"agent/issue-77\"},{\"databaseId\":93,\"status\":\"queued\",\"event\":\"pull_request\",\"headBranch\":\"ci/x\"}]"
root_saved="$ROOT"; ROOT="$wr"; GH_REPO=fixture-org/fixture-repo ci_wip_gate_test; ROOT="$root_saved"
[[ "$(field pr-42 .product_paths):$(field pr-40 .product_paths)" == "false:true" ]] || fail "product paths not classified ($(field pr-42 .product_paths) $(field pr-40 .product_paths))"
[[ "$(field pr-40 '.history[-1].stage')" == ci-wip-start && "$(field pr-40 '.ci_wip_wait // "none"')" == none ]] \
  || fail "the free slot did not follow same-class readiness ($(field pr-40 '.history[-1].stage // "none"'))"
[[ "$(cat "$wr/cancelled")" == 92 && "$(field pr-41 .ci_wip_wait)" == "$H1" && "$(field pr-42 '.ci_wip_wait // "none"')" == none ]] \
  || fail "the next waiting unit's queued run was not cancelled or a non-product PR waited ($(tr '\n' ' ' < "$wr/cancelled"))"
GH_RUN_JSON=
# 本机预检：等名额的单元先在本机跑 PR 自己改动的测试；FAIL 直接返工、不占 CI 名额，PASS 才开始 CI（10-22 批准后 CI 红 14/14 在 PR 自己改的测试里）
CFG="$(jq '.precheck=true' <<<"$CFG_SAVED")"; GH_RERUNS=(); TICK_UNFINISHED='[]'; ALIVE_PIDS=""; mkdir -p "$fixture/wt-precheck"
wait_precheck_output() {
  local id="$1" attempt
  for ((attempt=0; attempt<50; attempt++)); do
    [[ -s "$SUP/precheck-pr-$id.out" ]] && return 0
    sleep 0.1
  done
  fail "precheck $id did not write a result"
}
units "{\"units\":[{\"id\":\"pr-50\",\"pr\":50,\"stage\":\"ready-to-merge\",\"branch\":\"p50\",\"approved_sha\":\"$H1\",\"ci_wip_wait\":\"$H1\",\"ready_since\":1,\"history\":[]},{\"id\":\"pr-51\",\"pr\":51,\"stage\":\"ready-to-merge\",\"branch\":\"p51\",\"approved_sha\":\"$H2\",\"ci_wip_wait\":\"$H2\",\"ready_since\":2,\"history\":[]}]}"
here_saved="$HERE"; HERE="$fixture/precheck-code"; mkdir -p "$HERE"
printf '#!/usr/bin/env bash\ncase "$2" in 50) printf "PRECHECK: FAIL changed tests fail locally in packages/x\\n FAIL  tests/a.test.ts > keeps totals\\n" ;; *) echo "PRECHECK: PASS changed tests pass locally in packages/y" ;; esac\n' > "$HERE/precheck.sh"
gh() { if [[ "$1 $2" == "pr view" && "$*" == *files* ]]; then echo packages/x/a.ts; elif [[ "$*" == "run list --commit"*"select(.conclusion"* ]]; then echo 99; else eval "${gh_merge_stub/gh ()/gh_m ()}"; gh_m "$@"; fi; }
root_saved="$ROOT"; ROOT="$wr"; ci_wip_gate_test; ROOT="$root_saved"
p50="$(field pr-50 '.precheck_pid // "none"')"
[[ "$p50" != none && "$(field pr-51 '.precheck_pid // "none"')" == none && "${GH_RERUNS[*]:-}" != *rerun* ]] || fail "unprechecked unit got a CI slot or prechecks ran in parallel (${GH_RERUNS[*]:-none})"
wait "$p50" 2>/dev/null || :
wait_precheck_output 50
root_saved="$ROOT"; ROOT="$wr"; ci_wip_gate_test; ROOT="$root_saved"
[[ "$(field pr-50 .stage):$(field pr-50 '.approved_sha // "none"'):$(field pr-50 '.ci_wip_wait // "none"')" == "repair-pending:none:none" && "$(field pr-50 .repair_hint)" == *"keeps totals"* ]] \
  || fail "local precheck failure did not go straight to repair with the failing test ($(field pr-50 .stage))"
p51="$(field pr-51 '.precheck_pid // "none"')"; [[ "$p51" != none ]] || fail 'next waiting unit was not prechecked'
wait "$p51" 2>/dev/null || :
wait_precheck_output 51
root_saved="$ROOT"; ROOT="$wr"; ci_wip_gate_test; ROOT="$root_saved"
[[ "$(field pr-51 .precheck_sha)" == "$H2" && "$(field pr-51 '.ci_wip_wait // "none"')" == none && "${GH_RERUNS[*]:-}" == *"rerun 99 --failed"* ]] \
  || fail "passing precheck did not start the unit's CI ($(field pr-51 '.ci_wip_wait // "none"') ${GH_RERUNS[*]:-none})"
# 名额按 runner busy 折算（6adc3ba00）：两个在线 PR runner，run 60 的 job 占着 runner 1
# （busy=true）；runner 3（cihost-ci-main）不是 PR 池不参与，另一个 job 在它上面也不占 PR 名额 → 1 个空槽。
# GH_RUN_JOBS 仍供取消判定读取。
GH_RUNNERS='{"runners":[{"id":1,"status":"online","busy":true,"labels":[{"name":"cihost-ci"}]},{"id":2,"status":"online","busy":false,"labels":[{"name":"vecta-suites"}]},{"id":3,"status":"online","busy":true,"labels":[{"name":"cihost-ci-main"}]},{"id":4,"status":"offline","busy":false,"labels":[{"name":"cihost-ci"}]}]}'
GH_RUN_JOBS='{"60":{"jobs":[{"status":"in_progress","runner_id":1},{"status":"in_progress","runner_id":3}]}}'
: > "$wr/cancelled"
units "{\"units\":[{\"id\":\"pr-52\",\"pr\":52,\"stage\":\"ready-to-merge\",\"branch\":\"p52\",\"approved_sha\":\"$H1\",\"precheck_sha\":\"$H1\",\"ready_since\":1,\"history\":[]},{\"id\":\"pr-53\",\"pr\":53,\"stage\":\"ready-to-merge\",\"branch\":\"p53\",\"approved_sha\":\"$H2\",\"ci_wip_wait\":\"$H2\",\"ready_since\":2,\"history\":[]}]}"
TICK_UNFINISHED="[{\"databaseId\":60,\"status\":\"in_progress\",\"event\":\"pull_request\",\"headBranch\":\"p52\",\"headSha\":\"$H1\"},{\"databaseId\":61,\"status\":\"queued\",\"event\":\"pull_request\",\"headBranch\":\"p53\"}]"
root_saved="$ROOT"; ROOT="$wr"; ci_wip_gate_test; ROOT="$root_saved"
p53="$(field pr-53 '.precheck_pid // "none"')"
[[ "$p53" != none && "$(field pr-52 '.precheck_pid // "none"')" == none ]] || fail 'queued unit was not prechecked ahead of its CI slot'
[[ "$(field pr-53 .ci_wip_wait)" == "$H2" && "$(cat "$wr/cancelled" 2>/dev/null)" == 61 ]] \
  || fail "the busy runner slot did not keep the next unit waiting ($(tr '\n' ' ' < "$wr/cancelled" 2>/dev/null))"
wait "$p53" 2>/dev/null || :
wait_precheck_output 53
# 预检 PASS 后：1 个空槽（2 runner − 1 在跑 job）正好放行 pr-53；slot 1/1 钉住名额算术
root_saved="$ROOT"; ROOT="$wr"; ci_wip_gate_test; ROOT="$root_saved"
[[ "$(field pr-53 '.history[-1].stage'):$(field pr-53 '.history[-1].result')" == "ci-wip-start:slot 1/1" ]] \
  || fail "a freed runner slot did not start the prechecked waiting unit ($(field pr-53 '.history[-1].stage // "none"'):$(field pr-53 '.history[-1].result // "none"'))"
GH_RUNNERS='{"runners":[{"id":1,"status":"online","labels":[{"name":"cihost-ci"}]},{"id":2,"status":"offline","labels":[{"name":"cihost-ci"}]},{"id":3,"status":"online","labels":[{"name":"cihost-ci-main"}]}]}'; GH_RUN_JOBS='{}'
rm -f "$HERE/precheck.sh"; HERE="$here_saved"
CFG="$CFG_SAVED"; TICK_UNFINISHED=""; GH_RERUNS=()
units '{"units":[]}'; : > "$LOG"; TICK_UNFINISHED='[]'
root_saved="$ROOT"; ROOT="$wr"; ci_wip_gate_test; ROOT="$root_saved"
grep -q 'ci wip: [0-9]* free PR runner slot(s); 0 ready unit(s) wait for a CI slot (cancelled 0 queued run(s)); started 0; gated ready 0' "$LOG" \
  || fail 'an idle admission pass left no free-slot line'
echo 'scheduler-gates-ci-slots.test.sh: PASS'
