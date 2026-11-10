model_not_found_cache_file() { printf '%s/luna/model-not-found.cache\n' "${WORKER_SCRATCH_ROOT:-${HOME:-/tmp}/.zenoforge/scratch}"; }
model_not_found_cache_has() { # model → true only while the shared worker-cache expiry is in the future
  local wanted="$1" cache model expires now
  cache="$(model_not_found_cache_file)"; [[ -r "$cache" ]] || return 1
  now="$(date +%s)" || return 1
  while IFS=$'\t' read -r model expires; do
    [[ "$model" == "$wanted" && "$expires" =~ ^[0-9]+$ ]] && (( expires > now )) && return 0
  done < "$cache"
  return 1
}
model_not_found_cache_record() { # append model<TAB>expiry once per 24h outage window
  local model="$1" cache lock_fd now
  [[ "$model" =~ ^[A-Za-z0-9._-]+$ ]] || return 0
  cache="$(model_not_found_cache_file)"; mkdir -p "${cache%/*}" || return 1
  exec {lock_fd}>"$cache.lock" || return 1
  flock -x "$lock_fd" || { exec {lock_fd}>&-; return 1; }
  if model_not_found_cache_has "$model"; then flock -u "$lock_fd"; exec {lock_fd}>&-; return 0; fi
  now="$(date +%s)" || { flock -u "$lock_fd"; exec {lock_fd}>&-; return 1; }
  printf '%s\t%s\n' "$model" "$((now + 86400))" >> "$cache"
  flock -u "$lock_fd"; exec {lock_fd}>&-
}
model_not_found_fallback_tuple() { # current policy work identity -> fallback model<TAB>effort
  local identity provider model effort
  identity="$(model_policy identity work 2>/dev/null)" || return 1
  IFS=: read -r provider model effort <<<"$identity"
  [[ "$provider" == codex && -n "$model" && -n "$effort" ]] || return 1
  printf '%s\t%s\n' "$model" "$effort"
}
codex_model_for_profile() { # active configured supervisor profile -> its Codex model id
  local profile="$1" config="${CODEX_HOME:-${HOME:-}/.codex}/config.toml" model
  [[ -n "$profile" && "$profile" != *$'\n'* && -r "$config" ]] || return 1
  model="$(awk -v profile="$profile" '
    /^[[:space:]]*\[/ {
      header=$0
      sub(/^[[:space:]]*/, "", header)
      sub(/[[:space:]]*$/, "", header)
      if (header == "[profiles." profile "]") { active=1; next }
      if (active) exit
      active=0
      next
    }
    active && /^[[:space:]]*model[[:space:]]*=/ {
      value=$0
      sub(/^[^=]*=[[:space:]]*/, "", value)
      if (value ~ /^"[^"]+"/) {
        sub(/^"/, "", value)
        sub(/".*$/, "", value)
        if (value ~ /^[A-Za-z0-9._-]+$/) print value
      }
      exit
    }
  ' "$config")"
  [[ -n "$model" ]] || return 1
  printf '%s\n' "$model"
}
model_not_found_arbiter_prepare() { # profile stopped unit → model/effort overrides and cache decision log
  local profile="$1" stopped="$2" unit="$3" source_model fallback_tuple
  MODEL_NOT_FOUND_ARBITER_MODEL=; MODEL_NOT_FOUND_ARBITER_EFFORT=
  [[ "$stopped" != true ]] || return 0
  source_model="$(codex_model_for_profile "$profile" 2>/dev/null || true)"
  [[ -n "$source_model" ]] && model_not_found_cache_has "$source_model" || return 0
  fallback_tuple="$(model_not_found_fallback_tuple)" || { say "supervisor arbitration pending unit=$unit: cached profile model unavailable and no policy fallback is available"; return 1; }
  IFS=$'\t' read -r MODEL_NOT_FOUND_ARBITER_MODEL MODEL_NOT_FOUND_ARBITER_EFFORT <<<"$fallback_tuple"
  say "model-not-found cache swap arbiter profile=$profile from=$source_model to=$MODEL_NOT_FOUND_ARBITER_MODEL effort=$MODEL_NOT_FOUND_ARBITER_EFFORT"
}
model_not_found_cache_observe_log() { # model log → record only an explicit model_not_found response
  [[ -r "$2" ]] && grep -Eiq 'model_not_found' "$2" || return 0
  model_not_found_cache_record "$1" || true
}
model_not_found_cache_observe_worker() { # worker JSON log → observe actual model or mapped arbiter profile
  local kind model
  kind="$(jqf -r '.type // empty' <<<"$1")"; model="$(jqf -r '.model // empty' <<<"$1")"
  case "$kind" in
    implement|repair) ;;
    supervise) model="$(codex_model_for_profile "${model#profile:}" 2>/dev/null || true)"; [[ -n "$model" ]] || return 0 ;;
    *) return 0 ;;
  esac
  model_not_found_cache_observe_log "$model" "$2"
}
