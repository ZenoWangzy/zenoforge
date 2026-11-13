#!/usr/bin/env bash
# Model policy regression cases split from the library suite.
set -euo pipefail
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/test-env.sh"
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/test-lib-helpers.sh"
# --- persistent model policy: shared roles and one escalation ladder -------
assert_eq "work role identity resolves from policy model and effort" "$POLICY_WORK_IDENTITY" "$(model_policy identity work)"
assert_eq "production role identity resolves from policy model and effort" "$POLICY_PRODUCTION_IDENTITY" "$(model_policy identity production)"
assert_true "default review role uses an independent family with no configured fallbacks" jq -e '
  .roles.work.provider == "codex" and .roles.work.model == "gpt-6-luna" and .roles.work.effort == "max"
  and .roles.review.provider == "zcode" and .roles.review.model == "GLM-5.3" and .roles.review.effort == "max"
  and .roles.production.provider == "codex" and .roles.production.model == "gpt-6-luna" and .roles.production.effort == "high"
  and ([.roles.work, .roles.review, .roles.production] | all((has("fallback_model") | not) and (has("fallback_identity") | not)))
  and (.forbidden | index("sol") != null)
' "$MODEL_POLICY_DEFAULT"
assert_true "default model policy validates with no Codex fallbacks" model_policy_validate_file "$MODEL_POLICY_DEFAULT"
for role in work production review; do
  assert_eq "$role has no configured fallback identity" "" "$(model_policy fallback-identity "$role" 2>/dev/null || true)"
done
assert_eq "work service tier resolves from policy" "$POLICY_WORK_TIER" "$(model_policy tier work)"
assert_eq "service tier also resolves from the policy identity" "$POLICY_WORK_TIER" "$(model_policy tier "$POLICY_WORK_IDENTITY")"
assert_eq "production role has no policy service tier" "" "$(model_policy tier production)"
POLICY_INVALID_TIER="$(mktemp)"
jq '.roles.work.service_tier = []' "$MODEL_POLICY_DEFAULT" > "$POLICY_INVALID_TIER"
assert_false "model policy rejects a non-string service tier" model_policy_validate_file "$POLICY_INVALID_TIER"
rm -f "$POLICY_INVALID_TIER"
POLICY_LUNA_FALLBACK="$(mktemp)"
jq '.roles.work.fallback_model = .roles.work.model' "$MODEL_POLICY_DEFAULT" > "$POLICY_LUNA_FALLBACK"
assert_false "model policy rejects a redundant same-model fallback" model_policy_validate_file "$POLICY_LUNA_FALLBACK"
rm -f "$POLICY_LUNA_FALLBACK"
POLICY_MISSING_FALLBACK="$(mktemp)"
jq 'del(.roles.review.fallback_model)' "$MODEL_POLICY_DEFAULT" > "$POLICY_MISSING_FALLBACK"
assert_true "model policy accepts an active Codex role with no fallback" model_policy_validate_file "$POLICY_MISSING_FALLBACK"
rm -f "$POLICY_MISSING_FALLBACK"
POLICY_ZCODE_REVIEW="$(mktemp)"
jq '.roles.review = {provider:"zcode",model:"GLM-5.3",effort:"max"}' "$MODEL_POLICY_DEFAULT" > "$POLICY_ZCODE_REVIEW"
assert_true "model policy permits a ZCode cross-provider review role without a fallback" \
  model_policy_validate_file "$POLICY_ZCODE_REVIEW"
rm -f "$POLICY_ZCODE_REVIEW"
POLICY_NON_CODEX_FALLBACK="$(mktemp)"
jq '.roles.advisor.fallback_model = "unused"' "$MODEL_POLICY_DEFAULT" > "$POLICY_NON_CODEX_FALLBACK"
assert_false "model policy rejects fallback on non-Codex roles" model_policy_validate_file "$POLICY_NON_CODEX_FALLBACK"
rm -f "$POLICY_NON_CODEX_FALLBACK"
for fallback_model in gpt-6.1-sol gpt-5-terra gpt-reserve; do
  POLICY_FORBIDDEN_FALLBACK="$(mktemp)"
  jq --arg model "$fallback_model" '.roles.work.fallback_model = $model' "$MODEL_POLICY_DEFAULT" > "$POLICY_FORBIDDEN_FALLBACK"
  assert_false "model policy rejects non-Luna Codex fallback $fallback_model" model_policy_validate_file "$POLICY_FORBIDDEN_FALLBACK"
  rm -f "$POLICY_FORBIDDEN_FALLBACK"
done
POLICY_FORBIDDEN_FALLBACK_IDENTITY="$(mktemp)"
jq '
  .roles.work.fallback_identity = "codex:gpt-6-test-fallback:max"
  | .roles["fallback-fixture"] = {
      provider:"codex", model:"gpt-6-test-fallback", effort:"max", fallback_model:"gpt-6-luna"
    }
' "$MODEL_POLICY_DEFAULT" > "$POLICY_FORBIDDEN_FALLBACK_IDENTITY"
assert_false "model policy rejects non-Luna fallback identities even when their model is otherwise configured" \
  model_policy_validate_file "$POLICY_FORBIDDEN_FALLBACK_IDENTITY"
rm -f "$POLICY_FORBIDDEN_FALLBACK_IDENTITY"
POLICY_SAME_MODEL_FALLBACK_IDENTITY="$(mktemp)"
jq '.roles.work.fallback_identity = "codex:gpt-6-luna:high"' "$MODEL_POLICY_DEFAULT" > "$POLICY_SAME_MODEL_FALLBACK_IDENTITY"
assert_false "model policy rejects an effort-only fallback identity on the same Luna model" \
  model_policy_validate_file "$POLICY_SAME_MODEL_FALLBACK_IDENTITY"
rm -f "$POLICY_SAME_MODEL_FALLBACK_IDENTITY"
POLICY_ACTIVE_FALLBACK_IDENTITY="$(mktemp)"
jq '.roles.work.model = "gpt-6-candidate" | .roles.work.fallback_identity = "codex:gpt-6-luna:max"' \
  "$MODEL_POLICY_DEFAULT" > "$POLICY_ACTIVE_FALLBACK_IDENTITY"
assert_false "model policy rejects a cross-role fallback identity on an active Codex role" \
  model_policy_validate_file "$POLICY_ACTIVE_FALLBACK_IDENTITY"
rm -f "$POLICY_ACTIVE_FALLBACK_IDENTITY"
assert_eq "advisor role identity resolves from policy" "$POLICY_ADVISOR_IDENTITY" "$(model_policy identity advisor)"
assert_false "a disabled role (GLM, 2026-10-09) does not resolve" model_policy identity hand-zcode
assert_eq "all ordinary calls use work role" "$(model_policy identity work)" "$AGENT_MODEL"
assert_eq "retry defaults to work role" "$(model_policy identity work)" "$AGENT_MODEL_RETRY"
assert_eq "review defaults to work role" "$(model_policy identity work)" "$AGENT_MODEL_REVIEW"
assert_eq "advisor override alias stays on the work identity" "$(model_policy identity work)" "$AGENT_MODEL_ADVISOR"
assert_eq "advisor floor alias stays on the work identity" "$(model_policy identity work)" "$AGENT_MODEL_ADVISOR_FLOOR"
assert_eq "advisor resolves only through web-advisor-provider" "$POLICY_ADVISOR_IDENTITY" "$(model_policy identity advisor)"
assert_eq "first work failure allows one more Luna dispatch" work "$(model_policy transition work on_failure)"
assert_eq "advisor success allows one work retry" work_retry "$(model_policy transition advisor on_success)"
assert_eq "work retry failure concludes without a model switch" conclude "$(model_policy transition work_retry on_failure)"
assert_eq "advisor retry step stays on work role, never Sol" "$(model_policy identity work)" \
  "$(model_policy identity "$(model_policy step-role work_retry)")"
assert_false "an override outside its policy role is refused" env AGENT_MODEL="codex:other-model:$POLICY_WORK_EFFORT" bash -c 'source "$1" >/dev/null 2>&1' _ "$SCRIPT_DIR/lib.sh"
assert_true "the work role identity is accepted at the model boundary" model_policy_require_role_identity work "$(model_policy identity work)"
assert_false "an advisor identity cannot launch as work" model_policy_require_role_identity work "$(model_policy identity advisor)"
assert_true "the escalation ladder's production step can launch an implementer" model_policy_require_implementer_identity "$(model_policy identity production)"
assert_true "the work role can launch an implementer" model_policy_require_implementer_identity "$(model_policy identity work)"
assert_false "an advisor identity cannot launch an implementer" model_policy_require_implementer_identity "$(model_policy identity advisor)"
assert_true "a work-role stage (review) accepts the ladder's production identity" model_policy_require_stage_identity work "$(model_policy identity production)"
assert_false "a work-role stage refuses the advisor identity" model_policy_require_stage_identity work "$(model_policy identity advisor)"
assert_true "the advisor stage still requires the advisor identity" model_policy_require_stage_identity advisor "$(model_policy identity advisor)"
assert_false "the advisor stage refuses the work identity" model_policy_require_stage_identity advisor "$(model_policy identity work)"

# Capacity holds are model-scoped; active Codex roles have no fallback to escape a Luna hold.
SAVED_MODEL_POLICY_FILE="$MODEL_POLICY_FILE"
CAPACITY_POLICY_FILE="$(mktemp)"
jq ".roles.advisor.disabled = false" "$MODEL_POLICY_DEFAULT" > "$CAPACITY_POLICY_FILE"
MODEL_POLICY_FILE="$CAPACITY_POLICY_FILE"
export MODEL_POLICY_FILE
CAPACITY_PRIMARY_IDENTITY="$(model_policy identity work)"
CAPACITY_FALLBACK_MODEL_IDENTITY="$(model_policy fallback-identity work 2>/dev/null || true)"
assert_eq "active role has no fallback identity" "" "$CAPACITY_FALLBACK_MODEL_IDENTITY"
note_codex_provider_outage "session:capacity-test" provider-capacity test "$CAPACITY_PRIMARY_IDENTITY" >/dev/null 2>&1 || true
assert_true "capacity error marks primary model held" codex_model_capacity_held "$CAPACITY_PRIMARY_IDENTITY"
assert_false "capacity error does not open provider hold" provider_quota_exhausted codex
assert_eq "capacity hold does not bypass the hold with the same Luna model and effort" "$CAPACITY_PRIMARY_IDENTITY" "$(model_policy dispatch-identity work)"
CAPACITY_ACTIVE_SELECTED="$(
  state_read() {
    jq -nc --arg identity "$CAPACITY_PRIMARY_IDENTITY" \
      '{model_policy:{unit:"implement",step:"work",active:{role:"work",identity:$identity}}}'
  }
  model_policy dispatch-state-identity 509901
)"
assert_eq "active dispatch retains its current Luna identity without a fallback" "$CAPACITY_PRIMARY_IDENTITY" "$CAPACITY_ACTIVE_SELECTED"
capacity_primary_status=0
codex_budget_reserve work capacity-primary 1 1 "" "$CAPACITY_PRIMARY_IDENTITY" >/dev/null 2>&1 || capacity_primary_status=$?
assert_eq "capacity-held model dispatch defers" 75 "$capacity_primary_status"

note_provider_quota_exhausted codex "" "You’ve hit your usage limit" >/dev/null 2>&1
capacity_marker="$(codex_model_capacity_marker_file "$CAPACITY_PRIMARY_IDENTITY")"
rm -f "$capacity_marker"
quota_role_status=0
codex_budget_reserve work quota-role 1 1 "" "$CAPACITY_PRIMARY_IDENTITY" >/dev/null 2>&1 || quota_role_status=$?
assert_eq "provider quota hold blocks the configured Luna role" 75 "$quota_role_status"
codex_budget_release quota-role
rm -f "$CODEX_EXHAUSTED_MARKER_FILE" "$CODEX_EXHAUSTED_MARKER_FILE.alerted"
: > "$CODEX_PROVIDER_FAILURE_EVENTS_FILE"
outage_now="$(date +%s)"
for outage_kind in websocket-401 network-egress provider-5xx; do
  note_codex_provider_outage "session:wide-$outage_kind" "$outage_kind" test \
    "$CAPACITY_PRIMARY_IDENTITY" "$outage_now" >/dev/null 2>&1 || true
done
assert_true "401, network and 5xx outage signals retain provider-wide hold" provider_quota_exhausted codex
outage_role_status=0
codex_budget_reserve work outage-role 1 1 "" "$CAPACITY_PRIMARY_IDENTITY" >/dev/null 2>&1 || outage_role_status=$?
assert_eq "provider outage blocks the configured Luna role" 75 "$outage_role_status"
codex_budget_release outage-role
rm -f "$CODEX_EXHAUSTED_MARKER_FILE" "$CODEX_EXHAUSTED_MARKER_FILE.alerted" \
  "$CODEX_PROVIDER_PROBE_REQUIRED_FILE" "$CODEX_PROVIDER_PROBE_NOTICE_FILE"
: > "$CODEX_PROVIDER_FAILURE_EVENTS_FILE"
capacity_marker="$(codex_model_capacity_marker_file "$CAPACITY_PRIMARY_IDENTITY")"
rm -f "$capacity_marker"
MODEL_POLICY_FILE="$SAVED_MODEL_POLICY_FILE"
export MODEL_POLICY_FILE
rm -f "$CAPACITY_POLICY_FILE"
if [[ "${LIB_TEST_MODEL_POLICY_ONLY:-0}" == 1 ]]; then lib_case_exit; fi
JSON_STAGE_DISPATCH_OUTPUT="$(bash -c '
  set -euo pipefail
  source "$1/lib.sh"
  model_timeout_for_attempt() { printf "%s" "$1"; }
  run_codex_json() { printf "%s\t%s\t%s\t%s\t%s\t%s" "$CODEX_JSON_TIMEOUT_SECONDS" "$1" "$2" "$3" "$4" "$5"; }
  run_model_json "$1" "$(model_policy identity production)" 1 schema prompt settings work
' _ "$SCRIPT_DIR")"
printf -v JSON_STAGE_DISPATCH_EXPECTED '60\t%s\t%s\t%s\tschema\tprompt' \
  "$SCRIPT_DIR" "$POLICY_PRODUCTION_MODEL" "$POLICY_PRODUCTION_EFFORT"
assert_eq "work-stage JSON dispatcher accepts production escalation identity" \
  "$JSON_STAGE_DISPATCH_EXPECTED" "$JSON_STAGE_DISPATCH_OUTPUT"

MODEL_POLICY_STATE_TEST_HOME="$(mktemp -d)"
jq '.roles.advisor.disabled = false' "$MODEL_POLICY_TEST_DEFAULT_FILE" > "$MODEL_POLICY_STATE_TEST_HOME/model-policy.json"
MODEL_POLICY_STATE_TEST="$(AGENT_HOME="$MODEL_POLICY_STATE_TEST_HOME" SCRIPT_DIR="$SCRIPT_DIR" bash -c '
  set -euo pipefail
  source "$SCRIPT_DIR/lib.sh"
  gh() {
    if [ "$1 $2" = "pr list" ]; then echo "[]"; return 0; fi
    if [ "$1 $2" = "issue view" ]; then
      case "$3" in
        509991) echo '\''{"number":509991,"labels":[]}'\'' ;;
        509992) echo '\''{"number":509992,"labels":[{"name":"pipeline-system"}]}'\'' ;;
      esac
    fi
  }
  route_to_advisor() { state_merge "$1" ". + {advisor_routed: true}"; }
  state_merge 509991 "{}"
  model_policy_begin_unit 509991 triage
  active_patch="{\"unit\":\"triage\",\"step\":\"work\"}"
  state_merge 509991 ".model_policy.active = $active_patch"
  model_policy_mark_started 509991 triage
  PRODUCT_ISSUE_JSON="{\"labels\":[]}"
  model_policy_record_failure 509991 work triage "model exited" "short evidence" 1 needs-triage triage 0 "$PRODUCT_ISSUE_JSON"
  state_read 509991
')"
assert_eq "failed unit reaches advisor step and keeps unit key" $'triage\tadvisor\ttriage' \
  "$(jq -r '[.model_policy.unit,.model_policy.step,.model_policy.resume_stage] | @tsv' <<< "$MODEL_POLICY_STATE_TEST")"
printf -v POLICY_FAILURE_EXPECTED '%s\ttriage\tshort evidence' "$POLICY_WORK_IDENTITY"
assert_eq "failed unit stores policy identity, stage, and short evidence" \
  "$POLICY_FAILURE_EXPECTED" \
  "$(jq -r '[.model_policy.failure.identity,.model_policy.failure.stage,.model_policy.failure.evidence] | @tsv' <<< "$MODEL_POLICY_STATE_TEST")"
assert_true "failed unit clears live dispatch marker" \
  jq -e '.model_policy.active == null' >/dev/null <<< "$MODEL_POLICY_STATE_TEST"

MODEL_POLICY_PIPELINE_HOME="$(mktemp -d)"
jq '.roles.advisor.disabled = false' "$MODEL_POLICY_TEST_DEFAULT_FILE" > "$MODEL_POLICY_PIPELINE_HOME/model-policy.json"
MODEL_POLICY_PIPELINE_OUTPUT="$(AGENT_HOME="$MODEL_POLICY_PIPELINE_HOME" SCRIPT_DIR="$SCRIPT_DIR" bash -c '
  set -euo pipefail
  source "$SCRIPT_DIR/lib.sh"
  gh() {
    if [ "$1 $2" = "issue view" ]; then
      echo '\''{"number":509992,"labels":[{"name":"pipeline-system"}]}'\''
    fi
  }
  route_to_advisor() {
    [ "${5:-}" = hand-loop-breaker ] || return 1
    ISSUE_VERDICT_GUARD_SKIPPED=0
    printf "%s\t%s\n" "$1" "$5" >> "$AGENT_HOME/advisor-routes"
    state_merge "$1" '\''.hand_loop_breaker.advisor_pending = true'\''
  }
  record_run_decision() { :; }
  conclude_run() { printf "%s\t%s\t%s\n" "$1" "$2" "$3" >> "$AGENT_HOME/concluded"; }
  hold_issue() { printf "%s\t%s\n" "$1" "$*" >> "$AGENT_HOME/holds"; }
  supervisor_inbox_append_once() { printf "%s\t%s\n" "$1" "$2" >> "$AGENT_HOME/inbox-events"; }
  state_merge 509992 '\''{"pipeline_system":{"enabled":true},"attempts":1,"run":{"implement_started_at":"2026-09-27T00:00:00Z"}}'\''
  model_policy_begin_unit 509992 implement ready-for-agent
  model_policy_record_failure 509992 work package-gate "classified package failure" "test evidence" 1 ready-for-agent implement
  first_step="$(state_read 509992 | jq -r .model_policy.step)"
  first_role="$(model_policy state-identity 509992 implement)"
  first_transition="$(state_read 509992 | jq -r .model_policy.failure.transition)"
  model_policy_record_failure 509992 work package-gate "classified package failure" "same failure evidence" 1 ready-for-agent implement
  state="$(state_read 509992)"
  printf "%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n" \
    "$first_step" "$first_role" "$first_transition" \
    "$(jq -r .model_policy.step <<< "$state")" \
    "$(jq -r .model_policy.failure.role <<< "$state")" \
    "$(jq -r .model_policy.failure.same_failure_streak <<< "$state")" \
    "$(jq -r .hand_loop_breaker.advisor_pending <<< "$state")" \
    "$(wc -l < "$AGENT_HOME/advisor-routes" | tr -d "[:space:]")" \
    "$(cut -f2 "$AGENT_HOME/advisor-routes")"
  state_merge 509992 '\''.model_policy.step="work_retry" | .model_policy.advisor_decision="apply suggestion" | del(.hand_loop_breaker.advisor_pending)'\''
  model_policy_record_failure 509992 work_retry package-gate "different failure after advice" "retry evidence" 1 ready-for-agent implement
  printf "%s\t%s\t%s\t%s\t%s\n" \
    "$(state_read 509992 | jq -r .model_policy.step)" \
    "$(state_read 509992 | jq -r .model_policy.failure.role)" \
    "$(wc -l < "$AGENT_HOME/holds" | tr -d "[:space:]")" \
    "$(wc -l < "$AGENT_HOME/inbox-events" | tr -d "[:space:]")" \
    "$(wc -l 2>/dev/null < "$AGENT_HOME/concluded" | tr -d "[:space:]" || echo 0)"
')"
rm -rf "$MODEL_POLICY_PIPELINE_HOME"
printf -v POLICY_LUNA_RETRY_EXPECTED 'work\t%s\twork' "$POLICY_WORK_IDENTITY"
assert_eq "pipeline-system first failure requeues on work role" \
  "$POLICY_LUNA_RETRY_EXPECTED" "$(cut -f1-3 <<< "$(sed -n '1p' <<< "$MODEL_POLICY_PIPELINE_OUTPUT")")"
assert_eq "pipeline-system repeated work failure routes once to advisor, never Sol" \
  $'advisor\twork\t2\ttrue\t1\thand-loop-breaker' \
  "$(cut -f4-9 <<< "$(sed -n '1p' <<< "$MODEL_POLICY_PIPELINE_OUTPUT")")"
assert_eq "pipeline-system advisor retry parks once without a hold loop" \
  $'conclude\twork\t1\t1\t0' "$(tail -n 1 <<< "$MODEL_POLICY_PIPELINE_OUTPUT")"

MODEL_POLICY_LOOP_HOME="$(mktemp -d)"
jq '.roles.advisor.disabled = false' "$MODEL_POLICY_TEST_DEFAULT_FILE" > "$MODEL_POLICY_LOOP_HOME/model-policy.json"
MODEL_POLICY_LOOP_OUTPUT="$(AGENT_HOME="$MODEL_POLICY_LOOP_HOME" SCRIPT_DIR="$SCRIPT_DIR" AGENT_DRY_RUN=0 bash -c '
  set -euo pipefail
  source "$SCRIPT_DIR/lib.sh"
  gh() { printf "%s\\n" "{\"number\":510001,\"labels\":[]}"; }
  route_to_advisor() { printf "%s\n" "$1" >> "$AGENT_HOME/advisor-routes"; }
  issue_own_open_agent_pr() { return 1; }
  record_run_decision() { :; }
  hold_issue() { printf "%s\t%s\n" "$1" "$*" >> "$AGENT_HOME/holds"; }
  conclude_run() { printf "%s\n" "$1" >> "$AGENT_HOME/concluded"; printf "%s\n" "$2" >> "$AGENT_HOME/mail"; }
  : > "$AGENT_HOME/concluded"
  : > "$AGENT_HOME/mail"
  state_merge 510001 '\''{"attempts":1}'\''
  model_policy_begin_unit 510001 implement ready-for-agent
  model_policy_record_failure 510001 work package-gate "same blocker" "first evidence" 1 ready-for-agent implement
  printf "%s\t%s\n" "$(state_read 510001 | jq -r .model_policy.step)" "$(state_read 510001 | jq -r .model_policy.failure.transition)"
  model_policy_record_failure 510001 work package-gate "same blocker" "second evidence" 1 ready-for-agent implement
  printf "%s\t%s\n" "$(state_read 510001 | jq -r .model_policy.step)" "$(wc -l < "$AGENT_HOME/advisor-routes" | tr -d "[:space:]")"
  state_merge 510001 '\''.model_policy.step="work_retry" | .model_policy.advisor_decision="apply suggestion"'\''
  identity="$(model_policy state-identity 510001 implement)"
  model_policy_record_failure 510001 work_retry package-gate "same blocker" "retry evidence" 1 ready-for-agent implement
  model_policy_begin_unit 510001 implement on-hold
  state="$(state_read 510001)"
  printf "park=%s|%s|%s|%s|%s|%s|%s|%s\n" \
    "$(jq -r .model_policy.step <<< "$state")" \
    "$(jq -r .model_policy.failure.step <<< "$state")" \
    "$(jq -r .model_policy.failure.transition <<< "$state")" \
    "$(jq -r .model_policy.failure.role <<< "$state")" \
    "$identity" \
    "$(wc -l < "$AGENT_HOME/holds" | tr -d "[:space:]")" \
    "$(wc -l < "$AGENT_HOME/supervisor-inbox" | tr -d "[:space:]")" \
    "$(wc -l 2>/dev/null < "$AGENT_HOME/concluded" | tr -d "[:space:]")"
  printf "counts=%s/%s\n" "$(jq -r .attempts <<< "$state")" \
    "$(jq -r ".model_policy.failures | length" <<< "$state")"
  printf "failure-evidence=%s\n" "$(jq -r .model_policy.failure.evidence <<< "$state")"
  printf "hold-call=%s\n" "$(cat "$AGENT_HOME/holds")"
  printf "inbox=%s\n" "$(cat "$AGENT_HOME/supervisor-inbox")"
  printf "mail-count=%s\n" "$(wc -l < "$AGENT_HOME/mail" | tr -d "[:space:]")"
  printf "resume=%s|%s|%s\n" "$(state_read 510001 | jq -r .model_policy.step)" \
    "$(state_read 510001 | jq -r .model_policy.active)" \
    "$(wc -l < "$AGENT_HOME/advisor-routes" | tr -d "[:space:]")"
')"
rm -rf -- "$MODEL_POLICY_LOOP_HOME"
assert_eq "issue implement loop is Luna, Luna, advisor, one advised Luna then park" \
  "$(printf 'work\twork\nadvisor\t1')" "$(sed -n '1,2p' <<< "$MODEL_POLICY_LOOP_OUTPUT")"
assert_eq "advisor-seen work_retry parks at conclude without dropping the role or hold" \
  "$(printf 'park=conclude|work_retry|conclude|work|%s|1|1|0' "$POLICY_WORK_IDENTITY")" \
  "$(sed -n '3p' <<< "$MODEL_POLICY_LOOP_OUTPUT")"
assert_contains "the loop breaker preserves the attempt and three failure records" \
  "$MODEL_POLICY_LOOP_OUTPUT" "counts=1/3"
assert_contains "park retains evidence from both work failures and the advisor-guided retry" \
  "$MODEL_POLICY_LOOP_OUTPUT" "failure-evidence=Repeated classified failure at package-gate."
assert_contains "park preserves the first failure evidence" \
  "$MODEL_POLICY_LOOP_OUTPUT" "Previous failure: same blocker first evidence"
assert_contains "park includes the current retry evidence" \
  "$MODEL_POLICY_LOOP_OUTPUT" "Current failure: same blocker retry evidence"
assert_contains "hold is assigned to the loop breaker with its explicit release condition" \
  "$MODEL_POLICY_LOOP_OUTPUT" "--holder hand-loop-breaker"
assert_contains "hold records the supervisor release condition" \
  "$MODEL_POLICY_LOOP_OUTPUT" "--release supervisor reviews the recorded failure and explicitly requeues"
assert_contains "loop breaker writes one actionable supervisor inbox event" \
  "$MODEL_POLICY_LOOP_OUTPUT" "hand-loop-breaker issue=#510001 action=parked role=work stage=package-gate"
assert_contains "park does not conclude or send mail" "$MODEL_POLICY_LOOP_OUTPUT" "mail-count=0"
assert_contains "a later begin on the held terminal state does not redispatch or add an advisor event" \
  "$MODEL_POLICY_LOOP_OUTPUT" "resume=conclude|null|1"

POLICY_STARTED_HOME="$(mktemp -d)"
POLICY_STARTED_STATE="$(AGENT_HOME="$POLICY_STARTED_HOME" SCRIPT_DIR="$SCRIPT_DIR" bash -c '
  set -euo pipefail
  source "$SCRIPT_DIR/lib.sh"
  state_merge 509994 '\''{"attempts":4}'\''
  state_merge 509994 '\''.model_policy = {"unit":"implement","active":{"unit":"implement"}}'\''
  model_policy_mark_started 509994 implement aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
  started_at="$(jq -r '\''.run.implement_started_at'\'' "$(state_file 509994)")"
  model_policy_mark_started 509994 implement bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
  jq -e --arg started "$started_at" '\''.run.implement_started_at == $started and .run.implement_started_sha == "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"'\'' "$(state_file 509994)" >/dev/null
  state_merge 509994 '\''.attempts = 5'\''
  model_policy_mark_started 509994 implement cccccccccccccccccccccccccccccccccccccccc
  jq -e '\''.run.implement_started_attempt == 5 and (.run.implement_started_at | test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$")) and .run.implement_started_sha == "cccccccccccccccccccccccccccccccccccccccc"'\'' "$(state_file 509994)" >/dev/null
  state_read 509994
')"
assert_true "real implement start records its timestamp for the conclusion guard" \
  jq -e '.run.implement_started_at != null' >/dev/null <<< "$POLICY_STARTED_STATE"
assert_eq "implement attempts append exact lifecycle starts before the hourly census" \
  $'4\taaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\n5\tcccccccccccccccccccccccccccccccccccccccc' \
  "$(jq -sr '[.[] | select(.event_type == "implementation-started")] | sort_by(.attempt)[] | [.attempt,.sha] | @tsv' \
    "$POLICY_STARTED_HOME"/metrics/efficiency-*.jsonl)"
rm -rf "$POLICY_STARTED_HOME"

POLICY_REQUEUE_HOME="$(mktemp -d)"
POLICY_REQUEUE_STATE="$(AGENT_HOME="$POLICY_REQUEUE_HOME" SCRIPT_DIR="$SCRIPT_DIR" bash -c '
  set -euo pipefail
  source "$SCRIPT_DIR/lib.sh"
  state_merge 509993 '\''{"attempts":0,"model_policy":{"unit":"implement","step":"conclude","failure":{"reason":"old run","recorded_at":"2026-09-20T00:00:00Z"}}}'\''
  model_policy_begin_unit 509993 implement ready-for-agent
  state_read 509993
')"
assert_eq "requeued implement work restarts stale conclude at the policy initial step" \
  "$(model_policy initial-step)" "$(jq -r '.model_policy.step' <<< "$POLICY_REQUEUE_STATE")"
assert_true "requeued implement work drops stale failure evidence" \
  jq -e '.model_policy.failure == null' >/dev/null <<< "$POLICY_REQUEUE_STATE"
rm -rf "$POLICY_REQUEUE_HOME"

STATE_REQUEUE_HOME="$(mktemp -d)"
STATE_REQUEUE_RESULT="$(AGENT_HOME="$STATE_REQUEUE_HOME" SCRIPT_DIR="$SCRIPT_DIR" REPO=test/repo bash -c '
  set -euo pipefail
  source "$SCRIPT_DIR/lib.sh"
  roadmap_ensure_issue_parent() { :; }
  ensure_state_labels() { :; }
  guarded_write() { printf "write:"; printf "%s " "$@"; printf "\\n"; }
  recut_parent_has_open_child() { return 1; }
  state_merge 509989 '\''{"attempts":4,"state":"concluded","model_policy":{"unit":"implement","step":"conclude","failure":{"reason":"old episode"}},"pipeline_system":{"enabled":true,"resume_artifact_sha":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","resume_artifact_attempt":4}}'\''
  state_requeue 509989 "" conclusion-requeue
  state_read 509989 | jq -c .
')"
STATE_REQUEUE_STATE="$(tail -n 1 <<< "$STATE_REQUEUE_RESULT")"
assert_eq "state_requeue clears prior implement attempts" 0 "$(jq -r '.attempts' <<< "$STATE_REQUEUE_STATE")"
assert_eq "state_requeue retains saved implementation artifact" \
  aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa "$(jq -r '.pipeline_system.resume_artifact_sha' <<< "$STATE_REQUEUE_STATE")"
assert_eq "state_requeue re-aims checkpoint at the preceding dispatch" \
  0 "$(jq -r '.pipeline_system.resume_artifact_attempt' <<< "$STATE_REQUEUE_STATE")"
assert_eq "state_requeue starts policy at its configured first step" \
  "$(model_policy initial-step)" "$(jq -r '.model_policy.step' <<< "$STATE_REQUEUE_STATE")"
assert_eq "state_requeue marks the new ready episode" ready-for-agent \
  "$(jq -r '.state' <<< "$STATE_REQUEUE_STATE")"
assert_true "state_requeue records an episode timestamp and archives old policy" \
  jq -e '.requeued_at != null and .model_policy.history[-1].requeued == true' >/dev/null <<< "$STATE_REQUEUE_STATE"
assert_contains "state_requeue swaps terminal label for ready queue label" \
  "$STATE_REQUEUE_RESULT" "--add-label ready-for-agent"
assert_contains "state_requeue removes concluded state label" \
  "$STATE_REQUEUE_RESULT" "--remove-label concluded"
rm -rf "$STATE_REQUEUE_HOME"

HOLD_EXPIRY_HOME="$(mktemp -d)"
mkdir -p "$HOLD_EXPIRY_HOME/state"
printf '%s\n' '{"attempts":4,"state":"on-hold","pipeline_system":{"enabled":true,"resume_artifact_sha":"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb","resume_artifact_attempt":4},"hold":{"holder":"supervisor","release_condition":"review complete","expires_at":"2000-01-01T00:00:00Z","stage_before":"ready-for-agent","kind":"conclusion"}}' \
  > "$HOLD_EXPIRY_HOME/state/509988.json"
HOLD_EXPIRY_STATE="$(AGENT_HOME="$HOLD_EXPIRY_HOME" REPO=test/repo bash -c '
  set -euo pipefail
  source "$1/lib.sh"
  roadmap_ensure_issue_parent() { :; }
  gh() {
    if [ "$1 ${2:-}" = "issue list" ]; then
      # #193 batched snapshot: the row carries the view fields itself.
      printf "%s\\n" '\''[{"number":509988,"state":"OPEN","labels":[{"name":"on-hold"}],"comments":[],"title":"fixture"}]'\''
    elif [ "$1 ${2:-}" = "issue view" ]; then
      printf "%s\\n" '\''{"state":"OPEN","labels":[{"name":"on-hold"}],"comments":[],"title":"fixture"}'\''
    elif [ "$1 ${2:-}" = "pr list" ]; then
      printf "%s\\n" '\''[]'\''
    else
      return 64
    fi
  }
  git_fetch_hand_bounded() { :; }
  git() { :; }
  recut_parent_has_open_child() { return 1; }
  guarded_issue_comment() { :; }
  guarded_write() { :; }
  hold_sweep
  state_read 509988
' _ "$SCRIPT_DIR")"
assert_eq "hold expiry at the four-attempt cap grants a fresh dispatch budget" \
  0 "$(jq -r '.attempts' <<< "$HOLD_EXPIRY_STATE")"
assert_eq "hold expiry re-aims retained checkpoint at the preceding dispatch" \
  0 "$(jq -r '.pipeline_system.resume_artifact_attempt' <<< "$HOLD_EXPIRY_STATE")"
assert_true "hold expiry resumes the saved implementation artifact" \
  jq -e '.state == "ready-for-agent" and .hold == null and .pipeline_system.resume_artifact_sha == "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb" and .attempts < 4' \
    >/dev/null <<< "$HOLD_EXPIRY_STATE"
rm -rf "$HOLD_EXPIRY_HOME"

POLICY_ADMISSION_TEST_HOME="$(mktemp -d)"
POLICY_ADMISSION_TEST="$(AGENT_HOME="$POLICY_ADMISSION_TEST_HOME" SCRIPT_DIR="$SCRIPT_DIR" bash -c '
  set -euo pipefail
  source "$SCRIPT_DIR/lib.sh"
  state_merge 509992 '\''{"attempts":4,"model_policy":{"unit":"implement","step":"advisor"}}'\''
  advisor_retry_admission 509992
  echo admitted
')"
assert_eq "persistent advisor step overrides legacy four-attempt admission cap" admitted "$POLICY_ADMISSION_TEST"
rm -rf "$POLICY_ADMISSION_TEST_HOME"

POLICY_SEED_HOME="$(mktemp -d)"
POLICY_SEED_IDENTITY="$(AGENT_HOME="$POLICY_SEED_HOME" MODEL_POLICY_TEST_SCRIPT_DIR="$SCRIPT_DIR" bash -c '
  source "$MODEL_POLICY_TEST_SCRIPT_DIR/lib.sh"
  model_policy identity work
')"
assert_eq "missing persistent policy seeds from the versioned default" \
  "$POLICY_WORK_IDENTITY" "$POLICY_SEED_IDENTITY"
assert_eq "seeded persistent policy is private" 600 "$(stat -c '%a' "$POLICY_SEED_HOME/model-policy.json")"
policy_active_file() {
  AGENT_HOME="$1" MODEL_POLICY_SOURCE_CHECK_ONLY=1 MODEL_POLICY_TEST_SCRIPT_DIR="$SCRIPT_DIR" bash -c '
    set -euo pipefail
    source "$MODEL_POLICY_TEST_SCRIPT_DIR/lib.sh"
    printf "%s\\n" "$MODEL_POLICY_FILE"
  '
}
POLICY_V1_MIGRATION_HOME="$(mktemp -d)"
POLICY_V1_MIGRATION_MODEL="gpt-6-legacy"
jq --arg model "$POLICY_V1_MIGRATION_MODEL" '
  .schema_version = 1
  | del(.roles["hand-claude"], .roles["triage-haiku"], .roles["unit-review-fallback"], .roles["unit-implement-hotfix"], .allow_roles)
  | .roles |= with_entries(if .value.provider == "codex" then del(.value.fallback_model) else . end)
  | .roles.work.fallback_model = $model
  | .roles["legacy-fallback"] = {provider:"codex", model:$model, effort:"max", disabled:true}
' "$SCRIPT_DIR/model-policy.default.json" > "$POLICY_V1_MIGRATION_HOME/model-policy.json"
chmod 640 "$POLICY_V1_MIGRATION_HOME/model-policy.json"
cp -- "$POLICY_V1_MIGRATION_HOME/model-policy.json" "$POLICY_V1_MIGRATION_HOME/before.json"
POLICY_V1_MIGRATION_FILE="$(policy_file_for_home "$POLICY_V1_MIGRATION_HOME")"
POLICY_V1_MIGRATION_CANONICAL_BEFORE="$(sha256sum "$POLICY_V1_MIGRATION_HOME/model-policy.json" | cut -d' ' -f1)"
POLICY_V1_MIGRATION_FILE_MODE="$(stat -c '%a' "$POLICY_V1_MIGRATION_FILE")"
# The quoted inner script reads these variables from its child environment.
# shellcheck disable=SC2016
# Source scanning is covered independently below; these cases exercise the policy view.
POLICY_V1_SOURCE_CHECK="$(ZF_CHECK_RULINGS_POLICY_SOURCE_SCAN_VERIFIED=1 AGENT_HOME="$POLICY_V1_MIGRATION_HOME" MODEL_POLICY_SOURCE_CHECK_ONLY=1 MODEL_POLICY_TEST_SCRIPT_DIR="$SCRIPT_DIR" bash -c '
  set -euo pipefail
  source "$MODEL_POLICY_TEST_SCRIPT_DIR/lib.sh"
  model_policy source-check
')"
assert_eq "read-only source-check accepts a safe v1 custom fallback" clean "$POLICY_V1_SOURCE_CHECK"
assert_true "read-only source-check leaves the v1 policy unchanged" \
  cmp -s "$POLICY_V1_MIGRATION_HOME/before.json" "$POLICY_V1_MIGRATION_HOME/model-policy.json"
POLICY_V1_MIGRATION_FILE="$(policy_active_file "$POLICY_V1_MIGRATION_HOME")"
cp -- "$POLICY_V1_MIGRATION_FILE" "$POLICY_V1_MIGRATION_HOME/active-before.json"
POLICY_V1_MIGRATION_MODE="$(stat -c '%a' "$POLICY_V1_MIGRATION_FILE")"
# The quoted inner script reads these variables from its child environment.
# shellcheck disable=SC2016
POLICY_V1_MIGRATION_IDENTITY="$(AGENT_HOME="$POLICY_V1_MIGRATION_HOME" MODEL_POLICY_TEST_SCRIPT_DIR="$SCRIPT_DIR" bash -c '
  set -euo pipefail
  source "$MODEL_POLICY_TEST_SCRIPT_DIR/lib.sh"
  model_policy identity work
')"
assert_eq "ordinary model-policy initialization migrates a valid v1 custom fallback" \
  "$POLICY_WORK_IDENTITY" "$POLICY_V1_MIGRATION_IDENTITY"
assert_true "ordinary v1 migration installs the complete current default" \
  jq -e --slurpfile default "$SCRIPT_DIR/model-policy.default.json" '. == $default[0]' \
    "$POLICY_V1_MIGRATION_FILE"
mapfile -t POLICY_V1_MIGRATION_BACKUPS < <(find "$POLICY_V1_MIGRATION_HOME" -maxdepth 1 -type f \
  -name "$(basename "$POLICY_V1_MIGRATION_FILE").bak.schema-v*" -print)
assert_eq "ordinary v1 migration preserves the original bytes in one backup" \
  1 "${#POLICY_V1_MIGRATION_BACKUPS[@]}"
assert_true "ordinary v1 migration backup retains the original bytes and mode" \
  bash -c 'cmp -s "$1" "$2" && [[ "$(stat -c %a "$2")" == "$3" ]]' _ \
    "$POLICY_V1_MIGRATION_HOME/active-before.json" "${POLICY_V1_MIGRATION_BACKUPS[0]}" "$POLICY_V1_MIGRATION_MODE"
if model_policy_validate_file "$POLICY_V1_MIGRATION_FILE"; then
  POLICY_V1_MIGRATED_CHECK=clean
else
  POLICY_V1_MIGRATED_CHECK=invalid
fi
assert_eq "migrated active policy view passes current validation" clean "$POLICY_V1_MIGRATED_CHECK"
assert_eq "v1 migration leaves the Zenoforge-owned policy bytes unchanged" \
  "$POLICY_V1_MIGRATION_CANONICAL_BEFORE" \
  "$(sha256sum "$POLICY_V1_MIGRATION_HOME/model-policy.json" | cut -d' ' -f1)"
rm -rf "$POLICY_V1_MIGRATION_HOME"

# The v1 contract predates the current "sol" ban. The active-role fallback is
# discarded during migration, so validate it against the v1 forbidden list and
# validate the retained policy independently against the current policy.
POLICY_V1_CURRENTLY_FORBIDDEN_FALLBACK_HOME="$(mktemp -d)"
POLICY_V1_CURRENTLY_FORBIDDEN_FALLBACK_MODEL="gpt-6.1-sol"
jq --arg model "$POLICY_V1_CURRENTLY_FORBIDDEN_FALLBACK_MODEL" '
  .schema_version = 1
  | del(.roles["hand-claude"], .roles["triage-haiku"], .roles["unit-review-fallback"], .roles["unit-implement-hotfix"], .allow_roles)
  | .forbidden |= map(select(. != "sol"))
  | .roles |= with_entries(if .value.provider == "codex" then del(.value.fallback_model) else . end)
  | .roles.work.fallback_model = $model
' "$SCRIPT_DIR/model-policy.default.json" > \
  "$POLICY_V1_CURRENTLY_FORBIDDEN_FALLBACK_HOME/model-policy.json"
cp -- "$POLICY_V1_CURRENTLY_FORBIDDEN_FALLBACK_HOME/model-policy.json" \
  "$POLICY_V1_CURRENTLY_FORBIDDEN_FALLBACK_HOME/before.json"
POLICY_V1_CURRENTLY_FORBIDDEN_FILE="$(policy_active_file "$POLICY_V1_CURRENTLY_FORBIDDEN_FALLBACK_HOME")"
set +e
POLICY_V1_CURRENTLY_FORBIDDEN_SOURCE_CHECK="$(ZF_CHECK_RULINGS_POLICY_SOURCE_SCAN_VERIFIED=1 AGENT_HOME="$POLICY_V1_CURRENTLY_FORBIDDEN_FALLBACK_HOME" \
  MODEL_POLICY_SOURCE_CHECK_ONLY=1 MODEL_POLICY_TEST_SCRIPT_DIR="$SCRIPT_DIR" bash -c '
    set -euo pipefail
    source "$MODEL_POLICY_TEST_SCRIPT_DIR/lib.sh"
    model_policy source-check
  ' 2>/dev/null)"
POLICY_V1_CURRENTLY_FORBIDDEN_SOURCE_STATUS=$?
set -e
assert_eq "read-only source-check accepts a v1 fallback forbidden only by current policy" \
  0 "$POLICY_V1_CURRENTLY_FORBIDDEN_SOURCE_STATUS"
assert_eq "read-only source-check reports the v1 fallback policy as clean" \
  clean "$POLICY_V1_CURRENTLY_FORBIDDEN_SOURCE_CHECK"
assert_true "read-only source-check leaves the v1 fallback policy unchanged" \
  cmp -s "$POLICY_V1_CURRENTLY_FORBIDDEN_FALLBACK_HOME/before.json" \
    "$POLICY_V1_CURRENTLY_FORBIDDEN_FILE"
set +e
POLICY_V1_CURRENTLY_FORBIDDEN_IDENTITY="$(AGENT_HOME="$POLICY_V1_CURRENTLY_FORBIDDEN_FALLBACK_HOME" \
  MODEL_POLICY_TEST_SCRIPT_DIR="$SCRIPT_DIR" bash -c '
    set -euo pipefail
    source "$MODEL_POLICY_TEST_SCRIPT_DIR/lib.sh"
    model_policy identity work
  ' 2>/dev/null)"
POLICY_V1_CURRENTLY_FORBIDDEN_IDENTITY_STATUS=$?
set -e
assert_eq "migration discards a v1 fallback forbidden only by current policy" \
  0 "$POLICY_V1_CURRENTLY_FORBIDDEN_IDENTITY_STATUS"
assert_eq "migration resolves work identity after discarding a v1 fallback forbidden only by current policy" \
  "$POLICY_WORK_IDENTITY" "$POLICY_V1_CURRENTLY_FORBIDDEN_IDENTITY"
mapfile -t POLICY_V1_CURRENTLY_FORBIDDEN_BACKUPS < <(find "$POLICY_V1_CURRENTLY_FORBIDDEN_FALLBACK_HOME" -maxdepth 1 -type f \
  -name "$(basename "$POLICY_V1_CURRENTLY_FORBIDDEN_FILE").bak.schema-v*" -print)
assert_eq "v1 fallback migration still preserves the original policy in one backup" 1 \
  "${#POLICY_V1_CURRENTLY_FORBIDDEN_BACKUPS[@]}"
assert_true "v1 fallback migration installs the complete current default" \
  jq -e --slurpfile default "$SCRIPT_DIR/model-policy.default.json" '. == $default[0]' \
    "$POLICY_V1_CURRENTLY_FORBIDDEN_FILE"
POLICY_V1_CURRENTLY_FORBIDDEN_BACKUPS=("$POLICY_V1_CURRENTLY_FORBIDDEN_FILE".bak.*)
assert_eq "v1 fallback migration still preserves the original policy in one backup" \
  1 "${#POLICY_V1_CURRENTLY_FORBIDDEN_BACKUPS[@]}"
assert_true "v1 fallback migration installs the complete current default" \
  jq -e --slurpfile default "$SCRIPT_DIR/model-policy.default.json" '. == $default[0]' \
    "$POLICY_V1_CURRENTLY_FORBIDDEN_FILE"
assert_true "migration leaves the Zenoforge-owned v1 policy unchanged" \
  cmp -s "$POLICY_V1_CURRENTLY_FORBIDDEN_FALLBACK_HOME/before.json" \
    "$POLICY_V1_CURRENTLY_FORBIDDEN_FALLBACK_HOME/model-policy.json"
rm -rf "$POLICY_V1_CURRENTLY_FORBIDDEN_FALLBACK_HOME"

POLICY_V1_RETAINED_INVALID_HOME="$(mktemp -d)"
jq '
  .schema_version = 1
  | del(.roles["hand-claude"], .roles["triage-haiku"], .roles["unit-review-fallback"], .roles["unit-implement-hotfix"], .allow_roles)
  | .forbidden |= map(select(. != "sol"))
  | .roles |= with_entries(if .value.provider == "codex" then del(.value.fallback_model) else . end)
  | .roles.work.model = "gpt-6.1-sol"
  | .roles.work.fallback_model = "gpt-6.1-sol"
' "$SCRIPT_DIR/model-policy.default.json" > "$POLICY_V1_RETAINED_INVALID_HOME/model-policy.json"
cp -- "$POLICY_V1_RETAINED_INVALID_HOME/model-policy.json" \
  "$POLICY_V1_RETAINED_INVALID_HOME/before.json"
POLICY_V1_RETAINED_INVALID_FILE="$(policy_file_for_home "$POLICY_V1_RETAINED_INVALID_HOME")"
set +e
POLICY_V1_RETAINED_INVALID_STATUS=0
AGENT_HOME="$POLICY_V1_RETAINED_INVALID_HOME" MODEL_POLICY_TEST_SCRIPT_DIR="$SCRIPT_DIR" bash -c '
  set -euo pipefail
  source "$MODEL_POLICY_TEST_SCRIPT_DIR/lib.sh"
  model_policy identity work
' >/dev/null 2>&1 || POLICY_V1_RETAINED_INVALID_STATUS=$?
set -e
assert_eq "migration rejects a current-forbidden model in retained v1 settings" \
  1 "$POLICY_V1_RETAINED_INVALID_STATUS"
assert_true "rejected v1 policy is not backed up or replaced before validation" \
  cmp -s "$POLICY_V1_RETAINED_INVALID_HOME/before.json" \
    "$POLICY_V1_RETAINED_INVALID_FILE"
assert_eq "rejected v1 policy creates no migration backup" 0 \
  "$(find "$POLICY_V1_RETAINED_INVALID_HOME" -maxdepth 1 -type f \
    -path "$POLICY_V1_RETAINED_INVALID_FILE.bak.schema-v*" -print | wc -l | tr -d '[:space:]')"
rm -rf "$POLICY_V1_RETAINED_INVALID_HOME"

POLICY_READ_ONLY_MISSING_HOME="$(mktemp -d)"
set +e
POLICY_READ_ONLY_MISSING_OUTPUT="$(AGENT_HOME="$POLICY_READ_ONLY_MISSING_HOME" \
  MODEL_POLICY_READ_ONLY=1 MODEL_POLICY_SOURCE_CHECK_ONLY=1 \
  MODEL_POLICY_TEST_SCRIPT_DIR="$SCRIPT_DIR" bash -c '
    set -euo pipefail
    source "$MODEL_POLICY_TEST_SCRIPT_DIR/lib.sh"
    model_policy identity work
  ' 2>&1)"
POLICY_READ_ONLY_MISSING_STATUS=$?
set -e
assert_eq "read-only model lookup rejects a missing persistent policy" \
  1 "$POLICY_READ_ONLY_MISSING_STATUS"
assert_contains "read-only model lookup explains the missing persisted policy" \
  "$POLICY_READ_ONLY_MISSING_OUTPUT" "persistent policy is missing (read-only)"
assert_eq "read-only model lookup does not seed a missing policy" \
  0 "$([[ ! -e "$POLICY_READ_ONLY_MISSING_HOME/model-policy.json" ]] && echo 0 || echo 1)"
rm -rf "$POLICY_READ_ONLY_MISSING_HOME"

POLICY_READ_ONLY_LEGACY_HOME="$(mktemp -d)"
jq 'del(.schema_version, .roles.work.fallback_model, .roles.production.fallback_model, .roles.review)
  | .roles.work.service_tier = "operator-fast"
  | .switches["roadmap-order"] = false
  | .fixture_live_marker = "legacy-policy"' \
  "$SCRIPT_DIR/model-policy.default.json" > "$POLICY_READ_ONLY_LEGACY_HOME/model-policy.json"
cp -- "$POLICY_READ_ONLY_LEGACY_HOME/model-policy.json" \
  "$POLICY_READ_ONLY_LEGACY_HOME/model-policy.expected.json"
POLICY_READ_ONLY_LEGACY_FILE="$(policy_file_for_home "$POLICY_READ_ONLY_LEGACY_HOME")"
POLICY_READ_ONLY_LEGACY_IDENTITY="$(AGENT_HOME="$POLICY_READ_ONLY_LEGACY_HOME" \
  MODEL_POLICY_READ_ONLY=1 MODEL_POLICY_SOURCE_CHECK_ONLY=1 \
  MODEL_POLICY_TEST_SCRIPT_DIR="$SCRIPT_DIR" bash -c '
    set -euo pipefail
    source "$MODEL_POLICY_TEST_SCRIPT_DIR/lib.sh"
    model_policy identity work
  ')"
assert_eq "read-only lookup resolves an existing legacy policy" \
  "$POLICY_WORK_IDENTITY" "$POLICY_READ_ONLY_LEGACY_IDENTITY"
assert_eq "read-only lookup leaves legacy policy bytes unchanged" \
  0 "$(cmp -s "$POLICY_READ_ONLY_LEGACY_HOME/model-policy.expected.json" \
    "$POLICY_READ_ONLY_LEGACY_FILE" && echo 0 || echo 1)"
assert_eq "read-only lookup does not create a migration backup" \
  0 "$(find "$POLICY_READ_ONLY_LEGACY_HOME" -maxdepth 1 -type f \
    -path "$POLICY_READ_ONLY_LEGACY_FILE.bak.schema-v*" -print | wc -l | tr -d '[:space:]')"
rm -rf "$POLICY_READ_ONLY_LEGACY_HOME"

FORBIDDEN_TEST_MODEL="$(jq -r '.forbidden[0]' "$SCRIPT_DIR/model-policy.default.json")"
jq --arg forbidden "$FORBIDDEN_TEST_MODEL" '.roles.work.model = $forbidden' "$SCRIPT_DIR/model-policy.default.json" \
  > "$POLICY_SEED_HOME/model-policy.json"
set +e
POLICY_INVALID_OUTPUT="$(AGENT_HOME="$POLICY_SEED_HOME" MODEL_POLICY_TEST_SCRIPT_DIR="$SCRIPT_DIR" bash -c '
  source "$MODEL_POLICY_TEST_SCRIPT_DIR/lib.sh"
  model_policy identity work
' 2>&1)"
POLICY_INVALID_STATUS=$?
set -e
assert_eq "persistent policy rejects a forbidden model" 1 "$POLICY_INVALID_STATUS"
rm -rf "$POLICY_SEED_HOME"

POLICY_STALE_LIVE_HOME="$(mktemp -d)"
POLICY_STALE_WORD="$(jq -r '.forbidden[0]' "$SCRIPT_DIR/model-policy.default.json")"
jq --arg forbidden "$POLICY_STALE_WORD" '.roles.work.model = $forbidden | .forbidden |= map(select(. != $forbidden))' \
  "$SCRIPT_DIR/model-policy.default.json" > "$POLICY_STALE_LIVE_HOME/model-policy.json"
set +e
POLICY_STALE_LIVE_OUTPUT="$(AGENT_HOME="$POLICY_STALE_LIVE_HOME" bash -c 'source "$1/lib.sh"' _ "$SCRIPT_DIR" 2>&1)"
POLICY_STALE_LIVE_STATUS=$?
set -e
assert_eq "live policy cannot bypass versioned forbidden names by omitting one" 1 "$POLICY_STALE_LIVE_STATUS"
assert_contains "the invalid live role fails closed during policy initialization" \
  "$POLICY_STALE_LIVE_OUTPUT" "model policy cannot resolve the work role"
rm -rf "$POLICY_STALE_LIVE_HOME"

set +e
POLICY_SOURCE_CHECK_OUTPUT="$(model_policy source-check 2>&1)"
POLICY_SOURCE_CHECK_STATUS=$?
set -e
assert_eq "maintainer ruling words and intent stay outside executable model scan" \
  '0:clean' "$POLICY_SOURCE_CHECK_STATUS:$POLICY_SOURCE_CHECK_OUTPUT"

POLICY_NUL_SCAN_DIR="$INBOX_HELPER_HOME/policy-source-scan"
mkdir -p "$POLICY_NUL_SCAN_DIR"
cp "$SCRIPT_DIR/model-policy.default.json" "$POLICY_NUL_SCAN_DIR/model-policy.default.json"
printf 'ordinary text\0continued text\n' > "$POLICY_NUL_SCAN_DIR/source.fixture"
set +e
POLICY_NUL_SCAN_OUTPUT="$(AGENT_HOME="$INBOX_HELPER_HOME/policy-source-scan-agent" bash -c '
  set -euo pipefail
  source "$1/lib.sh"
  MODEL_POLICY_DEFAULT="$2/model-policy.default.json"
  model_policy_scan_sources
  printf clean
' _ "$SCRIPT_DIR" "$POLICY_NUL_SCAN_DIR" 2>&1)"
POLICY_NUL_SCAN_STATUS=$?
set -e
assert_eq "source scan accepts binary NUL without Bash warning" \
  '0:clean' "$POLICY_NUL_SCAN_STATUS:$POLICY_NUL_SCAN_OUTPUT"

POLICY_SELECTION_SCAN_DIR="$INBOX_HELPER_HOME/policy-source-selection-scan"
mkdir -p "$POLICY_SELECTION_SCAN_DIR"
cp "$SCRIPT_DIR/model-policy.default.json" "$POLICY_SELECTION_SCAN_DIR/model-policy.default.json"
cat > "$POLICY_SELECTION_SCAN_DIR/source.py" <<'EOF'
errors.append("Claude plugin manifest is missing")
print("CLAUDE-MCP-BROWSER-DRIFT")
EOF
run_policy_selection_scan() {
  AGENT_HOME="$INBOX_HELPER_HOME/policy-source-selection-agent" bash -c '
    set -euo pipefail
    source "$1/lib.sh"
    MODEL_POLICY_DEFAULT="$2/model-policy.default.json"
    model_policy_scan_sources
    printf clean
  ' _ "$SCRIPT_DIR" "$POLICY_SELECTION_SCAN_DIR" 2>&1
}
set +e
POLICY_SELECTION_SCAN_OUTPUT="$(run_policy_selection_scan)"
POLICY_SELECTION_SCAN_STATUS=$?
set -e
assert_eq "source scan allows Claude integration/config diagnostics" \
  '0:clean' "$POLICY_SELECTION_SCAN_STATUS:$POLICY_SELECTION_SCAN_OUTPUT"

printf 'MODEL = "claude"\n' > "$POLICY_SELECTION_SCAN_DIR/source.py"
set +e
POLICY_SELECTION_SCAN_OUTPUT="$(run_policy_selection_scan)"
POLICY_SELECTION_SCAN_STATUS=$?
set -e
assert_eq "source scan rejects forbidden model assignment" 1 "$POLICY_SELECTION_SCAN_STATUS"
assert_contains "source scan reports forbidden model assignment" \
  "$POLICY_SELECTION_SCAN_OUTPUT" "forbidden model name 'claude'"

printf 'command = ["codex", "--model", "sonnet"]\n' > "$POLICY_SELECTION_SCAN_DIR/source.py"
set +e
POLICY_SELECTION_SCAN_OUTPUT="$(run_policy_selection_scan)"
POLICY_SELECTION_SCAN_STATUS=$?
set -e
assert_eq "source scan rejects forbidden CLI model selection" 1 "$POLICY_SELECTION_SCAN_STATUS"
assert_contains "source scan reports forbidden CLI model selection" \
  "$POLICY_SELECTION_SCAN_OUTPUT" "forbidden model name 'sonnet'"

ps() { printf '%s\n' "$MODEL_POLICY_TEST_PROCESSES"; }
MODEL_POLICY_TEST_PROCESSES='0 claude claude --version'
assert_eq "live scan ignores an unrelated interactive Claude process" clean "$(model_policy live)"
MODEL_POLICY_TOKEN_TEST="$(printf 'node\tnode $HOME/wt/x/packages/example-admin/build.mjs\n' | awk -v forbidden_words="sol" "$(sed -n '/function prohibited/,/^          return 0$/p' "$SCRIPT_DIR/lib.d/model-policy.sh")"'
          }
          { print prohibited($0) }')"
assert_eq "live scan matches forbidden names as whole tokens, not substrings" 0 "$MODEL_POLICY_TOKEN_TEST"
MODEL_POLICY_TEST_PROCESSES="0 bash bash -c rg claude -- $HOME/wt/issue-42 --glob '*.sh'"
assert_eq "live scan ignores forbidden model text in a worktree shell command" clean "$(model_policy live)"
MODEL_POLICY_TEST_PROCESSES="0 claude claude --model custom --settings $AGENT_HOME/checkout/engine/prompts/agent-settings.json --add-dir $HOME/wt/issue-42"
set +e
MODEL_POLICY_LIVE_OUTPUT="$(model_policy live 2>&1)"
MODEL_POLICY_LIVE_STATUS=$?
set -e
assert_eq "live scan rejects pipeline Claude even with a custom model" "1" "$MODEL_POLICY_LIVE_STATUS"
assert_contains "live scan names forbidden runtime status" "$MODEL_POLICY_LIVE_OUTPUT" forbidden
MODEL_POLICY_SETTINGS_CONFIG="$test_env_root/model-policy-settings/.zenoforge"
mkdir -p "$MODEL_POLICY_SETTINGS_CONFIG/prompts"
printf '{}\n' > "$MODEL_POLICY_SETTINGS_CONFIG/prompts/agent-settings.json"
MODEL_POLICY_PREVIOUS_CONFIG_ROOT="${ZF_CONFIG_ROOT-}"
MODEL_POLICY_CONFIG_ROOT_WAS_SET=0
[[ -n "${ZF_CONFIG_ROOT+x}" ]] && MODEL_POLICY_CONFIG_ROOT_WAS_SET=1
ZF_CONFIG_ROOT="$MODEL_POLICY_SETTINGS_CONFIG"
MODEL_POLICY_TEST_PROCESSES="0 claude claude --model custom --settings $MODEL_POLICY_SETTINGS_CONFIG/prompts/agent-settings.json"
set +e
MODEL_POLICY_LIVE_OUTPUT="$(model_policy live 2>&1)"
MODEL_POLICY_LIVE_STATUS=$?
set -e
assert_eq "live scan recognizes target-config agent settings" "1" "$MODEL_POLICY_LIVE_STATUS"
assert_contains "target-config settings mark a pipeline Claude process" "$MODEL_POLICY_LIVE_OUTPUT" forbidden
if (( MODEL_POLICY_CONFIG_ROOT_WAS_SET )); then ZF_CONFIG_ROOT="$MODEL_POLICY_PREVIOUS_CONFIG_ROOT"; else unset ZF_CONFIG_ROOT; fi
MODEL_POLICY_TEST_PROCESSES="0 claude claude --model custom --cd $HOME/wt/issue-42"
set +e
MODEL_POLICY_LIVE_OUTPUT="$(model_policy live 2>&1)"
MODEL_POLICY_LIVE_STATUS=$?
set -e
assert_eq "live scan rejects noninteractive pipeline Claude without settings marker" "1" "$MODEL_POLICY_LIVE_STATUS"
MODEL_POLICY_TEST_PROCESSES="0 codex codex exec --cd $HOME/wt/issue-42 -m $FORBIDDEN_TEST_MODEL -c model_reasoning_effort=$POLICY_WORK_EFFORT"
set +e
MODEL_POLICY_LIVE_OUTPUT="$(model_policy live 2>&1)"
MODEL_POLICY_LIVE_STATUS=$?
set -e
assert_eq "live scan rejects a forbidden Codex model" "1" "$MODEL_POLICY_LIVE_STATUS"
assert_contains "live scan reports a forbidden Codex model" "$MODEL_POLICY_LIVE_OUTPUT" forbidden
UNCONFIGURED_MODEL="unconfigured-$POLICY_WORK_MODEL"
MODEL_POLICY_TEST_PROCESSES="0 codex codex exec --cd $HOME/wt/issue-42 -m $UNCONFIGURED_MODEL -c model_reasoning_effort=$POLICY_WORK_EFFORT"
set +e
MODEL_POLICY_LIVE_OUTPUT="$(model_policy live 2>&1)"
MODEL_POLICY_LIVE_STATUS=$?
set -e
assert_eq "live scan rejects unconfigured Codex model" "1" "$MODEL_POLICY_LIVE_STATUS"
MODEL_POLICY_TEST_PROCESSES="0 codex codex exec --cd $HOME/wt/issue-42 -m $POLICY_WORK_MODEL -c model_reasoning_effort=$POLICY_WORK_EFFORT"
set +e
MODEL_POLICY_LIVE_OUTPUT="$(model_policy live 2>&1)"
MODEL_POLICY_LIVE_STATUS=$?
set -e
assert_eq "live scan accepts an allowed Codex identity" "0" "$MODEL_POLICY_LIVE_STATUS"
assert_eq "live scan returns clean for an allowed Codex identity" clean "$MODEL_POLICY_LIVE_OUTPUT"
assert_not_contains "live scan has no jq compile error for an allowed identity" "$MODEL_POLICY_LIVE_OUTPUT" "jq: error:"
# A run older than the live policy file was dispatched under an earlier role setting: only
# forbidden names apply to it, so a role change does not turn in-flight agents BROKEN.
EARLIER_POLICY_MODEL="earlier-$POLICY_WORK_MODEL"
EARLIER_POLICY_EFFORT="earlier-$POLICY_WORK_EFFORT"
MODEL_POLICY_TEST_PROCESSES="99999999 codex codex exec --cd $HOME/wt/issue-42 -m $EARLIER_POLICY_MODEL -c model_reasoning_effort=$EARLIER_POLICY_EFFORT"
assert_eq "live scan accepts a run that predates the policy file under an earlier role" clean "$(model_policy live)"
MODEL_POLICY_TEST_PROCESSES="0 codex codex exec --cd $HOME/wt/issue-42 -m $EARLIER_POLICY_MODEL -c model_reasoning_effort=$EARLIER_POLICY_EFFORT"
set +e
MODEL_POLICY_LIVE_OUTPUT="$(model_policy live 2>&1)"
MODEL_POLICY_LIVE_STATUS=$?
set -e
assert_eq "live scan still rejects a new run outside the configured roles" "1" "$MODEL_POLICY_LIVE_STATUS"
MODEL_POLICY_TEST_PROCESSES="99999999 codex codex exec --cd $HOME/wt/issue-42 -m $FORBIDDEN_TEST_MODEL -c model_reasoning_effort=$POLICY_WORK_EFFORT"
set +e
MODEL_POLICY_LIVE_OUTPUT="$(model_policy live 2>&1)"
MODEL_POLICY_LIVE_STATUS=$?
set -e
assert_eq "live scan rejects a forbidden model even in a run that predates the policy" "1" "$MODEL_POLICY_LIVE_STATUS"
unset -f ps


lib_case_exit
