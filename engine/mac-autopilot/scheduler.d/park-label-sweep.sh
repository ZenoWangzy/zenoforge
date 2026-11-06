# One-time label of the parks that predate park_fields, with the rulings of 2026-11-06. Delete once a tick logs no park-sweep line.
PARK_SWEEP_RESUME=(1374 5171 5170 5222 5091 1267 3137) # stopped by wall alone under the old measure, or state to reconcile: arbitrate once
declare -A PARK_SWEEP_CHILDREN=([4508]='[5315,5331]' [4757]='[5316,5317]' [4506]='[5318,5319]' [4376]='[5320,5321]' [1363]='[5322,5323,5324]' [3349]='[5325,5326,5327]' [5276]='[5328,5329,5330]')

park_sweep_log() { echo "[$STAMP] park-sweep unit=$1 action=$2" >> "$A/alerts/events.md"; say "park-sweep unit=$1 action=$2"; }

park_sweep_class() { # unit-json → reason<TAB>unpark condition
  jqf -r '
    (.note // "") as $n
    | if (.blocked_on | type) == "number" then ["waiting-predecessor", "#\(.blocked_on) delivered"]
      elif ($n | test("ticket stop-loss")) then ["ticket-stop-loss", "the issue changes or the ticket budget is raised"]
      elif ($n | test("third entry into supervisor-review")) then ["preserved-clone-hold", "a supervisor decision"]
      elif ($n | test("recut into child issues")) then ["recut-children", "the recut children are delivered"]
      elif ($n | test("recut is on hold")) then ["on-hold", "the on-hold label lifts"]
      elif ($n | test("state/label reconciliation")) then ["state-reconcile", "the issue state and labels agree"]
      elif ($n | test("cap triage could not complete")) then ["cap-recut-failed", "a supervisor decision"]
      elif ($n | test("run-release")) then ["head-hold", "the hold is lifted"]
      else ["supervisor-park", "a supervisor decision"] end | @tsv' <<<"$1"
}

park_label_sweep() {
  local u id issue reason unpark n
  while IFS= read -r u; do
    id="$(jqf -r .id <<<"$u")"
    IFS=$'\t' read -r reason unpark < <(park_sweep_class "$u")
    set_unit "$id" ".parked_reason=$(js "$reason") | .unpark_condition=$(js "$unpark")" && park_sweep_log "$id" "label $reason"
  done < <(jqf -c '.units[] | select(.stage == "parked" and .parked_reason == null)' "$UNITS")
  # Rulings that move a unit: at most one per sweep, each once.
  u="$(jqf -c '[.units[] | select(.id == "issue-3015" and .stage == "parked" and .parked_reason == "preserved-clone-hold")][0] // empty' "$UNITS")"
  if [[ -n "$u" ]]; then
    set_unit issue-3015 "$(hist park-sweep-resume "hold lifted: nothing in the clone needs preserving") | .parked_reason=\"supervisor-arbitration-cap\" | .unpark_condition=\"a cap triage verdict\" | del(.hold_handoff_waiting, .hold_handoff_wait_issues)" \
      && park_sweep_log issue-3015 'arbiter route'; return 0
  fi
  u="$(jqf -c '[.units[] | select(.id == "issue-4247" and .stage == "parked" and .parked_reason == "head-hold")][0] // empty' "$UNITS")"
  if [[ -n "$u" ]]; then
    set_unit issue-4247 "$(hist park-sweep-resume "hold lifted: the fork fix merged") | .stage=\"repair-pending\" | .note=null | del(.parked_reason, .unpark_condition)" \
      && park_sweep_log issue-4247 'repair-pending'; return 0
  fi
  for issue in "${PARK_SWEEP_RESUME[@]}"; do
    id="issue-$issue"
    jqf -e --arg id "$id" 'any(.units[]; .id == $id and .stage == "parked" and all((.history // [])[]; .stage != "park-sweep-resume"))' "$UNITS" >/dev/null || continue
    # The move goes first: a crash after it leaves the selector unmatched, while a crash after the marker would strand the unit.
    to_supervisor "$id" "parked under an old measure that would not stop it now, or with state to reconcile: decide whether it resumes" \
      && set_unit "$id" "$(hist park-sweep-resume "resumed once by ruling of 2026-11-06")" \
      && park_sweep_log "$id" supervisor-review
    return 0
  done
  for n in "${!PARK_SWEEP_CHILDREN[@]}"; do
    id="issue-$n"
    jqf -e --arg id "$id" 'any(.units[]; .id == $id and .stage == "parked" and .parked_reason == "recut-children" and all((.history // [])[]; .stage != "park-sweep-children"))' "$UNITS" >/dev/null || continue
    (source "$SCHEDULER_AGENT_LIB"; complete_recut_parent "$n" "${PARK_SWEEP_CHILDREN[$n]}") || { say "park-sweep unit=$id: recut record failed; next sweep retries"; return 0; }
    set_unit "$id" "$(hist park-sweep-children "${PARK_SWEEP_CHILDREN[$n]}")" && park_sweep_log "$id" "children ${PARK_SWEEP_CHILDREN[$n]}"
    return 0
  done
}
