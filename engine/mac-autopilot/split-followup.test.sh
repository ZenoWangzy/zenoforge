#!/usr/bin/env bash
# A split follow-up stays out of its parent's children, so the parent can reach awaiting-release.
set -euo pipefail
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/test-env.sh"

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
fixture="$test_env_root/split-followup"
sup="$fixture/supervisor"
mkdir -p "$sup/autopi/alerts" "$fixture/repo/engine/prompts" "$fixture/bin"
export ZF_ROADMAP_TREE_CACHE_FILE="$fixture/roadmap-tree.json"
jq -cn '{roots:[]}' > "$ZF_ROADMAP_TREE_CACHE_FILE"
jq '.auto_merge = false | .advisor = false | .precheck = false | .supervisor_arbiter.enabled = true' "$script_dir/config.template.json" > "$sup/autopi/config.json"
echo '{"units":[]}' > "$sup/autopi/units.json"
echo '{"workers":[]}' > "$sup/autopi/workers.json"
export MAC_AUTOPILOT_ROOT="$fixture/repo" MAC_AUTOPILOT_SUPERVISOR_DIR="$sup" MAC_AUTOPILOT_RUNTIME_DIR="$sup/autopi"
export ZF_CONFIG_ROOT="$fixture/repo/.zenoforge"
mkdir -p "$ZF_CONFIG_ROOT/prompts"
cp "$script_dir/../prompts/supervisor-arbiter.md" "$ZF_CONFIG_ROOT/prompts/supervisor-arbiter.md"
cp "$script_dir/../prompts/review-contract.md" "$ZF_CONFIG_ROOT/prompts/review-contract.md"
cp "$script_dir/../prompts/supervisor-arbiter.md" "$fixture/repo/engine/prompts/supervisor-arbiter.md"
export CODEX_SESSIONS_DIR="$fixture/sessions"
export REQUIRED_PR_CHECKS_FILE="$fixture/required-pr-checks.json"
printf '%s\n' '{"required":[],"current_regression":"","legacy_regression":[]}' > "$REQUIRED_PR_CHECKS_FILE"
export AUTOPI_TEST_LIBRARY_ONLY=true
source "$script_dir/scheduler.sh"
unset AUTOPI_TEST_LIBRARY_ONLY

fail() { echo "split-followup.test.sh: $*" >&2; exit 1; }
printf '%s\n' '{"units":[{"id":"issue-40","issue":40,"title":"t","stage":"review","history":[]}]}' > "$UNITS"
printf 'slice report\n' > "$fixture/report"
created="$fixture/created"
gh() {
  case "$1 $2" in
    "api repos/{owner}/{repo}/issues/40/parent") printf '%s' "${PARENT_OF_40:-}"; [[ -n "${PARENT_OF_40:-}" ]] ;;
    "issue create") printf '%s\n' "$*" > "$created"; echo "https://github.com/o/r/issues/41" ;;
    *) return 1 ;;
  esac
}
PARENT_OF_40=7 split_followup_issue issue-40 40 50 'SPLIT: the rest' "$fixture/report"
grep -q -- '--parent 7' "$created" || fail "the follow-up must be the parent's sibling ($(cat "$created"))"
! grep -q -- '--parent 40' "$created" || fail "an open child would make the parent a container"
[[ "$(jqf -r '.units[0].split_followup' "$UNITS")" == 41 ]] || fail "the follow-up number was not recorded"
PARENT_OF_40= split_followup_issue issue-40 40 50 'SPLIT: the rest' "$fixture/report"
! grep -q -- '--parent' "$created" || fail "a top-level parent has no parent to share"
echo "split-followup.test.sh: all assertions passed"
