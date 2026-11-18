#!/usr/bin/env bash
# Sourced by roadmap.sh (kept apart: roadmap.sh sits at the 800-line size-ratchet cap).
# roadmap_body_check_refuse <body-file> <label>... -> rc 0 to create; rc 1 with the check's output on stderr to refuse.
# Rule: night.json `roadmap.body_check_command` (target, then pack, then engine). A ready-for-agent ticket without
# bug/hotfix/engine/pipeline-system runs it on the body; a non-zero exit refuses. No setting, nothing runs.
roadmap_body_check_refuse() {
  local body_file="$1" config_file check_cmd check_out label is_feature=0
  shift
  for label in "$@"; do
    case "$label" in
      ready-for-agent) is_feature=1 ;;
      bug|hotfix|engine|pipeline-system) return 0 ;; # pipeline-system: engine incidents, not feature tickets (597)
    esac
  done
  [[ "$is_feature" == 1 ]] || return 0
  declare -F zf_config_file >/dev/null || { echo 'roadmap: refusing to create issue; zf_config_file is undefined' >&2; return 1; }
  config_file="$(zf_config_file night.json 2>/dev/null || true)"
  [[ -n "$config_file" && -f "$config_file" ]] || return 0
  check_cmd="$(jq -r '.roadmap.body_check_command // ""' "$config_file")" || {
    echo "roadmap: refusing to create issue; $config_file is not readable JSON" >&2
    return 1
  }
  [[ -n "$check_cmd" ]] || return 0
  if ! check_out="$(bash -c "$check_cmd \"\$1\"" roadmap-body-check "$body_file" 2>&1)"; then
    [[ -z "$check_out" ]] || printf '%s\n' "$check_out" >&2
    echo 'roadmap: refusing to create issue; roadmap.body_check_command rejected the ticket body' >&2
    return 1
  fi
}
