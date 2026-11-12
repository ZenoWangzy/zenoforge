# Every tick: a ticket closed on GitHub (PR auto-close, manual close) while its
# state file still says ready-for-agent never passes conclude_run. The audit
# helpers in sweeps.sh had no production caller, so 16 such tickets kept an
# intake handoff episode. Cutoff = now takes every local ready-for-agent state.
sweep_closed_ready_states() {
  local cutoff rows row n failure=0
  cutoff="$(date -u +%Y-%m-%dT%H:%M:%SZ)" || return 1
  if ! rows="$(outcomes_closed_state_reconciliation_snapshot "$AGENT_HOME" "$REPO" '[]' "$cutoff")"; then
    echo "sweep_closed_ready_states: could not read closed ready-for-agent issues; retrying next tick" >&2
    return 1
  fi
  while IFS= read -r row; do
    # Past the slice deadline every write is refused; the rest run next tick.
    gh_tick_attempt_timeout_sec >/dev/null 2>&1 || {
      echo "sweep_closed_ready_states: gh deadline reached; the rest run next tick" >&2
      break
    }
    n="$(jq -r '.number' <<< "$row")" || return 1
    if issue_reconcile_closed_state "$n" "$(jq -c '. + {state:"CLOSED"}' <<< "$row")"; then
      echo "sweep_closed_ready_states: reconciled closed ready-for-agent state for #$n" >&2
    else
      echo "sweep_closed_ready_states: could not reconcile closed #$n" >&2
      failure=1
    fi
  done < <(jq -c '.[]' <<< "$rows")
  return "$failure"
}

