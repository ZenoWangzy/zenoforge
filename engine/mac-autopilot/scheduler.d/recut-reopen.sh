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
    | select(.stage == "closed" and ((.history // []) | map(select(.stage != "supervisor-cap-default")) | last | (.stage | IN("supervisor-budget-recut", "supervisor-cap-triage-recut")) and .at < $refused))' <(units_history_doc))" || return 1
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
intake_reopen_episode() { # issue reopened-at [ruling]
  local n="$1" at="$2" kind="${3:-reopen}" word=reopened units
  [[ "$kind" == reopen ]] || word=ruling
  [[ -n "$(jqf_optional_file "${AGENT_HOME:-${HOME:-}/.zenoforge}/state/$n.json" -r 'select(.state == "ready-for-agent") | .state' 2>/dev/null)" ]] || return 0
  # A ruling after the delivery says more remains, so merged/landed units do not block it; a reopen event alone still does.
  units="$(jqf -c --arg kind "$kind" --argjson n "$n" '[.units[] | select(.issue == $n or .branch == ("agent/issue-" + ($n | tostring)))]
    | {at: (map((.history // [])[-1].at // "") | max), other: (map(select(.stage != "closed" and ($kind == "reopen" or (.stage | IN("merged", "landed") | not))) | .stage) | unique | join(",")),
       sized: any(.[]; ((.hold_handoff_episode // "") | startswith("ruling-")) and ((.history // []) as $h
         | ([$h | to_entries[] | select(.value.stage == "hold-handoff") | .key] | max // -1) as $i
         | any($h[($i + 1):][]; .stage == "size-recut" or ((.result // "") | tostring | contains("size admission")))))}' <(units_history_doc))" || return 0
  [[ "$at" > "$(jqf -r '.at // ""' <<<"$units")" ]] || return 0
  if [[ -n "$(jqf -r '.other' <<<"$units")" ]]; then
    say "intake $word issue #$n at $at: skipped, its units ended $(jqf -r '.other' <<<"$units")"; return 0
  fi
  if [[ "$kind" == ruling ]] && jqf -e '.sized' <<<"$units" >/dev/null; then
    say "intake ruling issue #$n at $at: not restored, its last ruling restore failed size admission"; return 0
  fi
  if (source "$SCHEDULER_AGENT_LIB"; state_merge "$n" ".scheduler_handoff.episode = $(js "$kind-$at")"); then
    say "intake $word issue #$n at $at: new episode; the hold handoff restores its closed unit"
  else
    say "intake $word issue #$n at $at: could not record the episode; retry next tick"
  fi
}
# An advisor ruling sends an open issue back to ready-for-agent with no reopen event, and terminal skip kept it from any
# worker. The state change is fixed, so a unit that closes again is newer than it: one restore per ruling. A later ruling
# after a size failure would loop advisor, restore, size failure, so it stays closed and closed_units_open_issues names it.
# Work outside this repository has no worker: external_deliverable routes it to the supervisor.
# A triage verdict after the last unit ended is the same kind of ruling: intake_closed_unit_rows asks triage about a delivered
# issue, and triage answers awaiting-release only for a PR verified merged into main (triage_merged_pr_for_issue, run-triage.sh).
# A held issue (.hold) and an issue at CONCLUDE_RUN_ATTEMPT_CAP are not restored: the hold mechanism is the exclusion, there is no list.
intake_attempt_cap() { # → CONCLUDE_RUN_ATTEMPT_CAP read from lib.sh; empty when unreadable, so callers leave the row alone
  ( REPO_DIR="$ROOT"; source "$SCHEDULER_AGENT_LIB" >/dev/null 2>&1 && printf '%s' "${CONCLUDE_RUN_ATTEMPT_CAP:-}" )
}
intake_ruling_episodes() { # issue...
  local n at cap
  cap="$(intake_attempt_cap)"; [[ "$cap" =~ ^[0-9]+$ ]] || return 0
  for n; do
    at="$(jqf_optional_file "${AGENT_HOME:-${HOME:-}/.zenoforge}/state/$n.json" -r --argjson cap "$cap" 'select(.state == "ready-for-agent" and (.state_changed_from | IN("needs-advisor", "needs-triage"))
      and .hold == null and (.attempts // 0) < $cap and .external_deliverable.required != true) | .state_changed_at // empty' 2>/dev/null)" || continue
    [[ -z "$at" ]] || intake_reopen_episode "$n" "$at" ruling
  done
}
# An open issue whose units all ended, with no ruling after them, is a stopped ticket. Delivered (a merged unit): ask triage,
# which decides awaiting-release (verified merged PR) or sends it on, and the ruling path above then restores it as the next
# slice. Never closed here. Closed by a stop-loss recut and not delivered: restore once per unit; a unit that closes again
# stays closed and counted. A unit closed on purpose (obsolete, pr-closed) is not restored.
intake_closed_unit_rows() { # issue...
  local n row units cap id
  cap="$(intake_attempt_cap)"; [[ "$cap" =~ ^[0-9]+$ ]] || return 0
  for n; do
    row="$(jqf_optional_file "${AGENT_HOME:-${HOME:-}/.zenoforge}/state/$n.json" -c --argjson cap "$cap" 'select(.state == "ready-for-agent" and .hold == null
      and (.attempts // 0) < $cap and .external_deliverable.required != true)
      | {at: (.state_changed_at // ""), from: (.state_changed_from // ""), episode: (.scheduler_handoff.episode // "")}' 2>/dev/null)" || continue
    [[ -n "$row" ]] || continue
    units="$(jqf -c --argjson n "$n" --argjson row "$row" '[.units[] | select(.issue == $n or .branch == ("agent/issue-" + ($n | tostring)))] as $us
      | (($us | map((.history // [])[-1].at // "") | max) // "") as $at
      | {merged: any($us[]; .stage | IN("merged", "landed")), ids: [$us[].id],
         closed_by_recut: (($us | length) == 1 and $us[0].stage == "closed" and ((($us[0].history // []) | map(select(.stage != "supervisor-cap-default")) | last | .stage) | IN("supervisor-budget-recut", "supervisor-cap-triage-recut"))),
         spent: any($us[]; .closed_units_restored_at != null),
         skip: (($row.episode != "" and any($us[]; (.hold_handoff_episode // "") != $row.episode))
           or (($row.from | IN("needs-advisor", "needs-triage")) and $row.at > $at))}' <(units_history_doc))" || continue
    jqf -e '.skip | not' <<<"$units" >/dev/null || continue # a newer ruling or a pending episode already owns this row
    if jqf -e '.merged' <<<"$units" >/dev/null; then
      if scheduler_issue_transition "$n" needs-triage "closed-units:delivered" . 0; then
        say "intake closed-units issue #$n: unit delivered, issue still open; routed to triage (awaiting-release needs a verified merged PR)"
      else
        say "intake closed-units issue #$n: could not route to triage; retry next tick"
      fi
    elif jqf -e '.closed_by_recut' <<<"$units" >/dev/null; then
      id="$(jqf -r '.ids[0]' <<<"$units")"
      restore_archived_unit "$id" || continue
      if jqf -e '.spent' <<<"$units" >/dev/null; then
        [[ "$(unit_field "$id" '.closed_units_restore_refused // empty')" == true ]] \
          || { set_unit "$id" '.closed_units_restore_refused = true' && say "intake closed-units unit=$id issue=#$n: already restored once; stays closed"; }
        continue
      fi
      intake_reopen_episode "$n" "$STAMP" ruling
      [[ "$(jqf_optional_file "${AGENT_HOME:-${HOME:-}/.zenoforge}/state/$n.json" -r '.scheduler_handoff.episode // empty')" == "ruling-$STAMP" ]] \
        && set_unit "$id" ".closed_units_restored_at = $(js "$STAMP")"
    fi
  done
  return 0
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
