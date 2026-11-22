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

# release_batch_cadence_mark [batch sha]: called once the batch unit started; the sha starts its outcome row.
release_batch_cadence_mark() {
  guarded_state_write "$RELEASE_BATCH_CADENCE_FILE" "$(date +%s)" \
    || echo "issue-pipeline: could not record the release-batch cadence marker" >&2
  [ -z "${1:-}" ] || ( release_batch_outcome_start "$1" ) || true
}
release_batch_cadence_open() {
  local last
  last="$(cat "$RELEASE_BATCH_CADENCE_FILE" 2>/dev/null || true)"
  [[ "$last" =~ ^[0-9]+$ ]] || return 0
  [ $(( $(date +%s) - last )) -ge 7200 ]
}

# release_batch_hold_active: head's hold file holds an epoch "until" and stops every release batch, fleet
# continuations included. Why: 2026-11-18 the cadence marker held the train 2 h, yet at 00:09Z a fleet
# continuation passed the closed window and started a release anyway.
release_batch_hold_active() {
  local until
  until="$(cat "$RELEASE_BATCH_HOLD_FILE" 2>/dev/null || true)"
  [[ "$until" =~ ^[0-9]+$ ]] && [ "$until" -gt "$(date +%s)" ] || return 1
  echo "issue-pipeline: release hold until $(date -u -d "@$until" +%Y-%m-%dT%H:%M:%SZ) (release-batch-hold); no release batch, fleet continuations included" >&2
  return 0
}

# Same-failure hold (queue 938). Why: 2026-11-21 the production release failed three times on one run-release line,
# and a fourth batch started 2.5 min after the third, on the commit before its fix. Rows of
# $AGENT_HOME/release-batch-outcomes: <start epoch> TAB <batch sha> TAB <pending|failed|ok> TAB <run-release line>.
# release_batch_outcome_replace <file>: stdin becomes <file> through a temp file and mv; a failed write keeps the old file.
release_batch_outcome_replace() {
  local tmp
  tmp="$(mktemp "$1.XXXXXX")" || return 1
  if cat > "$tmp" && mv -f "$tmp" "$1"; then return 0; fi
  rm -f "$tmp"
  return 1
}

# release_batch_outcome_start <batch sha>: a dispatched batch gets a pending row. Dry runs write nothing.
# Runs in a subshell from release_batch_cadence_mark, so no failure here can stop the dispatch.
release_batch_outcome_start() {
  [ -n "${AGENT_HOME:-}" ] && [ "${DRY_RUN:-0}" != 1 ] || return 0
  local file="$AGENT_HOME/release-batch-outcomes"
  mkdir -p "$AGENT_HOME" 2>/dev/null || return 0
  { tail -n 4 "$file" 2>/dev/null || true; printf '%s\t%s\tpending\t\n' "$(date +%s)" "$1"; } \
    | release_batch_outcome_replace "$file" || true
  return 0
}

# release_batch_outcome_settle: a pending last row is final once its batch unit has ended, so its run is read from the
# user journal since its start epoch. With no end line the batch is still running or the journal is unreadable: the
# row stays pending and is read again next time. Always returns 0.
release_batch_outcome_settle() {
  local file="${AGENT_HOME:-}/release-batch-outcomes" start sha result line journal body
  [ -n "${AGENT_HOME:-}" ] && [ -f "$file" ] || return 0
  IFS=$'\t' read -r start sha result line < <(tail -n 1 "$file" 2>/dev/null) || true
  [ "${result:-}" = pending ] || return 0
  [[ "${start:-}" =~ ^[0-9]+$ ]] && [ -n "${sha:-}" ] || return 0
  journal="$(journalctl --user --no-pager -o cat --since "@$start" -u "${UNIT_PREFIX_TRANSIENT:-}-release-batch*" 2>/dev/null \
    | grep -E '^run-release:|Failed with result|Deactivated successfully' || true)"
  line="$(grep '^run-release:' <<< "$journal" | tail -n 1 | cut -c1-120 || true)"
  line="${line//$'\t'/ }"
  if grep -q 'Failed with result' <<< "$journal"; then result=failed
  elif grep -q 'Deactivated successfully' <<< "$journal"; then result=ok
  else return 0; fi
  body="$(sed '$d' "$file" 2>/dev/null)" || return 0
  { [ -z "$body" ] || printf '%s\n' "$body"; printf '%s\t%s\t%s\t%s\n' "$start" "$sha" "$result" "$line"; } \
    | release_batch_outcome_replace "$file" || true
  return 0
}

# release_batch_same_failure_hold <candidate sha> <anchor issue>: exit 0 (hold) when the last two finished batches
# failed on the same run-release line and scripts/release is unchanged since the last failed one. Any unreadable or
# malformed input ends the subshell non-zero, which is "do not hold", so a read error never stops select_release_batch.
# A git error counts as changed. Logs one decision and alerts once per line and candidate.
release_batch_same_failure_hold() {
  (
    candidate="${1:-}"; anchor="${2:-}"
    # Probe: a failure may be fixed outside the repository (2026-11-21 network failures), so after 2 h one batch runs again. Manual lift: delete $AGENT_HOME/release-batch-outcomes.
    probe_after=7200
    re=$'^[0-9]+\t[^\t]+\t(pending|failed|ok)\t'
    [ -n "${AGENT_HOME:-}" ] && [ -n "$candidate" ] || exit 1
    file="$AGENT_HOME/release-batch-outcomes"
    release_batch_outcome_settle || true
    [ -f "$file" ] || exit 1
    rows=()
    mapfile -t rows < <(tail -n 2 "$file" 2>/dev/null)
    [ "${#rows[@]}" -eq 2 ] || exit 1
    [[ "${rows[0]}" =~ $re ]] && [[ "${rows[1]}" =~ $re ]] || exit 1
    IFS=$'\t' read -r _ a_sha a_res a_line <<< "${rows[0]}"
    IFS=$'\t' read -r b_start b_sha b_res b_line <<< "${rows[1]}"
    [ "$a_res" = failed ] && [ "$b_res" = failed ] && [ -n "$b_line" ] && [ "$a_line" = "$b_line" ] || exit 1
    [ $(( $(date +%s) - b_start )) -lt "$probe_after" ] || exit 1
    git -C "${REPO_DIR:-}" diff --quiet "$b_sha" "$candidate" -- scripts/release 2>/dev/null || exit 1
    record_release_decision "$anchor" skipped same-failure "${UNIT_PREFIX_TRANSIENT:-}-release-batch" "error=\"$b_line\" failed=$a_sha,$b_sha candidate=$candidate" || true
    supervisor_inbox_append_once "release-same-failure:$candidate:$b_line" \
      "release batch held: the last two batches failed on the same line ($b_line); candidate $candidate changes nothing under scripts/release; failed batches at $a_sha and $b_sha" || true
    exit 0
  )
}
