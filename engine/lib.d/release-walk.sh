#!/usr/bin/env bash
# Release walk budget. A GitHub outage made the per-issue reads hang the whole
# release train for 34 min, so the walk stops at a deadline and dispatches what it has.

release_walk_now() { date +%s; }

# release_walk_begin <newline-separated issue numbers>: start the walk clock and
# fill RELEASE_PR_CACHE with one bulk read of recent merged main PRs, so
# merged_pr_main_row answers without a per-PR read.
release_walk_begin() {
  local merged_rows row
  RELEASE_WALK_START="$(release_walk_now)"
  RELEASE_WALK_BUDGET="${RELEASE_WALK_DEADLINE_SECONDS:-300}"
  RELEASE_WALK_DONE=0
  RELEASE_WALK_TOTAL="$(printf '%s\n' "$1" | sed '/^$/d' | wc -l)"
  RELEASE_PR_CACHE=()
  # shortcut: the map holds only the newest 1000 merged PRs; older tickets fall back to a per-PR read, upgrade if old tickets keep missing.
  merged_rows="$(gh pr list --repo "$REPO" --state merged --base main -L 1000 \
    --json number,mergeCommit,mergedAt 2>/dev/null)" || return 0
  while IFS= read -r row; do
    RELEASE_PR_CACHE["$(jq -r '.number' <<< "$row")"]="$row"
  done < <(jq -c '.[] | select((.mergeCommit.oid // "") != "")
    | {number, merged: true, base: {ref: "main"}, merge_commit_sha: .mergeCommit.oid, merged_at: .mergedAt}' \
    <<< "$merged_rows")
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

# release_cadence_keep_fleet <newline-separated issue numbers>: for a closed cadence window, where only a
# pending Fleet roll can dispatch. Sets RELEASE_FLEET_IDS to the tickets with one (local state, no gh read),
# logs the cadence skip for the rest, and exits 1 when none remain to walk (11-14: three ticks spent
# 313-316 s walking 133/582 tickets that were all cadence skips).
release_cadence_keep_fleet() {
  local n
  RELEASE_FLEET_IDS=""
  while IFS= read -r n; do
    [[ "$n" =~ ^[0-9]+$ ]] || continue
    if [ "$(state_read "$n" | jq -r '.fleet_roll_pending.status // empty')" = pending ]; then
      RELEASE_FLEET_IDS+="$n"$'\n'
    else
      record_release_decision "$n" skipped release-cadence ${UNIT_PREFIX_TRANSIENT}-release-batch "window-not-elapsed"
    fi
  done <<< "$1"
  [ -n "$RELEASE_FLEET_IDS" ]
}
