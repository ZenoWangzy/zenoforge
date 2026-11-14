#!/usr/bin/env bash
# Release walk budget. A GitHub outage made the per-issue reads hang the whole
# release train for 34 min, so the walk stops at a deadline and dispatches what it has.

release_walk_now() { date +%s; }

# release_walk_begin <newline-separated issue numbers>: start the walk clock.
release_walk_begin() {
  RELEASE_WALK_START="$(release_walk_now)"
  RELEASE_WALK_BUDGET="${RELEASE_WALK_DEADLINE_SECONDS:-300}"
  RELEASE_WALK_DONE=0
  RELEASE_WALK_TOTAL="$(printf '%s\n' "$1" | sed '/^$/d' | wc -l)"
}

# release_walk_expired: exit 0 once the budget is spent (the caller stops the walk);
# exit 1 and count one walk step otherwise.
release_walk_expired() {
  local now
  now="$(release_walk_now)"
  if (( now - RELEASE_WALK_START < RELEASE_WALK_BUDGET )); then
    RELEASE_WALK_DONE=$((RELEASE_WALK_DONE + 1))
    return 1
  fi
  echo "issue-pipeline: release-walk deadline hit after $RELEASE_WALK_DONE/$RELEASE_WALK_TOTAL issues" >&2
  return 0
}
