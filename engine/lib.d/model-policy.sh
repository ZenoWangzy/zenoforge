model_policy_validate_json() {
  jq -e --slurpfile canonical "$MODEL_POLICY_DEFAULT" '
    . as $policy
    | ([ $policy.roles | to_entries[] | select(.value.fallback_identity != null)
        | . as $entry
        | if ($entry.value.fallback_identity | type) != "string"
             or (($entry.value.fallback_identity | test("^codex:[A-Za-z0-9._-]+:[A-Za-z0-9_-]+$")) | not)
          then false
          else ($entry.value.provider == "codex")
            and (($entry.value.fallback_identity | split(":")[1]) == $canonical[0].roles.work.model)
            and (($entry.value.fallback_identity | split(":")[1]) != $entry.value.model)
            and any($policy.roles[]; .provider == "codex" and .disabled != true
              and ("codex:" + .model + ":" + .effort) == $entry.value.fallback_identity)
          end
      ] | all) as $fallbacks_valid
    | .schema_version == $canonical[0].schema_version
    and $fallbacks_valid
    and (.roles.work.provider == "codex")
    and (.roles.production.provider == "codex")
    and (.roles.advisor.provider == "web-advisor-provider")
    and ([.roles[] | .model] | all(type == "string" and test("^[A-Za-z0-9._-]+$")))
    and ([.roles | to_entries[] | if (.key == "work" or .key == "review" or .key == "production") then
      (.value | (has("fallback_model") | not) and (has("fallback_identity") | not))
      elif .value.provider == "codex" then
        (if (.value | has("fallback_model")) then
          .value.fallback_model == $canonical[0].roles.work.model
         else .value.disabled == true end)
      else (.value | has("fallback_model") | not) end] | all(. == true))
    and ([.roles[] | select(.provider == "codex" or .provider == "zcode") | .effort] | all(type == "string" and length > 0 and test("^[A-Za-z0-9_-]+$")))
    and ([.roles[] | select(has("service_tier")) | .service_tier] | all(.[]; type == "string"))
    and (.forbidden | type == "array" and length > 0 and all(.[]; type == "string" and test("^[A-Za-z0-9-]+$")))
    and ((.forbidden + $canonical[0].forbidden | unique) as $forbidden
      | [.roles[] as $role | $forbidden[] as $word | (($role.model + " " + ($role.effort // "") + " " + ($role.fallback_model // "")) | ascii_downcase | contains($word | ascii_downcase))]
      | any | not)
    and (.escalation.initial_step | type == "string" and length > 0)
    and (.escalation.steps | type == "array" and length > 0 and all(.[]; (.name | type == "string" and length > 0)))
    and (.escalation as $e | ([$e.steps[].name] | unique | length) == ($e.steps | length))
    and (if has("switches") then (.switches | type == "object" and (if has("roadmap-order") then .["roadmap-order"] | type == "boolean" else true end)) else true end)
    and ([.escalation.steps[].role?] | all(. as $role | $role == null or ($role | type == "string")))
  ' >/dev/null 2>&1
}

model_policy_validate_file() {
  model_policy_validate_json < "$1"
}

# Schema v1 allowed a safe, distinct Codex fallback model instead of requiring
# the canonical work model. Keep its exact validation rules for upgrades: the
# caller will back up the v1 bytes and install the complete validated default.
model_policy_validate_v1_json() {
  jq -e '
    . as $policy
    | ([ $policy.roles | to_entries[] | select(.value.fallback_identity != null)
        | . as $entry
        | if ($entry.value.fallback_identity | type) != "string"
             or (($entry.value.fallback_identity | test("^codex:[A-Za-z0-9._-]+:[A-Za-z0-9_-]+$")) | not)
          then false
          else ($entry.value.provider == "codex")
            and (($entry.value.fallback_identity | split(":")[1]) != $entry.value.model)
            and any($policy.roles[]; .provider == "codex" and .disabled != true
              and ("codex:" + .model + ":" + .effort) == $entry.value.fallback_identity)
          end
      ] | all) as $fallbacks_valid
    | .schema_version == 1
    and $fallbacks_valid
    and (.roles.work.provider == "codex")
    and (.roles.production.provider == "codex")
    and (.roles.advisor.provider == "web-advisor-provider")
    and ([.roles[] | .model] | all(type == "string" and test("^[A-Za-z0-9._-]+$")))
    and ([.roles[] | if .provider == "codex" then
      (if has("fallback_model") then
        (.fallback_model | type == "string" and test("^[A-Za-z0-9._-]+$"))
        and .fallback_model != .model
       else true end)
      else (has("fallback_model") | not) end] | all(. == true))
    and ([.roles[] | select(.provider == "codex" or .provider == "zcode") | .effort] | all(type == "string" and length > 0 and test("^[A-Za-z0-9_-]+$")))
    and ([.roles[] | select(has("service_tier")) | .service_tier] | all(.[]; type == "string"))
    and (.forbidden | type == "array" and length > 0 and all(.[]; type == "string" and test("^[A-Za-z0-9-]+$")))
    and ([$policy.roles[] as $role | $policy.forbidden[] as $word | (($role.model + " " + ($role.effort // "") + " " + ($role.fallback_model // "")) | ascii_downcase | contains($word | ascii_downcase))]
      | any | not)
    and (.escalation.initial_step | type == "string" and length > 0)
    and (.escalation.steps | type == "array" and length > 0 and all(.[]; (.name | type == "string" and length > 0)))
    and (.escalation as $e | ([$e.steps[].name] | unique | length) == ($e.steps | length))
    and (if has("switches") then (.switches | type == "object" and (if has("roadmap-order") then .["roadmap-order"] | type == "boolean" else true end)) else true end)
    and ([.escalation.steps[].role?] | all(. as $role | $role == null or ($role | type == "string")))
  ' >/dev/null 2>&1
}

model_policy_validate_v1_file() {
  model_policy_validate_v1_json < "$1"
}

model_policy_effective_live_json() {
  jq -s '
    .[0] as $default | .[1] as $live
    | ["work", "review", "production"] as $active_codex_roles
    | ($default * $live)
    | .schema_version = $default.schema_version
    | .roles = reduce ((($default.roles // {}) + ($live.roles // {})) | keys[]) as $role
        ({}; .[$role] = (
          ($default.roles[$role] // {}) as $default_role
          | ($live.roles[$role] // {}) as $live_role
          | if ($default_role.provider // null) != null
               and ($live_role.provider // null) != null
               and $default_role.provider != $live_role.provider
            then $live_role
            else $default_role * $live_role
            end
        ))
    # Schema v2 allowed fallbacks on the three active Codex roles, while v3
    # forbids them. A schema upgrade backs up the complete live file and
    # installs the complete v3 default, so discard legacy active-role
    # fallbacks from the validation candidate before checking the remaining
    # settings. This covers both redundant and operator-selected fallbacks.
    | .roles |= with_entries(
        if (.key == "work" or .key == "review" or .key == "production")
           and ($live.schema_version // 0) < $default.schema_version
        then .value |= del(.fallback_model, .fallback_identity)
        else . end)
    # A v1 active fallback is removed above. Its custom target role is also
    # absent from the upgraded default, so omit that role from the current-
    # policy candidate only when no other retained policy reference uses it.
    # This handles fallback_model and fallback_identity alike without
    # suppressing independently configured roles.
    | (if ($live.schema_version // 0) < $default.schema_version then
        [
          $active_codex_roles[] as $source_role
          | $live.roles[$source_role] as $source
          | (
              (if ($source.fallback_identity? | type) == "string" then
                ($source.fallback_identity | split(":")) as $identity_parts
                | {provider:$identity_parts[0], model:$identity_parts[1], effort:$identity_parts[2]}
               else empty end),
              (if ($source.fallback_model? | type) == "string" then
                {provider:$source.provider, model:$source.fallback_model, effort:$source.effort}
               else empty end)
            ) as $target_identity
          | $live.roles | to_entries[]
          | . as $target
          | select($target.value.provider == $target_identity.provider
              and $target.value.model == $target_identity.model
              and $target.value.effort == $target_identity.effort)
          | select((($default.roles // {}) | has($target.key)) | not)
          | select(([$live.escalation.steps[]?.role?] | index($target.key)) == null)
          | select(([
              $live.roles | to_entries[]
              | . as $entry
              | select(($active_codex_roles | index($entry.key)) == null)
              | select(
                  $entry.value.fallback_identity == (
                    $target_identity.provider + ":" + $target_identity.model + ":" + $target_identity.effort
                  )
                  or (
                    $entry.value.provider == $target_identity.provider
                    and $entry.value.fallback_model == $target_identity.model
                    and $entry.value.effort == $target_identity.effort
                  )
                )
            ] | length) == 0)
          | $target.key
        ] | unique
      else [] end) as $discarded_fallback_target_roles
    | .roles |= with_entries(
        . as $role
        | if ($discarded_fallback_target_roles | index($role.key)) == null
          then $role else empty end)
    | .forbidden = reduce ((($live.forbidden // []) + ($default.forbidden // []))[]) as $word
        ([]; if index($word) == null then . + [$word] else . end)
  ' "$MODEL_POLICY_DEFAULT" "$1"
}

model_policy_validate_v1_upgrade_file() {
  local effective_policy
  # Validate original settings by the v1 contract, including fallbacks the
  # upgrade will discard, then validate retained settings by today's policy.
  model_policy_validate_v1_file "$1" || return 1
  effective_policy="$(model_policy_effective_live_json "$1" 2>/dev/null)" || return 1
  model_policy_validate_json <<< "$effective_policy"
}

model_policy_schema_version() {
  jq -er '
    if type != "object" then error("model policy must be an object")
    elif (has("schema_version") | not) then 0
    elif (.schema_version | type == "number" and . >= 0 and floor == .) then .schema_version
    else error("model policy schema_version must be a non-negative integer") end
  ' "$1" 2>/dev/null
}

model_policy_migrate_live() {
  local force="${1:-0}" live_version default_version effective_policy live_json migrated_json backup temporary
  default_version="$(model_policy_schema_version "$MODEL_POLICY_DEFAULT")" || {
    echo "model_policy: versioned policy has an invalid schema_version" >&2
    return 1
  }
  live_version="$(model_policy_schema_version "$MODEL_POLICY_FILE")" || {
    echo "model_policy: persistent policy has an invalid schema_version" >&2
    return 1
  }
  if (( live_version > default_version )); then
    echo "model_policy: persistent schema version $live_version is newer than supported version $default_version" >&2
    return 1
  fi

  model_policy_validate_file "$MODEL_POLICY_DEFAULT" || {
    echo "model_policy: versioned policy is invalid" >&2
    return 1
  }
  if (( live_version == 1 && live_version < default_version )); then
    model_policy_validate_v1_upgrade_file "$MODEL_POLICY_FILE" || {
      echo "model_policy: persistent policy cannot be migrated without changing its valid settings" >&2
      return 1
    }
  else
    effective_policy="$(model_policy_effective_live_json "$MODEL_POLICY_FILE" 2>/dev/null)" || {
      echo "model_policy: persistent policy cannot be migrated" >&2
      return 1
    }
    model_policy_validate_json <<< "$effective_policy" || {
      echo "model_policy: persistent policy cannot be migrated without changing its valid settings" >&2
      return 1
    }
  fi
  if (( live_version == default_version )) && [[ "$force" != 1 ]]; then
    return 0
  fi
  live_json="$(jq -S . "$MODEL_POLICY_FILE" 2>/dev/null)" || {
    echo "model_policy: persistent policy is not valid JSON" >&2
    return 1
  }
  # The live bytes are recoverable in the backup; schema upgrades and forced
  # default syncs install the complete policy so host overrides cannot drift.
  migrated_json="$(jq -S . "$MODEL_POLICY_DEFAULT")" || return 1
  [[ "$live_json" == "$migrated_json" ]] && return 0

  # HEALTH resolves model identities while inspecting hand agents. Those
  # lookups must not rewrite the persistent policy before HEALTH can report
  # whether the original file was missing or stale.
  [[ "${MODEL_POLICY_READ_ONLY:-0}" == 1 ]] && return 0

  if (( live_version < default_version )); then
    backup="$MODEL_POLICY_FILE.bak.schema-v$live_version.$(date -u +%Y%m%dT%H%M%SZ).$$"
    cp -p -- "$MODEL_POLICY_FILE" "$backup" || {
      echo "model_policy: could not preserve the pre-migration policy" >&2
      return 1
    }
  fi
  temporary="$(mktemp "$AGENT_HOME/.model-policy.json.XXXXXX")" || return 1
  if ! printf '%s\n' "$migrated_json" > "$temporary" \
    || ! chmod 600 "$temporary" \
    || ! mv -f -- "$temporary" "$MODEL_POLICY_FILE"; then
    rm -f -- "$temporary"
    echo "model_policy: could not atomically update persistent policy" >&2
    return 1
  fi
}

model_policy_identity_is_allowed() {
  jq -e --slurpfile defaults "$MODEL_POLICY_DEFAULT" --arg identity "$1" '
    ([.roles[], $defaults[0].roles[]]
      | map(if .provider == "codex" or .provider == "zcode" then
          [.provider + ":" + .model + ":" + .effort]
          + (if .fallback_model then [.provider + ":" + .fallback_model + ":" + .effort] else [] end)
        else ["web:" + .model] end)
      | flatten) as $configured
    | ($configured + [.roles[].fallback_identity?, $defaults[0].roles[].fallback_identity? | select(type == "string")])
    | index($identity) != null
  ' "$MODEL_POLICY_FILE" >/dev/null 2>&1
}

model_policy_require_role_identity() {
  local role="$1" identity="$2" expected fallback fallback_model_identity
  expected="$(model_policy identity "$role")" || return 1
  fallback="$(jq -r --arg role "$role" '.roles[$role].fallback_identity // empty' "$MODEL_POLICY_FILE")"
  fallback_model_identity="$(model_policy fallback-identity "$role" 2>/dev/null || true)"
  [ "$identity" = "$expected" ] || { [ -n "$fallback" ] && [ "$identity" = "$fallback" ]; } \
    || { [ -n "$fallback_model_identity" ] && [ "$identity" = "$fallback_model_identity" ]; } || {
    echo "model_policy: identity does not match role '$role' (expected $expected${fallback:+ or $fallback}${fallback_model_identity:+ or $fallback_model_identity})" >&2
    return 64
  }
}

# The escalation ladder runs implement/repair on the work role first and on
# the production role as its last step (model-policy.json). Codex launch
# boundaries accept either; any other role (advisor, forbidden) is refused.
model_policy_require_implementer_identity() {
  local identity="$1" role fallback fallback_model_identity
  for role in work production; do
    [ "$identity" = "$(model_policy identity "$role")" ] && return 0
    fallback="$(jq -r --arg role "$role" '.roles[$role].fallback_identity // empty' "$MODEL_POLICY_FILE" 2>/dev/null || true)"
    [ -n "$fallback" ] && [ "$identity" = "$fallback" ] && return 0
    fallback_model_identity="$(model_policy fallback-identity "$role" 2>/dev/null || true)"
    [ -n "$fallback_model_identity" ] && [ "$identity" = "$fallback_model_identity" ] && return 0
  done
  echo "model_policy: identity matches neither the work nor the production role" >&2
  return 64
}

# Stages that run on the work role (implement, review, triage, recut) also
# run on the ladder's production step (V346); other roles must match exactly.
# The review stage (maintainer ruling 2026-10-07, pipeline-node-execution-model)
# runs on the cross-provider review role when the other provider is available
# and on the implementer's own work/production identity as its documented
# same-provider fallback -- both are legitimate reviewer identities.
model_policy_require_stage_identity() {
  case "$1" in
    work) model_policy_require_implementer_identity "$2" ;;
    review)
      [ "$2" = "$(model_policy identity review 2>/dev/null || true)" ] && return 0
      model_policy_require_implementer_identity "$2"
      ;;
    *) model_policy_require_role_identity "$1" "$2" ;;
  esac
}

model_policy() {
  local action="${1:-}" arg="${2:-}" field="${3:-}" temporary override effective_policy identity fallback primary_identity
  # Checks validate legacy state through the effective view without migrating it.
  if [ "$action" = "source-check" ]; then
    model_policy_validate_file "$MODEL_POLICY_DEFAULT" || { echo "model_policy: versioned policy is invalid" >&2; return 1; }
    [ -s "$MODEL_POLICY_FILE" ] || { echo "model_policy: persistent policy is missing" >&2; return 1; }
    local default_version live_version
    default_version="$(model_policy_schema_version "$MODEL_POLICY_DEFAULT")" || {
      echo "model_policy: versioned policy has an invalid schema_version" >&2
      return 1
    }
    live_version="$(model_policy_schema_version "$MODEL_POLICY_FILE")" || {
      echo "model_policy: persistent policy has an invalid schema_version" >&2
      return 1
    }
    if (( live_version > default_version )); then
      echo "model_policy: persistent schema version $live_version is newer than supported version $default_version" >&2
      return 1
    fi
    if (( live_version == 1 && live_version < default_version )); then
      model_policy_validate_v1_upgrade_file "$MODEL_POLICY_FILE" || {
        echo "model_policy: live policy is invalid or assigns a forbidden model" >&2
        return 1
      }
    else
      effective_policy="$(model_policy_effective_live_json "$MODEL_POLICY_FILE" 2>/dev/null)" || {
        echo "model_policy: live policy is invalid or assigns a forbidden model" >&2
        return 1
      }
      model_policy_validate_json <<< "$effective_policy" || {
        echo "model_policy: live policy is invalid or assigns a forbidden model" >&2
        return 1
      }
    fi
    model_policy_scan_sources || return 1
    echo clean
    return 0
  fi
  if [ ! -s "$MODEL_POLICY_FILE" ]; then
    if [[ "${MODEL_POLICY_READ_ONLY:-0}" == 1 ]]; then
      echo "model_policy: persistent policy is missing (read-only)" >&2
      return 1
    fi
    mkdir -p "$(dirname -- "$MODEL_POLICY_FILE")" || return 1
    temporary="$MODEL_POLICY_FILE.tmp.$$"
    cp -- "$MODEL_POLICY_DEFAULT" "$temporary" && chmod 600 "$temporary" && mv -- "$temporary" "$MODEL_POLICY_FILE" || {
      rm -f -- "$temporary"
      echo "model_policy: cannot seed persistent policy" >&2
      return 1
    }
  fi
  model_policy_migrate_live || return 1
  effective_policy="$(model_policy_effective_live_json "$MODEL_POLICY_FILE" 2>/dev/null)" || {
    echo "model_policy: persistent policy is invalid or contains a forbidden model" >&2
    return 1
  }
  if ! model_policy_validate_json <<< "$effective_policy"; then
    echo "model_policy: persistent policy is invalid or contains a forbidden model" >&2
    return 1
  fi
  case "$action" in
    identity)
      jq -er --arg role "$arg" '
        .roles[$role] as $r |
        # A disabled role stays in the policy but resolves to nothing, so dispatch refuses it.
        if $r.disabled == true then error("role disabled")
        elif $r.provider == "codex" then "codex:" + $r.model + ":" + $r.effort
        elif $r.provider == "zcode" then "zcode:" + $r.model + ":" + $r.effort
        elif $r.provider == "web-advisor-provider" then "web:" + $r.model
        else error("unsupported role provider") end
      ' <<< "$effective_policy"
      ;;
    fallback-identity)
      jq -er --slurpfile defaults "$MODEL_POLICY_DEFAULT" --arg role "$arg" '
        .roles[$role] as $r |
        ($r.fallback_model // $defaults[0].roles[$role].fallback_model // empty) as $model |
        if $r.disabled == true or $r.provider != "codex" or $model == "" then error("fallback model unavailable")
        else "codex:" + $model + ":" + $r.effort end
      ' <<< "$effective_policy"
      ;;
    dispatch-identity)
      identity="$(model_policy identity "$arg")" || return $?
      primary_identity="$identity"
      if [ -n "$field" ] && [ "$field" != "$identity" ]; then
        fallback="$(jq -r --arg role "$arg" '.roles[$role].fallback_identity // empty' <<< "$effective_policy")"
        [ -n "$fallback" ] || fallback="$(model_policy fallback-identity "$arg" 2>/dev/null || true)"
        [ -n "$fallback" ] && [ "$field" = "$fallback" ] || return 64
        identity="$field"
      fi
      if [ "$identity" = "$primary_identity" ] && [[ "$identity" == codex:* ]] \
        && codex_model_capacity_held "$identity"; then
        fallback="$(jq -r --arg role "$arg" '.roles[$role].fallback_identity // empty' <<< "$effective_policy")"
        [ -n "$fallback" ] || fallback="$(model_policy fallback-identity "$arg" 2>/dev/null || true)"
        if [ -n "$fallback" ] && model_policy_identity_is_allowed "$fallback" \
          && ! codex_model_capacity_held "$fallback"; then
          identity="$fallback"
        fi
      fi
      printf '%s\n' "$identity"
      ;;
    tier)
      jq -r --arg role "$arg" '
        (if .roles[$role] != null then .roles[$role]
         else [.roles[] | select(.provider == "codex" and ("codex:" + .model + ":" + .effort) == $role)][0] // {}
         end) | .service_tier // empty
      ' <<< "$effective_policy"
      ;;
    resolve)
      [[ "$field" =~ ^AGENT_MODEL([A-Z0-9_]*)$ ]] || { echo "model_policy: invalid override name" >&2; return 64; }
      override="${!field:-}"
      if [ -n "$override" ]; then
        model_policy_require_role_identity "$arg" "$override" || return $?
        printf '%s\n' "$override"
      else
        model_policy identity "$arg"
      fi
      ;;
    step-role)
      jq -er --arg step "$arg" '.escalation.steps[] | select(.name == $step) | .role' <<< "$effective_policy"
      ;;
    transition)
      jq -er --arg step "$arg" --arg event "$field" '.escalation.steps[] | select(.name == $step) | .[$event]' <<< "$effective_policy"
      ;;
    initial-step)
      jq -er '.escalation.initial_step' <<< "$effective_policy"
      ;;
    state-identity)
      local issue="$arg" unit="${field:-implement}" step role state
      state="$(state_read "$issue")"
      if [ "$(jq -r '.model_policy.unit // (if .model_policy.step then "implement" else empty end)' <<< "$state")" != "$unit" ]; then
        step="$(model_policy initial-step)"
      else
        step="$(jq -r '.model_policy.step // empty' <<< "$state")"
        step="${step:-$(model_policy initial-step)}"
      fi
      role="$(model_policy step-role "$step")" || return 1
      model_policy identity "$role"
      ;;
    dispatch-state-identity)
      local issue="$arg" unit="${field:-implement}" step role state active_role active_identity primary fallback fallback_model_identity
      state="$(state_read "$issue")"
      if [ "$(jq -r '.model_policy.unit // (if .model_policy.step then "implement" else empty end)' <<< "$state")" != "$unit" ]; then
        step="$(model_policy initial-step)"
      else
        step="$(jq -r '.model_policy.step // empty' <<< "$state")"
        step="${step:-$(model_policy initial-step)}"
      fi
      role="$(model_policy step-role "$step")" || return 1
      primary="$(model_policy identity "$role")" || return 1
      active_role="$(jq -r '.model_policy.active.role // empty' <<< "$state")"
      active_identity="$(jq -r '.model_policy.active.identity // empty' <<< "$state")"
      fallback="$(jq -r --arg role "$role" '.roles[$role].fallback_identity // empty' <<< "$effective_policy")"
      fallback_model_identity="$(model_policy fallback-identity "$role" 2>/dev/null || true)"
      if [ "$active_role" = "$role" ] && [[ "$active_identity" == "$primary" \
        || ( -n "$fallback" && "$active_identity" == "$fallback" ) \
        || ( -n "$fallback_model_identity" && "$active_identity" == "$fallback_model_identity" ) ]]; then
        printf '%s\n' "$active_identity"
      else
        model_policy dispatch-identity "$role"
      fi
      ;;
    live)
      local forbidden_words allowed_identities pipeline_worktrees pipeline_settings policy_age
      forbidden_words="$(jq -r '.forbidden | join(",")' <<< "$effective_policy")"
      allowed_identities="$(jq -nr --argjson live "$effective_policy" --slurpfile defaults "$MODEL_POLICY_DEFAULT" '
        [$live.roles[], $defaults[0].roles[]]
          | map(select(.provider == "codex")
            | [.model + ":" + .effort]
              + (if .fallback_model then [.fallback_model + ":" + .effort] else [] end))
          | flatten | unique | join(",")
      ')"
      pipeline_worktrees="${ZF_WORKTREE_ROOT:-${HOME:?HOME is not set}/wt}/"
      pipeline_settings="${ZF_ENGINE_LIVE:-$AGENT_HOME/checkout/engine}/prompts/agent-settings.json"
      # A Codex run older than the live policy file was dispatched under an earlier policy; judging it
      # by today's roles turned 4 in-flight agents BROKEN for hours after a role change (2026-09-30).
      # Forbidden names still apply to it.
      policy_age=$(( $(date +%s) - $(stat -c %Y "$MODEL_POLICY_FILE") ))
      ps -ww -eo etimes=,comm=,args= | awk -v forbidden_words="$forbidden_words" \
        -v allowed_identities="$allowed_identities" -v policy_age="$policy_age" \
        -v worktrees="$pipeline_worktrees" -v settings="$pipeline_settings" '
        BEGIN {
          bad = 0
          forbidden_count = split(forbidden_words, forbidden, ",")
          allowed_count = split(allowed_identities, allowed, ",")
        }
        function basename(value) {
          sub(/^.*\//, "", value)
          return tolower(value)
        }
        # Whole-token match: a substring test flagged package paths such as
        # example-admin and turned model-policy BROKEN on ordinary runs.
        function prohibited(value, i, word) {
          value = tolower(value)
          for (i = 1; i <= forbidden_count; i++) {
            word = tolower(forbidden[i])
            if (word == "") continue
            gsub(/\./, "\\.", word)
            if (value ~ ("(^|[^a-z0-9])" word "([^a-z0-9]|$)")) return 1
          }
          return 0
        }
        function allowed_identity(model, effort, i, identity) {
          identity = tolower(model ":" effort)
          for (i = 1; i <= allowed_count; i++)
            if (identity == tolower(allowed[i])) return 1
          return 0
        }
        {
          predates_policy = ($1 + 0 > policy_age + 0)
          $1 = ""
          $0 = $0
          has_forbidden_executable = 0
          has_codex_exec = 0
          in_pipeline_worktree = 0
          uses_pipeline_settings = 0
          model = ""
          effort = ""
          process = basename($1)
          argv0 = basename($2)
          if (prohibited(process) || prohibited(argv0)) has_forbidden_executable = 1
          if ((process == "codex" || argv0 == "codex") && $3 == "exec") has_codex_exec = 1
          for (i = 1; i < NF; i++) {
            if ($i == "--settings" && index($(i + 1), settings) == 1) uses_pipeline_settings = 1
            if ($i == "--cd" && index($(i + 1), worktrees) == 1) in_pipeline_worktree = 1
            if (index($i, "--cd=") == 1 && index(substr($i, 6), worktrees) == 1) in_pipeline_worktree = 1
            if (index($i, worktrees) == 1) in_pipeline_worktree = 1
            if ($i == "-m" || $i == "--model") {
              model = tolower($(i + 1))
            }
            if ($i ~ /^--model=/) {
              model = tolower(substr($i, 9))
            }
            if (($i == "-c" || $i == "--config") && $(i + 1) ~ /^model_reasoning_effort=/) {
              effort = tolower($(i + 1))
              sub(/^model_reasoning_effort=/, "", effort)
              gsub(/^[\047\042]|[\047\042]$/, "", effort)
            }
            if ($i ~ /^model_reasoning_effort=/) {
              effort = tolower($i)
              sub(/^model_reasoning_effort=/, "", effort)
              gsub(/^[\047\042]|[\047\042]$/, "", effort)
            }
          }
          if (has_forbidden_executable && (uses_pipeline_settings || in_pipeline_worktree)) bad = 1
          if (has_codex_exec && in_pipeline_worktree && (model == "" || prohibited(model))) bad = 1
          if (has_codex_exec && in_pipeline_worktree && !predates_policy && (effort == "" || !allowed_identity(model, effort))) bad = 1
        }
        END { exit bad }
      ' || { echo forbidden; return 1; }
      echo clean
      ;;
    *)
      echo "model_policy: unsupported operation" >&2
      return 64
      ;;
  esac
}

model_policy_scan_sources() {
  local script_dir file source process_name target_text selection word model scan_detail
  local expected_id blocked_family approved_filter approved_sanitized_filter approved_policy_input legacy_policy_input expanded_approved_policy_input assertion incident_guards_file rulings_file
  local -a forbidden_words role_models forbidden_patterns role_patterns
  if [[ "${ZF_CHECK_RULINGS_POLICY_SOURCE_SCAN_VERIFIED:-0}" == 1 ]]; then return 0; fi
  script_dir="$(dirname -- "$MODEL_POLICY_DEFAULT")"
  if [[ -n "$ZF_CONFIG_ROOT" && "$MODEL_POLICY_DEFAULT" == "$ZF_CONFIG_ROOT/"* ]]; then
    # Config is data-only; keep scanning executable sources from the engine.
    script_dir="$_AGENT_LIB_DIR"
  fi
  incident_guards_file="$(zf_config_file state/incident-guards.json 2>/dev/null || true)"
  rulings_file="$(zf_config_file state/rulings.json 2>/dev/null || true)"
  mapfile -t forbidden_words < <(jq -r '.forbidden[]' "$MODEL_POLICY_DEFAULT")
  mapfile -t role_models < <(jq -r '.roles[].model' "$MODEL_POLICY_DEFAULT")
  for word in "${forbidden_words[@]}"; do forbidden_patterns+=( -e "$word" ); done
  for model in "${role_models[@]}"; do role_patterns+=( -e "$model" ); done
  while IFS= read -r -d '' file; do
    [[ "$file" == "$MODEL_POLICY_DEFAULT" || "$file" == "$script_dir/model-policy.default.json" || "$file" == *.test.* || "${file##*/}" == test-* || "$file" == *-test.* ]] && continue
    if [[ "$file" == "$rulings_file" || "$file" == "$script_dir/state/rulings.json" ]]; then
      # Keep each switch and argv intact. Only the one exact repository jq assertion is eligible for masking.
      source=""
      expected_id='gpt-6-luna'
      blocked_family='sol'
      approved_filter=".roles.work.provider == \"codex\" and .roles.work.model == \"$expected_id\" and .roles.work.effort == \"max\" and (.roles.work | (has(\"fallback_identity\") | not) and (has(\"fallback_model\") | not)) and .roles.review.provider == \"codex\" and .roles.review.model == \"$expected_id\" and .roles.review.effort == \"max\" and (.roles.review | (has(\"fallback_identity\") | not) and (has(\"fallback_model\") | not)) and .roles.production.provider == \"codex\" and .roles.production.model == \"$expected_id\" and .roles.production.effort == \"high\" and (.roles.production | (has(\"fallback_identity\") | not) and (has(\"fallback_model\") | not)) and (.forbidden | index(\"$blocked_family\")) != null"
      approved_sanitized_filter="$approved_filter"
      assertion=".roles.work.model == \"$expected_id\""
      approved_sanitized_filter="${approved_sanitized_filter//"$assertion"/__approved_policy_assertion__}"
      assertion=".roles.review.model == \"$expected_id\""
      approved_sanitized_filter="${approved_sanitized_filter//"$assertion"/__approved_policy_assertion__}"
      assertion=".roles.production.model == \"$expected_id\""
      approved_sanitized_filter="${approved_sanitized_filter//"$assertion"/__approved_policy_assertion__}"
      assertion="(.forbidden | index(\"$blocked_family\")) != null"
      approved_sanitized_filter="${approved_sanitized_filter//"$assertion"/__approved_policy_assertion__}"
      # This file has hundreds of switches. Extract all command strings in one jq
      # pass instead of starting multiple jq processes for every switch on each
      # HEALTH sample. Preserve the exact approved assertion exception.
      if [[ "$MODEL_POLICY_DEFAULT" == "$REPO_DIR/"* ]]; then
        approved_policy_input="\${REPO_DIR}/${MODEL_POLICY_DEFAULT#"$REPO_DIR"/}"
      else
        approved_policy_input="\${REPO_DIR}/$ZF_PACK_REL/model-policy.default.json"
      fi
      legacy_policy_input="\${REPO_DIR}/$ZF_PACK_REL/model-policy.default.json"
      expanded_approved_policy_input="${approved_policy_input//'${REPO_DIR}'/$REPO_DIR}"
      [[ "$expanded_approved_policy_input" == "$MODEL_POLICY_DEFAULT" ]] || approved_policy_input=""
      while IFS= read -r -d '' target_text; do
        source+="$target_text"$'\n'
      done < <(jq -j --arg filter "$approved_filter" --arg input "$approved_policy_input" --arg legacy_input "$legacy_policy_input" \
        --arg sanitized_filter "$approved_sanitized_filter" '
        def emit: if type == "string" then ., "\u0000" else empty end;
        .rulings[]? | .switches[]? as $switch
        | if $switch.kind == "command" and $switch.scope == "repository"
             and $switch.expected == "exit:0"
             and ($switch | (has("per_tick_target") | not) and (has("per_tick_scope") | not))
             and ($switch.target | type == "array" and length == 4 and all(.[]; type == "string"))
             and $switch.target[0] == "jq" and $switch.target[1] == "-e"
             and $switch.target[2] == $filter
             and ($switch.target[3] == $input or $switch.target[3] == $legacy_input)
          then [$switch.target[0], $switch.target[1], $sanitized_filter, $switch.target[3]][]
          else [$switch.target?, $switch.per_tick_target?][]
            | if type == "array" then .[]? else . end
          end
        | emit
      ' "$file")
      source="$(sed -E 's/\.claude([^[:alnum:]_]|$)/ /Ig' <<< "$source")"
      selection="$source"
    else
      source="$(sed -E 's/CLAUDE\.md//Ig; s/\.claude([^[:alnum:]_]|$)/ /Ig; s#/tmp/[[:alpha:]]+-[0-9]+# #g; /source=.*CLAUDE/d' "$file" | tr -d '\000')"
      if [[ "$file" == "$script_dir/network-traffic.py" ]]; then
        # `comm` is read-only OS process metadata here, not a model choice.
        # Split token so this scanner does not match its own exception.
        process_name=cla
        process_name+=ude
        source="$(sed -E "s/(comm[[:space:]]+in[[:space:]]*\\([^)]*)([^[:alnum:]_])${process_name}([^[:alnum:]_][^)]*\\))/\\1\\2process-name\\3/g" <<< "$source")"
      fi
      if [[ "$file" == "$incident_guards_file" || "$file" == "$script_dir/state/incident-guards.json" \
        || "$file" == "$script_dir"/fragment-text--*.txt ]]; then
        selection="$source"
      else
        selection="$(grep -Ei '(^|[^[:alnum:]_])(--[[:alnum:]_-]*model([_-]name)?([[:space:]]+|=|[[:punct:]]+[[:space:]]*[,;])|([[:alnum:]_]*_)?model([_-](name|id|provider))?[[:space:]]*[:=])' <<< "$source" || true)"
      fi
    fi
    if [[ ${#forbidden_patterns[@]} -gt 0 ]] \
      && grep -Eiwq "${forbidden_patterns[@]}" <<< "$selection"; then
      scan_detail=""
      for word in "${forbidden_words[@]}"; do
        if grep -Fiwq -- "$word" <<< "$selection"; then scan_detail="$word"; break; fi
      done
      echo "model_policy: forbidden model name '$scan_detail' appears in $file" >&2
      return 1
    fi
    if [[ ${#role_patterns[@]} -gt 0 ]] \
      && grep -Fiwq "${role_patterns[@]}" <<< "$selection"; then
      echo "model_policy: role model is hardcoded in $file" >&2
      return 1
    fi
    if grep -Eiq 'gpt-[0-9][[:alnum:]._-]*|(^|[^[:alnum:]_])(codex|web):[[:alnum:]][[:alnum:]._-]*(:[[:alnum:]_-]+)?([^[:alnum:]_]|$)' <<< "$selection"; then
      echo "model_policy: hardcoded model identity appears in $file" >&2
      return 1
    fi
  # bin/ (the worker launchers luna, terra, worker in a packaged engine) names concrete models on purpose.
  done < <(
    find "$script_dir" -type f ! -name '*.test.*' ! -path "$script_dir/bin/*" -print0
    for file in "$rulings_file" "$incident_guards_file"; do
      [[ -n "$file" && "$file" != "$script_dir/"* && -f "$file" ]] && printf '%s\0' "$file"
    done
  )
}

model_policy_identity_allowed() {
  model_policy_identity_is_allowed "$1"
}


implement_model_for_attempt() {
  local issue="${N:-}"
  if [[ "$issue" =~ ^[0-9]+$ ]]; then model_policy dispatch-state-identity "$issue"; else model_policy dispatch-identity work; fi
}

zcode_provider_config_model_matches() {
  local identity="$1" model config_model
  model="${identity#zcode:}"
  model="${model%:*}"
  [ -r "$ZCODE_PROVIDER_CONFIG_FILE" ] || return 1
  config_model="$(jq -er '.config.defaultModelSelection.modelId | strings' "$ZCODE_PROVIDER_CONFIG_FILE" 2>/dev/null || true)"
  [ -n "$config_model" ] && [ "$config_model" = "$model" ]
}

review_cross_identity_for() {
  local implement_provider="$1" cross
  cross="$(model_policy identity review 2>/dev/null || true)"
  if [ -n "$cross" ] && [ "${cross%%:*}" != "$implement_provider" ]; then
    printf '%s\n' "$cross"
    return 0
  fi
  # A zcode implementer's other provider is codex: the work role. A codex
  # implementer has no zcode reviewer left to try when the review role is
  # unresolvable or same-provider -- the caller falls back.
  if [ "$implement_provider" = zcode ]; then
    model_policy identity work 2>/dev/null && return 0
  fi
  return 1
}

review_identity_available() {
  local identity="$1"
  case "${identity%%:*}" in
    codex)
      codex_quota_exhausted && return 1
      codex_probe_ok || return 1
      command -v codex >/dev/null 2>&1
      ;;
    zcode)
      provider_quota_exhausted zcode && return 1
      command -v zcode >/dev/null 2>&1 || return 1
      zcode_provider_config_model_matches "$identity"
      ;;
    *) return 1 ;;
  esac
}

record_review_provider_fallback() {
  local issue="$1" wanted="$2" used="$3" reason="$4" wanted_json used_json reason_json reason_file
  wanted_json="$(jq -cn --arg value "$wanted" '$value')" || return 1
  used_json="$(jq -cn --arg value "$used" '$value')" || return 1
  reason_file="$(jq_arg_file "$reason")" || return 1
  reason_json="$(jq -cn --rawfile value "$reason_file" '$value')" || { rm -f "$reason_file"; return 1; }
  rm -f "$reason_file"
  state_merge "$issue" ".review_provider_fallback = {at:(now|todate),wanted:$wanted_json,used:$used_json,reason:$reason_json} | .review_provider_fallback_history = ((.review_provider_fallback_history // []) + [.review_provider_fallback]) | .review_provider_fallback_history |= .[-5:]" >/dev/null
}

review_model_for_implementer() {
  local issue="$1" implement_identity="$2" cross
  cross="$(review_cross_identity_for "${implement_identity%%:*}" || true)"
  if [ -n "$cross" ]; then
    if review_identity_available "$cross"; then
      printf '%s\n' "$cross"
      return 0
    fi
    record_review_provider_fallback "$issue" "$cross" "$implement_identity" \
      "cross-provider reviewer unavailable (quota hold, outage, or missing runtime/config); reviewing on the implementer's own provider" || true
  else
    record_review_provider_fallback "$issue" "review-role-unresolvable" "$implement_identity" \
      "cross-provider review role could not be resolved from the live policy; reviewing on the implementer's own provider" || true
  fi
  printf '%s\n' "$implement_identity"
}


# resolve_guarded_reviewer <identity> [fallback] -> a policy-approved identity.
resolve_guarded_reviewer() {
  local id="$1" fallback="${2:-$(model_policy identity work)}"
  model_policy_identity_allowed "$fallback" || fallback="$(model_policy identity work)"
  model_policy_identity_allowed "$id" || { echo "$fallback"; return 0; }
  case "$id" in
    codex:*)
      if [ ! -f "$CODEX_PROBE_MARKER" ]; then
        echo "guarded reviewer $id requested but $CODEX_PROBE_MARKER is absent -- engine/probe-codex-sandbox.sh has not passed on this box; using $fallback" >&2
        echo "$fallback"
      elif codex_quota_exhausted; then
        # 2026-09-17: a second, different reason to refuse the same identity.
        # The probe gate above is about safety and is unchanged. This one is
        # availability: while the Codex account-wide usage-limit window is
        # open, dispatching a Codex reviewer buys a guaranteed refusal, and
        # each refusal that reaches run-advisor.sh's ladder end writes the
        # PAUSE file and stops the WHOLE pipeline for an hour -- so one
        # provider outage was idling unrelated issue work too.
        echo "guarded reviewer $id requested but the Codex quota window is closed until $(date -d "@$(cat "$CODEX_EXHAUSTED_MARKER_FILE" 2>/dev/null || echo 0)" '+%H:%M:%S' 2>/dev/null) -- using $fallback" >&2
        echo "$fallback"
      else
        echo "$id"
      fi
      ;;
    *) echo "$id" ;;
  esac
}
