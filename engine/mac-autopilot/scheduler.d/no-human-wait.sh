# hold.sh --rule requeue records the owner's comment id (issue 5742: "supervisor ruling 6736537359: ...", decision null); plain requeue has no id.
# The next supervisor-arbiter row consumes that ruling, granting one run without resetting lifetime spend.
supervisor_arbiter_owner_ruling_pending() { # unit-json → 0 when an owner ruling came after the unit's last supervisor-arbiter run
  jqf -e '(.history // []) as $h
    | ([$h | to_entries[] | select(.value.stage == "supervisor-arbiter") | .key] | last // -1) as $last
    | any($h[$last + 1:][]?; .stage == "supervisor-requeue" and ((.result // "") | test("^supervisor ruling [0-9]+: ")))' <<<"$1" >/dev/null
}
# Re-read an arbiter candidate after a phase boundary; output id<TAB>current JSON, or nothing if it is no longer eligible.
supervisor_arbiter_live_candidate() { # stale unit-json → id<TAB>current candidate JSON
  local candidate_id candidate_unit
  candidate_id="$(jqf -r .id <<<"$1")"
  candidate_unit="$(jqf -c --arg id "$candidate_id" '[.units[] | select(.id==$id)][0] // empty' "$UNITS")"
  [[ -n "$candidate_unit" && "$candidate_unit" != null ]] || return 1
  jqf -e '(.stage == "supervisor-review" or .stage == "parked") and (.hold_handoff_waiting // false)==false and (.supervisor_owned // false)==false' <<<"$candidate_unit" >/dev/null || return 1
  printf '%s\t%s\n' "$candidate_id" "$candidate_unit"
}
# At the lifetime cap with no ruling, head gets SUPERVISOR_CAP_WAIT_S from the last run; then one default decision (the recut route once), and a second cap closes durably.
SUPERVISOR_CAP_WAIT_S=21600
supervisor_arbiter_capped_default() { # id unit-json → the lifetime cap's route; dispatches no run
  local id="$1" u="$2" runs
  u="$(jqf -c --arg id "$id" '[.units[] | select(.id==$id)][0] // empty' "$UNITS")"
  [[ -n "$u" && "$u" != null ]] || return 0
  runs="$(supervisor_arbiter_lifetime_runs "$u")"
  (( runs >= SUPERVISOR_ARBITER_UNIT_CAP )) || return 0
  supervisor_arbiter_owner_ruling_pending "$u" && return 0
  if [[ "$(jqf -r '.arbiter_cap_logged // 0' <<<"$u")" != "$runs" ]]; then
    set_unit "$id" ".arbiter_cap_logged=$runs" || :
    u="$(jqf -c --arg id "$id" '[.units[] | select(.id==$id)][0] // empty' "$UNITS")"
    [[ -n "$u" && "$u" != null ]] || return 0
    runs="$(supervisor_arbiter_lifetime_runs "$u")"
    (( runs >= SUPERVISOR_ARBITER_UNIT_CAP )) || return 0
    supervisor_arbiter_owner_ruling_pending "$u" && return 0
    [[ "$(jqf -r '.arbiter_cap_logged // 0' <<<"$u")" == "$runs" ]] || return 0
    say "arbiter cap reached unit=$id runs=$runs owner=head"
  fi
  jqf -e --argjson wait "$SUPERVISOR_CAP_WAIT_S" --argjson now "$(date +%s)" '([(.history // [])[] | select(.stage == "supervisor-arbiter") | .at] | last // "1970-01-01T00:00:00Z" | sub("\\.[0-9]+Z$"; "Z") | fromdateiso8601) + $wait <= $now' <<<"$u" >/dev/null || return 0
  if jqf -e 'any((.history // [])[]?; .stage == "supervisor-cap-default" and ((.result // "") | test("arbitration cap")))' <<<"$u" >/dev/null; then
    supervisor_cap_second_close "$id" arbitration-cap-again "the cap came back after its default decision and no head ruling" \
      "$(decision_entry 'Supervisor cap close' 'the cap came back after one default decision and no head ruling' 'supervisor-arbiter history events' '[]' scheduler)"
    return
  fi
  supervisor_cap_default "$id" "$u" lifetime
}
# Close with hold.sh (the on-hold writer) so recurrence reopens work; if the hold fails, leave the unit open for the next tick.
supervisor_close_with_hold() { # id token detail decision
  local id="$1" token="$2" detail="$3" decision="$4" issue hold_cli
  issue="$(unit_field "$id" '.issue // empty')"
  if [[ "$issue" =~ ^[1-9][0-9]*$ ]]; then
    hold_cli="${ZF_ENGINE_DIR:-$ROOT/engine}/hold.sh"; [[ -r "$hold_cli" ]] || hold_cli="$HERE/../hold.sh"
    bash "$hold_cli" --hold "$issue" --holder scheduler-stop-loss --release "a new failure or a supervisor ruling reopens this issue" \
      --expires 24h --kind stop-loss >/dev/null 2>&1 \
      || { say "supervisor close unit=$id reason=$token: durable hold on issue #$issue not applied; left open for the next tick"; return 1; }
  fi
  cap_set_unit "$id" close "$detail" "" "$(hist supervisor-close "$detail" "$decision") | .stage=\"closed\" | .note=$(js "$detail") | del(.parked_reason, .unpark_condition)" \
    && say "supervisor close unit=$id reason=$token: closed with a durable hold"
}
# Second cap: the hold on the issue first, then the open PR under it (see supervisor_cap_close_pr).
supervisor_cap_second_close() { # id token detail decision
  supervisor_close_with_hold "$@" && supervisor_cap_close_pr "$1" "$2" "$3"
}
# Cap-exhausted parks (supervisor_cap_exhausted, reask-exhausted) leave without a human: a head ruling after the park releases it to one arbiter run (the
# +1 rule); else six hours after the park, the recut default once; a second exhaustion with no ruling closes durably (supervisor_cap_second_close).
supervisor_cap_exhausted_sweep() { # each tick
  local id at u
  while IFS=$'\t' read -r id at; do
    u="$(jqf -c --arg id "$id" '[.units[] | select(.id==$id)][0]' "$UNITS")"
    if supervisor_arbiter_owner_ruling_pending "$u"; then
      set_unit "$id" 'del(.cap_exhausted_mark, .unpark_condition) | .parked_reason="supervisor-arbitration-cap"' \
        && say "supervisor cap-exhausted unit=$id reason=supervisor-cap-exhausted: released by a head ruling (one arbiter run)"
      continue
    fi
    (( ${NOW_EPOCH:-$(date +%s)} - $(date -d "$at" +%s 2>/dev/null || echo 0) >= SUPERVISOR_CAP_WAIT_S )) || continue
    if jqf -e 'any((.history // [])[]?; .stage == "supervisor-cap-default" and ((.result // "") | test("arbitration cap")))' <<<"$u" >/dev/null; then
      supervisor_cap_second_close "$id" cap-exhausted-again "exhausted again after its recut default and no head ruling" \
        "$(decision_entry 'Supervisor cap close' 'exhausted again after its default decision and no head ruling' 'supervisor-arbiter history events' '[]' scheduler)"
    else
      say "supervisor cap-exhausted unit=$id reason=supervisor-cap-exhausted: six hours without a ruling, recut default once"
      supervisor_cap_default "$id" "$u" lifetime || :
    fi
  done < <(jqf -r '.units[] | select(.stage == "parked" and .parked_reason == "supervisor-cap-exhausted" and (.cap_exhausted_by // "") != "no-answer" and any((.history // [])[]?; .stage == "supervisor-cap-exhausted"))
    | [.id, ([(.history // [])[] | select(.stage == "supervisor-cap-exhausted") | .at] | last)] | @tsv' "$UNITS")
  return 0
}
# Close the open PR under its issue hold unless session-owned or cited by an open issue; one state/label/body read per close, no polling.
supervisor_cap_close_pr() { # id token detail
  local id="$1" token="$2" detail="$3" pr issue repo state cited
  pr="$(unit_field "$id" '.pr // empty')"; issue="$(unit_field "$id" '.issue // empty')"; repo="${REPO:-${ZF_REPO:-}}"
  [[ "$pr" =~ ^[1-9][0-9]*$ ]] || return 0
  state="$(gh pr view "$pr" --json state,labels --jq '.state + " " + ([.labels[].name] | join(","))' 2>/dev/null)" || state=""
  [[ "$state" == OPEN\ * ]] || return 0
  [[ "$state" != *session-owned* ]] || { say "supervisor close unit=$id reason=$token: PR #$pr kept open, session-owned"; return 0; }
  [[ "$issue" =~ ^[1-9][0-9]*$ && -n "$repo" ]] || { say "supervisor close unit=$id reason=$token: PR #$pr kept open, no issue hold to link"; return 0; }
  cited="$(gh issue list --repo "$repo" --state open --limit 1000 --json number,body --jq ".[] | select((.body // \"\") | test(\"PR #$pr(?![0-9])\")) | .number" 2>/dev/null)" \
    || { say "supervisor close unit=$id reason=$token: PR #$pr kept open, open-issue read failed"; return 0; }
  if [[ -n "$cited" ]]; then say "supervisor close unit=$id reason=$token: PR #$pr kept open, first slice cited by open issue #${cited%%$'\n'*}"; return 0; fi
  gh pr close "$pr" --comment "Autopilot cap close: unit $id is closed. Its issue #$issue is on hold (hold.sh, holder scheduler-stop-loss): $detail. A recurrence of that issue reopens the work." >/dev/null 2>&1 \
    && say "supervisor close unit=$id reason=$token: PR #$pr closed, hold on issue #$issue" \
    || say "supervisor close unit=$id reason=$token: could not close PR #$pr; left open"
  return 0
}
# An arbiter park waits for a state change or 24 h; one more arbitration then sees the earlier verdict in its history. A park that repeats is the repeat
# verdict: the unit closes with a durable hold and is never parked again.
supervisor_park_verdict() { # id reason decision
  local id="$1" reason="$2" decision="$3" u pr head=""
  u="$(jqf -c --arg id "$id" '[.units[] | select(.id==$id)][0]' "$UNITS")"
  if jqf -e 'any((.history // [])[]?; .stage == "supervisor-park")' <<<"$u" >/dev/null; then
    supervisor_close_with_hold "$id" supervisor-park-repeat "repeated verdict: $reason" "$decision"
    return
  fi
  pr="$(jqf -r '.pr // empty' <<<"$u")"
  [[ ! "$pr" =~ ^[0-9]+$ ]] || head="$(tick_pr_head "$pr" 2>/dev/null || true)"
  set_unit "$id" "$(hist supervisor-park "$reason" "$decision") | .stage=\"parked\" | .note=$(js "$reason") | $(park_fields supervisor-park 'a state change or 24 h') | .supervisor_park_main=$(js "${MAIN_HEAD:-}") | .supervisor_park_head=$(js "$head")" \
    && say "supervisor park unit=$id reason=supervisor-park: waits for a state change or 24 h"
}
# Each tick: a main-red-guard park is released by the first green main run created after it; a supervisor-park re-arbitrates once after a main or PR head
# change, or 24 h after its park. The repeat verdict is then closed by supervisor_park_verdict.
supervisor_parked_unpark_sweeps() {
  local id at main head pr cur why rows runs run sha
  rows="$(jqf -r '.units[] | select(.stage == "parked" and .parked_reason == "main-red-guard") | [.id, (([(.history // [])[] | select(.stage == "supervisor-park") | .at] | last) // "-")] | @tsv' "$UNITS")"
  if [[ -n "$rows" ]]; then
    # The engine's own main-CI verdict (lib.d/ci-checks.sh), loaded in a subshell as the per-item modules are; no new GitHub read.
    run="$(REPO="${REPO:-${ZF_REPO:-}}"; scheduler_scope_lib ci-checks fix-forward && runs="$(ci_main_completed_push_runs)" && ci_main_latest_completed_push_run "$runs")" 2>/dev/null || run=""
    if [[ -n "$run" && "$(jqf -r '.conclusion // ""' <<<"$run")" == success ]]; then
      sha="$(jqf -r '.head_sha // ""' <<<"$run")"
      while IFS=$'\t' read -r id at; do
        [[ "$at" == - || "$(jqf -r '.created_at // ""' <<<"$run")" > "$at" ]] || continue
        jqf -e --arg id "$id" --arg at "$at" 'any(.units[]; .id==$id and .stage=="parked" and .parked_reason=="main-red-guard" and (([(.history // [])[] | select(.stage=="supervisor-park") | .at] | last // "-") == $at))' "$UNITS" >/dev/null || continue
        set_unit "$id" "$(hist supervisor-main-green "main green at ${sha:0:9}: released from the main-red-guard park") | .stage=\"supervisor-review\" | del(.parked_reason, .unpark_condition)" \
          && say "supervisor park unit=$id reason=main-red-guard released: main green at ${sha:0:9}"
      done <<<"$rows"
    fi
  fi
  while IFS=$'\t' read -r id at main head pr; do
    why=""
    [[ "$main" =~ $SHA_RE && "$MAIN_HEAD" =~ $SHA_RE && "$MAIN_HEAD" != "$main" ]] && why="main moved to ${MAIN_HEAD:0:9}"
    if [[ -z "$why" && "$pr" =~ ^[0-9]+$ && "$head" =~ $SHA_RE ]]; then
      cur="$(tick_pr_head "$pr" 2>/dev/null || true)"
      [[ ! "$cur" =~ $SHA_RE || "$cur" == "$head" ]] || why="PR head changed to ${cur:0:9}"
    fi
    if [[ -z "$why" ]] && { [[ "$at" == - ]] || (( ${NOW_EPOCH:-$(date +%s)} - $(date -d "$at" +%s 2>/dev/null || echo 0) >= 86400 )); }; then why="24 h since the park"; fi
    [[ -n "$why" ]] || continue
    jqf -e --arg id "$id" --arg at "$at" --arg main "$main" --arg head "$head" --arg pr "$pr" \
      'any(.units[]; .id==$id and .stage=="parked" and .parked_reason=="supervisor-park" and (([(.history // [])[] | select(.stage=="supervisor-park") | .at] | last // "-") == $at) and (.supervisor_park_main // "-")==$main and (if (.supervisor_park_head // "") == "" then "-" else .supervisor_park_head end)==$head and (((.pr // "-") | tostring)==$pr))' "$UNITS" >/dev/null || continue
    set_unit "$id" "$(hist supervisor-park-recheck "re-arbitrate once: $why") | .stage=\"supervisor-review\" | del(.parked_reason, .unpark_condition)" \
      && say "supervisor park unit=$id reason=supervisor-park re-arbitrate once: $why"
  # park-label-sweep can infer this generic reason for legacy parks; require a recorded arbiter park before rechecking it.
  done < <(jqf -r '.units[] | select(.stage == "parked" and .parked_reason == "supervisor-park" and any((.history // [])[]?; .stage == "supervisor-park")) | [.id, (([(.history // [])[] | select(.stage == "supervisor-park") | .at] | last) // "-"), (.supervisor_park_main // "-"), (if (.supervisor_park_head // "") == "" then "-" else .supervisor_park_head end), (.pr // "-")] | @tsv' "$UNITS")
  return 0
}

