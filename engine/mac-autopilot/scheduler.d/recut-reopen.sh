# Stop-loss closes the unit and sends the issue to recut. When recut refuses the split, admission returns the issue to
# ready-for-agent, but the unit stays closed and intake skips it forever. Reopen that one unit, refill its stop-loss
# budget once (a supervisor-requeue history entry resets the round count), and mark it so a second stop-loss stays closed.
intake_reopen_refused_recut() { # issue state-file → 0 when the issue's single closed unit was reopened
  local n="$1" state_file="$2" refused u id
  refused="$(jqf_optional_file "$state_file" -r 'select(.state == "ready-for-agent") | .recut_refused_at // empty' 2>/dev/null)" || return 1
  [[ -n "$refused" ]] || return 1
  u="$(jqf -c --argjson n "$n" --arg refused "$refused" '
    [.units[] | select(.issue == $n or .branch == ("agent/issue-" + ($n | tostring)))] as $us
    | select(($us | length) == 1) | $us[0]
    | select(.stage == "closed" and ((.history // [])[-1] | (.stage | IN("supervisor-budget-recut", "supervisor-cap-triage-recut")) and .at < $refused))' <(units_history_doc))" || return 1
  [[ -n "$u" ]] || return 1
  id="$(jqf -r '.id' <<<"$u")"
  restore_archived_unit "$id" || return 1 # a retired closed unit lives in the archive; bring it back to the hot ledger before set_unit
  if jqf -e '.recut_reopened_at' <<<"$u" >/dev/null; then
    jqf -e '.recut_reopen_refused' <<<"$u" >/dev/null && return 1
    set_unit "$id" '.recut_reopen_refused = true' && say "intake recut-reopen unit=$id issue=#$n: stop-loss budget already refilled once; stays closed"
    return 1
  fi
  set_unit "$id" "$(hist supervisor-requeue "recut refused at $refused; reopened with a refilled stop-loss budget") | .stage = \"implement-pending\" | .recut_reopened_at = \"$STAMP\" | .note = null | del(.blocked_on, .self_fix_pending, .recut_routed)" \
    && say "intake recut-reopen unit=$id issue=#$n: recut refused at $refused; stop-loss budget refilled" \
    && added=$((${added:-0}+1)) && INTAKE_ADDED=$((${INTAKE_ADDED:-0}+1)) # a reopen is admitted work: it consumes want (added is register_new_issues local)
}
# A reopen is new work, but the terminal skip reads only the ledger, so a reopened issue sat ready-for-agent with no worker
# and no log line. An unconsumed episode sends it through the hold handoff, which restores the closed unit next tick.
# An issue that stayed open has no reopen event: its unit closed on purpose and stays closed. The reopen time is fixed, so
# a unit that closes again is newer than it and this cannot loop.
intake_reopen_episode() { # issue reopened-at
  local n="$1" at="$2" units
  [[ -n "$(jqf_optional_file "${AGENT_HOME:-${HOME:-}/.zenoforge}/state/$n.json" -r 'select(.state == "ready-for-agent") | .state' 2>/dev/null)" ]] || return 0
  units="$(jqf -c --argjson n "$n" '[.units[] | select(.issue == $n or .branch == ("agent/issue-" + ($n | tostring)))]
    | {at: (map((.history // [])[-1].at // "") | max), other: (map(select(.stage != "closed") | .stage) | unique | join(","))}' <(units_history_doc))" || return 0
  [[ "$at" > "$(jqf -r '.at // ""' <<<"$units")" ]] || return 0
  if [[ -n "$(jqf -r '.other' <<<"$units")" ]]; then
    say "intake reopened issue #$n at $at: skipped, its units ended $(jqf -r '.other' <<<"$units")"; return 0
  fi
  if (source "$SCHEDULER_AGENT_LIB"; state_merge "$n" ".scheduler_handoff.episode = $(js "reopen-$at")"); then
    say "intake reopened issue #$n at $at: new episode; the hold handoff restores its closed unit"
  else
    say "intake reopened issue #$n at $at: could not record the episode; retry next tick"
  fi
}
intake_reopen_episodes() { # issue... → one read per 20 issues: about 8 rows reach this each tick against a cap of 24 reads
  local -a issues=("$@")
  local start n at q response
  for ((start=0; start<${#issues[@]}; start+=20)); do
    q=""
    for n in "${issues[@]:start:20}"; do
      q+=" i$n: issue(number: $n) { number timelineItems(itemTypes: [REOPENED_EVENT], last: 1) { nodes { ... on ReopenedEvent { createdAt } } } }"
    done
    response="$(intake_gh_read api graphql -F owner='{owner}' -F name='{repo}' -f query="query(\$owner: String!, \$name: String!) { repository(owner: \$owner, name: \$name) {$q} }" 2>/dev/null)" || continue
    while IFS=$'\t' read -r n at; do
      intake_reopen_episode "$n" "$at"
    done < <(jqf -r '.data.repository | to_entries[] | .value | select(.timelineItems.nodes[0].createdAt != null) | "\(.number)\t\(.timelineItems.nodes[0].createdAt)"' <<<"$response")
  done
}
