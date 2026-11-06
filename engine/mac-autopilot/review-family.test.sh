#!/usr/bin/env bash
set -euo pipefail
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/../test-env.sh"

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
repo_root="$(cd "$script_dir/../.." && pwd -P)"
fixture="$test_env_root/review-family"
sup="$fixture/supervisor"
autopi="$sup/autopi"
mkdir -p "$autopi/alerts" "$fixture/repo/.zenoforge/mac-autopilot" "$fixture/zcode" "$test_env_bin"
cp "$script_dir/config.template.json" "$autopi/config.json"
cp "$repo_root/engine/model-policy.default.json" "$fixture/model-policy.json"
export MODEL_POLICY_DEFAULT="$repo_root/engine/model-policy.default.json"
export MODEL_POLICY_FILE="$fixture/model-policy.json"
export ZCODE_PROVIDER_CONFIG_FILE="$fixture/zcode/provider_config.json"
export ZF_REPO_DIR="$repo_root" ZF_ENGINE_DIR="$repo_root/engine"
export MAC_AUTOPILOT_ROOT="$repo_root" MAC_AUTOPILOT_SUPERVISOR_DIR="$sup" MAC_AUTOPILOT_RUNTIME_DIR="$autopi"
export REQUIRED_PR_CHECKS_FILE="$fixture/repo/.zenoforge/mac-autopilot/required-pr-checks.json"
printf '%s\n' '{"required":[],"current_regression":"","legacy_regression":[]}' > "$REQUIRED_PR_CHECKS_FILE"
printf '%s\n' '{"units":[]}' > "$autopi/units.json"
printf '%s\n' '{"workers":[]}' > "$autopi/workers.json"
printf '%s\n' '{"zcode":0,"claude":0,"codex":0}' > "$autopi/cooldown.json"
touch "$AGENT_HOME/codex-probe-passed"
jq -n '{config:{defaultModelSelection:{modelId:"GLM-5.3"}}}' > "$ZCODE_PROVIDER_CONFIG_FILE"
cat > "$test_env_bin/zcode" <<'SH'
#!/usr/bin/env bash
echo 'review output'
SH
cat > "$test_env_bin/claude" <<'SH'
#!/usr/bin/env bash
echo 'review output'
SH
cat > "$test_env_bin/codex" <<'SH'
#!/usr/bin/env bash
echo 'review output'
SH
chmod +x "$test_env_bin/zcode" "$test_env_bin/claude" "$test_env_bin/codex"

AUTOPI_TEST_LIBRARY_ONLY=true source "$script_dir/scheduler.sh"
SCHED_LOCK_HELD=true
unset AUTOPI_TEST_LIBRARY_ONLY

fail() { echo "review-family.test.sh: $*" >&2; exit 1; }
set_config() { jq "$1" "$script_dir/config.template.json" > "$autopi/config.json"; CFG="$(cat "$autopi/config.json")"; }
set_policy() { jq "$1" "$repo_root/engine/model-policy.default.json" > "$MODEL_POLICY_FILE"; }
unit_for() {
  local id="$1" author="$2"
  jq -cn --arg id "$id" --arg author "$author" \
    '{id:$id,issue:9001,pr:9001,stage:"review-pending",implement_identity:$author,history:[]}'
}
write_units() { printf '%s\n' "$1" > "$UNITS"; }
write_workers() { printf '%s\n' "$1" > "$WORKERS"; }
DISPATCH_COUNT=0
DISPATCH_MODEL=""
DISPATCH_EFFORT=""
dispatch_if_room() {
  DISPATCH_COUNT=$((DISPATCH_COUNT + 1))
  DISPATCH_MODEL="$6"
  DISPATCH_EFFORT="$7"
  return 0
}
dispatch_selected_review() {
  local unit_json="$1" id
  id="$(jqf -r '.id' <<<"$unit_json")"
  pick_review_for_unit "$unit_json" || return 75
  dispatch_if_room "$id" review review review.log review.md "$PICK_MODEL" "$PICK_EFFORT" prompt "" "$ROOT" "" "" "$unit_json"
}
if [[ "${1:-}" == --plant-old ]]; then
  # The historical helper printed the implementer's identity when no
  # different-provider reviewer was available (engine/lib.d/model-policy.sh:761).
  review_model_for_implementer() { printf '%s\n' "$2"; }
  set_config '.models.review=["gpt-6-luna","max","fast"] | .models.review_cross=["gpt-6-luna","max"] | .models.review_fallback=null'
  set_policy '.'
  unit_json="$(unit_for planted-old 'codex:gpt-6-luna:max')"
  write_units "$(jq -cn --argjson unit "$unit_json" '{units:[$unit]}')"
  write_workers '{"workers":[]}'
  if dispatch_selected_review "$unit_json"; then
    echo "FAIL planted pre-fix helper dispatched same-family reviewer=$DISPATCH_MODEL"
    exit 1
  fi
  echo 'unexpected-pass: planted pre-fix helper was not caught'
  exit 0
fi
set_cooldowns() {
  local zcode_until="$1" claude_until="$2"
  jq -cn --argjson zcode "$zcode_until" --argjson claude "$claude_until" '{zcode:$zcode,claude:$claude,codex:0}' > "$COOLDOWN"
}

# A Luna-authored unit is dispatched to the configured GLM reviewer.
set_config '.models.review=["gpt-6-luna","max","fast"] | .models.review_cross=["GLM-5.3","max"] | .models.review_fallback=["claude-sonnet-4-5","high"]'
set_policy '.allow_roles.sonnet=["review_fallback"]'
unit_json="$(unit_for codex-author 'codex:gpt-6-luna:max')"
write_units "$(jq -cn --argjson unit "$unit_json" '{units:[$unit]}')"
write_workers '{workers:[]}'
DISPATCH_COUNT=0
dispatch_selected_review "$unit_json" || fail 'Luna-authored review did not dispatch'
[[ "$DISPATCH_MODEL:$DISPATCH_EFFORT" == 'GLM-5.3:max' ]] || fail "Luna-authored review selected $DISPATCH_MODEL:$DISPATCH_EFFORT"
[[ "$(provider_of "$DISPATCH_MODEL")" == zcode ]] || fail 'GLM review did not resolve to the zcode backend'
grep -Fq 'pick_review_for_unit "$u" || continue' "$script_dir/scheduler.d/dispatch-queue.sh" || fail 'review/rereview dispatch path bypasses family selection'
grep -Fq 'pick_review_for_unit "$u" || continue' "$script_dir/scheduler.d/health-release.sh" || fail 'new PR review dispatch path bypasses family selection'

# A GLM-authored repair worker is read from the worker ledger and its review runs on Luna.
unit_json='{"id":"glm-author","issue":9002,"pr":9002,"stage":"rereview-pending","history":[]}'
write_units "$(jq -cn --argjson unit "$unit_json" '{units:[$unit]}')"
write_workers '{"workers":[{"unit":"glm-author","type":"repair","provider":"zcode","model":"GLM-5.3","effort":"max","started":"2026-11-03T01:00:00Z","harvested":true}]}'
dispatch_selected_review "$unit_json" || fail 'GLM-authored rereview did not dispatch'
[[ "$DISPATCH_MODEL:$DISPATCH_EFFORT" == 'gpt-6-luna:max' ]] || fail "GLM-authored review selected $DISPATCH_MODEL:$DISPATCH_EFFORT"
[[ "$(provider_of "$DISPATCH_MODEL")" == codex ]] || fail 'Luna review did not resolve to Codex'

# A Claude-authored head (hand-claude implement) is reviewed by a different family, never by Claude.
set_config '.models.review=["gpt-6-luna","max","fast"] | .models.review_cross=["GLM-5.3","max"] | .models.review_fallback=["claude-sonnet-5-5","high"]'
set_policy '.allow_roles.sonnet=["review_fallback"]'
set_cooldowns 0 0
unit_json="$(unit_for claude-author 'claude:claude-sonnet-5-5:high')"
write_units "$(jq -cn --argjson unit "$unit_json" '{units:[$unit]}')"
write_workers '{workers:[]}'
dispatch_selected_review "$unit_json" || fail 'Claude-authored review did not dispatch'
[[ "$DISPATCH_MODEL:$DISPATCH_EFFORT" == 'GLM-5.3:max' ]] || fail "Claude-authored review selected $DISPATCH_MODEL:$DISPATCH_EFFORT"
# A PR with no worker record: Co-Authored-By on all its commits names the author, and without that it waits.
outside_pr='{"id":"pr-901","pr":901,"stage":"review-pending"}'
write_units "$(jq -cn --argjson unit "$outside_pr" '{units:[$unit]}')"
gh() { printf '%s\n' "$ALL_COMMITS_CLAUDE"; }
ALL_COMMITS_CLAUDE=true
dispatch_selected_review "$outside_pr" || fail 'a Claude-authored PR from outside the pipeline never reached a reviewer'
[[ "$DISPATCH_MODEL:$DISPATCH_EFFORT" == 'GLM-5.3:max' ]] || fail "outside PR review selected $DISPATCH_MODEL:$DISPATCH_EFFORT"
ALL_COMMITS_CLAUDE=false
if dispatch_selected_review "$outside_pr"; then fail 'a PR with any commit lacking the Claude trailer must keep waiting'; fi
unset -f gh
write_units "$(jq -cn --argjson unit "$unit_json" '{units:[$unit]}')"
set_cooldowns "$((NOW_EPOCH + 1800))" 0
dispatch_selected_review "$unit_json" || fail 'Claude-authored review did not fall back to the other family during a GLM hold'
[[ "$(provider_of "$DISPATCH_MODEL")" == codex ]] || fail "Claude-authored review fell back to $DISPATCH_MODEL, not Codex"

# A same-family reviewer setting is logged and never dispatched.
set_config '.models.review=["gpt-6-luna","max","fast"] | .models.review_cross=["gpt-6-luna","max"] | .models.review_fallback=null'
set_policy '.'
unit_json="$(unit_for same-family 'codex:gpt-6-luna:max')"
write_units "$(jq -cn --argjson unit "$unit_json" '{units:[$unit]}')"
write_workers '{workers:[]}'
before_dispatch="$DISPATCH_COUNT"
if dispatch_selected_review "$unit_json"; then fail 'same-family configuration dispatched'; fi
[[ "$DISPATCH_COUNT" == "$before_dispatch" ]] || fail 'same-family configuration reached dispatch_if_room'
grep -Fq 'review-family refused unit=same-family author=codex reviewer=codex reason=same-family-or-unknown' "$LOG" || fail 'same-family refusal was not logged'

# A zcode quota hold selects the named Sonnet fallback and logs one countable line.
set_config '.models.review=["gpt-6-luna","max","fast"] | .models.review_cross=["GLM-5.3","max"] | .models.review_fallback=["claude-sonnet-4-5","high"]'
set_policy '.allow_roles.sonnet=["review_fallback"]'
set_cooldowns "$((NOW_EPOCH + 1800))" 0
unit_json="$(unit_for quota-fallback 'codex:gpt-6-luna:max')"
write_units "$(jq -cn --argjson unit "$unit_json" '{units:[$unit]}')"
write_workers '{workers:[]}'
dispatch_selected_review "$unit_json" || fail 'Sonnet fallback did not dispatch during a GLM hold'
[[ "$DISPATCH_MODEL:$DISPATCH_EFFORT" == 'claude-sonnet-4-5:high' ]] || fail "quota fallback selected $DISPATCH_MODEL:$DISPATCH_EFFORT"
grep -Fq 'review-family fallback unit=quota-fallback author=codex reviewer=sonnet reason=glm hold' "$LOG" || fail 'Sonnet fallback line did not record the GLM hold'

# When GLM and Sonnet are both held, the unit stays pending, alerts once, and never uses Luna.
set_cooldowns "$((NOW_EPOCH + 1800))" "$((NOW_EPOCH + 1800))"
unit_json="$(unit_for both-held 'codex:gpt-6-luna:max')"
write_units "$(jq -cn --argjson unit "$unit_json" '{units:[$unit]}')"
write_workers '{workers:[]}'
before_dispatch="$DISPATCH_COUNT"
if dispatch_selected_review "$unit_json"; then fail 'review dispatched while both independent families were held'; fi
unit_json="$(jq -c '.units[0]' "$UNITS")"
if dispatch_selected_review "$unit_json"; then fail 'review escaped its wait state on the next attempt'; fi
[[ "$DISPATCH_COUNT" == "$before_dispatch" ]] || fail 'held review reached dispatch_if_room'
[[ "$(jq -r '.units[0].stage' "$UNITS")" == rereview-pending || "$(jq -r '.units[0].stage' "$UNITS")" == review-pending ]] || fail 'held review left its pending stage'
[[ "$(grep -Fc 'review-family wait unit=both-held ' "$LOG")" == 1 ]] || fail 'wait alert was not deduplicated to one line'
grep -Fq 'review-family wait unit=' "$script_dir/bell.sh" && grep -Fq 'sched-review-family-wait' "$script_dir/bell.sh" || fail 'wait alert is not wired to bell incident intake'

# The Sonnet exception is limited to the fallback role; implement identity checks stay Codex-only.
model_policy_model_allowed_for_role claude-sonnet-4-5 review_fallback || fail 'named Sonnet review role was not permitted by allow_roles'
if model_policy_model_allowed_for_role claude-haiku-5-5 review_fallback; then fail 'Sonnet exception allowed a non-Sonnet Claude model'; fi
if model_policy_model_allowed_for_role claude-sonnet-4-5 implement; then fail 'Sonnet exception leaked into implement'; fi
if model_policy_validate_json <<<"$(jq '.allow_roles.claude=["review_fallback"]' "$MODEL_POLICY_FILE")"; then fail 'a broad Claude exception was accepted by model-policy schema'; fi
model_policy_require_stage_identity review claude:claude-sonnet-4-5:high || fail 'policy-authorized Sonnet was refused for review'
if model_policy_require_implementer_identity claude:claude-sonnet-4-5:high >/dev/null 2>&1; then fail 'Claude identity was accepted for implement'; fi
build_codex_command implement claude-sonnet-5-5 high claude-impl 'prompt' 'prompt' "$fixture/repo" claude || fail 'Claude implement command was refused'
[[ "${CODEX_COMMAND[0]}" == claude && " ${CODEX_COMMAND[*]} " == *' --output-format stream-json '* ]] || fail 'Claude implement command is not claude -p stream-json'
# The hand-claude role is the only implement grant; opus and fable stay refused for every role.
model_policy_model_allowed_for_role claude-sonnet-5-5 hand-claude || fail 'hand-claude was not permitted for Sonnet'
for refused in claude-opus-5-5 claude-fable-5 claude-haiku-5-5; do
  if model_policy_model_allowed_for_role "$refused" hand-claude; then fail "$refused was permitted for hand-claude"; fi
done
if model_policy_validate_json <<<"$(jq '.roles["hand-claude"].model="claude-opus-5-5"' "$MODEL_POLICY_DEFAULT")"; then fail 'an opus hand-claude role passed the model-policy schema'; fi

set +e
planted_output="$(bash "$script_dir/review-family.test.sh" --plant-old 2>&1)"
planted_status=$?
set -e
[[ "$planted_status" == 1 ]] || fail "planted pre-fix selector exited $planted_status instead of failing"
grep -Fq 'FAIL planted pre-fix helper dispatched same-family reviewer=gpt-6-luna' <<<"$planted_output" || fail 'planted pre-fix selector did not reproduce the same-family dispatch'
printf 'PLANTED_OLD_EXIT_CODE=%s\n%s\n' "$planted_status" "$planted_output"

# Credits route: past the Codex hold only ZCode-authored review and the arbiter may run, up to a hard cap.
set_config '.'; set_policy '.'
printf '%s\n' '{"zcode":0,"claude":0,"codex":0}' > "$COOLDOWN"
rm -f "$(_quota_marker_file zcode)" "$(_quota_marker_file claude)"
sessions="$fixture/sessions/2026/11/06"; mkdir -p "$sessions"
export CODEX_SESSIONS_DIR="$fixture/sessions"
balance() { printf '{"payload":{"rate_limits":{"credits":{"has_credits":true,"balance":"%s"}}}}\n' "$1" > "$sessions/rollout-a.jsonl"; }
printf '%s\n' "$(($(date +%s) + 3600))" > "$(_quota_marker_file codex)"
: > "$AGENT_HOME/codex-credits.log"
glm_unit="$(unit_for credit-glm zcode:GLM-5.3:max)"
codex_unit="$(unit_for credit-codex codex:gpt-6-luna:max)"
balance 29000.5
if pick_review_for_unit "$glm_unit"; then fail 'credits route must be closed without config'; fi
CODEX_CREDITS_ROLES="review arbiter"; CODEX_CREDITS_CAP=5000; CODEX_CREDITS_START_BALANCE=29582
pick_review_for_unit "$glm_unit" || fail 'a ZCode unit must get a reviewer on credits'
[[ "$PICK_PROVIDER" == codex ]] || fail "a ZCode unit was reviewed by $PICK_PROVIDER"
grep -Fq $'review\tcredit-glm\tbalance=29000.5\tspent=582' "$AGENT_HOME/codex-credits.log" || fail 'a credit-funded review must be logged per unit'
pick_review_for_unit "$codex_unit" || fail 'a Codex unit must keep its GLM reviewer'
[[ "$PICK_PROVIDER" == zcode ]] || fail "a Codex unit was reviewed by $PICK_PROVIDER"
codex_credits_open arbiter || fail 'the arbiter must be open under the cap'
if codex_credits_open implement || codex_credits_open triage; then fail 'implement and triage must never spend credits'; fi
balance 24583
codex_credits_open arbiter || fail 'one credit under the cap must stay open'
balance 24582
if pick_review_for_unit "$glm_unit"; then fail 'spending past the cap must refuse the review'; fi
if codex_credits_open arbiter; then fail 'spending past the cap must close the arbiter'; fi
grep -Fq 'codex-credits-stop' "$AGENT_HOME/supervisor-inbox" || fail 'the stop must alert'
rm -f "$sessions/rollout-a.jsonl"
if codex_credits_open review; then fail 'an unreadable balance must close the route'; fi
rm -f "$(_quota_marker_file codex)"
pick_review_for_unit "$glm_unit" || fail 'after the reset a ZCode unit must get normal Codex'
[[ "$PICK_PROVIDER" == codex ]] || fail 'after the reset the reviewer must be Codex'
CODEX_CREDITS_ROLES=""; CODEX_CREDITS_CAP=""; CODEX_CREDITS_START_BALANCE=""

echo 'PASS review family dispatch, fallback, wait, alert, and role policy'

