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
  set_unit "$id" "$(hist supervisor-requeue "recut refused at $refused; reopened with a refilled stop-loss budget") | .stage = \"implement-pending\" | .recut_reopened_at = \"$STAMP\" | .note = null | del(.blocked_on, .self_fix_pending)" \
    && say "intake recut-reopen unit=$id issue=#$n: recut refused at $refused; stop-loss budget refilled" \
    && added=$((${added:-0}+1)) && INTAKE_ADDED=$((${INTAKE_ADDED:-0}+1)) # a reopen is admitted work: it consumes want (added is register_new_issues local)
}
