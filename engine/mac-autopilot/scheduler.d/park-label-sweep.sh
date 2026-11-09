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

# A cap-triage founder park waits on a question, but the stop-loss hold that started it expires after 24h on its own
# (the hold comment says undecided holds resume). Once that hold is gone the issue is ready-for-agent again, and the unit must not stay parked behind it.
park_sweep_hold_lifted() { # issue unit-episode → 0 when the issue state shows no hold, and no handoff episode the intake path still owes the unit
  jqf_optional_file "${AGENT_HOME:-${HOME:-}/.zenoforge}/state/$1.json" -e --arg unit_episode "$2" \
    '.state == "ready-for-agent" and .hold == null and ((.scheduler_handoff.episode // "") | . == "" or . == $unit_episode)' >/dev/null 2>&1
}

park_label_sweep() {
  local u id issue reason unpark n unit_episode state labels updated parked_at budget release cache US=$'\x1f'
  while IFS= read -r u; do
    id="$(jqf -r .id <<<"$u")"
    IFS=$'\t' read -r reason unpark < <(park_sweep_class "$u")
    set_unit "$id" ".parked_reason=$(js "$reason") | .unpark_condition=$(js "$unpark")" && park_sweep_log "$id" "label $reason"
  done < <(jqf -c '.units[] | select(.stage == "parked" and .parked_reason == null)' "$UNITS")
  # Ticket stop-loss records an issue-change / budget-refill exit; detect both from the batched GitHub snapshot.
  cache="$(jqf_optional_file "$A/dep-check.cache.json" -c 'if (.states|type)=="object" then .states else {} end' 2>/dev/null || true)"
  [[ -n "$cache" ]] || cache='{}'
  while IFS="$US" read -r id issue state labels updated parked_at; do
    [[ "$state" == OPEN && ",$labels," == *,ready-for-agent,* && -n "$updated" ]] || continue
    u="$(jqf -c --arg id "$id" '.units[] | select(.id==$id)' "$UNITS")"
    budget="$(ticket_budget_reason "$u" 2>/dev/null || true)"
    release=""
    if [[ -z "$budget" ]]; then
      release="ticket budget is available again"
    elif [[ -n "$parked_at" && "$updated" > "$parked_at" ]]; then
      release="issue updated after the stop-loss park"
    fi
    [[ -n "$release" ]] || continue
    set_unit "$id" "$(hist supervisor-requeue "$release; the issue is ready-for-agent") | .stage=\"implement-pending\" | .note=null | del(.parked_reason, .unpark_condition)" \
      && park_sweep_log "$id" "ticket-stop-loss-resume ($release)"
  done < <(jqf -r --argjson c "$cache" '
    .units[] | select(.stage=="parked" and .parked_reason=="ticket-stop-loss" and (.issue|type)=="number")
    | ($c[(.issue|tostring)] // {}) as $x
    | [.id,.issue,($x.state // ""),($x.labels // ""),($x.updated_at // ""),
       ([.history[]? | select(.stage=="supervisor-budget-park") | .at] | last // "")]
    | map(tostring) | join("\u001f")' "$UNITS")
  # The same return as the issue-3015 ruling below, for any unit whose stop-loss hold is gone. The retry mark is what the arbiter's own
  # swept route sets for this park: one more triage run, and a second cap ends terminal instead of asking again.
  while IFS=$'\t' read -r id issue unit_episode; do
    park_sweep_hold_lifted "$issue" "$unit_episode" || continue
    set_unit "$id" "$(hist park-sweep-hold-lifted "stop-loss hold lifted: back to supervisor-review for one more cap triage") | .stage=\"supervisor-review\" | .supervisor_cap_retry=\"pending\" | .supervisor_cap_from_parked=true | del(.parked_reason, .unpark_condition)" \
      && park_sweep_log "$id" supervisor-review
  done < <(jqf -r '.units[] | select(.stage == "parked" and .parked_reason == "supervisor-cap-founder" and .supervisor_cap_retry == null and (.hold_handoff_waiting // false) == false and (.issue | type) == "number") | [.id, .issue, (.hold_handoff_episode // "")] | @tsv' "$UNITS")
  # Rulings that move a unit: at most one per sweep, each once.
  # The stale form an earlier sweep left (arbitration cap, resume already in history) is released here too.
  u="$(jqf -c '[.units[] | select(.id == "issue-3015" and .stage == "parked" and (.parked_reason == "preserved-clone-hold" or (.parked_reason == "supervisor-arbitration-cap" and any((.history // [])[]; .stage == "park-sweep-resume"))))][0] // empty' "$UNITS")"
  if [[ -n "$u" ]]; then
    set_unit issue-3015 "$(hist park-sweep-resume "hold lifted: nothing in the clone needs preserving; back to supervisor-review") | .stage=\"supervisor-review\" | del(.parked_reason, .unpark_condition, .hold_handoff_waiting, .hold_handoff_wait_issues)" \
      && park_sweep_log issue-3015 supervisor-review; return 0
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
