queue_run_lander() {
  queue_source_lib || return 1
  coord_lane_run land "${ZF_COORD_LAND_LANE_WAIT_SECONDS:-${MERGE_LOCK_WAIT_SECONDS:-120}}" \
    queue_run_lander_owned "$@"
}

queue_run_lander_owned() {
  local repo="$1" package="$2" output_file="$3" owner_issues
  owner_issues="$(jq -r '.owned_issues // ""' "$request")"
  shift 3
  if (cd -- "$repo" && AGENT_HOME="$AGENT_HOME" ZF_REPO_DIR="$repo" REPO_DIR="$repo" \
      ZF_LAND_RESULT_DIR="${result_dir:-}" \
      ZF_LAND_QUEUE_DIRECT=1 PLAN_PACKAGE="$package" ZF_AGENT_NAME="${ZF_AGENT_NAME:-${owner:-land-queue}}" \
      ZF_AGENT_ISSUES="$owner_issues" \
      ZF_AGENT_REPORT="${ZF_AGENT_REPORT:-${report:-}}" \
      bash "${ZF_ENGINE_LIVE:-$QUEUE_ENGINE_DIR}/land-direct-main.sh" "$@") >> "$output_file" 2>&1; then
    return 0
  else
    return $?
  fi
}
