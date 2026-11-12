# Footprint memo and cache helpers, sourced by footprint.sh. scheduler_footprint costs about 24 processes per row; these keep
# its per-pass result and the owner scopes it fills (inside dispatch_pending only, TICK_FOOTPRINT_MAIN set).
# scheduler_footprint is a pure function of the unit row, the issue state file and origin/main, and costs about 24 processes. One dispatch
# pass asked for it 3 to 4 times per candidate and once per live owner at every fresh snapshot. TICK_FOOTPRINT_MAIN (set by dispatch_pending;
# empty anywhere else, which bypasses the memo) keys the rows to the main they were filtered against.
declare -gA TICK_FOOTPRINT_SCOPE_MEMO=()
TICK_FOOTPRINT_MAIN=''
TICK_FOOTPRINT_HOT_CONFLICT_PATHS='[]'
TICK_FOOTPRINT_HOT_CONFLICT_PATHS_LOADED=false
footprint_hot_conflict_paths_load() {
  [[ "$TICK_FOOTPRINT_HOT_CONFLICT_PATHS_LOADED" == true ]] && return 0
  local archive_file now rc paths
  archive_file="$(mktemp)" || return 1
  if jqf_optional_file "${UNITS_ARCHIVE:-}" -c 'if type == "object" and (.units | type) == "array" then . else error("invalid archive") end' > "$archive_file"; then
    :
  else
    rc=$?
    rm -f -- "$archive_file"
    if (( rc == 64 )); then
      archive_file="$(mktemp)" || return 1
      printf '%s\n' '{"units":[]}' > "$archive_file" || { rm -f -- "$archive_file"; return 1; }
    else
      TICK_FOOTPRINT_HOT_CONFLICT_PATHS='[]'; TICK_FOOTPRINT_HOT_CONFLICT_PATHS_LOADED=true
      say "footprint hot-conflict paths unavailable rc=$rc paths=none"
      return 0
    fi
  fi
  now="$(date -u +%s)" || { rm -f -- "$archive_file"; return 1; }
  TICK_FOOTPRINT_HOT_CONFLICT_PATHS="$(jqf -c --argjson now "$now" --slurpfile live "$UNITS" --slurpfile archive "$archive_file" '
    (reduce (($archive[0].units // []) + ($live[0].units // []))[] as $unit ({}; .[$unit.id] = $unit) | [.[]]) as $units
    | [$units[] | (.history // [])[]? | select(.stage == "merge-conflict")
        | (try (.at | fromdateiso8601) catch null) as $at | select($at != null and $now - 86400 <= $at and $at <= $now)
        | (.conflict_files // "") as $files | select(($files | type) == "string")
        | select(($files | startswith("unavailable") or startswith("none ")) | not)
        | ($files | sub(" count=[0-9]+$"; "") | split(",") | map(gsub("^\\s+|\\s+$"; "")) | unique[]) as $path
        | select($path != "") | $path]
    | group_by(.) | map(select(length >= 3) | .[0]) | sort' <<< '{}')" || {
      rc=$?; rm -f -- "$archive_file"
      TICK_FOOTPRINT_HOT_CONFLICT_PATHS='[]'; TICK_FOOTPRINT_HOT_CONFLICT_PATHS_LOADED=true
      say "footprint hot-conflict paths unavailable rc=$rc paths=none"
      return 0
    }
  rm -f -- "$archive_file"
  TICK_FOOTPRINT_HOT_CONFLICT_PATHS_LOADED=true
  paths="$(jqf -r 'if length == 0 then "none" else join(",") end' <<<"$TICK_FOOTPRINT_HOT_CONFLICT_PATHS")" || paths=unavailable
  say "footprint hot-conflict paths window=24h threshold=3 paths=$paths"
}
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
