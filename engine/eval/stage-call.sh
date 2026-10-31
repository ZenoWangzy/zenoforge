#!/usr/bin/env bash
# Lower, side-effect-free stage seam. No stage wrapper or GitHub operation.
set -euo pipefail
unset GH_TOKEN GITHUB_TOKEN
stage=$1; repo=$2; wt=$3; prompt=$4; artifact=$5; input=$6
export REPO_DIR="$repo" ZF_REPO_DIR="${ZF_REPO_DIR:-$repo}" TMPDIR="$artifact/tmp" AGENT_HOME="$artifact/agent-home"
mkdir -p "$TMPDIR" "$AGENT_HOME"
# Seed an isolated persistent policy with the caller's selected pipeline policy.
cp "$EVAL_POLICY_FILE" "$AGENT_HOME/model-policy.json"
# lib.sh normally loads this non-secret host tuning file. Preserve that input
# when isolating state; otherwise a busy WSL silently uses different defaults.
if [[ -r "$HOME/.zenoforge/capacity.env" ]]; then
  cp "$HOME/.zenoforge/capacity.env" "$AGENT_HOME/capacity.env"
fi
source "$repo/engine/lib.sh"
N=$(jq -r '.issue.number' "$input")
export N
mkdir -p "$STATE_DIR"
jq '.priorState + {last_failure_reason:.failure, last_failure_tail:.failure}' "$input" > "$STATE_DIR/$N.json"
settings="$(zf_config_file prompts/agent-settings.json)"
save_usage() {
  if [[ -f "$artifact/worker.log" ]]; then
    tokens=$(codex_tokens_used "$artifact/worker.log")
    [[ -n "$tokens" ]] || tokens=$(zcode_tokens_used "$artifact/worker.log")
    jq -nc --arg tokens "$tokens" '{tokens:(if $tokens=="" then null else ($tokens|tonumber) end)}' > "$artifact/usage.json"
  fi
}
trap save_usage EXIT
# Record the identity this call actually ran on; run-eval.mjs copies it into results.
record_identity() { printf '%s\n' "$1" > "$artifact/identity.txt"; }
case "$stage" in
  triage|recut)
    identity=$(model_policy dispatch-state-identity "$N" "$stage"); record_identity "$identity"
    run_model_json "$wt" "$identity" 45 \
      "$(zf_config_file "prompts/$stage.schema.json")" "$prompt" "$settings" work
    ;;
  advisor)
    identity=$(model_policy identity advisor); record_identity "$identity"
    run_model_json "$wt" "$identity" 45 \
      "$(zf_config_file prompts/advisor.schema.json)" "$prompt" "$settings" advisor
    ;;
  advisor-batch)
    identity=$(model_policy identity advisor); record_identity "$identity"
    [[ "$identity" == web:* ]] || { echo 'batch advisor requires the policy web role' >&2; exit 64; }
    raw=$(run_web_advisor_provider_ndjson "$prompt")
    web_advisor_provider_normalize_batch_json <<< "$raw" | jq -ce '
      if .kind == "advisor_batch_result" and (.requested_issues|length)==1
        and (.rulings|length)==1 and .rulings[0].issue==.requested_issues[0]
      then {is_error:false, structured_output:(.rulings[0] | del(.kind,.issue,.duplicate_of))}
      else error("invalid frozen batch manifest") end'
    ;;
  implement)
    identity=$(jq -r '.repairIdentity // empty' "$input")
    [[ -n "$identity" ]] || identity=$(implement_model_for_attempt)
    record_identity "$identity"
    session_id=$(jq -r '.sessionId // empty' "$input")
    record_session=$(jq -r '.recordSession // false' "$input")
    if [[ "$identity" == codex:* && ( "$record_session" == true || -n "$session_id" ) ]]; then
      model_policy_require_implementer_identity "$identity"
      IFS=: read -r provider model effort <<< "$identity"
      tier=$(model_policy tier "$identity")
      tier_args=(); [[ -z "$tier" ]] || tier_args=(-c "service_tier=\"$tier\"")
      # The end-to-end implementer must persist its session; the usual text
      # seam is ephemeral. Resume uses the scheduler's exec ... resume ID shape.
      codex_args=(exec --sandbox "$CODEX_SANDBOX_MODE")
      if [[ -n "$session_id" ]]; then
        codex_args+=(resume "$session_id")
      else
        codex_args+=(--cd "$wt")
      fi
      status=0
      (cd "$wt"; pipeline_execution_run timeout 120m codex "${codex_args[@]}" \
        --skip-git-repo-check -m "$model" -c "model_reasoning_effort=$effort" \
        "${tier_args[@]}" -c mcp_servers.gitnexus.enabled=false --json \
        --output-last-message "$artifact/report.md" - < "$prompt" > "$artifact/worker.log" 2>&1) || status=$?
      [[ ! -f "$artifact/report.md" ]] || cat "$artifact/report.md"
      exit "$status"
    else
      run_model_text "$wt" "$identity" 120 "$prompt" "$artifact/worker.log" "$settings"
    fi
    ;;
  review)
    # Same resolution as the pipeline: the cross-provider review role, or the
    # implementer's own identity as the documented fallback. Dispatch follows
    # the resolved provider; nothing here names a provider or model.
    identity=$(review_model_for_implementer "$N" "$(implement_model_for_attempt)")
    model_policy_require_stage_identity review "$identity"
    record_identity "$identity"
    IFS=: read -r provider model effort <<< "$identity"
    case "$provider" in
      codex)
        tier=$(model_policy tier "$identity")
        tier_args=(); [[ -z "$tier" ]] || tier_args=(-c "service_tier=\"$tier\"")
        pipeline_execution_run timeout 45m codex exec --sandbox "$CODEX_SANDBOX_MODE" --cd "$wt" \
          --skip-git-repo-check --ephemeral -m "$model" -c "model_reasoning_effort=$effort" \
          "${tier_args[@]}" -c mcp_servers.gitnexus.enabled=false \
          --output-last-message "$artifact/report.md" - < "$prompt" > "$artifact/worker.log" 2>&1
        ;;
      zcode)
        # Same invocation as run_zcode_json (prompt via -p, --cwd, yolo mode, proxied egress),
        # but a text report: the eval review prompt asks for a verdict line, not JSON.
        NODE_USE_ENV_PROXY=1 pipeline_execution_run timeout 45m zcode -p "$(cat "$prompt")" \
          --cwd "$wt" --mode yolo > "$artifact/report.md" 2> "$artifact/worker.log"
        ;;
      *) echo "eval review: unsupported review provider: $provider" >&2; exit 64 ;;
    esac
    cat "$artifact/report.md"
    ;;
  supervisor)
    # #4369: the same terra-profile invocation the live scheduler dispatches (codex exec -p terra
    # in dispatch_supervisor_arbiters). The arbitration reads only the frozen record, so there is
    # no provider or model resolution here.
    profile="${ZF_SUPERVISOR_PROFILE:-terra}"
    record_identity "codex:profile:$profile"
    pipeline_execution_run timeout 45m codex exec -p "$profile" --sandbox "$CODEX_SANDBOX_MODE" \
      --skip-git-repo-check --ephemeral --json \
      --output-last-message "$artifact/report.md" - < "$prompt" > "$artifact/worker.log" 2>&1
    cat "$artifact/report.md"
    ;;
esac
