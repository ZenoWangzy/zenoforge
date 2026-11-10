reconcile_size_recuts() {
  local u id issue state hold_note reconcile_note
  while IFS= read -r u; do
    id="$(jqf -r .id <<<"$u")"; issue="$(jqf -r '.issue // empty' <<<"$u")"
    state="$(scheduler_issue_state "$issue")" || continue
    if jqf -e '.state == "tracker" or (.state == "released" and (has("recut_children") or .tracker_parent == true)) or (.state == "concluded" and .run.outcome == "duplicate" and .closed_by_pipeline == true)' <<<"$state" >/dev/null; then
      supervisor_close_recut_parent "$id" "issue #$issue became a tracker or a closed duplicate" \
        "unit $id recut completed; parent is a tracker or closed duplicate" || continue
    elif [[ "$(jqf -r '.stage // empty' <<<"$u")" == supervisor-review ]]; then
      # The arbiter owns a supervisor-review unit: only the completed recut above may move it here.
      continue
    elif jqf -e '.state == "on-hold" or .hold != null' <<<"$state" >/dev/null; then
      hold_note="issue #$issue recut is on hold"
      if [[ "$(jqf -r '.note // ""' <<<"$u")" != "$hold_note" ]]; then
        set_unit "$id" "$(hist size-recut-held "$hold_note") | .stage=\"parked\" | .note=$(js "$hold_note") | $(park_fields on-hold 'the on-hold label lifts')"
      fi
    elif jqf -e '.state == "ready-for-agent"' <<<"$state" >/dev/null; then
      # Refusal, advisor recovery, and release-hold all requeue through the
      # shared issue state machine. Resume the existing unit, not a duplicate.
      set_unit "$id" "$(hist size-recut-resumed "issue #$issue returned to implementation") | .stage=\"implement-pending\" | .note=null | del(.size_recut_pending)"
    elif jqf -e '.state == "needs-recut" and (has("recut_children") or has("recut_refused_at"))' <<<"$state" >/dev/null; then
      # A label-write failure can leave a completed marker in the active
      # queue, whose prefilter will never dispatch it again. Park until the
      # issue state and label are reconciled; automated unit requeue alone
      # would allow the parent to race its already-created children.
      reconcile_note="issue #$issue needs state/label reconciliation before this unit can resume"
      if ! scheduler_size_recut_active "$issue" && [[ "$(jqf -r '.note // ""' <<<"$u")" != "$reconcile_note" ]]; then
        set_unit "$id" "$(hist size-recut-reconcile "issue #$issue has a completed marker but remains needs-recut") | .stage=\"parked\" | .note=$(js "$reconcile_note") | $(park_fields state-reconcile 'the issue state and labels agree')"
        echo "[$STAMP] size-recut issue=#$issue action=parked reason=state-label-reconciliation-required" >> "$A/alerts/events.md"
        say "unit $id parked for issue #$issue recut state/label reconciliation"
      fi
    elif [[ "$(jqf -r '.stage // empty' <<<"$u")" == parked && "$(jqf -r '.note // ""' <<<"$u")" == "issue #$issue recut is on hold" ]]; then
      # The hold is gone and no branch above claimed the state: size-recut-held lifts on its own.
      set_unit "$id" "$(hist size-recut-unheld "issue #$issue hold lifted") | .stage=\"blocked-external\" | .note=null | del(.parked_reason, .unpark_condition)"
      say "unit $id recut hold lifted; back to waiting for issue #$issue recut"
    fi
  done < <(jqf -c '.units[] | select((.stage=="blocked-external" or .stage=="parked" or .stage=="supervisor-review") and .size_recut_pending==true)' "$UNITS")
}
