# Footprint memo and cache helpers, sourced by footprint.sh. scheduler_footprint costs about 24 processes per row; these keep
# its per-pass result and the owner scopes it fills (inside dispatch_pending only, TICK_FOOTPRINT_MAIN set).
# scheduler_footprint is a pure function of the unit row, the issue state file and origin/main, and costs about 24 processes. One dispatch
# pass asked for it 3 to 4 times per candidate and once per live owner at every fresh snapshot. TICK_FOOTPRINT_MAIN (set by dispatch_pending;
# empty anywhere else, which bypasses the memo) keys the rows to the main they were filtered against.
declare -gA TICK_FOOTPRINT_SCOPE_MEMO=()
TICK_FOOTPRINT_MAIN=''
footprint_scope_for() { # unit-json var-name -> sets the variable to scheduler_footprint's scope; fills the memo only in the caller's shell
  local key="$TICK_FOOTPRINT_MAIN|$1" out
  if [[ -z "$TICK_FOOTPRINT_MAIN" ]]; then
    out="$(scheduler_footprint "$1")" || return 1
  elif [[ -n "${TICK_FOOTPRINT_SCOPE_MEMO[$key]+set}" ]]; then
    out="${TICK_FOOTPRINT_SCOPE_MEMO[$key]}"
  else
    out="$(scheduler_footprint "$1")" || return 1
    TICK_FOOTPRINT_SCOPE_MEMO["$key"]="$out"
  fi
  printf -v "$2" %s "$out"
}
footprint_drop_check_scope_cache() {
  TICK_CHECK_SCOPE_SOURCE=()
  TICK_CHECK_SCOPE=()
  TICK_OLD_SCOPE=()
  TICK_HOTSPOT_COUNTS=()
}
footprint_active_rows() { # ledger rows that hold a live implement/repair worker, with the worker's workdir
  jqf -c --slurpfile w "$WORKERS" --argjson live "$FOOTPRINT_LIVE_WRITER_STAGES" '
    [.units[] | . as $u
      | select(.stage as $s | $live | index($s) != null)
      | select(any($w[0].workers[]; .unit==$u.id and .harvested!=true and .lease_expired!=true and (.type | IN("implement","repair"))))
      | . + {live_workdir: ([$w[0].workers[] | select(.unit==$u.id and .harvested!=true and .lease_expired!=true and (.type | IN("implement","repair"))) | .workdir] | first)}]' "$UNITS"
}
# Every snapshot is taken in $( ), where the memo cannot be filled: compute the owners' scopes here, in the caller's shell, first. A repeat
# snapshot of unchanged owners then finds them all in the memo.
footprint_prime_owner_scopes() {
  local other discard
  [[ -n "$TICK_FOOTPRINT_MAIN" ]] || return 0
  while IFS= read -r other; do
    footprint_scope_for "$other" discard || return 0
  done < <(footprint_active_rows | jqf -c '.[]')
}
footprint_cache_prune() { # main sha: keep only entries of the current main, then the newest FOOTPRINT_CACHE_KEEP
  local dir="$A/footprint-cache" f n=0
  [[ "$FOOTPRINT_CACHE_PRUNED" != "$1" ]] || return 0
  FOOTPRINT_CACHE_PRUNED="$1"
  rm -f -- "$dir"/.*.tmp 2>/dev/null || :
  for f in "$dir"/*; do
    [[ -e "$f" ]] || continue
    [[ "${f##*/}" == "$1-"*.json ]] || rm -f -- "$f"
  done
  for f in $(ls -t "$dir" 2>/dev/null); do
    n=$((n + 1)); (( n <= FOOTPRINT_CACHE_KEEP )) || rm -f -- "$dir/$f"
  done
}
