# Shared E1 input aliases for full and standalone engine consumers.
# Retire a legacy alias only after two consecutive deployed pins with zero
# successful reads from every known consumer, complete deployment/config
# coverage and a successful old-version rollback rehearsal. Any use, conflict
# or missing coverage resets the window. Removing stored legacy config is a
# separately authorized action before observation begins. For rollback,
# restore the legacy switch/config before pinning an older engine; stay off
# when the configuration is missing or conflicting.

# A successful repository-variable listing establishes presence and values.
# A failed listing cannot prove absence (GitHub can hide an inaccessible
# repository behind 404), so it always stops dispatch.
_ZF_MODE_NORMALIZE_JQ='def normalize:
  gsub("[\u0009-\u000d ]"; "") |
  if . == "off" then "off"
  elif . == "triage" or . == "implement" or . == "release" then "triage"
  else "invalid" end;'
zf_read_repository_mode_pair() {
  local consumer="$1" variables parsed legacy new
  if ! variables="$(gh variable list --repo "$REPO" --json name,value \
    --jq '[.[] | select(.name == "AGENT_ZENOFORGE" or .name == "AGENT_PIPELINE")]' 2>/dev/null)"; then
    echo "issue-pipeline: $consumer could not read repository mode variables; off" >&2
    return 1
  fi
  if ! parsed="$(jq -sr "$_ZF_MODE_NORMALIZE_JQ"'
    (if length == 1 then .[0] else error("invalid mode data") end) |
    if type == "array" and
       all(.[]; (.name == "AGENT_ZENOFORGE" or .name == "AGENT_PIPELINE") and (.value | type == "string")) and
       ([.[].name] | length == (unique | length)) then
      ([.[] | select(.name == "AGENT_PIPELINE") | .value | normalize][0] // "absent") as $legacy |
      ([.[] | select(.name == "AGENT_ZENOFORGE") | .value | normalize][0] // "absent") as $new |
      [$legacy, $new] | @tsv
    else error("invalid mode data") end
  ' 2>/dev/null <<< "$variables")"; then
    echo "issue-pipeline: $consumer received invalid repository mode data; off" >&2
    return 1
  fi
  IFS=$'\t' read -r legacy new <<< "$parsed"
  if [[ ! "$legacy" =~ ^(absent|off|triage|invalid)$ || ! "$new" =~ ^(absent|off|triage|invalid)$ ]]; then
    echo "issue-pipeline: $consumer received invalid repository mode data; off" >&2
    return 1
  fi
  if [ "$legacy" != absent ]; then
    echo "issue-pipeline: legacy AGENT_PIPELINE read by $consumer" >&2
  fi
  printf '%s\t%s\n' "$legacy" "$new"
}

zf_recheck_legacy_mode() {
  local consumer="$1" expected="$2" expected_new="$3" errors output observed confirmed old new
  errors="$(mktemp)" || { echo "issue-pipeline: $consumer cannot verify legacy mode; off" >&2; return 1; }
  output="$(mktemp)" || { rm -f -- "$errors"; echo "issue-pipeline: $consumer cannot verify legacy mode; off" >&2; return 1; }
  # Keep raw output out of shell variables: command substitution discards NULs,
  # which could otherwise turn a malformed value into a valid running mode.
  if gh variable get AGENT_PIPELINE --repo "$REPO" >"$output" 2>"$errors"; then
    echo "issue-pipeline: legacy AGENT_PIPELINE read by $consumer" >&2
    if ! observed="$(jq -Rsr "$_ZF_MODE_NORMALIZE_JQ"'
      normalize # invalid legacy mode data
    ' "$output" 2>/dev/null)" || [[ ! "$observed" =~ ^(off|triage|invalid)$ ]]; then
      rm -f -- "$errors" "$output"
      echo "issue-pipeline: $consumer received invalid legacy mode data; off" >&2
      return 1
    fi
    rm -f -- "$errors" "$output"
    printf '%s\n' "$observed"
    return 0
  fi
  if [ "$expected" = absent ] && grep -Fxq 'variable AGENT_PIPELINE was not found' "$errors"; then
    rm -f -- "$errors" "$output"
    confirmed="$(zf_read_repository_mode_pair "$consumer")" || return 1
    IFS=$'\t' read -r old new <<< "$confirmed"
    if [ "$old" = absent ] && [ "$new" = "$expected_new" ]; then
      echo absent
      return 0
    fi
    echo "issue-pipeline: $consumer repository mode changed during read; off" >&2
    return 1
  fi
  rm -f -- "$errors" "$output"
  echo "issue-pipeline: $consumer could not verify legacy mode; off" >&2
  return 1
}

read_zenoforge_mode() {
  local consumer="$1" first observed legacy new
  first="$(zf_read_repository_mode_pair "$consumer")" || { echo off; return; }
  IFS=$'\t' read -r legacy new <<< "$first"
  if [ "$legacy" = invalid ] || [ "$new" = invalid ] || \
     { [ "$legacy" != absent ] && [ "$new" != absent ] && [ "$legacy" != "$new" ]; }; then
    echo "issue-pipeline: $consumer repository mode conflict or malformed value; off" >&2
    echo off; return
  fi
  if [ "$legacy" = off ] || [ "$new" = off ]; then
    echo "issue-pipeline: $consumer repository mode requests off" >&2
  fi
  # gh paginates listings. A direct legacy read after the listing catches a
  # stop that happened after its legacy page was read. A confirmed absence
  # requires both a missing-key response and another successful listing.
  if [ "$legacy" = triage ] || [ "$new" = triage ]; then
    observed="$(zf_recheck_legacy_mode "$consumer" "$legacy" "$new")" || { echo off; return; }
    if [ "$legacy" != "$observed" ]; then
      echo "issue-pipeline: $consumer repository mode changed during read; off" >&2
      echo off; return
    fi
  fi
  if [ "$new" != absent ]; then echo "$new"
  elif [ "$legacy" != absent ]; then echo "$legacy"
  else echo off
  fi
}

zf_call_profile_file() {
  local consumer="${1:-engine}" value=''
  _ZF_CALL_PROFILE_RESOLVED_FILE=''
  if [[ -v ZF_PIPELINE_CALL_PROFILE_FILE ]]; then
    echo "issue-pipeline: legacy ZF_PIPELINE_CALL_PROFILE_FILE read by $consumer" >&2
  fi
  if [[ -v ZF_CALL_PROFILE_FILE && -v ZF_PIPELINE_CALL_PROFILE_FILE ]] && \
     [ "$ZF_CALL_PROFILE_FILE" != "$ZF_PIPELINE_CALL_PROFILE_FILE" ]; then
    echo "issue-pipeline: $consumer conflicting ZF_PIPELINE_CALL_PROFILE_FILE and ZF_CALL_PROFILE_FILE; profiling disabled" >&2
    return 1
  fi
  if [[ -v ZF_CALL_PROFILE_FILE ]]; then
    value="$ZF_CALL_PROFILE_FILE"
  elif [[ -v ZF_PIPELINE_CALL_PROFILE_FILE ]]; then
    value="$ZF_PIPELINE_CALL_PROFILE_FILE"
  fi
  [ -n "$value" ] || return 1
  _ZF_CALL_PROFILE_RESOLVED_FILE="$value"
}

# Profile producers publish both flags. A caller or fixture may supply either;
# a conflicting pair never enables instrumentation.
zf_call_profile_enabled() {
  local consumer="${1:-engine}" value=0
  if [[ -v ZF_PIPELINE_CALL_PROFILE_ENABLED ]]; then
    echo "issue-pipeline: legacy ZF_PIPELINE_CALL_PROFILE_ENABLED read by $consumer" >&2
  fi
  if [[ -v ZF_CALL_PROFILE_ENABLED && -v ZF_PIPELINE_CALL_PROFILE_ENABLED ]] && \
     [ "$ZF_CALL_PROFILE_ENABLED" != "$ZF_PIPELINE_CALL_PROFILE_ENABLED" ]; then
    echo "issue-pipeline: $consumer conflicting profile enabled flags ZF_PIPELINE_CALL_PROFILE_ENABLED and ZF_CALL_PROFILE_ENABLED; profiling disabled" >&2
    return 1
  fi
  if [[ -v ZF_CALL_PROFILE_ENABLED ]]; then
    value="$ZF_CALL_PROFILE_ENABLED"
  elif [[ -v ZF_PIPELINE_CALL_PROFILE_ENABLED ]]; then
    value="$ZF_PIPELINE_CALL_PROFILE_ENABLED"
  fi
  case "$value" in 1) return 0 ;; 0|'') return 1 ;; *)
    echo "issue-pipeline: $consumer invalid profile enabled flag; profiling disabled" >&2; return 1 ;;
  esac
}
