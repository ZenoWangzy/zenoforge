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
codex_model_for_profile() { # active configured supervisor profile → its Codex model id
  case "$1" in terra|gpt-6.1-terra) printf '%s\n' gpt-6.1-terra ;; *) return 1 ;; esac
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
