# Fail closed: any fact that cannot be read means not dead. Prints the arbiter's evidence.
dep_predecessor_dead() { # waiter-unit-json predecessor
  local dep="$2" waiter rows st prs subs c b sha branches="" labels active_labels
  dep_delivered_in_ledger "$dep" && return 1
  if (( DEP_ROWS_PASS && DEP_ROWS_BUILT )); then
    if [[ -z "${DEP_ROWS_IDS[$dep]:-}" ]]; then rows='[]'; else dep_rows_flag "$dep" 1 || return 1; rows="$(dep_rows_json "$dep")" || return 1; fi
  else rows="$(dep_rows_json "$dep")" || return 1; fi
  st="$(scheduler_issue_state "$dep")" && [[ -n "$st" ]] || return 1
  labels="$(jqf -r '.labels // ""' <<<"$(dep_cache_info "$dep")")"
  active_labels="$(printf '%s\n' "${DEP_DEAD_ACTIVE_LABELS[@]}" | jqf -Rsc 'split("\n")[:-1]')" || return 1
  jqf -e --slurpfile st <(printf '%s' "$st") --arg labels "$labels" --argjson active "$active_labels" '
    ($labels | split(",")) as $l
    | if length == 0 then $st[0].state == "tracker" or $st[0].tracker_parent == true or
        ((any($l[]; IN("needs-owner","ready-for-human"))) and all($l[]; . as $label | $active | index($label) == null))
      else all(.[]; .stage == "closed" or (.stage == "parked" and .parked_reason == "dep-dead-repeat")) and (any(.[]; .stage == "parked") or $st[0].state == "tracker" or $st[0].state == "ready-for-agent" or $st[0].tracker_parent == true or
        (($st[0].state | IN("on-hold","needs-recut","needs-triage","ready-for-agent","needs-advisor","checks-blocked","awaiting-pipeline-sync","awaiting-release","finish-first","session-owned") | not)
          and all($l[]; . as $label | $active | index($label) == null)))
      end' <<<"$rows" >/dev/null || return 1
  jqf -e --slurpfile w "$A/workers.json" 'map(.id) as $ids | all($w[0].workers[]; .harvested == true or (.unit as $u | ($ids | index($u)) == null))' <<<"$rows" >/dev/null || return 1
  prs="$(tick_prs)" || return 1
  jqf -e --slurpfile rows <(printf '%s' "$rows") --arg d "$dep" '
    ($rows[0] | map(.pr)) as $own | ($rows[0] | map(.branch) + ["agent/issue-" + $d]) as $heads
    | all(.[]; (.number as $n | $own | index($n)) == null and (.headRefName as $h | $heads | index($h)) == null
      and ((.body // "") | test("#" + $d + "([^0-9]|$)") | not))' <<<"$prs" >/dev/null || return 1
  subs="$(gh api --paginate "repos/{owner}/{repo}/issues/$dep/sub_issues?per_page=100" --jq '.[].number' 2>/dev/null)" || return 1
  waiter="$(jqf -r '.issue // empty' <<<"$1")"
  for c in $(printf '%s\n%s\n' "$(jqf -r '(.recut_children // [])[]' <<<"$st")" "$subs" | sort -un); do
    [[ "$c" != "$waiter" ]] || continue
    dep_delivered_in_ledger "$c" && continue
    jqf -e --argjson c "$c" --argjson d "$dep" 'any(.units[]; .issue == $c and .dep_wait_delivery == $d)' "$UNITS" >/dev/null && continue # waits on the same dead predecessor
    [[ "$(dep_states "$c" | cut -f2)" =~ ^(CLOSED|MERGED)$ ]] || { say "dep-dead skip waiter=#$waiter predecessor=#$dep live child #$c"; return 1; }
  done
  for b in $(jqf -r --arg d "$dep" 'map(.branch // empty) + ["agent/issue-" + $d] | unique | .[]' <<<"$rows"); do
    sha="$(gh api "repos/{owner}/{repo}/git/ref/heads/$b" --jq .object.sha 2>/dev/null)" || sha=gone
    branches+=" $b@${sha:0:12}"
  done
  printf 'predecessor #%s can never deliver (%s), no open PR, no live worker, no live child; branches:%s' \
    "$dep" "$(jqf -r 'if length == 0 then "open tracker with no unit" else "unit closed undelivered: " + (last.note // "no note" | .[0:200]) end' <<<"$rows")" "$branches"
}
