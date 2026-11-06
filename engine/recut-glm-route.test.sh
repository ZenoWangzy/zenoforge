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

pace_case() { # 5h-pct elapsed-seconds|none inflight -> status
  local now=1800000000; jq -n --argjson now "$now" --argjson pct "$1" --arg elapsed "$2" \
    '{freshness:"fresh",read_at:$now,max_age_seconds:900,five_h_pct:$pct,week_pct:1,cap_5h:60,cap_week:100}
     + (if $elapsed == "none" then {} else {five_h_reset:($now + 18000 - ($elapsed | tonumber))} end)' > "$pace_file"
  NOW_EPOCH=$now ZCODE_QUOTA_SNAPSHOT_FILE="$pace_file" ZCODE_PACE_INFLIGHT="$3" zcode_quota_status
}
pace_file="$(mktemp)"
assert_eq "an open window allows the slack" available "$(pace_case 19 0 0)"
assert_eq "over the slack at the start waits" paced "$(pace_case 21 0 0)"
assert_eq "a window not started counts as elapsed 0" paced "$(pace_case 21 none 0)"
assert_eq "halfway allows half the cap plus slack" available "$(pace_case 49 9000 0)"
assert_eq "halfway past that waits" paced "$(pace_case 50 9000 0)"
assert_eq "the end of the window never allows past the cap" available "$(pace_case 59 17999 0)"
assert_eq "the cap stays exhausted, not paced" exhausted "$(pace_case 60 17999 0)"
assert_eq "a run in flight counts before the meter moves" paced "$(pace_case 6 0 1)"
assert_eq "one run in flight still leaves room" available "$(pace_case 4 0 1)"
rm -f "$pace_file"

prompt="$(mktemp)"; schema="$(mktemp)"; echo '{"required":["children"]}' > "$schema"
cat > "$AGENT_HOME/zcode" <<'Z'
#!/usr/bin/env bash
printf '%s\n' "${GH_TOKEN:-}${GITHUB_TOKEN:-}" > "$AGENT_HOME/zcode-token-seen"
printf '%s\n' "${https_proxy-unset}" > "$AGENT_HOME/zcode-proxy-seen"
printf '%s\n' '```json' "$ZCODE_FAKE_REPLY" '```'
Z
chmod +x "$AGENT_HOME/zcode"; PATH="$AGENT_HOME:$PATH"
assert_eq "a reply with every required key passes" false "$(ZCODE_FAKE_REPLY='{"children":[]}' run_zcode_json . "$GLM" 1 "$schema" "$prompt" hand-zcode | jq -r .is_error)"
GH_TOKEN=planted GITHUB_TOKEN=planted ZCODE_FAKE_REPLY='{"children":[]}' run_zcode_json . "$GLM" 1 "$schema" "$prompt" hand-zcode >/dev/null
assert_eq "zcode never inherits the pipeline GitHub token" "" "$(cat "$AGENT_HOME/zcode-token-seen")"
https_proxy='' ZCODE_FAKE_REPLY='{"children":[]}' run_zcode_json . "$GLM" 1 "$schema" "$prompt" hand-zcode >/dev/null
assert_eq "an empty proxy from systemd-run -E never reaches zcode" unset "$(cat "$AGENT_HOME/zcode-proxy-seen")"
https_proxy=http://proxy.test:1 ZCODE_FAKE_REPLY='{"children":[]}' run_zcode_json . "$GLM" 1 "$schema" "$prompt" hand-zcode >/dev/null
assert_eq "a real proxy still reaches zcode" http://proxy.test:1 "$(cat "$AGENT_HOME/zcode-proxy-seen")"
assert_eq "a reply missing a required key fails closed" true "$(ZCODE_FAKE_REPLY='{"other":1}' run_zcode_json . "$GLM" 1 "$schema" "$prompt" hand-zcode | jq -r .is_error || true)"
rm -f "$prompt" "$schema"

now_iso() { date -u -d "@$(( $(date +%s) - ${1:-0} ))" +%Y-%m-%dT%H:%M:%SZ; }
unset -f state_read state_merge
source "$SCRIPT_DIR/lib.d/issue-state.sh"
lane_case() { # issue failures-json -> remaining backoff is 0 or not
  state_merge "$1" ".model_policy.failures = $2" >/dev/null
  model_policy_lane_backoff "$1" recut "reason" 2>/dev/null
  state_read "$1" | jq -e --argjson now "$(date +%s)" '(.model_failure_backoff.until_epoch // 0) > $now' >/dev/null && echo held || echo open
}
assert_eq "one failed run keeps the ticket at the head" open "$(lane_case 910710 "[{\"unit\":\"recut\",\"recorded_at\":\"$(now_iso 60)\"}]")"
assert_eq "two failed runs move the lane on" held "$(lane_case 910711 "[{\"unit\":\"recut\",\"recorded_at\":\"$(now_iso 400)\"},{\"unit\":\"recut\",\"recorded_at\":\"$(now_iso 60)\"}]")"
assert_eq "old failures do not count" open "$(lane_case 910712 "[{\"unit\":\"recut\",\"recorded_at\":\"$(now_iso 90000)\"},{\"unit\":\"recut\",\"recorded_at\":\"$(now_iso 60)\"}]")"
assert_eq "another unit's failure does not count" open "$(lane_case 910713 "[{\"unit\":\"implement\",\"recorded_at\":\"$(now_iso 400)\"},{\"unit\":\"recut\",\"recorded_at\":\"$(now_iso 60)\"}]")"
assert_true "every recorded failure reaches the lane check" grep -q 'model_policy_lane_backoff "\$n" "\$unit" "\$reason"' "$SCRIPT_DIR/lib.d/model-units.sh"

# Every ZCode launch: new paths must strip too. stage-call.sh and bin/zc unset at the top of the script.
launches="$(cd "$SCRIPT_DIR/.." && git grep -lE '(^|[ (=])zcode -p |/bin/zcode"' -- engine ':!*.test.*' ':!*.md')"
assert_eq "the known ZCode launch set" "engine/bin/zc engine/eval/stage-call.sh engine/lib.d/model-calls.sh engine/mac-autopilot/scheduler.d/worker-command.sh engine/night/dispatch.sh" "$(tr '\n' ' ' <<< "$launches" | sed 's/ $//')"
for launch in engine/lib.d/model-calls.sh engine/mac-autopilot/scheduler.d/worker-command.sh engine/night/dispatch.sh; do
  assert_true "$launch strips the token at launch" grep -Eq 'env -u GH_TOKEN -u GITHUB_TOKEN .*zcode -p ' "$SCRIPT_DIR/../$launch"
done
for launch in engine/bin/zc engine/eval/stage-call.sh; do
  assert_true "$launch unsets the token" grep -Eq '^unset GH_TOKEN GITHUB_TOKEN$' "$SCRIPT_DIR/../$launch"
done

# A unit passing a lower-case proxy by name must fill it first: an unset name arrives empty and turns the proxy off.
assert_eq "config fills a lower-case proxy from the upper-case one" http://proxy.test:1 \
  "$(unset https_proxy; HTTPS_PROXY=http://proxy.test:1; source "$SCRIPT_DIR/config.sh" >/dev/null; printf '%s' "$https_proxy")"
for launch in $(cd "$SCRIPT_DIR/.." && git grep -lE -- '-E (https?_proxy|no_proxy)( |$)' -- engine ':!*.test.*'); do
  assert_true "$launch fills lower-case proxies before systemd-run -E" \
    grep -Eq '(^|[ ])https_proxy="\$\{https_proxy:-|(lib|config)\.sh"' "$SCRIPT_DIR/../$launch"
done

lib_case_exit
