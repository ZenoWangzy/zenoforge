# A size recut that recut refuses (recut_refused_at) comes back ready-for-agent and is resumed, then admission sends it to recut
# again: #6292 looped that way for hours. Count the round trips on the unit, like intake_guarded_recut_roundtrip; past
# SIZE_RECUT_RESUME_MAX the unit goes to the supervisor instead of another resume.
SIZE_RECUT_RESUME_MAX="${SIZE_RECUT_RESUME_MAX:-1}"
size_recut_sizes() { # unit-json → "lines limit" from the latest size-recut entry, or "unknown unknown"
  jqf -r '[(.history // [])[] | select(.stage == "size-recut") | (.result // "")] | last // ""
    | (capture("(?<x>[0-9]+) lines exceed (?<y>[0-9]+)") // {x: "unknown", y: "unknown"}) | "\(.x) \(.y)"' <<<"$1"
}
reconcile_size_recuts() {
  local u id issue state hold_note reconcile_note k i n cursor=0 deadline rt refused sizes estimate waived limit extra row_offset stage unit_note recut_row_filter
  local -a pending=() refreshed=()
  # The budget is checked between units, so a unit already running may finish past it. A stopped walk resumes at its unit next tick, so no unit starves.
  deadline=$((SECONDS + ${SIZE_RECUT_RECONCILE_SECONDS:-300}))
  recut_row_filter='[ (.id|tostring|rtrimstr("\n")), ((.issue // "")|tostring|rtrimstr("\n")), ((.stage // "")|tostring|rtrimstr("\n")), ((.note // "")|tostring|rtrimstr("\n")), tojson ] | map(. + "\u0000") | .[]'
  mapfile -d '' -t pending < <(jqf -j ".units[] | select((.stage==\"blocked-external\" or .stage==\"parked\" or .stage==\"supervisor-review\") and .size_recut_pending==true) | $recut_row_filter" "$UNITS")
  n=$((${#pending[@]} / 5))
  cursor="$(cat "$A/.size-recut-cursor" 2>/dev/null || true)"
  [[ "$cursor" =~ ^[0-9]+$ ]] && (( n > 0 )) && cursor=$((cursor % n)) || cursor=0
  for ((k = 0; k < n; k++)); do
    i=$(((cursor + k) % n))
    row_offset=$((i * 5)); id="${pending[row_offset]}"; issue="${pending[row_offset + 1]}"
    stage="${pending[row_offset + 2]}"; unit_note="${pending[row_offset + 3]}"; u="${pending[row_offset + 4]}"
    scheduler_lock_yield_between_units || return 1
    if [[ "${SCHEDULER_LOCK_YIELDED:-false}" == true ]]; then
      mapfile -d '' -t refreshed < <(jqf -j --arg id "$id" ".units[] | select(.id==\$id and .size_recut_pending==true and (.stage==\"blocked-external\" or .stage==\"parked\" or .stage==\"supervisor-review\")) | $recut_row_filter" "$UNITS")
      (( ${#refreshed[@]} == 5 )) || continue
      issue="${refreshed[1]}"; stage="${refreshed[2]}"; unit_note="${refreshed[3]}"; u="${refreshed[4]}"
    fi
    if (( SECONDS >= deadline )); then
      # shortcut: cursor is a snapshot index; list membership changes can defer one unit a tick; store the unit id if that starves anything
      printf '%s\n' "$i" > "$A/.size-recut-cursor"
      say "size-recut reconcile stopped at ${SECONDS}s: $((n - k)) units left, resumes at unit $i next tick"
      scheduler_lock_yield_between_units || return 1
      return 0
    fi
    state="$(scheduler_issue_state "$issue")" || continue
    if jqf -e '.state == "tracker" or (.state == "released" and (has("recut_children") or .tracker_parent == true)) or (.state == "concluded" and .run.outcome == "duplicate" and .closed_by_pipeline == true)' <<<"$state" >/dev/null; then
      supervisor_close_recut_parent "$id" "issue #$issue became a tracker or a closed duplicate" \
        "unit $id recut completed; parent is a tracker or closed duplicate" || continue
    elif [[ "$stage" == supervisor-review ]]; then
      # The arbiter owns a supervisor-review unit: only the completed recut above may move it here.
      continue
    elif jqf -e '.state == "on-hold" or .hold != null' <<<"$state" >/dev/null; then
      hold_note="issue #$issue recut is on hold"
      if [[ "$unit_note" != "$hold_note" ]]; then
        set_unit "$id" "$(hist size-recut-held "$hold_note") | .stage=\"parked\" | .note=$(js "$hold_note") | $(park_fields on-hold 'the on-hold label lifts')"
      fi
    elif jqf -e '.state == "ready-for-agent"' <<<"$state" >/dev/null; then
      # Refusal, advisor recovery, and release-hold all requeue through the
      # shared issue state machine. Resume the existing unit, not a duplicate.
      rt="$(jqf -r '(.size_recut_roundtrips // 0) + 1' <<<"$u")"
      refused=false; jqf -e 'has("recut_refused_at")' <<<"$state" >/dev/null && refused=true
      if [[ "$refused" == true ]] && (( rt > SIZE_RECUT_RESUME_MAX )); then
        sizes="$(size_recut_sizes "$u")"
        estimate="${sizes% *}"
        waived="$(jqf -r '.size_waiver.max_lines | select(type == "number") // empty' <<<"$u")"
        if [[ "$estimate" =~ ^[0-9]+$ && "$waived" =~ ^[0-9]+$ ]] && (( estimate <= waived )); then
          set_unit "$id" "$(hist size-recut-resumed "issue #$issue returned to implementation under supervisor size waiver ($estimate <= $waived lines)") | .stage=\"implement-pending\" | .note=null | .size_recut_roundtrips=0 | del(.size_recut_pending)"
          say "size-recut-cap unit=$id issue=#$issue: size waiver $waived covers estimate $estimate; resumed and reset round trips"
          continue
        fi
        limit="$(size_admission_limit_for "$u")"
        set_unit "$id" ".size_recut_roundtrips = $rt"
        to_supervisor "$id" "recut refused $rt times; size estimate $estimate > limit $limit" \
          'Stop size-recut loop' "recut refused $rt times" "$estimate lines over $limit" '["Resume the unit again at the same scope"]'
        say "size-recut-cap unit=$id issue=#$issue round trip $rt of $SIZE_RECUT_RESUME_MAX: sent to supervisor, not resumed"
        continue
      fi
      extra=""; [[ "$refused" == true ]] && extra=" | .size_recut_roundtrips = $rt"
      set_unit "$id" "$(hist size-recut-resumed "issue #$issue returned to implementation") | .stage=\"implement-pending\" | .note=null | del(.size_recut_pending)$extra"
    elif jqf -e '.state == "needs-recut" and (has("recut_children") or has("recut_refused_at"))' <<<"$state" >/dev/null; then
      # A label-write failure can leave a completed marker in the active
      # queue, whose prefilter will never dispatch it again. Park until the
      # issue state and label are reconciled; automated unit requeue alone
      # would allow the parent to race its already-created children.
      reconcile_note="issue #$issue needs state/label reconciliation before this unit can resume"
      if ! scheduler_size_recut_active "$issue" && [[ "$unit_note" != "$reconcile_note" ]]; then
        set_unit "$id" "$(hist size-recut-reconcile "issue #$issue has a completed marker but remains needs-recut") | .stage=\"parked\" | .note=$(js "$reconcile_note") | $(park_fields state-reconcile 'the issue state and labels agree')"
        echo "[$STAMP] size-recut issue=#$issue action=parked reason=state-label-reconciliation-required" >> "$A/alerts/events.md"
        say "unit $id parked for issue #$issue recut state/label reconciliation"
      fi
    elif [[ "$stage" == parked && "$unit_note" == "issue #$issue recut is on hold" ]]; then
      # The hold is gone and no branch above claimed the state: size-recut-held lifts on its own.
      set_unit "$id" "$(hist_blocked size-recut-unheld '' size-recut-unhold "issue #$issue hold lifted") | .stage=\"blocked-external\" | .note=null | del(.parked_reason, .unpark_condition)"
      say "unit $id recut hold lifted; back to waiting for issue #$issue recut"
    fi
  done
  rm -f -- "$A/.size-recut-cursor"
  scheduler_lock_yield_between_units || return 1
}
