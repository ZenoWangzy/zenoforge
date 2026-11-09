#!/usr/bin/env bash
# 2026-11-08 #5937 (unit issue-5306): to_supervisor cancelled the PR's runs as the PR opened; the unit went
# supervisor-review -> repair -> parked on the same head and no CI path ever reran it (~3 h, head did it by hand).
# Replays that state through ci_admission: the stale all-cancelled head must raise one CI-CANCELLED-STALE alert.
set -euo pipefail
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)/test-env.sh"
script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
engine_dir="$(cd -- "$script_dir/../.." && pwd -P)"

fixture="$test_env_root/ci-cancel-stale"
supervisor="$fixture/supervisor"
mkdir -p "$supervisor/autopi/alerts" "$fixture/repo"
export MAC_AUTOPILOT_ROOT="$fixture/repo" MAC_AUTOPILOT_SUPERVISOR_DIR="$supervisor" \
  MAC_AUTOPILOT_RUNTIME_DIR="$supervisor/autopi" REQUIRED_PR_CHECKS_FILE="$fixture/required-pr-checks.json"
printf '%s\n' '{"required":[],"current_regression":"","legacy_regression":[]}' > "$REQUIRED_PR_CHECKS_FILE"
jq '.precheck = false | .hotfix_lane = {"label":"hotfix","branch_prefixes":[]}' \
  "$engine_dir/mac-autopilot/config.template.json" > "$supervisor/autopi/config.json"
echo '{"units":[]}' > "$supervisor/autopi/units.json"
echo '{"workers":[]}' > "$supervisor/autopi/workers.json"
export AUTOPI_TEST_LIBRARY_ONLY=true
source "$engine_dir/mac-autopilot/scheduler.sh"
unset AUTOPI_TEST_LIBRARY_ONLY

fail() { echo "ci-cancel-stale.test.sh: $*" >&2; [[ -z "${LOG:-}" ]] || tail -n 15 "$LOG" >&2; exit 1; }
head5937=28ba332a77e9bd53dcf211675b56c89e30133064
now="$(date -u +%s)"
iso() { date -u -d "@$1" +%Y-%m-%dT%H:%M:%SZ; }

# $1 = stage of unit issue-5306, $2 = minutes since the runs ended, $3 = conclusion of the CI run
cancel_fixture() {
  td="$test_env_root/cancel-$1-$2-$3"; rm -rf "$td"; mkdir -p "$td/alerts"
  A="$td"; LOG="$td/scheduler.log"; : > "$LOG"; UNITS="$td/units.json"; WORKERS="$td/workers.json"
  STAMP="$(iso "$now")"; SCHED_LOCK_HELD=true;   TICK_PRS="[{\"number\":5937,\"headRefName\":\"agent/issue-5306\",\"headRefOid\":\"$head5937\",\"isDraft\":true,\"labels\":[],\"body\":\"\",\"baseRefName\":\"main\"}]"
  TICK_PR_CHECK_CENSUS=''; TICK_HOTFIX_ISSUES_LOADED=true; TICK_HOTFIX_ISSUES='[]'
  GATED_OF=(); GATED_SLOT=(); READIED_PRS=(); SLOT_SYNC_CARRIED_HEAD=""; SLOT_SYNC_SPENT=0
  command jq -cn --arg s "$1" '{units:[{id:"issue-5306",pr:5937,branch:"agent/issue-5306",lane:"pr",stage:$s,history:[]}]}' > "$UNITS"
  echo '{"workers":[]}' > "$WORKERS"
  fx_ended="$(iso $((now - $2 * 60)))"
  fx_runs="[{\"conclusion\":\"$3\",\"event\":\"pull_request\",\"updatedAt\":\"$fx_ended\"},{\"conclusion\":\"cancelled\",\"event\":\"pull_request\",\"updatedAt\":\"$fx_ended\"},{\"conclusion\":\"skipped\",\"event\":\"pull_request\",\"updatedAt\":\"$fx_ended\"},{\"conclusion\":\"success\",\"event\":\"pull_request_target\",\"updatedAt\":\"$fx_ended\"}]"
  ci_pr_free_slots() { printf '5\n'; }
  unfinished_runs() { printf '[]'; }
  ci_jobs_prefetch() { :; }
  gh() { case "$*" in "run list --commit $head5937"*) echo x >> "$td/gh-calls"; printf '%s' "$fx_runs" ;; *) echo "unexpected gh call: $*" >&2; return 97 ;; esac; }
}
gh_calls() { { cat "$td/gh-calls" 2>/dev/null || true; } | wc -l; }
alerts() { grep -c CI-CANCELLED-STALE "$td/alerts/gate.md" 2>/dev/null || echo 0; }

# 1. the #5937 state: parked, every PR run cancelled 45 min ago -> one alert, naming the head; a second pass adds none
cancel_fixture parked 45 cancelled
ci_admission
[[ "$(alerts)" == 1 ]] || fail "parked head with every run cancelled for 45 min raised $(alerts) alerts, want 1"
grep -q "unit=issue-5306 PR#5937 head=$head5937 stage=parked" "$td/alerts/gate.md" || fail "alert line does not name unit, PR, head and stage"
ci_admission
[[ "$(alerts)" == 1 && "$(gh_calls)" == 1 ]] || fail "second pass re-alerted or re-queried ($(alerts) alerts, $(gh_calls) gh calls)"

# 2. runs cancelled only 10 min ago: not stale yet
cancel_fixture parked 10 cancelled
ci_admission
[[ "$(alerts)" == 0 ]] || fail "10 min old cancel already alerted"

# 3. one PR run already succeeded (rerun happened): nothing to say, and the clean result is remembered
cancel_fixture parked 45 success
ci_admission; ci_admission
[[ "$(alerts)" == 0 && "$(gh_calls)" == 1 ]] || fail "readmitted head alerted or was re-queried every pass ($(alerts) alerts, $(gh_calls) gh calls)"

# 4. review stages cancel CI on purpose (ci_defer_unapproved): never scanned
cancel_fixture review-pending 45 cancelled
ci_admission
[[ "$(alerts)" == 0 && "$(gh_calls)" == 0 ]] || fail "review-pending unit was scanned ($(alerts) alerts, $(gh_calls) gh calls)"
echo "ci-cancel-stale.test.sh: ok"
