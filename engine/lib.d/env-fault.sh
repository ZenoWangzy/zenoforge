
# Host binaries repaired by the night timer. Keep both roots configurable here
# so timer, probes and temporary-directory tests resolve identical paths.
codex_runtime_user_bin_dir() { printf '%s\n' "${ZF_CODEX_RUNTIME_BIN_DIR:-${ZF_LOCAL_BIN_DIR:-$HOME/.local/bin}}"; }

# An empty bundle dir means no bundled-binary repair; the public export defaults it to empty.
codex_runtime_bundle_dir() { printf '%s\n' "${ZF_CHATGPT_RESOURCES_DIR:-}"; }


# One safe file name per signature/scope: anything outside [A-Za-z0-9._:@-]
# becomes `_`, so a signature built from a log pattern cannot escape the
# directory or collide on a slash.
env_fault_key() {
  printf '%s' "$1" | tr -c 'A-Za-z0-9._:@-' '_'
}


# record_env_fault <signature> <stage> <issue> <detail> [package_dir] [now] [refund_attempt]
record_env_fault() {
  agent_pipeline_write_guard record_env_fault "$AGENT_HOME" "$ENV_FAULT_DIR" || return 1
  local signature="$1" stage="$2" n="$3" detail="$4" pkg="${5:-}" now="${6:-$(date +%s)}" refund_attempt="${7:-1}" f
  f="$ENV_FAULT_DIR/$(env_fault_key "$signature").log"
  if [ "$DRY_RUN" = "1" ]; then
    echo "[dry-run] record_env_fault $signature stage=$stage issue=$n scope=$(quarantine_scope "$stage" "$pkg") detail=$detail" >&2
    return 0
  fi
  mkdir -p "$ENV_FAULT_DIR"
  printf '%s\t%s\t%s\t%s\t%s\n' "$now" "$(quarantine_scope "$stage" "$pkg")" "$n" "$signature" "${detail//[$'\t\n']/ }" >> "$f"
  if [ "$stage" = "implement" ] && [ "$refund_attempt" = "1" ]; then
    refund_implement_attempt "$n"
  fi
}

codex_config_probe() {
  local status=0
  CODEX_CONFIG_PROBE_OUTPUT="$(timeout 10s codex features list 2>&1)" || status=$?
  CODEX_CONFIG_PROBE_STATUS="$status"
  return "$status"
}


# 2026-10-03: `inherit = "core"` under [shell_environment_policy] hid GH_TOKEN and the
# proxy from every hand agent shell; gh said "not logged in" and pushes failed all day.
codex_config_hides_env() {
  local file="${CODEX_HOME:-$HOME/.codex}/config.toml"
  [ -f "$file" ] || return 1
  awk '/^[[:space:]]*\[/ { s = ($0 ~ /^[[:space:]]*\[shell_environment_policy\][[:space:]]*$/) }
    s && /^[[:space:]]*inherit[[:space:]]*=[[:space:]]*"(core|none)"/ { f = 1 }
    END { exit !f }' "$file"
}


codex_config_error_detail() {
  local output="$1" text
  if jq -e 'type == "object"' >/dev/null 2>&1 <<< "$output"; then
    text="$(jq -r '[.result, .error, .detail] | map(select(type == "string")) | join("\n")' <<< "$output")"
  else
    text="$output"
  fi
  printf '%s\n' "$text" \
    | grep -iE 'Error loading config\.toml|failed to load .*configuration|config\.toml:[0-9]+:[0-9]+:|TOML parse error|duplicate key' \
    | head -n 3 \
    | tr '\r\n\t' '   ' \
    | sed -E 's/[[:space:]]+/ /g; s/^ //; s/ $//' \
    || true
}


codex_config_parse_error() {
  local detail
  detail="$(codex_config_error_detail "$1")"
  [ -n "$detail" ]
}


codex_config_fast_failure() {
  local output="$1" elapsed="" text="$1"
  if jq -e 'type == "object"' >/dev/null 2>&1 <<< "$output"; then
    elapsed="$(jq -r '.codex_elapsed_seconds // empty' <<< "$output")"
    text="$(jq -r '[.result, .error, .detail] | map(select(type == "string")) | join("\n")' <<< "$output")"
  else
    elapsed="$(sed -nE 's/^codex-exec-elapsed-seconds=([0-9]+)$/\1/p' <<< "$output" | tail -n 1)"
  fi
  [[ "$elapsed" =~ ^[0-9]+$ ]] && (( elapsed < 10 )) && codex_config_parse_error "$text"
}


record_codex_config_fault() {
  local n="$1" stage="$2" output="$3" refund_attempt="${4:-1}" detail
  detail="$(codex_config_error_detail "$output")"
  [ -n "$detail" ] || detail="$(sed -n '1,3p' <<< "$output" | tr '\r\n\t' '   ' | sed -E 's/[[:space:]]+/ /g; s/^ //; s/ $//')"
  record_env_fault env:codex-config-invalid "$stage" "${n:-0}" "$detail" "" "" 0 || return 1
  if [[ "$n" =~ ^[1-9][0-9]*$ ]] && [ "$DRY_RUN" != 1 ]; then
    [ "$refund_attempt" = 0 ] || state_unbump_attempts "$n" || return 1
    [ "$stage" = advisor ] || state_merge "$n" '.model_policy.active.config_fault = true' || return 1
  fi
  supervisor_inbox_append_once env:codex-config-invalid \
    "env:codex-config-invalid stage=$stage issue=${n:-0} $detail"
}


record_codex_runtime_fault() {
  local signature="$1" stage="$2" n="${3:-0}" detail="$4"
  record_env_fault "$signature" "$stage" "$n" "$detail" "" "" 0 || return 1
  supervisor_inbox_append_once "$signature" "$signature stage=$stage issue=$n $detail"
}


codex_dispatch_preflight() {
  local stage="${1:-dispatch}" detail signature
  if codex_config_probe; then
    if [ -e "$CODEX_PROVIDER_PROBE_REQUIRED_FILE" ] && codex_probe_ok; then
      # Scheduler entry precedes issue backoff filtering, so legacy held issues cannot starve recovery.
      codex_provider_recovery_probe_if_due "$(model_policy identity work)" || true
    fi
    return 0
  fi
  if codex_config_parse_error "$CODEX_CONFIG_PROBE_OUTPUT"; then
    record_codex_config_fault 0 "$stage" "$CODEX_CONFIG_PROBE_OUTPUT" 0 || return 1
    echo "env:codex-config-invalid stage=$stage: $(codex_config_error_detail "$CODEX_CONFIG_PROBE_OUTPUT")" >&2
    return 1
  fi
  detail="$(printf '%s\n' "$CODEX_CONFIG_PROBE_OUTPUT" | sed -n '1,3p' | tr '\r\n\t' '   ' | sed -E 's/[[:space:]]+/ /g; s/^ //; s/ $//')"
  [ -n "$detail" ] || detail="codex features list exited $CODEX_CONFIG_PROBE_STATUS"
  if model_call_missing_agent_binary "$CODEX_CONFIG_PROBE_OUTPUT" "" "" unknown; then
    signature=env:codex-binary-missing
  else
    signature=env:codex-features-probe-failed
  fi
  record_codex_runtime_fault "$signature" "$stage" 0 "$detail" || return 1
  echo "$signature stage=$stage issue=0 $detail" >&2
  return 1
}


codex_runtime_self_repair() {
  local user_bin bundle name link bundled old_target stamp
  user_bin="$(codex_runtime_user_bin_dir)"
  bundle="$(codex_runtime_bundle_dir)"
  [ -d "$user_bin" ] && [ -n "$bundle" ] || return 0
  for name in codex rg; do
    link="$user_bin/$name"
    bundled="$bundle/$name"
    [[ -L "$link" && ! -e "$link" && -x "$bundled" ]] || continue
    case "$name" in
      codex) timeout 10s "$bundled" features list >/dev/null 2>&1 || continue ;;
      rg) timeout 5s "$bundled" --version >/dev/null 2>&1 || continue ;;
    esac
    old_target="$(readlink "$link" 2>/dev/null || true)"
    ln -sfn -- "$bundled" "$link" || return 1
    hash -r 2>/dev/null || true
    stamp="$(date -u +%Y%m%dT%H%M%SZ)"
    supervisor_inbox_append_once "codex-runtime-repair:$name:$stamp:$$" \
      "codex-runtime-repair binary=$name link=$link old_target=$old_target new_target=$bundled" || return 1
  done
}


# Config faults stay closed for the exact role configuration, with no timed
# canary. The role marker shares one fault across tickets and stages using it.
model_config_fault_file() { printf '%s/model-config-%s.json\n' "$AGENT_HOME" "$(env_fault_key "$1")"; }


model_config_fault_blocked() {
  local role="$1" identity="$2" f config
  f="$(model_config_fault_file "$role")"
  [ -f "$f" ] || return 1
  config="$(model_policy_effective_live_json "$MODEL_POLICY_FILE" 2>/dev/null | jq -c --arg role "$role" '.roles[$role]')" || return 0
  if jq -e --arg identity "$identity" --argjson config "$config" \
    '.identity == $identity and .config == $config' "$f" >/dev/null 2>&1; then
    return 0
  fi
  return 1
}


# record_model_config_fault <issue> <stage> <role> <identity> <detail> [refund_attempt=1]
record_model_config_fault() {
  local n="$1" stage="$2" role="$3" identity="$4" detail="$5" refund_attempt="${6:-1}" config f lock_fd signature
  if codex_config_parse_error "$detail"; then
    record_codex_config_fault "$n" "$stage" "$detail" "$refund_attempt"
    return $?
  fi
  config="$(model_policy_effective_live_json "$MODEL_POLICY_FILE" 2>/dev/null | jq -c --arg role "$role" '.roles[$role]')" || return 1
  f="$(model_config_fault_file "$role")"
  signature="env:model-config:$role:$identity"
  mkdir -p "$AGENT_HOME/locks"
  exec {lock_fd}>"$AGENT_HOME/locks/model-config-$(env_fault_key "$role").lock"
  flock "$lock_fd"
  if ! model_config_fault_blocked "$role" "$identity"; then
    if [ "$DRY_RUN" != 1 ]; then
      jq -n --arg role "$role" --arg identity "$identity" --argjson config "$config" \
        '{role:$role,identity:$identity,config:$config}' > "$f.tmp" && mv "$f.tmp" "$f" || { unlock_fd "$lock_fd"; return 1; }
    fi
    record_env_fault "$signature" "$stage" "$n" "model configuration failure for $role/$identity: ${detail:0:500}" "" "" 0 || { unlock_fd "$lock_fd"; return 1; }
    [ "$DRY_RUN" = 1 ] || quarantine_supervisor_notice "$stage" open "$signature role=$role identity=$identity" || true
  fi
  unlock_fd "$lock_fd"
  if [[ "$n" =~ ^[1-9][0-9]*$ ]]; then
    [ "$refund_attempt" = 0 ] || state_unbump_attempts "$n"
    [ "$stage" = advisor ] || state_merge "$n" '.model_policy.active.config_fault = true'
  fi
}


# env_fault_lines_since <signature> <since_epoch> -> the ledger lines newer
# than $since (tab-separated: epoch, scope, issue, signature, detail).
env_fault_lines_since() {
  local f since="$2"
  f="$ENV_FAULT_DIR/$(env_fault_key "$1").log"
  [ -f "$f" ] || return 0
  awk -F'\t' -v s="$since" '$1 > s' "$f"
}


# env_fault_is_systemic <signature> [now] [window] -> true iff, within the
# window, the signature hit >= ENV_FAULT_SYSTEMIC_DISTINCT_ISSUES distinct
# issues OR >= ENV_FAULT_SYSTEMIC_TOTAL_HITS times at all (one ticket
# re-dispatched into the same wall three times is the same evidence as
# three tickets hitting it once).
env_fault_is_systemic() {
  local signature="$1" now="${2:-$(date +%s)}" window="${3:-$ENV_FAULT_WINDOW_SECONDS}" lines distinct total
  lines="$(env_fault_lines_since "$signature" "$((now - window))")"
  [ -n "$lines" ] || return 1
  distinct="$(printf '%s\n' "$lines" | cut -f3 | sort -u | wc -l)"
  total="$(printf '%s\n' "$lines" | wc -l)"
  [ "$distinct" -ge "$ENV_FAULT_SYSTEMIC_DISTINCT_ISSUES" ] || [ "$total" -ge "$ENV_FAULT_SYSTEMIC_TOTAL_HITS" ]
}


# env_fault_latest_scope <signature> -> the scope on the newest ledger line.
env_fault_latest_scope() {
  local f
  f="$ENV_FAULT_DIR/$(env_fault_key "$1").log"
  [ -f "$f" ] && tail -n 1 "$f" | cut -f2
}


# env_fault_probe <signature> -> 0 the fault is gone, 1 still present, 2 no
# probe known (canary only). Config probes read the dispatched unit's
# EnvironmentFile, not this process's environment (V86); web session probes hold
# the shared transport lease and inspect the existing account target.
env_fault_probe() {
  local env_file="${ENV_FAULT_ENV_FILE:-$AGENT_HOME/env}" tab_status=0 df_line total_kb avail_kb free_gib required_kb
  case "$1" in
    env:network-timeout)
      # A failed per-call read is not proof the whole stage is offline. Use
      # an independent, bounded GitHub API request to confirm the shared
      # dependency is still unavailable before opening a stage quarantine.
      command -v curl >/dev/null 2>&1 || return 2
      if curl -fsS --connect-timeout 3 --max-time 8 https://api.github.com/meta >/dev/null 2>&1; then
        return 0
      fi
      return 1
      ;;
    env:leg-not-executable:*)
      [ -x "$ZF_ENGINE_DIR/run-${1#env:leg-not-executable:}.sh" ]
      ;;
    env:codex-sandbox-probe)
      codex_probe_ok
      ;;
    env:git-identity)
      grep -qE '^ZF_AGENT_GIT_USER_NAME=.+' "$env_file" 2>/dev/null \
        && grep -qE '^ZF_AGENT_GIT_USER_EMAIL=.+' "$env_file" 2>/dev/null
      ;;
    env:test-gate:docker)
      docker info >/dev/null 2>&1
      ;;
    env:codex-binary-missing|env:codex-features-probe-failed)
      codex_config_probe
      ;;
    env:ci-runner-capacity|env:build-capacity)
      # Match the CI runner's capped disk floor and the shared build gate.
      df_line="$(timeout 35 ssh -o BatchMode=yes -o ConnectTimeout=15 "$ZF_CIHOST_HOST" 'df -Pk /' 2>/dev/null \
        | awk 'NR == 2 && $2 ~ /^[0-9]+$/ && $4 ~ /^[0-9]+$/ { print $2, $4; exit }')" || return 2
      read -r total_kb avail_kb <<< "$df_line"
      [[ "${total_kb:-}" =~ ^[0-9]+$ && "${avail_kb:-}" =~ ^[0-9]+$ ]] || return 2
      required_kb="$(ci_runner_disk_capped_kb "$total_kb")" || return 2
      if [ "$1" = env:ci-runner-capacity ]; then
        [ "$avail_kb" -ge "$required_kb" ] || return 1
        return 0
      fi
      free_gib=$((avail_kb / 1024 / 1024))
      [ "$free_gib" -ge "$BUILD_CAPACITY_GATE_GIB" ] || return 1
      return 0
      ;;
    env:main-ci-red)
      main_ci_red_quarantine_probe >/dev/null
      ;;
    env:web-advisor-provider:*)
      # Provider seam: the web advisor's own transport health checks live in
      # providers/web-advisor-provider.sh and return 0/1/2; unknown families report
      # no probe.
      web_advisor_provider_env_fault_probe "$1"
      ;;
    *) return 2 ;;
  esac
}


# env_fault_repair <signature> -> 0 repaired (caller re-probes), 1 no repair
# allowlisted, 2 repair failed, 75 transport lease busy (retry on next tick). Grow
# the allowlist only with repairs derivable without a human's choice.
env_fault_repair() {
  local env_file="${ENV_FAULT_ENV_FILE:-$AGENT_HOME/env}" login id name tab_status=0
  case "$1" in
    env:git-identity)
      # The pipeline commits as the maintainer's own GitHub account by his
      # explicit decision; GitHub's noreply form (<id>+<login>@users.noreply.
      # github.com) is that account's own attribution address, derivable
      # from the authenticated session, and never a real mailbox. Written
      # ONLY when the key is absent -- a value a human already set is
      # never overwritten -- and only outside version control.
      login="$(gh api user -q '.login' 2>/dev/null)" || return 2
      id="$(gh api user -q '.id' 2>/dev/null)" || return 2
      name="$(gh api user -q '.name // .login' 2>/dev/null)" || name="$login"
      [ -n "$login" ] && [ -n "$id" ] || return 2
      if [ "$DRY_RUN" = "1" ]; then
        echo "[dry-run] env_fault_repair env:git-identity -> append ZF_AGENT_GIT_USER_NAME/EMAIL to $env_file" >&2
        return 0
      fi
      grep -qE '^ZF_AGENT_GIT_USER_NAME=.+' "$env_file" 2>/dev/null \
        || printf 'ZF_AGENT_GIT_USER_NAME=%s\n' "$name" >> "$env_file"
      grep -qE '^ZF_AGENT_GIT_USER_EMAIL=.+' "$env_file" 2>/dev/null \
        || printf 'ZF_AGENT_GIT_USER_EMAIL=%s+%s@users.noreply.github.com\n' "$id" "$login" >> "$env_file"
      return 0
      ;;
    env:codex-binary-missing)
      codex_runtime_self_repair || return 2
      return 0
      ;;
    env:codex-sandbox-probe)
      # 10-28: the marker went missing and nothing re-ran the probe, so recut stayed quarantined.
      bash "$ZF_ENGINE_DIR/probe-codex-sandbox.sh" >/dev/null 2>&1 || return 2
      return 0
      ;;
    env:web-advisor-provider:*)
      # Provider seam: only the web advisor's tab-unresponsive family has a
      # machine repair (providers/web-advisor-provider.sh); other families report no
      # repair allowlisted here.
      web_advisor_provider_env_fault_repair "$1"
      ;;
    *) return 1 ;;
  esac
}
