# Focused policy tests run one admission stage with a fresh per-call cancellation ledger.
# 一拍内的 run/job 快照在准入各阶段间共享（8ca4eceaa）：每次聚焦调用先清缓存重新取；
# 夹具预置的 TICK_UNFINISHED 就是一份完整快照（含 in_progress，各阶段不再单独回读 gh）。
ci_tick_reset() {
  CI_RUN_JOBS_CACHE=()
  GATED_CENSUS_LOADED=false
  TICK_UNFINISHED_LOADED=false
  TICK_UNFINISHED_IN_PROGRESS_OK=false
  TICK_UNFINISHED_ALL_OK=false
  if [[ -n "${TICK_UNFINISHED:-}" ]]; then
    TICK_UNFINISHED_LOADED=true; TICK_UNFINISHED_IN_PROGRESS_OK=true; TICK_UNFINISHED_ALL_OK=true
  fi
  return 0
}
ci_wip_gate_test() { local CI_HOTFIX_BRANCHES='[]'; local -A CI_ADMISSION_CANCELLED=(); ci_tick_reset; ci_assign_wip; }
ci_admission_test() { ci_tick_reset; ci_admission; }
ci_defer_ci_test() { local CI_HOTFIX_BRANCHES='[]'; local -A CI_ADMISSION_CANCELLED=(); ci_tick_reset; ci_defer_unapproved; }
ci_defer_classified_test() {
  local CI_HOTFIX_BRANCHES
  local -A CI_ADMISSION_CANCELLED=()
  CI_HOTFIX_BRANCHES="$(ci_hotfix_branches)" || CI_HOTFIX_BRANCHES='[]'
  ci_tick_reset
  ci_defer_unapproved
}

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
fixture="$test_env_root/gates"
sup="$fixture/supervisor"
mkdir -p "$sup/autopi/alerts" "$fixture/repo"
# Scheduler helpers may inspect the configured checkout against origin/main.
# GitHub's shallow test checkout may not have that remote-tracking ref, so give
# the isolated fixture a stable base instead of letting unrelated lane checks
# read the host checkout's incomplete refs.
command git -C "$fixture/repo" init -q -b main
command git -C "$fixture/repo" -c user.name=fixture -c user.email=fixture@example.invalid commit --allow-empty -qm base
command git -C "$fixture/repo" update-ref refs/remotes/origin/main "$(command git -C "$fixture/repo" rev-parse HEAD)"
# Repair now reads the failure itself, rather than sending just its path.
printf 'VERDICT: REQUEST-CHANGES\nNew review failure\n' > "$sup/r.md"
printf 'VERDICT: REQUEST-CHANGES\nNew review failure\n' > "$sup/review-14.md"
# 顾问与本机预检默认开；各自的用例里显式打开，其余用例按原状态机断言
jq '.auto_merge = true | .advisor = false | .precheck = false' "$script_dir/config.template.json" > "$sup/autopi/config.json"
echo '{"units":[]}' > "$sup/autopi/units.json"
echo '{"workers":[]}' > "$sup/autopi/workers.json"
export MAC_AUTOPILOT_ROOT="$fixture/repo" MAC_AUTOPILOT_SUPERVISOR_DIR="$sup" MAC_AUTOPILOT_RUNTIME_DIR="$sup/autopi"
# 本套件在本机跑时也会撞到生产 luna-slots 路径：指向 fixture，隔离在用的门。
export LUNA_SLOTS="$fixture/luna-slots"; mkdir -p "$LUNA_SLOTS"
export CODEX_SESSIONS_DIR="$fixture/sessions"
export ZF_TEST_EVIDENCE_LEDGER="$sup/test-evidence.jsonl"
# Existing state-machine fixtures intentionally use synthetic check names. The scheduler must select this target override.
mkdir -p "$fixture/repo/.zenoforge/mac-autopilot"
export REQUIRED_PR_CHECKS_FILE="$fixture/repo/.zenoforge/mac-autopilot/required-pr-checks.json"
printf '%s\n' '{"required":[],"current_regression":"","legacy_regression":[]}' > "$REQUIRED_PR_CHECKS_FILE"
unset REQUIRED_PR_CHECKS_FILE
export AUTOPI_TEST_LIBRARY_ONLY=true
source "$script_dir/scheduler.sh"
[[ "$REQUIRED_PR_CHECKS_FILE" == "$fixture/repo/.zenoforge/mac-autopilot/required-pr-checks.json" ]] || {
  echo 'scheduler-gates.test.sh: target required checks override did not win' >&2
  exit 1
}
ensure_clone_source="$(declare -f ensure_clone)"
checkout_pr_head_source="$(declare -f checkout_pr_head)"
unset AUTOPI_TEST_LIBRARY_ONLY
# Gate orchestration has a real-tree fixture in scheduler-self-check.test.sh.
self_check_before_review() { return 0; }
# Scheduler gate cases use synthetic SHAs without real diffs; this fixture
# models them as changes that do not affect prompt-evaluation stages.
decision_eval_stages() { printf '\n'; }
# A real tick caches the open-PR census and drops it when the scheduler changes a PR; these fixtures edit the PR table between calls, so every read starts empty.
tick_prs_real_def="$(declare -f tick_prs)"; eval "${tick_prs_real_def/tick_prs ()/tick_prs_real ()}"
tick_prs() { TICK_PRS=""; tick_prs_real; }
# The reproduction worker is detached and slow; the older red-main fixtures below do not exercise it.
main_red_real="$(declare -f main_red_attribution)"
main_red_attribution() { MAIN_RED_REVERTED=0; MAIN_RED_PENDING=0; }
# This suite tests scheduler gates and state transitions; reviewer-family
# availability is covered by review-family.test.sh.
pick_review_for_unit() { PICK_MODEL="GLM-5.3"; PICK_EFFORT=max; return 0; }
