# Per-candidate step timing for register_new_issues: intake_mark charges the seconds since the last mark to a named step,
# intake_steps_say logs the pass's `intake detail steps` line. Both use register_new_issues' locals (dynamic scope, like intake_skip).
intake_mark() { intake_step_secs[$1]=$(( ${intake_step_secs[$1]:-0} + SECONDS - intake_step_at )); intake_step_counts[$1]=$(( ${intake_step_counts[$1]:-0} + 1 )); intake_step_at=$SECONDS; }
intake_steps_say() {
  (( ${#intake_step_secs[@]} )) || return 0
  local step_name step_line="${1:-intake detail steps}"
  while IFS= read -r step_name; do step_line+=" $step_name=${intake_step_secs[$step_name]}s/${intake_step_counts[$step_name]}"; done < <(for step_name in "${!intake_step_secs[@]}"; do printf '%s %s\n' "${intake_step_secs[$step_name]}" "$step_name"; done | sort -k1,1nr -k2,2 | cut -d' ' -f2)
  say "$step_line"
}
# Rows intake drops with only a count, or none: skip-label rows in intake_candidates and open-PR mentions in register_new_issues.
# One `intake skip issue #N: reason` per issue and reason, repeated at most every 6h ($A/intake-skip-noted.tsv: "n reason<TAB>epoch").
intake_skip_note() {
  local f="$A/intake-skip-noted.tsv" now; now="$(date +%s)"
  awk -F'\t' -v k="$1 $2" -v now="$now" '$1==k && now-$2<21600{f=1} END{exit !f}' "$f" 2>/dev/null && return 0
  say "intake skip issue #$1: $2"
  { awk -F'\t' -v k="$1 $2" -v now="$now" '$1!=k && now-$2<21600' "$f" 2>/dev/null; printf '%s %s\t%s\n' "$1" "$2" "$now"; } > "$f.tmp.$$" && mv -f -- "$f.tmp.$$" "$f"
}
intake_skip_refused_recut() { intake_skip_note "$1" "unit=$2 stays closed, recut refused and its reopen is spent"; intake_skip recut_refused; }
intake_skip_label_report() { # candidate rows JSON, skip labels JSON
  local n hit
  [[ -s "$1" ]] || return 0
  while IFS=$'\t' read -r n hit; do intake_skip_note "$n" "skip label $hit"; done < <(jqf -r --argjson skip "$2" 'unique_by(.number)[] | ([.labels[].name] | map(select(IN($skip[]))) | join(",")) as $hit | select($hit != "") | "\(.number)\t\($hit)"' "$1")
}
# Open-PR census for the hold check: one `branch:<head>` line and one `body:<line>` per body line, so a body line cannot pose as a branch.
intake_busy_text() { jqf -r '.[] | "branch:\(.headRefName)", ((.body // "") | gsub("\r"; "") | split("\n")[] | "body:" + .)'; }
# Whether an open PR in $busy holds issue $1: its branch is agent/issue-N or agent/auto-issue-N (optionally followed by -<anything>) or the handoff branch $2, or a body line opens with Refs/Fixes/Closes/Resolves #N.
intake_open_pr_holds() {
  local n="$1" br="${2:-}"
  grep -qE "^branch:agent/(auto-)?issue-$n(-.*)?\$" <<<"$busy" && return 0
  [[ -z "$br" ]] || ! grep -qxF "branch:$br" <<<"$busy" || return 0
  grep -qiE "^body:[[:space:]]*(Refs|Fixes|Closes|Resolves)[[:space:]]+#$n([^0-9A-Za-z_]|\$)" <<<"$busy"
}
