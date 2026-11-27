#!/usr/bin/env bash
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
cancel_unit_runs() { :; }
fail() { echo "proof-review-gate.test.sh: $*" >&2; exit 1; }
field() { jq -r ".units[0] | $1" "$UNITS"; }
gh_calls="$sup/gh-calls"
gh() { echo "$*" >> "$gh_calls"; return 1; }

SHA=1111111111111111111111111111111111111111
OTHER=2222222222222222222222222222222222222222
REVIEWED=".reviewed_sha=\"$SHA\""
WORKER='{"workdir":"/nonexistent-review-clone"}'
PLAN='{"status":"available","phase":"exact-head","matched_features":["F1"]}'
build_verification_exact_plan_json() { printf '%s' "$PLAN"; }

new_unit() {
  jq -n '{units:[{id:"pr-9",pr:9,lane:"pr",branch:"agent/issue-9",stage:"review",implementation_report:"impl-9.md",history:[]}]}' > "$UNITS"
}
write_report() { printf '## how\nfixture\n\n%s\n' "$1" > "$sup/impl-9.md"; }
write_proof() { jq -n --arg sha "$1" --arg status "$2" '{source_sha:$sha,features:[{feature_id:"F1",status:$status}]}' > "$sup/proof-9.json"; }
write_over_budget_proof() {
  jq -n --arg sha "$1" '{source_sha:$sha,features:[{feature_id:"F1",status:"PASS",performance:{first_paint_ms:150,largest_contentful_paint_ms:400,js_heap_used_mb:80,long_task_count:0,run_count:5,error_count:0,work_count:3}}]}' > "$sup/proof-9.json"
}
gate() { proof_review_gate pr-9 "$WORKER" "$SHA" "$REVIEWED"; }

new_unit; write_proof "$SHA" PASS; write_report "Proof: $sup/proof-9.json"
rc=0; gate || rc=$?
[[ "$rc" == 1 && "$(field .stage)" == review && "$(field '.history | length')" == 0 ]] || fail "an ok proof must leave READY alone (rc=$rc stage=$(field .stage))"
[[ "$(review_proof_rule "$(jq -c '.units[0]' "$UNITS")" /nonexistent-review-clone "$SHA")" == *"Proof for head $SHA: ok."* ]] || fail 'the review prompt lacks the ok proof paragraph'
echo 'ok - valid proof: READY proceeds unchanged'

PLAN='{"status":"available","phase":"exact-head","matched_features":[]}'
new_unit; write_report 'no proof line'
rc=0; gate || rc=$?
[[ "$rc" == 1 && "$(field .stage)" == review && "$(field '.history | length')" == 0 ]] || fail "a plan with no feature must not need proof (rc=$rc)"
[[ "$(review_proof_rule "$(jq -c '.units[0]' "$UNITS")" /nonexistent-review-clone "$SHA")" == *"Proof for head $SHA: not-required."* ]] || fail 'the review prompt lacks the not-required paragraph'
PLAN='{"status":"unavailable","phase":"exact-head","reason":"planner failed"}'
rc=0; gate || rc=$?
[[ "$rc" == 1 && "$(field .stage)" == review ]] || fail "an unavailable plan must not block (rc=$rc)"
echo 'ok - no matched feature or no plan: behaves as before'

PLAN='{"status":"available","phase":"exact-head","matched_features":["F1"]}'
new_unit; write_report "Proof: $sup/no-such-proof.json"
rc=0; gate || rc=$?
[[ "$rc" == 0 && "$(field .stage)" == repair-pending && "$(field .approved_sha)" == null ]] || fail "a missing proof file must route to repair (rc=$rc stage=$(field .stage))"
jq -e --arg sha "$SHA" '.units[0] | .history[-1].stage == "proof-missing" and (.history[-1].result | startswith($sha + " missing") and contains("F1"))
  and (.repair_hint | contains("verify-feature.mjs --feature F1") and contains("Proof: <path>")) and .reviewed_sha == $sha' "$UNITS" > /dev/null \
  || fail "proof-missing event or repair hint is wrong: $(field '.history[-1]')"
[[ ! -e "$gh_calls" ]] || fail "the proof gate consulted GitHub: $(cat "$gh_calls")"
echo 'ok - missing proof: repair-pending with a proof-missing event and the verify command'

jq '.units[0].stage = "review"' "$UNITS" > "$UNITS.next" && mv "$UNITS.next" "$UNITS"
rc=0; gate || rc=$?
[[ "$rc" == 0 && "$(field .stage)" == supervisor-review ]] || fail "a second miss on the same head must go to the supervisor (rc=$rc stage=$(field .stage))"
[[ "$(field '[.history[] | select(.stage == "proof-missing")] | length')" == 2 ]] || fail 'the second miss was not recorded once'
[[ "$(field '[.history[] | select(.stage == "repair-delivered" or .stage == "repair-no-push")] | length')" == 0 ]] || fail 'a second miss started a repair'
echo 'ok - second miss on the same head goes to the supervisor once'

new_unit; write_report 'Proof: unavailable no candidate target serves this build'
rc=0; gate || rc=$?
[[ "$rc" == 0 && "$(field .stage)" == repair-pending && "$(field '.history[-1].result')" == "$SHA missing features=F1" ]] || fail "Proof: unavailable must count as missing (rc=$rc: $(field '.history[-1].result'))"
echo 'ok - Proof: unavailable is missing, not a pass'

new_unit; write_proof "$OTHER" PASS; write_report "Proof: $sup/proof-9.json"
rc=0; gate || rc=$?
[[ "$rc" == 0 && "$(field '.history[-1].result')" == "$SHA stale features=F1" ]] || fail "a proof for another head must be stale (rc=$rc: $(field '.history[-1].result'))"
new_unit; write_proof "$SHA" FAIL; write_report "Proof: $sup/proof-9.json"
rc=0; gate || rc=$?
[[ "$rc" == 0 && "$(field '.history[-1].result')" == "$SHA invalid features=F1" && "$(field .stage)" == repair-pending ]] || fail "a failed feature must route to repair (rc=$rc: $(field '.history[-1].result'))"
echo 'ok - stale and failed proofs route to repair'

export ZF_CONFIG_ROOT="$test_env_root/perf-config/.zenoforge"
mkdir -p "$ZF_CONFIG_ROOT/state"
printf '%s\n' '{"default":{"basis":"Measured fixture values across five completed runs.","first_paint_ms":100,"largest_contentful_paint_ms":600,"js_heap_used_mb":100,"long_task_count":1}}' > "$ZF_CONFIG_ROOT/state/perf-budget.json"
new_unit; write_over_budget_proof "$SHA"; write_report "Proof: $sup/proof-9.json"
rc=0; gate || rc=$?
[[ "$rc" == 0 && "$(field .stage)" == repair-pending && "$(field '.history[-1].result')" == "$SHA over-budget features=F1" ]] || fail "an over-budget proof must route to repair (rc=$rc: $(field '.history[-1].result'))"
echo 'ok - over-budget proof routes to repair'

new_unit; write_report "Proof: $sup/proof-9.json"
jq '.units[0].lane = "direct-main"' "$UNITS" > "$UNITS.next" && mv "$UNITS.next" "$UNITS"
rc=0; gate || rc=$?
[[ "$rc" == 1 && "$(field .stage)" == review ]] || fail "direct-main has no worker proof and must not be gated (rc=$rc)"
echo 'ok - direct-main is not gated'
