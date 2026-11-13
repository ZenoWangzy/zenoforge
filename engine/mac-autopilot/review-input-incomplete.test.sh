#!/usr/bin/env bash
# INPUT_INCOMPLETE reviews judged nothing about the code: no variant may reach repair-pending (pr-5650: 3 repairs on one head, 822k tokens).
set -euo pipefail
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/test-env.sh"
script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
sup="$test_env_root/supervisor"
mkdir -p "$sup/autopi/alerts" "$test_env_root/root"
cp "$script_dir/config.template.json" "$sup/autopi/config.json"
printf '{"workers":[]}' > "$sup/autopi/workers.json"
printf '{"units":[]}' > "$sup/autopi/units.json"
export MAC_AUTOPILOT_ROOT="$test_env_root/root" MAC_AUTOPILOT_SUPERVISOR_DIR="$sup" AUTOPI_TEST_LIBRARY_ONLY=true
unset GH_TOKEN GITHUB_TOKEN
source "$script_dir/scheduler.sh"
tick_prs_prime() { :; }
session_usage_for_id() { echo null; }
cancel_unit_runs() { :; }
park_blocked() { set_unit "$1" ".blocked_on=$2"; }
fail() { echo "review-input-incomplete.test.sh: $*" >&2; exit 1; }
field() { jq -r ".units[0] | $1" "$UNITS"; }
bash -c true & DEAD_PID=$!; wait "$DEAD_PID"
SHA=1111111111111111111111111111111111111111
touch "$sup/worker.log"
# one review worker whose report is $1; the worker is dead, so harvest reads the report at once
review_with_report() {
  printf '%s\n' "$1" > "$sup/rep.md"
  jq -n --arg sha "$SHA" --argjson pid "$DEAD_PID" '{workers:[{pid:$pid,pid_start:1,process_group:$pid,claim_owner:"test-owner",unit:"pr-9",type:"review",provider:"zcode",log:"worker.log",report:"rep.md",sha:$sha,pr_head:$sha,started:"2026-11-04T00:00:00Z",harvested:false}]}' > "$WORKERS"
  harvest_workers
}
DENIED='本会话的 Bash 被权限模式拒绝（don'"'"'t-ask 模式）。

VERDICT: INPUT_INCOMPLETE'

printf '{"units":[{"id":"pr-9","pr":9,"lane":"pr","branch":"agent/issue-9","stage":"review","history":[]}]}' > "$UNITS"
review_with_report "$DENIED"
[[ "$(field .stage)" == review-pending && "$(field .reviewed_sha)" == null ]] || fail "first denial must re-review once, got $(field .stage)"
review_with_report "$DENIED"
[[ "$(field .stage)" == supervisor-review ]] || fail "second denial on the same head must escalate, got $(field .stage)"
[[ "$(field .supervisor_cap_return_stage)" == review-pending ]] || fail "denied-review escalation must return to review, got $(field .supervisor_cap_return_stage)"
[[ "$(field '[.history[] | select(.stage == "repair-delivered" or .stage == "repair-no-push")] | length')" == 0 ]] || fail "denied review must not start a repair"
echo 'ok - reviewer tool denial: one re-review per head, then supervisor, never repair'

printf '{"units":[{"id":"pr-9","pr":9,"lane":"pr","branch":"agent/issue-9","stage":"review","history":[]}]}' > "$UNITS"
review_with_report '## Verdict
BLOCKED-ON: #77

VERDICT: INPUT_INCOMPLETE'
[[ "$(field .blocked_on)" == 77 && "$(field .stage)" == blocked-external ]] || fail "BLOCKED-ON review must take the dependency hold ($(field .stage):$(field .blocked_on))"
jq -e '.units[0].history[-1] | .stage == "review-block" and .blocked_on == 77 and .source == "review-report"' "$UNITS" >/dev/null \
  || fail 'BLOCKED-ON review transition must record its blocker and source'
echo 'ok - BLOCKED-ON review takes the existing dependency hold'

printf '{"units":[{"id":"pr-9","pr":9,"lane":"pr","branch":"agent/issue-9","stage":"review","history":[]}]}' > "$UNITS"
review_with_report 'VERDICT: INPUT_INCOMPLETE'
[[ "$(field .stage)" == blocked-external && "$(field '[.history[] | select(.stage == "review-tools-denied")] | length')" == 0 ]] || fail "plain INPUT_INCOMPLETE keeps the blocked hold"
jq -e '.units[0].history[-1] | .stage == "review-block" and .blocked_on == null and .source == "review-report"' "$UNITS" >/dev/null \
  || fail 'a review hold without a named dependency must record null and its source'
echo 'ok - plain INPUT_INCOMPLETE is not mistaken for a denial'
