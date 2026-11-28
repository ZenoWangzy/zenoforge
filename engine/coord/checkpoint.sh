COORD_CHECKPOINT_FILE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/checkpoint.json"

coord_checkpoint_spec_valid() {
  jq -e 'type == "object" and .version == 1
    and (.state | type == "array" and all(.[]; type == "string") and length == (unique | length))
    and (.unit | type == "array" and all(.[]; type == "string") and length == (unique | length))' \
    "$COORD_CHECKPOINT_FILE" >/dev/null 2>&1
}

coord_checkpoint_valid() {
  coord_checkpoint_spec_valid || return 1
  jq -e --slurpfile spec "$COORD_CHECKPOINT_FILE" '
    type == "object" and (.state | type == "object") and (.unit | type == "object")
    and ((.state | keys) - $spec[0].state | length) == 0
    and ((.unit | keys) - $spec[0].unit | length) == 0
  ' <<<"${1:-}" >/dev/null 2>&1
}

coord_checkpoint_project() {
  local subject="${1:-}" unit="${2:-}" units_file="${3:-${ZF_COORD_UNITS_FILE:-${UNITS:-}}}"
  local runtime="${MAC_AUTOPILOT_RUNTIME_DIR:-${A:-${AGENT_HOME:-}/autopilot}}"
  local state_file="${STATE_DIR:-${AGENT_HOME:-}/state}/${1:-}.json" state_data unit_data
  coord_checkpoint_spec_valid || return 3
  state_data='{}'
  if [[ "$subject" =~ ^[1-9][0-9]*$ ]]; then
    if [[ -r "$state_file" ]]; then
      jq -e 'type == "object"' "$state_file" >/dev/null 2>&1 || return 3
      state_data="$(jq -cn --slurpfile source "$state_file" --slurpfile spec "$COORD_CHECKPOINT_FILE" '
        reduce $spec[0].state[] as $key ({}; if ($source[0] | has($key)) then .[$key] = $source[0][$key] else . end)
      ')" || return 3
    else
      state_data='{"attempts":0}'
      state_data="$(jq -cn --argjson source "$state_data" --slurpfile spec "$COORD_CHECKPOINT_FILE" '
        reduce $spec[0].state[] as $key ({}; if ($source | has($key)) then .[$key] = $source[$key] else . end)
      ')" || return 3
    fi
  fi
  unit_data='{}'
  [[ -n "$units_file" ]] || units_file="$runtime/units.json"
  if [[ -n "$unit" && -r "$units_file" ]]; then
    jq -e 'type == "object" and (.units | type == "array")
      and all(.units[]; type == "object" and (.id | type == "string"))
      and ([.units[].id] | length) == ([.units[].id] | unique | length)' \
      "$units_file" >/dev/null 2>&1 || return 3
    unit_data="$(jq -cn --arg id "$unit" --slurpfile source "$units_file" --slurpfile spec "$COORD_CHECKPOINT_FILE" '
      ([$source[0].units[] | select(.id == $id)][0] // {}) as $row
      | reduce $spec[0].unit[] as $key ({}; if ($row | has($key)) then .[$key] = $row[$key] else . end)
    ')" || return 3
  fi
  jq -cn --argjson state "$state_data" --argjson unit "$unit_data" '{state:$state,unit:$unit}'
}

coord_checkpoint_fit_claim() {
  local claim="${1:-}" projection="${2:-}" limit="${ZF_COORD_CHECKPOINT_MAX:-8192}" size old_exists empty='{"state":{},"unit":{}}'
  jq -e 'type == "object"' <<<"$claim" >/dev/null 2>&1 || return 3
  coord_checkpoint_valid "$projection" || return 3
  [[ "$limit" =~ ^[1-9][0-9]*$ ]] || limit=8192
  size="$(jq -c -j '.' <<<"$projection" | wc -c | tr -d '[:space:]')" || return 3
  if (( size <= limit )); then
    jq -cn --argjson claim "$claim" --argjson checkpoint "$projection" \
      '$claim + {checkpoint:$checkpoint} | del(.checkpoint_truncated)'
    return
  fi
  old_exists=false
  jq -e 'has("checkpoint") and .checkpoint != null' <<<"$claim" >/dev/null 2>&1 && old_exists=true
  if [[ "$old_exists" == true ]]; then
    jq -cn --argjson claim "$claim" '$claim + {checkpoint_truncated:true}'
    return
  fi
  size="$(jq -c -j '.' <<<"$empty" | wc -c | tr -d '[:space:]')" || return 3
  (( size <= limit )) || return 3
  jq -cn --argjson claim "$claim" --argjson checkpoint "$empty" \
    '$claim + {checkpoint:$checkpoint,checkpoint_truncated:true}'
}

_coord_checkpoint_load_state_merge() {
  declare -F state_merge >/dev/null 2>&1 && return 0
  local lib="${SCHEDULER_AGENT_LIB:-}"
  [[ -n "$lib" ]] || lib="${ZF_ENGINE_DIR:-$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)}/lib.sh"
  [[ -r "$lib" ]] || return 1
  source "$lib" >/dev/null 2>&1 || return 1
  declare -F state_merge >/dev/null 2>&1
}

_coord_checkpoint_load_scheduler_unit_writer() {
  declare -F scheduler_unit_restore >/dev/null 2>&1 && return 0
  local engine="${ZF_ENGINE_DIR:-$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)}"
  local scheduler="$engine/mac-autopilot" runtime="${MAC_AUTOPILOT_RUNTIME_DIR:-${A:-${AGENT_HOME:?}/autopilot}}"
  [[ -r "$scheduler/scheduler.d/core.sh" && -r "$scheduler/scheduler.d/unit-transition-log.sh" \
    && -r "$scheduler/scheduler.d/reports.sh" && -r "$scheduler/scheduler.d/locks-views.sh" \
    && -r "$scheduler/scheduler.d/units.sh" ]] || return 1
  ZF_ENGINE_DIR="$engine" MAC_AUTOPILOT_RUNTIME_DIR="$runtime" A="$runtime"
  HERE="$scheduler" SCHED_DIR="$scheduler" ROOT="${MAC_AUTOPILOT_ROOT:-${ZF_REPO_DIR:-$(cd -- "$engine/.." && pwd -P)}}"
  ENGINE_ROOT="$ROOT" UNITS="${ZF_COORD_UNITS_FILE:-${UNITS:-$runtime/units.json}}"
  WORKERS="${ZF_COORD_WORKERS_FILE:-${WORKERS:-$runtime/workers.json}}"
  UNITS_ARCHIVE="${UNITS_ARCHIVE:-$runtime/units-archive.json}" LOG="${LOG:-$runtime/scheduler.log}"
  STAMP="${STAMP:-$(date -u +%Y-%m-%dT%H:%M:%SZ)}" SCHED_LOCK="${SCHED_LOCK:-$runtime/.scheduler.lock}"
  SCHEDULER_AGENT_LIB="${SCHEDULER_AGENT_LIB:-$engine/lib.sh}" SCHED_LOCK_HELD="${SCHED_LOCK_HELD:-false}"
  source "$scheduler/scheduler.d/core.sh" || return 1
  source "$scheduler/scheduler.d/unit-transition-log.sh" || return 1
  source "$scheduler/scheduler.d/reports.sh" || return 1
  source "$scheduler/scheduler.d/locks-views.sh" || return 1
  source "$scheduler/scheduler.d/units.sh" || return 1
  declare -F scheduler_unit_restore >/dev/null 2>&1
}

coord_checkpoint_restore() {
  local claim="${1:-}" checkpoint subject unit state_values unit_values unit_keys patch_file
  jq -e 'type == "object" and (.subject | type == "string") and (.unit | type == "string")' \
    <<<"$claim" >/dev/null 2>&1 || return 1
  checkpoint="$(jq -c '.checkpoint // empty' <<<"$claim")" || return 1
  [[ -n "$checkpoint" ]] || return 0
  coord_checkpoint_valid "$checkpoint" || return 1
  local limit="${ZF_COORD_CHECKPOINT_MAX:-8192}" size
  [[ "$limit" =~ ^[1-9][0-9]*$ ]] || limit=8192
  size="$(jq -c -j '.' <<<"$checkpoint" | wc -c | tr -d '[:space:]')" || return 1
  (( size <= limit )) || return 1
  subject="$(jq -r '.subject' <<<"$claim")" || return 1
  unit="$(jq -r '.unit' <<<"$claim")" || return 1
  state_values="$(jq -c '.state' <<<"$checkpoint")" || return 1
  if [[ "$subject" =~ ^[1-9][0-9]*$ ]]; then
    _coord_checkpoint_load_state_merge || return 1
    mkdir -p "${AGENT_HOME:?AGENT_HOME must be set}/coord" || return 1
    patch_file="$(mktemp "$AGENT_HOME/coord/.checkpoint-patch.XXXXXX")" || return 1
    if ! jq -cn --argjson values "$state_values" --slurpfile spec "$COORD_CHECKPOINT_FILE" \
      '{state_keys:$spec[0].state,state_values:$values}' >"$patch_file"; then
      rm -f -- "$patch_file"
      return 1
    fi
    if state_merge "$subject" \
      'reduce $state_merge_patch[0].state_keys[] as $key (. ; del(.[$key])) | . + $state_merge_patch[0].state_values' \
      '' "$patch_file"; then
      rm -f -- "$patch_file"
    else
      local rc=$?
      rm -f -- "$patch_file"
      return "$rc"
    fi
  elif [[ "$state_values" != '{}' ]]; then
    return 1
  fi
  unit_values="$(jq -c '.unit' <<<"$checkpoint")" || return 1
  if [[ "$unit_values" != '{}' ]]; then
    _coord_checkpoint_load_scheduler_unit_writer || return 1
    unit_keys="$(jq -c '.unit' "$COORD_CHECKPOINT_FILE")" || return 1
    scheduler_unit_restore "$unit" "$unit_values" "$unit_keys" || return 1
  fi
}

coord_checkpoint_alert() {
  local claim="${1:-}" key subject unit
  key="$(jq -r '.key // "unknown"' <<<"$claim")" || key=unknown
  subject="$(jq -r '.subject // "unknown"' <<<"$claim")" || subject=unknown
  unit="$(jq -r '.unit // "unknown"' <<<"$claim")" || unit=unknown
  _coord_checkpoint_load_state_merge || return 1
  declare -F supervisor_inbox_append_once >/dev/null 2>&1 || return 1
  supervisor_inbox_append_once "checkpoint-restore-failed:$key" \
    "checkpoint-restore-failed claim=$key issue=$subject unit=$unit"
}
