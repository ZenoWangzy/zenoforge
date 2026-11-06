#!/usr/bin/env bash
# Recut leaves an exhausted Codex route for GLM; any other hold on the policy helper reaches the supervisor.
set -euo pipefail
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/test-env.sh"
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/test-lib-helpers.sh"
eval "$(sed -n '/^dispatch_policy_unit() {/,/^}/p' "$SCRIPT_DIR/issue-pipeline.sh")"
ZCODE_QUOTA_SNAPSHOT_FILE="$AGENT_HOME/zc-quota.json"
jq '.roles["hand-zcode"].disabled = false' "$MODEL_POLICY_FILE" > "$AGENT_HOME/policy.tmp" && mv "$AGENT_HOME/policy.tmp" "$MODEL_POLICY_FILE"
GLM="$(model_policy identity hand-zcode)"
glm_quota() { jq -n --argjson now "$(date +%s)" --argjson pct "$1" '{freshness:"fresh",read_at:$now,max_age_seconds:900,five_h_pct:$pct,week_pct:10,cap_5h:60,cap_week:100}' > "$ZCODE_QUOTA_SNAPSHOT_FILE"; }
codex_exhausted() { printf '%s\n' "$(( $(date +%s) + 3600 ))" > "$CODEX_EXHAUSTED_MARKER_FILE"; }

state_read() { echo '{}'; }
state_merge() { printf '%s\n' "$2" >> "$AGENT_HOME/merged"; }
state_bump_attempts() { :; }
issue_spend_budget_status() { printf 'clear\t0\t0\n'; }
recover_stale_policy_unit() { return 1; }
model_policy_begin_unit() { :; }
agent_implement_dispatch_resources_allow() { return 0; }
issue_model_failure_backoff_remaining() { echo 0; }
codex_probe_ok() { return 0; }
codex_provider_recovery_probe_if_due() { return 0; }
ensure_issue_roadmap_parent_for_dispatch() { return 0; }
pipeline_claim_begin() { :; }
pipeline_claim_drop() { :; }
coord_assert_owned() { :; }
PIPELINE_CLAIM_KEY=key PIPELINE_CLAIM_OWNER=owner
dispatch() { echo "$1" > "$AGENT_HOME/dispatched"; }
touch "$AGENT_HOME/supervisor-inbox"
inbox_lines() { grep -c policy-route-held "$AGENT_HOME/supervisor-inbox" || true; }

rm -f "$CODEX_EXHAUSTED_MARKER_FILE"
glm_quota 10
assert_eq "recut stays on Codex while Codex is open" "" "$(recut_glm_identity || true)"

codex_exhausted
assert_eq "recut takes GLM while Codex is exhausted" "$GLM" "$(recut_glm_identity)"
dispatch_policy_unit recut 910701 needs-recut
assert_eq "recut dispatches past the marker" recut "$(cat "$AGENT_HOME/dispatched")"
assert_contains "the dispatch records the GLM identity" "$(cat "$AGENT_HOME/merged")" "$GLM"
assert_eq "no hold alert while recut moves" 0 "$(inbox_lines)"

rm -f "$AGENT_HOME/dispatched"
glm_quota 90
assert_eq "no GLM route at the 5h cap" "" "$(recut_glm_identity || true)"
status=0; dispatch_policy_unit recut 910702 needs-recut 2>"$AGENT_HOME/err" || status=$?
assert_eq "both routes closed hold the queue" 77 "$status"
assert_contains "the hold is logged" "$(cat "$AGENT_HOME/err")" 'recut route held'
assert_eq "the hold reaches the supervisor" 1 "$(inbox_lines)"
dispatch_policy_unit recut 910703 needs-recut 2>/dev/null || :
assert_eq "one alert a day" 1 "$(inbox_lines)"

glm_quota 10
status=0; dispatch_policy_unit implement 910704 ready-for-agent 2>/dev/null || status=$?
assert_eq "implement never leaves Codex here" 77 "$status"
assert_true "the alert is per unit, not recut only" grep -q 'unit=implement' "$AGENT_HOME/supervisor-inbox"

prompt="$(mktemp)"; schema="$(mktemp)"; echo '{"required":["children"]}' > "$schema"
cat > "$AGENT_HOME/zcode" <<'Z'
#!/usr/bin/env bash
printf '%s\n' '```json' "$ZCODE_FAKE_REPLY" '```'
Z
chmod +x "$AGENT_HOME/zcode"; PATH="$AGENT_HOME:$PATH"
assert_eq "a reply with every required key passes" false "$(ZCODE_FAKE_REPLY='{"children":[]}' run_zcode_json . "$GLM" 1 "$schema" "$prompt" hand-zcode | jq -r .is_error)"
assert_eq "a reply missing a required key fails closed" true "$(ZCODE_FAKE_REPLY='{"other":1}' run_zcode_json . "$GLM" 1 "$schema" "$prompt" hand-zcode | jq -r .is_error || true)"
rm -f "$prompt" "$schema"

lib_case_exit
