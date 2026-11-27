risk_tiered_review_script() { printf '%s/../risk-tiered-review.mjs' "$(dirname -- "${BASH_SOURCE[0]}")"; }

risk_tiered_review_try_skip() {
  local id="$1" unit="$2" repo="$3" sha="$4" pr_head="$5" base output status self_sha decision checks paths names
  status="$(jqf -r '.self_check_status // empty' <<<"$unit")"
  self_sha="$(jqf -r '.self_check_sha // empty' <<<"$unit")"
  output="$(jqf -r '.self_check_output // empty' <<<"$unit")"
  [[ "$status" == pass && "$self_sha" == "$sha" && -s "$output" ]] || return 1
  base="$(git -C "$repo" merge-base refs/remotes/origin/main "$sha" 2>/dev/null)" || return 1
  [[ "$base" =~ $SHA_RE ]] || return 1
  decision="$(node "$(risk_tiered_review_script)" --decision --repo "$repo" --base "$base" --head "$sha" \
    --check-output "$output" --status "$status" --self-check-sha "$self_sha" \
    --invalidations "$SUP/risk-tiered-review-invalidations.json" 2>/dev/null)" || return 1
  jqf -e '.eligible == true' <<<"$decision" >/dev/null || return 1
  checks="$(jqf -c '.checks' <<<"$decision")" || return 1
  paths="$(jqf -c '.paths' <<<"$decision")" || return 1
  names="$(jqf -r '[.checks[] | "\(.kind):\(.name)"] | join(", ")' <<<"$decision")" || return 1
  set_unit "$id" "$(hist review-skip "$sha") | .history[-1].paths=$paths | .history[-1].checks=$checks | .approved_sha=$(js "$sha") | .reviewed_sha=$(js "$sha") | .reviewed_pr_head=$(js "$pr_head") | .stale_base_hop_used=false | del(.behind_main_hops,.stale_hops) | .stage=\"ready-to-merge\" | .ready_since=(.ready_since // $NOW_EPOCH)" || return 1
  post_approved_status "$id" "$pr_head"
  say "risk-tiered-review: skipped unit=$id head=$sha checks=$names"
  return 0
}

risk_tiered_review_body() {
  local unit="${1:-}" event names sha
  event="$(jqf -c '[(.history // [])[] | select(.stage == "review-skip")] | last // empty' <<<"$unit")"
  [[ -n "$event" && "$event" != null ]] || return 0
  sha="$(jqf -r '.result // ""' <<<"$event")"
  names="$(jqf -r '[.checks[]? | "\(.kind):\(.name)"] | join(", ")' <<<"$event")"
  printf '\n\n## review\nReview skipped for covered, green, small diff at %s. Checks: %s.\n' "$sha" "$names"
}

risk_tiered_review_record_escape() {
  local unit="$1" base="$2" head="$3" id hotpatch invalidations issue path unit_id paths_json recorded escape_event
  id="$(jqf -r '.id // empty' <<<"$unit")"
  hotpatch="$(jqf -r '.hotpatch // false' <<<"$unit")"
  if [[ "$hotpatch" != true ]] && ! incident_labels_match_json "$unit" "${INCIDENT_LABELS:-$INCIDENT_DEFAULT_LABELS_JSON}"; then return 0; fi
  recorded="$(unit_field "$id" '.risk_tiered_escape_recorded_sha // empty')"
  [[ "$recorded" != "$head" ]] || return 0
  base="$(git -C "$ROOT" merge-base "$base" "$head" 2>/dev/null)" || return 1
  invalidations="$(node "$(risk_tiered_review_script)" --record-escape --repo "$ROOT" --base "$base" --head "$head" \
    --invalidations "$SUP/risk-tiered-review-invalidations.json" 2>/dev/null)" || return 1
  paths_json="$(jqf -c '[.paths[].path] | unique' <<<"$invalidations")" || return 1
  issue="$(jqf -r '.issue // empty' <<<"$unit")"
  recorded="$(unit_field "$id" '[.history[]? | select(.stage == "merged")] | last.at // ""')"
  escape_event="issue=$issue head=$head"
  while IFS= read -r path; do
    [[ -n "$path" ]] || continue
    while IFS= read -r unit_id; do
      [[ -n "$unit_id" ]] || continue
      unit_id="${unit_id//$'\r'/}"
      scheduler_lock_yield_between_units || return 1
      set_unit "$unit_id" "$(hist review-skip-escape "$escape_event path=$path") | .history[-1].paths=[$(js "$path")]" || return 1
    done < <(jqf -r --arg id "$id" --arg path "$path" --arg at "$recorded" --arg event "$escape_event path=$path" '.units[] as $u | select($u.id != $id
      and any($u.history[]?; .stage == "merged" and .at <= $at)
      and any($u.history[]?; .stage == "review-skip" and .result == $u.approved_sha and .at <= $at and ((.paths // []) | index($path) != null))
      and (any($u.history[]?; .stage == "review-skip-escape" and .result == $event) | not)) | $u.id' "$UNITS")
  done < <(jqf -r '[.paths[]?.path] | unique | .[]' <<<"$invalidations")
  set_unit "$id" ".risk_tiered_escape_recorded_sha=$(js "$head")"
  say "risk-tiered-review: escape paths recorded unit=$id head=$head paths=$paths_json"
}
