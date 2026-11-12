#!/usr/bin/env bash
# A direct-main land refused as product-path work moves a unit without a PR to the PR lane, not to a supervisor.
set -euo pipefail
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/test-env.sh"
script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
sup="$test_env_root/supervisor"
mkdir -p "$sup/autopi/alerts" "$test_env_root/root"
cp "$script_dir/config.template.json" "$sup/autopi/config.json"
printf '{"workers":[]}' > "$sup/autopi/workers.json"
export MAC_AUTOPILOT_ROOT="$test_env_root/root" MAC_AUTOPILOT_SUPERVISOR_DIR="$sup" AUTOPI_TEST_LIBRARY_ONLY=true
unset GH_TOKEN GITHUB_TOKEN
source "$script_dir/scheduler.sh"
tick_prs_prime() { :; }
session_usage_for_id() { echo null; }
blocked_on_of() { :; }
cancel_unit_runs() { :; }
fail() { echo "needs-pr-lane.test.sh: $*" >&2; exit 1; }
field() { jq -r --arg id "$1" '.units[] | select(.id==$id) | '"$2" "$UNITS"; }

# Land refused "not eligible" on a unit with no PR: PR lane on the same branch, no supervisor.
printf '%s\n' '{"units":[{"id":"issue-5","issue":5,"lane":"direct-main","branch":"agent/auto-issue-5","stage":"landing","task":"t","history":[]}]}' > "$UNITS"
printf 'FAILED not eligible for the direct-main lane (product paths)\n' > "$sup/land-5.md"
jq -n '{workers:[{pid:9005,unit:"issue-5",type:"land",log:"land-5.log",report:"land-5.md"}]}' > "$WORKERS"
harvest_workers || :
[[ "$(field issue-5 .stage):$(field issue-5 .lane):$(field issue-5 .branch)" == "implement-pending:pr:agent/issue-5" ]] \
  || fail "refused no-PR land did not switch to the PR lane: $(jq -c '.units' "$UNITS")"
[[ "$(field issue-5 .task)" == *"PR 车道"* ]] || fail 'PR lane switch left no task note'
jq -e '[.units[0].history[] | select(.stage == "supervisor-escalated" or .stage == "supervisor-review")] | length == 0' "$UNITS" >/dev/null \
  || fail 'refused no-PR land escalated to the supervisor'
echo 'ok - refused no-PR land moves to the PR lane without supervisor escalation'

# The implement NEEDS-PR report reaches the same shared helper.
printf '%s\n' '{"units":[{"id":"issue-6","issue":6,"lane":"direct-main","branch":"agent/auto-issue-6","stage":"implement","task":"t","history":[]}]}' > "$UNITS"
printf 'NEEDS-PR: needs packages/example change\n' > "$sup/impl-issue-6.md"
jq -n '{workers:[{pid:9006,unit:"issue-6",type:"implement",log:"impl-issue-6.log",report:"impl-issue-6.md"}]}' > "$WORKERS"
harvest_workers || :
[[ "$(field issue-6 .stage):$(field issue-6 .lane):$(field issue-6 .branch)" == "implement-pending:pr:agent/issue-6" ]] \
  || fail "NEEDS-PR implement report did not switch to the PR lane: $(jq -c '.units' "$UNITS")"
echo 'ok - NEEDS-PR implement report uses the shared PR-lane switch'
