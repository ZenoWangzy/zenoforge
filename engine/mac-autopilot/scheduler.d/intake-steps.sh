intake_parent_retry_escalate() { # issue, attempt -> one session-visible alert per retry episode
  local n="$1" attempt="$2" already stamp alerts="$AGENT_HOME/logs/head-watch.alerts"
  already="$(jqf -r --arg n "$n" '.intake_parent_retry[$n].escalated // false' "$UNITS")" || return 1
  [[ "$already" != true ]] || return 0
  mkdir -p "${alerts%/*}" || return 1
  stamp="${STAMP:-$(date -u +%Y-%m-%dT%H:%M:%SZ)}"
  printf '%s INTAKE-PARENT-LABEL-FAILED issue=#%s attempts=%s retry=backoff\n' "$stamp" "$n" "$attempt" >> "$alerts" || return 1
  units_update --arg n "$n" '.intake_parent_retry[$n].escalated = true'
}
intake_parent_retry_recorded() {
  jqf -e --arg n "$1" '(.intake_parent_retry // {}) | has($n)' "$UNITS" >/dev/null 2>&1
}
# Idle capacity with no eligible issue goes to head-watch.alerts once an hour, with the stage of each candidate's unit (what blocks the slots).
intake_idle_alert() { # live pending
  local alerts="$AGENT_HOME/logs/head-watch.alerts" cand stages
  mkdir -p "${alerts%/*}" || return 1
  grep -F "${STAMP:0:13}" "$alerts" 2>/dev/null | grep -Fq "IDLE-CAPACITY " && return 0
  cand='[]'; [[ ! -s "$A/intake-candidates.json" ]] || cand="$(jqf -c '[.rows | split("\n")[] | split("\t")[0] | tonumber?]' "$A/intake-candidates.json")" || cand='[]'
  stages="$(jqf -r --argjson c "${cand:-[]}" '[.units[] | select(.issue as $i | any($c[]; . == $i)) | .stage] | group_by(.) | sort_by(-length) | map("\(.[0])=\(length)") | join(" ")' "$UNITS" 2>/dev/null)"
  printf '%s IDLE-CAPACITY live=%s/%s pending=%s: intake found no eligible issue (labels or skip labels too narrow?) stages: %s\n' "$STAMP" "$1" "$MAX" "$2" "${stages:-none}" >> "$alerts"
}
# Per-candidate step timing for register_new_issues: intake_mark charges the seconds since the last mark to a named step,
# intake_steps_say logs the pass's `intake detail steps` line. Both use register_new_issues' locals (dynamic scope, like intake_skip).
intake_mark() { intake_step_secs[$1]=$(( ${intake_step_secs[$1]:-0} + SECONDS - intake_step_at )); intake_step_counts[$1]=$(( ${intake_step_counts[$1]:-0} + 1 )); intake_step_at=$SECONDS; }
intake_steps_say() {
  (( ${#intake_step_secs[@]} )) || return 0
  local step_name step_line="${1:-intake detail steps}"
  while IFS= read -r step_name; do step_line+=" $step_name=${intake_step_secs[$step_name]}s/${intake_step_counts[$step_name]}"; done < <(for step_name in "${!intake_step_secs[@]}"; do printf '%s %s\n' "${intake_step_secs[$step_name]}" "$step_name"; done | sort -k1,1nr -k2,2 | cut -d' ' -f2)
  say "$step_line"
}
issue_skip_labels() {
  jqf -cn --arg hotfix "$(hotfix_lane_label)" \
    '["on-hold","needs-info","awaiting-release","ready-for-human","needs-owner","needs-advisor","needs-triage","roadmap-epic","roadmap-theme","roadmap","concluded","needs-recut","checks-blocked","awaiting-pipeline-sync","hotfix","opt-lane","session-owned",$hotfix] | unique'
}
# A parent verdict also reads other issues (sub-issues, blockers), whose change need not move this issue's updatedAt,
# so a cached verdict lives at most INTAKE_SKIP_CACHE_TTL seconds (default 1 h) and is then read again.
intake_skip_cache_load() {
  local n updated_at verdict stamped now ttl="${INTAKE_SKIP_CACHE_TTL:-3600}"
  now="$(date +%s)"
  while IFS=$'\t' read -r n updated_at verdict stamped; do
    [[ "$n" =~ ^[0-9]+$ && -n "$updated_at" && "$stamped" =~ ^[0-9]+$ ]] || continue
    (( now >= stamped && now - stamped < ttl )) || continue
    case "$verdict" in parent|author_hold|m5|task) ;; *) continue ;; esac
    intake_skip_cache_at["$n"]="$updated_at"; intake_skip_cache_verdict["$n"]="$verdict"; intake_skip_cache_stamp["$n"]="$stamped"
  done < <(jqf_optional_file "$A/intake-candidates.json" -r '
    if .schema == 5 and (.skipped | type == "object") then
      .skipped | to_entries[] | [.key, .value.updated_at // "", .value.verdict // "", (.value.at // "" | tostring)] | @tsv
    else empty end' 2>/dev/null || true)
}
intake_skip_cache_hit() {
  local n="$1" updated_at="$2" verdict="${intake_skip_cache_verdict[$1]:-}"
  [[ -n "$updated_at" && "${intake_skip_cache_at[$n]:-}" == "$updated_at" && -n "$verdict" ]] || return 1
  intake_skip "$verdict" cached
}
intake_skip_cache_flush() {
  local cache_file="$A/intake-candidates.json" cache_tmp updates n now ttl merge_filter
  (( ${#intake_skip_cache_pending[@]} )) || return 0
  updates="$(for n in "${!intake_skip_cache_pending[@]}"; do
    printf '%s\t%s\t%s\t%s\n' "$n" "${intake_skip_cache_at[$n]}" "${intake_skip_cache_verdict[$n]}" "${intake_skip_cache_stamp[$n]}"
  done | jqf -Rn '[inputs | split("\t") | {key:.[0],value:{updated_at:.[1],verdict:.[2],at:(.[3] | tonumber)}}] | from_entries')" || return 0
  now="$(date +%s)"
  ttl="${INTAKE_SKIP_CACHE_TTL:-3600}"
  [[ "$ttl" =~ ^[0-9]+$ ]] || ttl=3600
  merge_filter='(. // {}) as $cache
    | {schema:5,created_at:($cache.created_at // 0),rows:($cache.rows // ""),
       skipped:((($cache.skipped // {}) | with_entries(select(
         (.value.at // "" | tostring) as $at
         | ($at | test("^[0-9]+$")) and ($at | tonumber) <= $now and ($now - ($at | tonumber) < $ttl)
       ))) + ($updates[0] // {}))}'
  cache_tmp="$cache_file.skip.$BASHPID.$RANDOM.tmp"
  if ! (
    exec 9>"$cache_file.lock" || exit 1
    flock -x 9 || exit 1
    if [[ -s "$cache_file" ]]; then
      jqf -c --slurpfile updates <(printf '%s' "$updates") --argjson now "$now" --argjson ttl "$ttl" \
        "$merge_filter" "$cache_file" >"$cache_tmp" || exit 1
    else
      printf '{}\n' | jqf -c --slurpfile updates <(printf '%s' "$updates") --argjson now "$now" --argjson ttl "$ttl" \
        "$merge_filter" >"$cache_tmp" || exit 1
    fi
    mv -f -- "$cache_tmp" "$cache_file"
  ); then
    rm -f -- "$cache_tmp"
    say "intake skip cache write failed"
  fi
}
intake_candidates_cache_write() {
  local cache_file="$1" rows_file="$2" json_tmp="$3" created_at="$4" skipped
  (
    exec 9>"$cache_file.lock" || exit 1
    flock -x 9 || exit 1
    skipped="$(jqf_optional_file "$cache_file" -c '.skipped // {}' 2>/dev/null || printf '{}')"
    jqf -Rs --argjson created_at "$created_at" --argjson skipped "$skipped" '
      . as $rows
      | ($rows | split("\n") | map(select(length > 0) | split("\t")[0] | tonumber?)) as $numbers
      | {schema:5,created_at:$created_at,rows:($rows | rtrimstr("\n")),
          skipped:($skipped | with_entries(select((.key | tonumber?) as $n | $n != null and (($numbers | index($n)) != null))))}' \
      <"$rows_file" >"$json_tmp" && mv -f -- "$json_tmp" "$cache_file"
  )
}
intake_skip() {
  intake_skip_counts[$1]=$(( ${intake_skip_counts[$1]:-0} + 1 )); intake_mark "skip_$1"
  if [[ "${2:-}" != cached && -n "${issue_updated_at:-}" && "${n:-}" =~ ^[0-9]+$ ]]; then
    case "$1" in
      parent|author_hold|m5|task)
        intake_skip_cache_at["$n"]="$issue_updated_at"; intake_skip_cache_verdict["$n"]="$1"; intake_skip_cache_stamp["$n"]="$(date +%s)"; intake_skip_cache_pending["$n"]=1 ;;
    esac
  fi
}
# Rows intake drops with only a count, or none: skip-label rows in intake_candidates and open-PR mentions in register_new_issues.
# One `intake skip issue #N: reason` per issue and reason, repeated at most every 6h ($A/intake-skip-noted.tsv: "n reason<TAB>epoch").
intake_skip_stamp() {
  local f="$A/intake-skip-noted.tsv" now="${3:-$(date +%s)}"
  (
    exec 9>"$f.lock" || exit 1
    flock -x 9 || exit 1
    { awk -F'\t' -v k="$1 $2" -v now="$now" '$1!=k && now-$2<21600' "$f" 2>/dev/null; printf '%s %s\t%s\n' "$1" "$2" "$now"; } > "$f.tmp.$BASHPID" \
      && mv -f -- "$f.tmp.$BASHPID" "$f" || { rm -f -- "$f.tmp.$BASHPID"; exit 1; }
  )
}
intake_skip_note() {
  local f="$A/intake-skip-noted.tsv" now; now="$(date +%s)"
  awk -F'\t' -v k="$1 $2" -v now="$now" '$1==k && now-$2<21600{f=1} END{exit !f}' "$f" 2>/dev/null && return 0
  say "intake skip issue #$1: $2"
  intake_skip_stamp "$1" "$2" "$now"
}
intake_skip_refused_recut() { intake_skip_note "$1" "unit=$2 stays closed, recut refused and its reopen is spent"; intake_skip recut_refused; }
intake_priority_open_unlabelled_issue() {
  jqf -e '(.state == "OPEN") and ([.labels[]? | if type == "string" then . else .name // "" end] as $labels
    | ($labels | index("needs-triage") == null) and all($labels[]; startswith("priority:") | not))' <<<"$1" >/dev/null
}
intake_priority_open_unlabelled_cooldown() { # issue number -> 0 while the existing 6 h cooldown applies
  awk -F'\t' -v k="$1 intake priority label not applied" -v now="$(date +%s)" '$1==k && now-$2<21600{f=1} END{exit !f}' \
    "$A/intake-skip-noted.tsv" 2>/dev/null
}
intake_priority_judge_issue() { # issue-json number repo; preserve the tick's call and #1206 stamp rules
  local issue="$1" number="$2" repo="$3" output priority_rc=0 priority_script="${ZF_INTAKE_PRIORITY_SCRIPT:-$HERE/../intake-priority.sh}"
  INTAKE_PRIORITY_JUDGE_OUTPUT="" INTAKE_PRIORITY_JUDGE_APPLIED=false INTAKE_PRIORITY_JUDGE_FALLBACK=false INTAKE_PRIORITY_JUDGE_DEFERRED=false
  output="$(printf '%s\n' "$issue" | bash "$priority_script" triage "$number" ready-for-agent "$repo" 2>&1)" || priority_rc=$?
  INTAKE_PRIORITY_JUDGE_OUTPUT="$output"
  [[ -z "$output" ]] || printf '%s\n' "$output" >>"$LOG"
  case "$output" in
    *'intake-priority: skipped (disabled)'*|*'intake-priority: skipped (missing-typesafe-key)'*|*'intake-priority: skipped (invalid-config)'*)
      if declare -F intake_judge_station_consume_candidate >/dev/null; then intake_judge_station_consume_candidate "$number" || return $?; fi
      return 0 ;;
  esac
  if (( priority_rc == 75 )) || grep -Fq "intake-priority: deferred issue=#$number " <<<"$output"; then
    INTAKE_PRIORITY_JUDGE_DEFERRED=true
    return 0
  fi
  if grep -Fq "intake-priority: applied issue=#$number " <<<"$output"; then
    INTAKE_PRIORITY_JUDGE_APPLIED=true
  elif ! grep -Fq 'intake-priority: label update failed' <<<"$output" \
    || { (( priority_rc != 75 )) && ! grep -Eq 'rate limit exhausted|rate-limit backoff active|rc 75' <<<"$output"; }; then
    intake_skip_stamp "$number" 'intake priority label not applied' || return $?
  fi
  if declare -F intake_judge_station_consume_candidate >/dev/null; then intake_judge_station_consume_candidate "$number" || return $?; fi
  return 0
}
# Open candidates outside needs-triage can bypass run-triage; judge them before intake drops tracker labels.
intake_priority_open_unlabelled_candidate() {
  local issue="$1" number repo="${REPO:-${ZF_REPO:-}}" claim_timeout="${AUTOPI_INTAKE_JUDGE_KILL_SECONDS:-1200}" judge_rc=0
  if declare -F intake_judge_fresh >/dev/null && intake_judge_fresh; then return 0; fi
  intake_priority_open_unlabelled_issue "$issue" || return 0
  [[ -n "$repo" ]] || return 0
  number="$(jqf -r '.number' <<<"$issue")" || return 0
  intake_priority_open_unlabelled_cooldown "$number" && return 0
  if (( intake_judges_used >= intake_judge_cap )) \
    || { [[ "$intake_judge_started" =~ ^[0-9]+$ && "$intake_judge_budget" =~ ^[0-9]+$ ]] \
      && (( SECONDS - intake_judge_started >= intake_judge_budget )); } \
    || { declare -F refill_stopped >/dev/null && refill_stopped; }; then
    intake_judges_deferred=$((intake_judges_deferred + 1))
    return 0
  fi
  intake_judges_used=$((intake_judges_used + 1))
  if declare -F intake_judge_claim_begin >/dev/null; then
    [[ "$claim_timeout" =~ ^[1-9][0-9]*$ ]] || claim_timeout=1200
    intake_judge_claim_begin "$number" "$claim_timeout" || { intake_judges_deferred=$((intake_judges_deferred + 1)); return 0; }
  fi
  intake_priority_judge_issue "$issue" "$number" "$repo" || judge_rc=$?
  if declare -F intake_judge_claim_end >/dev/null; then intake_judge_claim_end; fi
  if [[ "$INTAKE_PRIORITY_JUDGE_DEFERRED" == true ]]; then
    intake_judges_deferred=$((intake_judges_deferred + 1))
    return 0
  fi
  return "$judge_rc"
}
intake_priority_open_unlabelled_candidates() { # intake start budget; stdin is the deduplicated issue stream
  local intake_judge_started="${1:-}" intake_judge_budget="${2:-}" intake_judge_cap="${ZF_INTAKE_JUDGE_PER_PASS:-3}" intake_judges_used=0 intake_judges_deferred=0 row
  [[ "$intake_judge_cap" =~ ^[0-9]+$ ]] || intake_judge_cap=3
  intake_judge_cap=$((10#$intake_judge_cap))
  while IFS= read -r row; do
    intake_priority_open_unlabelled_candidate "$row"
    printf '%s\n' "$row"
  done
  if (( intake_judges_deferred > 0 )); then say "intake priority judges deferred=$intake_judges_deferred"; fi
}
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
