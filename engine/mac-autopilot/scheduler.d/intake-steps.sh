# Per-candidate step timing for register_new_issues: intake_mark charges the seconds since the last mark to a named step,
# intake_steps_say logs the pass's `intake detail steps` line. Both use register_new_issues' locals (dynamic scope, like intake_skip).
intake_mark() { intake_step_secs[$1]=$(( ${intake_step_secs[$1]:-0} + SECONDS - intake_step_at )); intake_step_counts[$1]=$(( ${intake_step_counts[$1]:-0} + 1 )); intake_step_at=$SECONDS; }
intake_steps_say() {
  (( ${#intake_step_secs[@]} )) || return 0
  local step_name step_line="${1:-intake detail steps}"
  while IFS= read -r step_name; do step_line+=" $step_name=${intake_step_secs[$step_name]}s/${intake_step_counts[$step_name]}"; done < <(for step_name in "${!intake_step_secs[@]}"; do printf '%s %s\n' "${intake_step_secs[$step_name]}" "$step_name"; done | sort -k1,1nr -k2,2 | cut -d' ' -f2)
  say "$step_line"
}
