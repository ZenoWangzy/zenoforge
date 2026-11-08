# Sourced next to intake.sh (scheduler.sh, and the tests that source intake.sh). Lookup tables, the handoff lookups they replace, and the queued ledger
# writes of register_new_issues: they use its locals through dynamic scope, so the table and queue functions only run inside it.
# Per-walk lookup tables over the units view (register_new_issues' locals, dynamic scope): the terminal check and the unit lookup
# ran one jq over the whole ledger per row (1.9 s per row on 2026-11-08). One jq pass fills these; they reload only when the view file changes.
# Tables are used for plain numeric issue/PR keys only; anything else, or an episode the tables cannot hold, takes the per-row jq.
intake_index_load() {
  local view sig rows i=0 issue bkey id stage pr ep prnum iany refd
  view="$(intake_units_view)"
  sig="$(stat -c '%i %s %y' -- "$view" 2>/dev/null)" || sig=''
  if [[ -n "$sig" && "$sig" == "$ix_sig" ]]; then (( ix_ok )); return; fi
  ix_sig="$sig"; ix_ok=0; ix_issue=(); ix_branch=(); ix_pr=(); ix_id=(); ix_stage=(); ix_prn=(); ix_ep=(); ix_prnum=(); ix_iany=(); ix_ref=()
  rows="$(jqf -r '.units | if any(.[]; ((.hold_handoff_episode | strings | test("[\n\u001f]")) or (.id | strings | test("[][\\\\\"$`[:space:]\u0001-\u001f]")))) then "UNSAFE" else
      (.[] | [(if (.issue | type) == "number" then (.issue | tostring) else "-" end),
        ((.branch | strings | select(test("^agent/issue-(0|[1-9][0-9]*)$")) | ltrimstr("agent/issue-")) // "-"),
        ((.id | strings) // "-"), ((.stage | strings) // "-"),
        ((.pr // "") | tostring | if . == "" then "-" else . end),
        ((.hold_handoff_episode | strings) // "\u0001"),
        (if (.pr | type) == "number" then "1" else "0" end), (if .issue == null then "\u0002" else (.issue | tostring) end),
        (if .stage == "closed" and .recut_reopen_refused == true then "1" else "0" end)] | join("\u001f")) end' "$view")" || { ix_sig=''; return 1; }
  [[ "$rows" != UNSAFE ]] || return 1
  while IFS=$'\037' read -r issue bkey id stage pr ep prnum iany refd; do
    [[ -n "$id" ]] || continue # the here-string of no rows is one empty line
    if [[ "$issue" != - ]]; then ix_issue[$issue]+="$i "; fi
    if [[ "$bkey" != - ]]; then ix_branch[$bkey]+="$i "; fi
    if [[ "$pr" == - ]]; then pr=''; else ix_pr[$pr]+="$i "; fi
    ix_id[i]="$id"; ix_stage[i]="$stage"; ix_prn[i]="$pr"; ix_ep[i]="$ep"; ix_prnum[i]="$prnum"; ix_iany[i]="$iany"
    if [[ "$refd" == 1 ]]; then ix_ref[$id]=1; fi
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
declare -gA INTAKE_EXISTING_WALKED=() # rows the existing-only walk took through the handoff block this tick (cleared when that walk starts)
intake_census_load() { # the open-PR census as lookup tables (same lifecycle as the units tables: reload when the census text changes)
  local src="${HANDOFF_PR_CENSUS:-[]}" rows i=0 num hot amb issues head entry entryf id
  if [[ "$src" == "$cx_src" ]]; then (( cx_ok )); return; fi
  cx_src="$src"; cx_ok=0; cx_issue=(); cx_has=(); cx_hotnum=(); cx_bynum=(); cx_num=(); cx_amb=(); cx_hotf=(); cx_head=(); cx_ent=(); cx_entf=()
  rows="$(jqf -r 'if any(.[]; (.headRefName | tostring | test("[\n\u001f]"))) then "UNSAFE" else .[] | . as $p
      | [($p.body // "") | match("(?i)\\b(?:fix(?:es)?|closes|resolves)[[:space:]:]+#(?<id>[0-9]+)"; "g") | .captures[0].string] as $fixes
      | [($p.body // "") | match("(?im)^[[:space:]]*[-*]?[[:space:]]*refs[[:space:]:]+#(?<id>[0-9]+)"; "g") | .captures[0].string] as $refs
      | (if ($fixes | length) > 0 then $fixes else $refs end) as $claims
      | ([($p.headRefName // "") | capture("^agent/issue-(?<id>[0-9]+)$").id] + $claims | unique) as $issues
      | any($p.labels[]; .name == "hotfix") as $hot
      | [($p.number | tostring), (if $hot then "1" else "0" end), (if ($issues | length) > 1 then "1" else "0" end), ($issues | join(" ")),
         ($p.headRefName | if type == "string" then . else tojson end),
         ({number: $p.number, headRefName: $p.headRefName, ambiguousIssues: (($issues | length) > 1), hotfix: $hot} | tojson),
         ({number: $p.number, headRefName: $p.headRefName, ambiguousIssues: false, hotfix: $hot} | tojson)] | join("\u001f") end' <<<"$src")" || { cx_src=$'\001'; return 1; }
  [[ "$rows" != UNSAFE ]] || return 1
  while IFS=$'\037' read -r num hot amb issues head entry entryf; do
    [[ -n "$num" ]] || continue
    for id in $issues; do cx_issue[$id]+="$i "; done
    cx_has[$num]=1; cx_bynum[$num]+="$i "
    if [[ "$hot" == 1 ]]; then cx_hotnum[$num]=1; fi
    cx_num[i]="$num"; cx_hotf[i]="$hot"; cx_amb[i]="$amb"; cx_head[i]="$head"; cx_ent[i]="$entry"; cx_entf[i]="$entryf"
    i=$((i + 1))
  done <<<"$rows"
  cx_ok=1
}
intake_pr_in_census() { # pr number: the census holds a PR with this number
  if [[ "$1" =~ ^(0|[1-9][0-9]*)$ ]] && intake_census_load; then [[ -n "${cx_has[$1]:-}" ]]; return; fi
  jqf -e --argjson pr "$1" 'any(.[]; .number == $pr)' <<<"${HANDOFF_PR_CENSUS:-[]}" >/dev/null
}
intake_known_prs() { # n handoff_pr: sets known_prs (JSON) and known_list: numeric PRs of the issue's units plus the recorded handoff PR. 1 = tables unusable
  local i; local -a nums=()
  [[ "$1" =~ ^(0|[1-9][0-9]*)$ && ( "$2" != *[!0-9]* ) && ${#2} -lt 16 ]] && intake_index_load || return 1
  for i in ${ix_issue[$1]:-} ${ix_branch[$1]:-}; do
    if [[ "${ix_prnum[i]}" == 1 ]]; then nums+=("${ix_prn[i]}"); fi
  done
  if [[ -n "$2" ]]; then nums+=("$((10#$2))"); fi
  known_list=()
  if (( ${#nums[@]} )); then mapfile -t known_list < <(printf '%s\n' "${nums[@]}" | sort -nu); fi
  known_prs="[$(IFS=,; printf '%s' "${known_list[*]}")]"
}
intake_units_other_episode() { # n episode: some unit of the issue holds another episode than this one
  local i
  for i in ${ix_issue[$1]:-} ${ix_branch[$1]:-}; do
    [[ "${ix_ep[i]}" == "$2" ]] || return 0
  done
  return 1
}
intake_lookup_fast() { # n handoff_pr: handoff_open_pr, the handoff PR's census row, and the hotfix test from the tables. 0 = done, 1 = no census (handoff_open_pr would fail), 2 = tables unusable
  local n="$1" hp="$2" i u j keep found num pr
  local -a ent=() nums=() heads=() hf=()
  [[ -n "${HANDOFF_PR_CENSUS:-}" ]] || return 1
  [[ "$n" =~ ^(0|[1-9][0-9]*)$ && ( -z "$hp" || "$hp" =~ ^(0|[1-9][0-9]*)$ ) ]] && intake_index_load && intake_census_load || return 2
  l_amb=0; l_hot=0
  for i in ${cx_issue[$n]:-}; do
    keep=1
    if [[ "${cx_amb[i]}" != 1 ]]; then
      for u in ${ix_pr[${cx_num[i]}]:-}; do
        if [[ "${ix_prnum[u]}" == 1 && "${ix_iany[u]}" != $'\002' && "${ix_iany[u]}" != "$n" ]]; then keep=0; break; fi
      done
    fi
    (( keep )) || continue
    ent+=("${cx_ent[i]}"); nums+=("${cx_num[i]}"); heads+=("${cx_head[i]}")
    if [[ "${cx_amb[i]}" == 1 ]]; then l_amb=1; fi
    if [[ "${cx_hotf[i]}" == 1 ]]; then l_hot=1; fi
  done
  if [[ -n "$hp" ]]; then
    found=0; for num in "${nums[@]}"; do [[ "$num" != "$hp" ]] || found=1; done
    if (( ! found )); then
      for j in ${cx_bynum[$hp]:-}; do
        ent+=("${cx_entf[j]}"); nums+=("$hp"); heads+=("${cx_head[j]}")
        if [[ "${cx_hotf[j]}" == 1 ]]; then l_hot=1; fi
      done
    fi
  fi
  for pr in "${known_list[@]}"; do
    if [[ -n "${cx_hotnum[$pr]:-}" ]]; then hf+=("$pr"); fi
  done
  lookup="[$(IFS=,; printf '%s' "${ent[*]}")]"
  hotfix_prs="[$(IFS=,; printf '%s' "${hf[*]}")]"
  l_count=${#ent[@]}; l_first_pr="${nums[0]:-}"; l_first_head="${heads[0]:-}"
  if (( ${#nums[@]} )); then l_ids="[$(printf '%s\n' "${nums[@]}" | sort -nu | paste -sd, -)]"; else l_ids='[]'; fi
  l_hotpath=0; if (( l_hot || ${#hf[@]} )); then l_hotpath=1; fi
  return 0
}
intake_row_units() { # n handoff_pr episode: sets ids (the row's unit ids, ledger order) and row_consumed (every one holds this episode and the recorded PR is in the ledger). 1 = tables unusable
  local i; local -A seen=(); local -a order=()
  [[ "$1" =~ ^(0|[1-9][0-9]*)$ && ( -z "$2" || "$2" =~ ^[0-9]+$ ) ]] && intake_index_load || return 1
  for i in ${ix_issue[$1]:-} ${2:+${ix_pr[$2]:-}}; do
    if [[ -z "${seen[$i]:-}" ]]; then seen[$i]=1; order+=("$i"); fi
  done
  if (( ${#order[@]} )); then mapfile -t order < <(printf '%s\n' "${order[@]}" | sort -n); fi
  row_consumed=1; ids='['
  for i in "${order[@]}"; do
    [[ "$ids" == '[' ]] || ids+=','
    ids+="\"${ix_id[i]}\""
    [[ "${ix_ep[i]}" == "$3" ]] || row_consumed=0
  done
  ids+=']'
  if [[ -n "$2" && -z "${ix_pr[$2]:-}" ]]; then row_consumed=0; fi
}
intake_recut_refused() { # unit id: a closed unit whose recut was refused and whose reopen is spent
  if intake_index_load; then [[ -n "${ix_ref[$1]:-}" ]]; return; fi
  jqf -e --arg id "$1" 'any(.units[]; .id == $id and .stage == "closed" and .recut_reopen_refused == true)' "$(intake_units_view)" >/dev/null
}
intake_op() { # append one wait-mark operation (a JSON line) to the walk's queue
  [[ -n "$wait_ops" ]] || wait_ops="$A/.intake-wait-ops.$BASHPID.$RANDOM"
  printf '%s\n' "$1" >> "$wait_ops"
}
intake_ops_flush() { # the queued wait-mark operations as one ledger update, applied in order with the same jq each row ran one by one
  [[ -n "$wait_ops" ]] || return 0
  if [[ -s "$wait_ops" ]]; then
    units_update --slurpfile ops "$wait_ops" '
      def addw($n): .hold_handoff_wait_issues = (((.hold_handoff_wait_issues // []) + [$n]) | unique) | .hold_handoff_waiting = true;
      .units |= reduce $ops[] as $o (.;
        if $o.k == "ep" then map(if (.issue == $o.n or .branch == ("agent/issue-" + ($o.n | tostring))) and .hold_handoff_episode != $o.episode then addw($o.n) else . end)
        elif $o.k == "wb" then map(if .issue == $o.n or .branch == ("agent/issue-" + ($o.n | tostring)) or ((.pr // null) as $pr | $o.prs | index($pr)) != null then addw($o.n) else . end)
        elif $o.k == "lp1" then map(if .pr == $o.pr then .hold_handoff_lookup_pending = true | .hold_handoff_waiting = true else . end)
        elif $o.k == "lp0" then map(if .pr == $o.pr then del(.hold_handoff_lookup_pending) | if ((.hold_handoff_wait_issues // []) | length) == 0 then del(.hold_handoff_waiting) else . end else . end)
        elif $o.k == "wa" then map(if .issue == $o.n or ((.pr // null) as $pr | $o.prs | index($pr)) != null then addw($o.n) else . end)
        elif $o.k == "clr" then map(
          if ((.hold_handoff_wait_issues // []) | index($o.n)) != null and .issue != $o.n
            and .hold_handoff_lookup_pending != true and ((.pr // null) as $pr | $o.prs | index($pr)) == null
          then (.hold_handoff_wait_issues |= map(select(. != $o.n)))
            | if (.hold_handoff_wait_issues | length) == 0 then del(.hold_handoff_wait_issues, .hold_handoff_waiting) else . end
          else . end)
        else map(if (.id as $id | $o.ids | index($id)) != null then .hold_handoff_wait_issues = ((.hold_handoff_wait_issues // []) | map(select(. != $o.n)))
          | if (.hold_handoff_wait_issues | length) == 0 and .hold_handoff_lookup_pending != true then del(.hold_handoff_wait_issues, .hold_handoff_waiting) else . end else . end)
        end)'
  fi
  rm -f -- "$wait_ops"; wait_ops=''
}
existing_handoff_candidates() {
  local state_dir="${AGENT_HOME:-${HOME:-}/.zenoforge}/state" file read_status
  local files=( "$state_dir"/*.json )
  [[ -e "${files[0]}" || -L "${files[0]}" ]] || return 0
  # One process per state file cost 20.5 s per tick on 1,034 files (2026-11-07 replay) and only 69 name a handoff.
  # A valid file without the key cannot select, so grep names the candidates; any file jq cannot parse keeps the per-file path (jqf logs it).
  if jq empty "${files[@]}" >/dev/null 2>&1; then
    mapfile -t files < <(grep -l -- '"scheduler_handoff"' "${files[@]}" 2>/dev/null)
  fi
  for file in "${files[@]}"; do
    if jqf_optional_file "$file" -r '
      select(.state == "ready-for-agent" and (.scheduler_handoff.episode // "") != "")
      | (input_filename | capture("(?<n>[0-9]+)\\.json$").n | tonumber) as $n
      | [$n, "pr", "handoff", "[]"] | @tsv
    ' 2>/dev/null; then
      :
    else
      read_status=$?
      (( read_status == 64 )) || return "$read_status"
    fi
  done
}
handoff_open_pr() { # issue → matching PR rows from this tick's single census
  local n="$1"
  [[ -n "${HANDOFF_PR_CENSUS:-}" ]] || return 1
  jqf -c --slurpfile u "$(intake_units_view)" --arg n "$n" '
    [.[] | . as $p
      | [($p.body // "") | match("(?i)\\b(?:fix(?:es)?|closes|resolves)[[:space:]:]+#(?<id>[0-9]+)"; "g") | .captures[0].string] as $fixes
      | [($p.body // "") | match("(?im)^[[:space:]]*[-*]?[[:space:]]*refs[[:space:]:]+#(?<id>[0-9]+)"; "g") | .captures[0].string] as $refs
      | (if ($fixes | length) > 0 then $fixes else $refs end) as $claims
      | ([($p.headRefName // "") | capture("^agent/issue-(?<id>[0-9]+)$").id] + $claims | unique) as $issues
      | select(($issues | index($n)) != null)
      | $p + {ambiguousIssues: (($issues | length) > 1)}]
    | map(. as $p | select($p.ambiguousIssues or (any($u[0].units[]; .pr == $p.number and .issue != null and (.issue | tostring) != $n) | not)))
    | map({number,headRefName,ambiguousIssues,hotfix:any(.labels[]; .name == "hotfix")})
  ' <<<"${HANDOFF_PR_CENSUS:-[]}"
}
handoff_include_pr() { # fallback after a failed census: inspect only a known PR
  local pr_number="$1" row
  row="$(intake_gh_read pr view "$pr_number" --json number,headRefName,title,body,state,labels 2>/dev/null)" || row=""
  if ! jqf -e --argjson pr "$pr_number" 'type=="object" and .number==$pr and (.headRefName|type)=="string" and (.state | IN("OPEN","CLOSED","MERGED")) and (.labels | type)=="array" and all(.labels[]; (.name | type)=="string")' <<<"$row" >/dev/null; then
    if [[ "${wait_ops_on:-}" == 1 ]]; then intake_op "$(printf '{"k":"lp1","pr":%s}' "$pr_number")" # inside a walk: a queued mark, applied in order
    else units_update --argjson pr "$pr_number" '.units |= map(if .pr == $pr then .hold_handoff_lookup_pending=true | .hold_handoff_waiting=true else . end)'; fi
    return 1
  fi
  if [[ "${wait_ops_on:-}" == 1 ]]; then intake_op "$(printf '{"k":"lp0","pr":%s}' "$pr_number")"
  else units_update --argjson pr "$pr_number" '.units |= map(if .pr == $pr then del(.hold_handoff_lookup_pending) | if ((.hold_handoff_wait_issues // []) | length) == 0 then del(.hold_handoff_waiting) else . end else . end)'; fi
  if jqf -e '.state == "OPEN"' <<<"$row" >/dev/null; then
    HANDOFF_PR_CENSUS="$(jqf -c --slurpfile row <(printf '%s' "$row") '. + [$row[0]]' <<<"${HANDOFF_PR_CENSUS:-[]}")"
  fi
}
