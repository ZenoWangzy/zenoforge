#!/usr/bin/env bash
# Read the queue's ownership record without starting a lander or loading lib.sh.
land_queue_owner_ticket() {
  local owner="$1" worktree="$2" report="${3:-}" ticket="${4:-}" requests file
  local -a files=()
  requests="${ZF_LAND_QUEUE_DIR:-${AGENT_HOME:-${H:-${ZF_HOME:-$HOME/.zenoforge}}}/land-queue}/requests"
  if [[ -n "$ticket" ]]; then
    [[ "$ticket" =~ ^[0-9]{20}$ && -r "$requests/$ticket.json" ]] || return 1
    files=("$requests/$ticket.json")
  else
    for file in "$requests"/*.json; do
      [[ -r "$file" ]] && files+=("$file")
    done
  fi
  ((${#files[@]})) || return 1
  jq -ers --arg owner "$owner" --arg wt "$worktree" --arg report "$report" --arg ticket "$ticket" '
    [.[] | select((.state == "queued" or .state == "running"
      or ($report != "" and .state == "landed" and (.landed_sha // "" | test("^[0-9a-f]{40}$"))))
      and (($owner != "" and .owner == $owner and (.owner_worktree // .worktree) == $wt)
        or ($report != "" and .report == $report))
      and ($ticket == "" or .ticket == $ticket)) | .ticket
      | select(type == "string" and test("^[0-9]{20}$"))][0] // empty
  ' "${files[@]}" 2>/dev/null
}
