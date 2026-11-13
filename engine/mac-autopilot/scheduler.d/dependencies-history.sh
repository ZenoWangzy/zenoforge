# unit-json → N when the unit's last run ended blocked-on #N with no commit and nothing since cleared it: no release, no
# supervisor or typesafe ruling. A handoff requeue is no ruling (see dep_dead_ruled), so it cannot free the unit by itself.
hist_blocked() { # stage dep-or-empty source [result] → history event with blocker and transition source
  local dep="${2:-}" blocked_on=null result="${4:-}"
  [[ "$dep" =~ ^[0-9]+$ ]] && blocked_on="$dep"
  [[ -n "$result" ]] || result="${dep:+#$dep}"
  echo "$(hist "$1" "$result") | .history[-1] += {blocked_on: $blocked_on, source: $(js "$3")}"
}
unit_blocked_run_dep() {
  jqf -r '(.history // []) as $h | ([$h | to_entries[] | select(.value.stage == "write-start") | .key] | max) as $s
    | if $s == null then empty else $h[$s:] as $r
      | (($r | map(select(.stage == "write-end")) | last) // {}) as $e
      | ([$r | to_entries[] | select(.value.stage == "blocked-on") | .key] | max) as $b
      | if $e.result == "[]" and $b != null
          and all($r[($b + 1):][]; (.stage == "unblocked" or ((.stage | IN("supervisor-requeue","supervisor-reroute","supervisor-cap-rule")) and (.decision.owner | IN("supervisor","typesafe")))) | not)
        then
          # The blocker moved since that run (blocker-repointed, in order): the number that run reported is stale, and a requeue must not bring it back (#3405 on #2827 -> #5434 -> #5793).
          (reduce ($r[($b + 1):][] | select(.stage == "blocker-repointed")) as $p ($r[$b].result // "" | ltrimstr("#");
            . as $cur | if (($p.result // "") | startswith("#" + $cur + " closed in ledger after recut; now waits on child #"))
              then ($p.result | sub("^.*child #"; "") | sub("[^0-9].*$"; "")) else $cur end)) as $d
          # A reroute dropped this blocker for the unit: it is no longer a wait.
          | if ((.dropped_deps // []) | map(tostring) | index($d)) != null then empty else $d end
        else empty end end' <<<"$1" 2>/dev/null
}
