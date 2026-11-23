triage_filter_issues_json() {
  local engine_dir
  engine_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
  AGENT_HOME="$AGENT_HOME" REPO_DIR="$REPO_DIR" python3 "$engine_dir/mac-autopilot/triage_split.py" filter <<< "$1" | jq -ce '.eligible | select(type == "array")'
}

triage_needs_queue_selectable_count() {
  local queue_json result
  queue_json="$(timeout 30s gh issue list --repo "$REPO" --limit 1000 --label needs-triage --state open --json number,labels)" || return 1
  jq -e 'type == "array"' <<< "$queue_json" >/dev/null 2>&1 || return 1
  result="$(triage_filter_issues_json "$queue_json")" || return 1
  jq -er 'length' <<< "$result"
}

triage_order_legacy_candidates() {
  jq -r '
    sort_by([
      (if any(.labels[]?; .name == "focus") then 0 else 1 end),
      (if any(.labels[]?; .name == "bug") and any(.labels[]?; .name == "priority:top") then 0 else 1 end),
      (if any(.labels[]?; .name == "founder-test") then 0 else 1 end),
      (if any(.labels[]?; .name == "priority:top") then 0 else 1 end),
      (if any(.labels[]?; .name == "critical-path") then 0 else 1 end),
      (if any(.labels[]?; .name == "legacy") then 1 else 0 end),
      .createdAt
    ])
    | .[].number
  ' <<< "$1"
}
