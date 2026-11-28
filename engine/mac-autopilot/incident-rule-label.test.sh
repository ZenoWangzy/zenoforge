#!/usr/bin/env bash
# The implement report headings apply to every unit; the incident rule stays label-scoped.
set -euo pipefail
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/test-env.sh"

repo_root="$MAC_AUTOPILOT_ENV_ROOT"
HERE="$repo_root/engine/mac-autopilot"
queue_source="$HERE/scheduler.d/dispatch-queue.sh"
fixture="$test_env_root/incident-rule-label"
sup="$fixture/supervisor"
mkdir -p "$sup/autopi/alerts" "$fixture/repo"
jq '.auto_merge=false | .advisor=false | .precheck=false' "$HERE/config.template.json" > "$sup/autopi/config.json"
printf '%s\n' '{"units":[]}' > "$sup/autopi/units.json"
printf '%s\n' '{"workers":[]}' > "$sup/autopi/workers.json"
export MAC_AUTOPILOT_ROOT="$fixture/repo" MAC_AUTOPILOT_SUPERVISOR_DIR="$sup" MAC_AUTOPILOT_RUNTIME_DIR="$sup/autopi"
export REQUIRED_PR_CHECKS_FILE="$fixture/required-pr-checks.json"
printf '%s\n' '{"required":[],"current_regression":"","legacy_regression":[]}' > "$REQUIRED_PR_CHECKS_FILE"
export AUTOPI_TEST_LIBRARY_ONLY=true
source "$HERE/scheduler.sh"
unset AUTOPI_TEST_LIBRARY_ONLY

bug_unit='{"id":"incident-bug","issue":5389,"labels":["bug"]}'
plain_unit='{"id":"ordinary","issue":5390,"labels":["enhancement"]}'
line='This unit IS an incident unit: its label bug is in incident.labels, so every requirement below applies to your report.'
[[ "$(grep -cF '$(implement_report_sections)' "$queue_source" || true)" == 2 ]] \
  || { echo 'not ok - implement report sections are not included in both REPORT blocks' >&2; exit 1; }
declare -F implement_report_sections >/dev/null \
  || { echo 'not ok - implement report section helper is missing from the dispatch queue' >&2; exit 1; }
report_sections="$(implement_report_sections)"

flaky_method_rule='若找不到根因，则保留测试、记录失败证据并提交诊断工单；仅当已证明测试过时、不验证任何有效行为，或有具名等效测试覆盖时，才可删除。'
obsolete_flaky_method_rule='若找不到根因，则删除该测试'
actual_method_rule="$(matt_method_rule "$fixture/repo")"
[[ "$actual_method_rule" == *"$flaky_method_rule"* && "$actual_method_rule" != *"$obsolete_flaky_method_rule"* ]] \
  || { echo 'not ok - METHOD lacks the flaky-test diagnosis rule or still permits deleting a test for an unknown cause' >&2; exit 1; }

bug_prompt="$(incident_worker_prompt implement "$bug_unit" "$report_sections")"
escape_repo="$fixture/escape-repo"
escape_test='packages/fruit/tests/escape.test.mjs'
mkdir -p "$escape_repo/packages/fruit/tests"
: > "$escape_repo/$escape_test"
git -C "$escape_repo" init -q -b main
git -C "$escape_repo" config user.name fixture
git -C "$escape_repo" config user.email fixture@example.invalid
git -C "$escape_repo" add "$escape_test"
git -C "$escape_repo" commit -qm 'fixture escape test'
(
  cd "$escape_repo"
  node "$HERE/scheduler.d/escape-suite-register.mjs" \
    --repo "$escape_repo" \
    --package packages/fruit \
    --test "$escape_test" \
    -- node --test "$escape_test"
)
escape_registry="$escape_repo/.zenoforge/state/escape-suites.json"
grep -Fq -- "\"test\": \"$escape_test\"" "$escape_registry" \
  || { echo 'not ok - escape-suite-register did not register the test path' >&2; exit 1; }

escape_test_line='escape-test: <package>/<test>'
escape_register_cli='node engine/mac-autopilot/scheduler.d/escape-suite-register.mjs --repo <checkout> --package <pkg> --test <path> -- <argv>'
incident_rule="$(incident_rule_text)"
[[ "$incident_rule" == *"$escape_test_line"* && "$incident_rule" == *"$escape_register_cli"* \
  && "$bug_prompt" == *"$escape_test_line"* && "$bug_prompt" == *"$escape_register_cli"* ]] \
  || { echo 'not ok - incident implement prompt lacks the escape-test line or registration command' >&2; exit 1; }
contract_prompt="$(tr '\n' ' ' < "$repo_root/engine/prompts/implement-contract.md")"
[[ "$contract_prompt" == *'Under `## recurrence-guard`'* \
  && "$contract_prompt" == *'kind: <architecture|state|script|lint|test>'* \
  && "$contract_prompt" == *"$escape_test_line"* \
  && "$contract_prompt" == *"$escape_register_cli"* ]] \
  || { echo 'not ok - implement contract lacks the recurrence-guard escape-test instructions' >&2; exit 1; }
[[ "$bug_prompt" == *"$line"$'\nINCIDENT_RULE\n'* ]] \
  || { echo 'not ok - bug-labelled implement prompt lacks the matched-label line before INCIDENT_RULE' >&2; exit 1; }

plain_prompt="$(incident_worker_prompt implement "$plain_unit" "$report_sections")"
[[ "$plain_prompt" == "$report_sections" && "$plain_prompt" != *'INCIDENT_RULE'* ]] \
  || { echo 'not ok - non-incident implement prompt received the incident rule or lost its base prompt' >&2; exit 1; }

for section in '## how' '## why' '## decision-log'; do
  grep -Fxq -- "$section" <<<"$plain_prompt" \
    || { echo "not ok - ordinary implement prompt lacks gate-required $section" >&2; exit 1; }
done

direct_rule='Do not run any test file or test command. The engine runs tests after delivery. A refused test command is not a failure; finish the change and deliver.'
declare -F direct_main_worker_prompt >/dev/null \
  || { echo 'not ok - direct-main worker prompt helper is missing' >&2; exit 1; }
direct_implement_prompt="$(direct_main_worker_prompt 'GOAL: implement the direct-main change.' '{"lane":"direct-main"}')"
direct_repair_prompt="$(direct_main_worker_prompt 'GOAL: repair the direct-main change.' '{"lane":"direct-main"}')"
[[ "$direct_implement_prompt" == *"$direct_rule"* && "$direct_repair_prompt" == *"$direct_rule"* ]] \
  || { echo 'not ok - direct-main implement or repair prompt lacks the no-test/refusal instruction' >&2; exit 1; }
[[ "$(direct_main_worker_prompt 'GOAL: ordinary PR change.' '{"lane":"pr"}')" == 'GOAL: ordinary PR change.' ]] \
  || { echo 'not ok - direct-main test instruction leaked into a PR prompt' >&2; exit 1; }
[[ "$(grep -cF 'direct_main_worker_prompt "$prompt" "$u"' "$queue_source" || true)" == 2 ]] \
  || { echo 'not ok - direct-main prompt rule is not applied to both implement and repair assembly' >&2; exit 1; }
direct_feature_prompt="$(feature_verification_prompt direct-main 'pipeline scripts')"
[[ "$direct_feature_prompt" == *'Feature verification plan (direct-main): no product feature verification commands; the lander runs the tests.'* && "$direct_feature_prompt" != *'Run node scripts/e2e/'* ]] \
  || { echo 'not ok - direct-main implement prompt includes a product feature test command' >&2; exit 1; }

git -C "$ROOT" init -q -b main
git -C "$ROOT" -c user.name='Test' -c user.email='test@example.invalid' commit --allow-empty -qm 'prompt test base'
git -C "$ROOT" branch -f agent/issue-prompt-implement HEAD
git -C "$ROOT" branch -f agent/issue-prompt-repair HEAD
footprint_waiters_revalidate() { :; }
dispatch_live_prime() { :; }
tick_prs_changed() { :; }
dispatch_capacity_free() { return 0; }
tick_prs_prime() { :; }
dispatch_why_load() { :; }
advisor_harvest() { :; }
dispatch_order() { jq -c '.units[]' "$UNITS"; }
paused_midrun() { return 1; }
unit_blocked_run_dep() { return 1; }
token_spend_gate() { return 0; }
ticket_budget_reason() { :; }
loop_rounds() { printf '0\n'; }
dispatch_why() { :; }
pick() { PICK_MODEL=fixture; PICK_EFFORT=high; PICK_PROVIDER=codex; PICK_HARD=false; PICK_REASON=configured; PICK_ROUTE_PROVIDER=codex; }
room_for() { return 0; }
footprint_room() { return 0; }
repair_cap_admission() { :; }
park_if_body_blocked() { return 1; }
no_finding_repair_route() { return 1; }
ensure_clone() { printf '%s' "$ROOT"; }
resume_handoff_integration() { return 0; }
repair_failure_prompt() { printf 'fixture review findings'; }
matt_method_rule() { printf 'Method requirements.'; }
decision_scope() { :; }
sweep_rule() { :; }
supervisor_rule() { :; }
verification_plan_for_state() { printf '{}'; }
verification_plan_brief() { printf 'pipeline scripts'; }
subject_of() { printf 'fixture issue %s' "$2"; }
captured_type=''; captured_prompt=''; captured_head=''
dispatch_if_room() {
  captured_type="$3"; captured_prompt="$8"; captured_head="${9:-}"
  set_unit "$1" '.stage="review-pending"'
  return 0
}
SCHED_LOCK_HELD=true
jq -n '{units:[{id:"issue-prompt-implement",issue:901,task:"direct-main implementation",branch:"agent/issue-prompt-implement",stage:"implement-pending",lane:"direct-main",title:"prompt fixture",history:[]}]}' > "$UNITS"
dispatch_pending false >/dev/null
[[ "$captured_type" == implement && "$captured_prompt" == *"$direct_rule"* && "$captured_head" == "$(git -C "$ROOT" rev-parse --verify HEAD)" ]] \
  || { echo 'not ok - actual direct-main implement dispatch lacks the no-tests line or source head' >&2; exit 1; }
jq -n '{units:[{id:"issue-prompt-repair",issue:902,review_report:"review-902.md",branch:"agent/issue-prompt-repair",stage:"repair-pending",lane:"direct-main",title:"prompt fixture",history:[{stage:"review-request-changes"}]}]}' > "$UNITS"
dispatch_pending false >/dev/null
[[ "$captured_type" == repair && "$captured_prompt" == *"$direct_rule"* && "$captured_head" == "$(git -C "$ROOT" rev-parse --verify HEAD)" ]] \
  || { echo 'not ok - actual direct-main repair dispatch lacks the no-tests line or source head' >&2; exit 1; }

# 测试跑在哪：未配 runner 时 PR 实现 prompt 带本机测试库措辞；配了 .engine.test_exec 就改说经 runner，本机只跑 agent。
feature_verification_prompt() { :; }
priority_admission_has_room() { return 0; } # 本机负载不决定这个提示词测试的派发
git -C "$ROOT" branch -f agent/issue-prompt-pr-implement HEAD
git -C "$ROOT" branch -f agent/issue-prompt-pr-runner HEAD
jq -n '{units:[{id:"issue-prompt-pr-implement",issue:905,task:"pr implementation",branch:"agent/issue-prompt-pr-implement",stage:"implement-pending",lane:"pr",title:"prompt fixture",history:[]}]}' > "$UNITS"
dispatch_pending false >/dev/null
[[ "$captured_type" == implement && "$captured_prompt" == *"本地定向验证全绿；$INTEGRATION_RULE"* ]] \
  || { echo 'not ok - unconfigured pr implement prompt lost the local verification lead and integration rule' >&2; exit 1; }
(
  # 调度器启动路径：ZF_CONFIG_ROOT 与 ZF_TEST_EXEC 都没有时，apply_test_host_rules 在 set -e 下要返回 0（调度器走到调用之后的行），三个默认措辞原样。
  unset ZF_CONFIG_ROOT ZF_TEST_EXEC
  apply_test_host_rules
  [[ "$INTEGRATION_RULE" == *'本机测试库'* && "$VERIFY_LEAD_RULE" == '本地定向验证全绿；' && "$CI_REPRO_RULE" == *'RUN_INTEGRATION=1 npx vitest run'* ]] \
    || { echo 'not ok - no-config-root call did not keep the three default texts' >&2; exit 1; }
  git -C "$ROOT" branch -f agent/issue-prompt-pr-no-root HEAD
  jq -n '{units:[{id:"issue-prompt-pr-no-root",issue:907,task:"pr implementation",branch:"agent/issue-prompt-pr-no-root",stage:"implement-pending",lane:"pr",title:"prompt fixture",history:[]}]}' > "$UNITS"
  dispatch_pending false >/dev/null
  [[ "$captured_type" == implement && "$captured_prompt" == *"本地定向验证全绿；$INTEGRATION_RULE"* ]] \
    || { echo 'not ok - no-config-root implement prompt lost the local wording' >&2; exit 1; }
)
(
  runner_root="$fixture/runner-config"; mkdir -p "$runner_root"
  printf '%s\n' '{"engine":{"test_exec":"/stub/test-runner"}}' > "$runner_root/config.json"
  export ZF_CONFIG_ROOT="$runner_root"
  apply_test_host_rules
  jq -n '{units:[{id:"issue-prompt-pr-runner",issue:906,task:"pr implementation",branch:"agent/issue-prompt-pr-runner",stage:"implement-pending",lane:"pr",title:"prompt fixture",history:[]}]}' > "$UNITS"
  dispatch_pending false >/dev/null
  [[ "$captured_type" == implement && "$captured_prompt" == *'/stub/test-runner "$(git rev-parse --show-toplevel)" -- <命令>'* ]] \
    || { echo 'not ok - runner-configured pr implement prompt lacks the configured runner call shape' >&2; exit 1; }
  [[ "$captured_prompt" == *'本机只跑 agent'* && "$captured_prompt" == *'test host unavailable'* && "$INTEGRATION_RULE" == *'交给 PR 的 CI 验证'* ]] \
    || { echo 'not ok - runner-configured pr implement prompt lacks the agents-only or CI-verifies sentences' >&2; exit 1; }
  [[ "$captured_prompt" != *'RUN_INTEGRATION=1 npx vitest run'* && "$captured_prompt" != *'本机测试库'* && "$captured_prompt" != *'本地定向验证'* ]] \
    || { echo 'not ok - runner-configured pr implement prompt still runs tests on this host' >&2; exit 1; }
  [[ "$CI_REPRO_RULE" == *'不在本机复现'* && "$CI_REPRO_RULE" != *'RUN_INTEGRATION=1 npx vitest run'* && "$CI_REPRO_RULE" != *'本机测试库'* ]] \
    || { echo 'not ok - runner-configured repair hint still reproduces on this host' >&2; exit 1; }
)
(
  export ZF_TEST_EXEC=/env-wins/test-runner
  apply_test_host_rules
  [[ "$VERIFY_LEAD_RULE" == *'/env-wins/test-runner'* ]] \
    || { echo 'not ok - ZF_TEST_EXEC did not win over the configured runner' >&2; exit 1; }
)
grep -q '${CI_REPRO_RULE}' "$HERE/scheduler.d/ci-status.sh" && grep -q '${CI_REPRO_RULE}' "$HERE/scheduler.d/merge-lane.sh" \
  || { echo 'not ok - ci repair hints no longer interpolate the shared reproduction rule' >&2; exit 1; }

# A direct-main unit still dispatches if its mocked worktree has no readable HEAD.
missing_head_root="$fixture/no-head-worktree"
mkdir -p "$missing_head_root"
missing_head_ensure_clone="$(declare -f ensure_clone)"
ensure_clone() { printf '%s' "$missing_head_root"; }
for missing_head_work in implement repair; do
  case "$missing_head_work" in
    implement)
      jq -n '{units:[{id:"issue-prompt-implement-no-head",issue:903,task:"direct-main implementation",branch:"agent/issue-prompt-implement",stage:"implement-pending",lane:"direct-main",title:"prompt fixture",history:[]}]}' > "$UNITS"
      ;;
    repair)
      jq -n '{units:[{id:"issue-prompt-repair-no-head",issue:904,review_report:"review-904.md",branch:"agent/issue-prompt-repair",stage:"repair-pending",lane:"direct-main",title:"prompt fixture",history:[{stage:"review-request-changes"}]}]}' > "$UNITS"
      ;;
  esac
  captured_type=''; captured_head='missing-dispatch'
  dispatch_pending false >/dev/null
  [[ "$captured_type" == "$missing_head_work" && -z "$captured_head" && "$(jq -r '.units[0].stage' "$UNITS")" == review-pending ]] \
    || { echo "not ok - direct-main $missing_head_work dispatch stalled when the worktree HEAD was unavailable" >&2; exit 1; }
done
eval "$missing_head_ensure_clone"
missing_head_sha="$(direct_main_worker_head "$missing_head_root")" \
  || { echo 'not ok - missing direct-main worktree HEAD did not fall back successfully' >&2; exit 1; }
[[ -z "$missing_head_sha" ]] \
  || { echo "not ok - missing direct-main worktree HEAD was not empty: $missing_head_sha" >&2; exit 1; }

two_labels="$(incident_match_line '{"labels":[{"name":"bug"},{"name":"incident"},{"name":"enhancement"}]}' '["bug","incident","production-anomaly"]')"
[[ "$two_labels" == 'This unit IS an incident unit: its label bug, incident is in incident.labels, so every requirement below applies to your report.' ]] \
  || { echo "not ok - two matched labels are not named comma-separated: $two_labels" >&2; exit 1; }

echo 'ok - implement report headings reach ordinary workers and incident rule names matched labels only'
