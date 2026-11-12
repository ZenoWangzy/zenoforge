# Fresh GitHub read of a predecessor (#536): the dependency cache refreshes only every DEP_CHECK_SECONDS, so a stale CLOSED frees nothing until one fresh read says so.
dep_fresh_state() { # predecessor → the fresh GitHub state, empty when unreadable; an OPEN or empty read is memoized for DEP_CHECK_SECONDS so a hold costs one read per window
  local f="$A/dep-fresh-$1" stamp memo fresh
  if [[ -f "$f" ]] && read -r stamp memo < "$f" && [[ "$stamp" =~ ^[0-9]+$ ]] && (( NOW_EPOCH - stamp < ${DEP_CHECK_SECONDS:-600} )); then printf '%s' "$memo"; return 0; fi
  fresh="$(dep_states "$1" 2>/dev/null | awk -F'\t' -v d="$1" '$1 == d { print $2; exit }' || true)"
  if [[ "$fresh" != CLOSED && "$fresh" != MERGED ]]; then printf '%s %s\n' "$NOW_EPOCH" "$fresh" > "$f"; fi
  printf '%s' "$fresh"
}
dep_fresh_closed() { # predecessor → 0 only when a fresh GitHub read says CLOSED or MERGED; an unreadable read is not closed
  local fresh; fresh="$(dep_fresh_state "$1")"
  [[ "$fresh" == CLOSED || "$fresh" == MERGED ]]
}
