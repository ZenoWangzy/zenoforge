#!/usr/bin/env bash
# Sensor: return a compact semantic diff without changing either file.
config_sensor_diff() { # source runtime
  local source_file="$1" runtime_file="$2" source_json runtime_json
  source_json="$(jq -cS 'if type == "object" then . else error("config must be an object") end' "$source_file" 2>/dev/null)" || return 1
  [[ -f "$runtime_file" ]] || return 0
  runtime_json="$(jq -cS 'if type == "object" then . else error("config must be an object") end' "$runtime_file" 2>/dev/null || true)"
  [[ "$runtime_json" != "$source_json" ]] || return 0
  if [[ -z "$runtime_json" ]]; then
    printf '%s\n' '{"keys":["invalid-json"],"diff":{"runtime":"invalid-json"}}'
    return 0
  fi
  jq -cn --slurpfile source "$source_file" --slurpfile runtime "$runtime_file" '
    (($source[0] | keys) + ($runtime[0] | keys) | unique) as $all
    | ($all | map(. as $key | select(($source[0] | has($key)) != ($runtime[0] | has($key)) or $source[0][$key] != $runtime[0][$key]))) as $keys
    | {keys:$keys, diff:(reduce $keys[] as $key ({}; .[$key] = {
        runtime: {present: ($runtime[0] | has($key)), value: $runtime[0][$key]},
        repository: {present: ($source[0] | has($key)), value: $source[0][$key]}
      }))}
  ' 2>/dev/null
}

# Actuator: install the pinned repository config into the runtime directory.
config_actuate() { # source runtime
  cp -- "$1" "$2"
}

# Report sensed drift before applying the repository rule. Prints a scheduler-log
# line only when an inbox event was appended.
reconcile_runtime_config() { # source runtime lib.sh
  local source_file="$1" runtime_file="$2" lib_file="$3"
  local drift keys message agent_home observed_at
  drift="$(config_sensor_diff "$source_file" "$runtime_file")" || return 1
  if [[ -n "$drift" ]]; then
    keys="$(jq -r '.keys | join(",")' <<<"$drift")"
    observed_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)" || return 1
    # The shared inbox collapses identical text within a day; keep separate drift episodes distinct.
    message="observed_at=$observed_at process=$$ runtime=$runtime_file repository=$source_file diff=$drift"
    agent_home="${AGENT_HOME:-${ZF_HOME:-${HOME:-}/.zenoforge}}"
    AGENT_HOME="$agent_home" bash -c 'source "$1" && supervisor_inbox_append config-reconcile "$2"' \
      bash "$lib_file" "$message" || return 1
    printf 'config-reconcile keys=%s\n' "$keys"
  fi
  if [[ -n "$drift" || ! -f "$runtime_file" ]]; then
    config_actuate "$source_file" "$runtime_file" || return 1
  fi
}
