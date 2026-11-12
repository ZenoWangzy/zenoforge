# Triage on Claude haiku while the weekly Codex stop is on (codex_week_stopped, codex-budget.sh). The model comes from the
# triage-haiku policy role; allow_roles.haiku grants that role the model. No Codex budget is reserved on this path.

# triage_claude_identity -> the role's identity on stdout, only when policy allows the model for the role, the CLI exists and the
# Claude provider is not quota-held. Callers defer the work when it fails.
triage_claude_identity() {
  local identity model
  identity="$(model_policy identity triage-haiku)" || return 1
  model="${identity#*:}"; model="${model%:*}"
  model_policy_model_allowed_for_role "$model" triage-haiku \
    && command -v claude >/dev/null 2>&1 && ! provider_quota_exhausted claude \
    && printf '%s\n' "$identity"
}

# claude_triage_call <cwd> <identity> <timeout_minutes> <settings_file> <prompt_file> [schema_file] -> claude's raw
# `--output-format json` result on stdout. Read-only like the Codex triage sandbox: the settings allow-list gates Bash, no
# Edit/Write tool is offered, and the prompt rides stdin because the batch prompt is far larger than one argv word.
claude_triage_call() {
  local cwd="$1" identity="$2" timeout_minutes="$3" settings_file="$4" prompt_file="$5" schema_file="${6:-}" model
  local -a schema_args=()
  model="${identity#*:}"; model="${model%:*}"
  [ -z "$schema_file" ] || schema_args=(--json-schema "$(cat "$schema_file")")
  ( cd "$cwd" && timeout "${timeout_minutes}m" env -u GH_TOKEN -u GITHUB_TOKEN claude -p \
      --model "$model" --output-format json --settings "$settings_file" --setting-sources project,local \
      --strict-mcp-config --permission-mode dontAsk --tools "Read,Grep,Glob,Bash" ${schema_args[@]+"${schema_args[@]}"} < "$prompt_file" )
}

# claude_tokens_used < <claude json result> -> fresh tokens of that call (input + output; cache read and creation stay out,
# as the Codex record keeps them), or empty when the result carries no usage object. Never zero for a missing usage.
claude_tokens_used() {
  jq -r 'if (.usage.input_tokens | type) == "number" and (.usage.output_tokens | type) == "number"
    then .usage.input_tokens + .usage.output_tokens else empty end' 2>/dev/null | tail -n 1
}

# Same {is_error, structured_output, tokens_used} envelope as run_codex_json, so run-triage.sh parses both alike.
run_claude_json() {
  local cwd="$1" identity="$2" timeout_minutes="$3" schema_file="$4" prompt_file="$5" settings_file="$6" raw status=0 tokens
  timeout_minutes="$(model_timeout_for_attempt "$timeout_minutes" "${N:-}")"
  raw="$(claude_triage_call "$cwd" "$identity" "$timeout_minutes" "$settings_file" "$prompt_file" "$schema_file")" || status=$?
  if [ "$status" -eq 0 ] && jq -e '.is_error == false and (.structured_output | type) == "object"' <<< "$raw" >/dev/null 2>&1; then
    tokens="$(claude_tokens_used <<< "$raw")"
    jq -c --arg tokens "$tokens" '{is_error: false, structured_output: .structured_output, tokens_used: $tokens, total_cost_usd: .total_cost_usd}' <<< "$raw"
  else
    jq -nc --arg result "$(tail -c 2000 <<< "$raw")" --arg status "$status" \
      '{is_error: true, subtype: "claude_exec_failure", result: $result, claude_exit_status: ($status|tonumber)}'
    [ "$status" -ne 0 ] || status=1
  fi
  return "$status"
}

# Batch triage: the final message (NDJSON records) on stdout, the raw reply kept in <transcript_file> for failure classification.
run_claude_text() {
  local cwd="$1" identity="$2" timeout_minutes="$3" prompt_file="$4" transcript_file="$5" settings_file="$6" status=0
  claude_triage_call "$cwd" "$identity" "$timeout_minutes" "$settings_file" "$prompt_file" > "$transcript_file" || status=$?
  if [ "$status" -eq 0 ] && jq -e '.is_error == false' "$transcript_file" >/dev/null 2>&1; then
    jq -r '.result // empty' "$transcript_file"
  else
    tail -c 2000 "$transcript_file"
    [ "$status" -ne 0 ] || status=1
  fi
  return "$status"
}
