# Sourced next to intake.sh (scheduler.sh, and the tests that source intake.sh). Lookup tables and the queued ledger write of register_new_issues:
# they use its locals through dynamic scope, so they only run inside it.
# Per-walk lookup tables over the units view (register_new_issues' locals, dynamic scope): the terminal check and the unit lookup
# ran one jq over the whole ledger per row (1.9 s per row on 2026-11-08). One jq pass fills these; they reload only when the view file changes.
# Tables are used for plain numeric issue/PR keys only; anything else, or an episode the tables cannot hold, takes the per-row jq.
intake_index_load() {
  local view sig rows i=0 issue bkey id stage pr ep
  view="$(intake_units_view)"
  sig="$(stat -c '%i %s %y' -- "$view" 2>/dev/null)" || sig=''
  if [[ -n "$sig" && "$sig" == "$ix_sig" ]]; then (( ix_ok )); return; fi
  ix_sig="$sig"; ix_ok=0; ix_issue=(); ix_branch=(); ix_pr=(); ix_id=(); ix_stage=(); ix_prn=(); ix_ep=()
  rows="$(jqf -r '.units | if any(.[]; ((.hold_handoff_episode, .id) | strings | test("[\n\u001f]"))) then "UNSAFE" else
      (.[] | [(if (.issue | type) == "number" then (.issue | tostring) else "-" end),
        ((.branch | strings | select(test("^agent/issue-(0|[1-9][0-9]*)$")) | ltrimstr("agent/issue-")) // "-"),
        ((.id | strings) // "-"), ((.stage | strings) // "-"),
        ((.pr // "") | tostring | if . == "" then "-" else . end),
        ((.hold_handoff_episode | strings) // "\u0001")] | join("\u001f")) end' "$view")" || { ix_sig=''; return 1; }
  [[ "$rows" != UNSAFE ]] || return 1
  while IFS=$'\037' read -r issue bkey id stage pr ep; do
    [[ -n "$id" ]] || continue # the here-string of no rows is one empty line
    if [[ "$issue" != - ]]; then ix_issue[$issue]+="$i "; fi
    if [[ "$bkey" != - ]]; then ix_branch[$bkey]+="$i "; fi
    if [[ "$pr" == - ]]; then pr=''; else ix_pr[$pr]+="$i "; fi
    ix_id[i]="$id"; ix_stage[i]="$stage"; ix_prn[i]="$pr"; ix_ep[i]="$ep"
    i=$((i + 1))
  done <<<"$rows"
  ix_ok=1
}
intake_row_terminal() { # n episode: every unit of the issue is terminal and, when the row has an episode, has consumed it
  local i list
  if [[ "$1" =~ ^(0|[1-9][0-9]*)$ ]] && intake_index_load; then
    list="${ix_issue[$1]:-} ${ix_branch[$1]:-}"
    [[ -n "${list// /}" ]] || return 1
    for i in $list; do
      case "${ix_stage[i]}" in merged|landed|closed|done|wontfix|duplicate) ;; *) return 1 ;; esac
      [[ -z "$2" || "${ix_ep[i]}" == "$2" ]] || return 1
    done
    return 0
  fi
  jqf -e --argjson n "$1" --arg episode "$2" '
      [.units[] | select(.issue == $n or .branch == ("agent/issue-" + ($n | tostring)))] as $us
      | ($us | length) > 0 and all($us[]; (.stage | IN("merged","landed","closed","done","wontfix","duplicate"))
        and ($episode == "" or .hold_handoff_episode == $episode))' "$(intake_units_view)" >/dev/null 2>&1
}
intake_unit_for_row() { # n handoff_pr: sets existing_id to the unit the row belongs to: PR match first, then live stage, then ledger order. Not in $( ): the tables must outlive the call
  local i best='' bestk=9 k
  existing_id=
  if [[ "$1" =~ ^(0|[1-9][0-9]*)$ && ( -z "$2" || "$2" =~ ^[0-9]+$ ) ]] && intake_index_load; then
    for i in ${ix_issue[$1]:-} ${2:+${ix_pr[$2]:-}}; do
      k=2; [[ -n "$2" && "${ix_prn[i]}" == "$2" ]] && k=0
      case "${ix_stage[i]}" in parked|supervisor-review|blocked-external|done|closed|landed|merged|wontfix|duplicate) k=$((k + 1)) ;; esac
      if (( k < bestk || (k == bestk && i < best) )); then best=$i; bestk=$k; fi
    done
    [[ -z "$best" || "${ix_id[best]}" == - ]] || existing_id="${ix_id[best]}"
    return 0
  fi
  existing_id="$(jqf -r --argjson n "$1" --arg pr "$2" '[.units[] | select(.issue == $n or ($pr != "" and ((.pr // "") | tostring) == $pr))] | sort_by([if ($pr != "" and ((.pr // "") | tostring) == $pr) then 0 else 1 end, if (.stage | IN("parked","supervisor-review","blocked-external","done","closed","landed","merged","wontfix","duplicate")) then 1 else 0 end]) | .[0].id // empty' "$(intake_units_view)")"
}
intake_census_flush() { # the walk's census_partial rows as one ledger update: per row the stale-wait clear, then the add (the same jq the rows ran one by one)
  [[ -n "$census_pairs" ]] || return 0
  if [[ -s "$census_pairs" ]]; then
    units_update --slurpfile pairs "$census_pairs" '.units |= reduce $pairs[] as $p (.;
      map(if ((.hold_handoff_wait_issues // []) | index($p.n)) != null and .issue != $p.n
            and .hold_handoff_lookup_pending != true and ((.pr // null) as $pr | $p.ids | index($pr)) == null
          then (.hold_handoff_wait_issues |= map(select(. != $p.n)))
            | if (.hold_handoff_wait_issues | length) == 0 then del(.hold_handoff_wait_issues, .hold_handoff_waiting) else . end
          else . end)
      | map(if .issue == $p.n or ((.pr // null) as $pr | $p.ids | index($pr)) != null then .hold_handoff_wait_issues = (((.hold_handoff_wait_issues // []) + [$p.n]) | unique) | .hold_handoff_waiting=true else . end))'
  fi
  rm -f -- "$census_pairs"; census_pairs=''
}
