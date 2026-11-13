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
# A unit still carrying awaiting_release_pending blocks too: retry_awaiting_release would conclude the issue on the old PR.
  units="$(jqf -c --arg kind "$kind" --argjson n "$n" '[.units[] | select(.issue == $n or .branch == ("agent/issue-" + ($n | tostring)))]
    | {at: (map((.history // [])[-1].at // "") | max), other: (map(select((.stage != "closed" and ($kind == "reopen" or (.stage | IN("merged", "landed") | not))) or .awaiting_release_pending != null) | .stage) | unique | join(",")),
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
  # tracker: hold.sh --rule --ready on a tracker parent (vecta#6299) is the same ruling as needs-advisor or needs-triage.
  for n; do
    at="$(jqf_optional_file "${AGENT_HOME:-${HOME:-}/.zenoforge}/state/$n.json" -r --argjson cap "$cap" 'select(.state == "ready-for-agent" and (.state_changed_from | IN("needs-advisor", "needs-triage", "tracker"))
      and .hold == null and (.attempts // 0) < $cap and .external_deliverable.required != true) | .state_changed_at // empty' 2>/dev/null)" || continue
    [[ -z "$at" ]] || intake_reopen_episode "$n" "$at" ruling
  done
}
# An open issue whose units all ended and were closed by a stop-loss recut, with no ruling after them, is a stopped ticket:
# restore it once per unit; a unit that closes again stays closed and counted. A unit closed on purpose (obsolete, pr-closed)
# is not restored. A delivered unit (merged) is not routed anywhere here: no signal says whether its PR did the whole work,
# and triage would conclude it as awaiting-release (triage_merged_pr_for_issue); only a ruling after the delivery restores it.
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
      | {ids: [$us[].id], stages: ($us | map(.stage) | unique | join(",")),
         closed_by_recut: (($us | length) == 1 and $us[0].stage == "closed" and (($us[0].history // []) as $h
           | ([$h | to_entries[] | select(.value.stage | IN("supervisor-budget-recut", "supervisor-cap-triage-recut")) | .key] | max // -1) as $recut
           | $recut >= 0 and all($h[($recut + 1):][]; .stage | IN("supervisor-requeue", "pr-closed", "supervisor-cap-default")))),
         spent: any($us[]; .closed_units_restored_at != null),
         skip: (($row.episode != "" and any($us[]; (.hold_handoff_episode // "") != $row.episode))
           or (($row.from | IN("needs-advisor", "needs-triage")) and $row.at > $at))}' <(units_history_doc))" || continue
    jqf -e '.skip | not' <<<"$units" >/dev/null || continue # a newer ruling or a pending episode already owns this row
    if jqf -e '.closed_by_recut' <<<"$units" >/dev/null; then
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
    else
      # A delivered unit is not routed (triage would conclude on a partial PR) and a unit closed on purpose stays closed, so no
      # label change: the row is named once per 6h instead of sitting silent. closed_units_open_issues still counts it.
      intake_skip_note "$n" "all units terminal ($(jqf -r ".stages" <<<"$units")) and no restore path applies; no worker starts, a ruling is needed (a unit closed by a recut: hold.sh --rule $(jqf -r '.ids[0] // empty' <<<"$units") requeue)"
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

# A guarded recut refusal hands the issue back (run-recut.sh) so the scheduler resumes it from its PR or rescued work. A unit that a
# stop-loss recut closed has spent its rounds, so each handoff resumed it into an immediate recut: 8 passes in 4 hours for issue-1171
# on 2026-11-07. Count the round trip on the unit. The first one resumes with a refilled budget (the work the refusal promised); past
# GUARDED_RECUT_RESUME_MAX the unit goes to the arbiter instead of the next recut. Returns 0 when it ended the cycle (the caller skips the resume).
GUARDED_RECUT_RESUME_MAX="${GUARDED_RECUT_RESUME_MAX:-1}"
intake_guarded_recut_roundtrip() { # unit issue state-file episode
  local id="$1" n="$2" state_file="$3" episode="$4" count
  jqf_optional_file "$state_file" -e '.guarded == true and (.recut_refused_at // "") != ""' >/dev/null 2>&1 || return 1
  jqf -e --arg id "$id" 'any(.units[]; .id == $id and .stage == "closed"
    and ((.history // []) | map(select(.stage != "supervisor-cap-default")) | last | .stage) == "supervisor-budget-recut")' <(units_history_doc) >/dev/null || return 1
  count=$(( $(unit_field "$id" '.guarded_recut_roundtrips // 0') + 1 ))
  if (( count <= GUARDED_RECUT_RESUME_MAX )); then
    set_unit "$id" "$(hist supervisor-requeue "guarded recut refused; resumed with a refilled budget (round trip $count of $GUARDED_RECUT_RESUME_MAX)") | .guarded_recut_roundtrips = $count" || return 1
    say "guarded-recut-roundtrip unit=$id issue=#$n count=$count max=$GUARDED_RECUT_RESUME_MAX: resumed with a refilled budget"
    return 1
  fi
  set_unit "$id" ".guarded_recut_roundtrips = $count | .hold_handoff_episode = $(js "$episode")
    | .hold_handoff_wait_issues = ((.hold_handoff_wait_issues // []) | map(select(. != $n)))
    | if (.hold_handoff_wait_issues | length) == 0 and .hold_handoff_lookup_pending != true then del(.hold_handoff_wait_issues, .hold_handoff_waiting) else . end" || return 1
  to_supervisor "$id" "guarded recut loop: issue #$n was refused by recut and handed back $count times since its stop-loss recut; the scope needs an arbiter ruling, not another resume" \
    'Arbiter rescopes or splits the ticket' 'the guarded recut round-trip bound was reached' \
    "round trip $count of $GUARDED_RECUT_RESUME_MAX allowed; each resume ended in the same stop-loss recut" '["Resume the unit again at the same scope"]'
  say "guarded-recut-loop unit=$id issue=#$n count=$count max=$GUARDED_RECUT_RESUME_MAX: cycle ended, unit sent to the arbiter"
}
