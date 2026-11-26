# ---------- Intake priority judge station (scheduler.sh --intake-judge) ----------
intake_judge_fresh() { # 0 = a station pass started within the freshness window, so the tick skips its fallback judge
  local at fresh="${AUTOPI_INTAKE_JUDGE_FRESH_SECONDS:-1800}"
  [[ "$fresh" =~ ^[0-9]+$ ]] || fresh=1800
  at="$(cat "$A/.intake-judge-epoch" 2>/dev/null)"
  [[ "$at" =~ ^[0-9]+$ ]] && (( $(date +%s) - at < fresh ))
}

intake_judge_claim_begin() { # issue number, stale seconds; atomically claim one judge call
  local number="$1" stale_after="${2:-${AUTOPI_INTAKE_JUDGE_KILL_SECONDS:-1200}}" claims="$A/.intake-judge-claims" claim started now token stale
  [[ "$number" =~ ^[1-9][0-9]*$ ]] || return 1
  [[ "$stale_after" =~ ^[1-9][0-9]*$ ]] || stale_after=1200
  mkdir -p -- "$claims" || return 1
  claim="$claims/$number"
  if ! mkdir -- "$claim" 2>/dev/null; then
    started="$(cat "$claim/start" 2>/dev/null || true)"
    started="${started%%$'\t'*}"
    if [[ ! "$started" =~ ^[0-9]+$ ]]; then
      started="$(python3 -c 'import os,sys; print(int(os.stat(sys.argv[1]).st_mtime))' "$claim" 2>/dev/null || true)"
    fi
    now="$(date +%s)"
    [[ "$started" =~ ^[0-9]+$ ]] && (( now >= started && now - started >= stale_after )) || return 1
    stale="$claims/$number.stale.$BASHPID.$RANDOM"
    mv -- "$claim" "$stale" 2>/dev/null || return 1
    rm -rf -- "$stale"
    mkdir -- "$claim" 2>/dev/null || return 1
  fi
  now="$(date +%s)"
  token="$now:$BASHPID:$RANDOM"
  if ! printf '%s\t%s\n' "$now" "$token" >"$claim/start"; then
    rm -rf -- "$claim"
    return 1
  fi
  INTAKE_JUDGE_CLAIM_PATH="$claim" INTAKE_JUDGE_CLAIM_TOKEN="$token"
}

intake_judge_claim_end() {
  [[ -n "${INTAKE_JUDGE_CLAIM_PATH:-}" && -n "${INTAKE_JUDGE_CLAIM_TOKEN:-}" ]] || return 0
  [[ "$(cut -f2- "$INTAKE_JUDGE_CLAIM_PATH/start" 2>/dev/null)" == "$INTAKE_JUDGE_CLAIM_TOKEN" ]] \
    && rm -rf -- "$INTAKE_JUDGE_CLAIM_PATH"
  INTAKE_JUDGE_CLAIM_PATH="" INTAKE_JUDGE_CLAIM_TOKEN=""
}

intake_judge_station_query_candidates() {
  local labels label repo
  local -a label_rows=()
  labels="$(jqf -r '[((.issue_intake.labels // [])[]), ((.issue_intake.product_labels // ["ready-for-agent"])[])] | unique | .[]' <<<"$CFG")" || return 1
  while IFS= read -r label; do [[ -z "$label" ]] || label_rows+=("$label"); done <<<"$labels"
  (( ${#label_rows[@]} > 0 )) || { printf '[]\n'; return 0; }
  repo="${REPO:-${ZF_REPO:-}}"
  if [[ -z "$repo" ]]; then scheduler_lib_context || return 1; repo="$SCHEDULER_LIB_REPO"; fi
  [[ -n "$repo" ]] || return 1
  issue_rest_list_labels_context "$repo" open 200 gh "${label_rows[@]}"
}

intake_judge_station_raw_candidates() { # Share one bounded candidate scan across station passes; successful calls consume rows below.
  local cache="$A/.intake-judge-candidates.json" consumed="$A/.intake-judge-consumed.tsv" now query_started query_file cache_tmp consumed_numbers marker_cutoff
  if [[ -s "$cache" ]] \
    && jqf -e --argjson now "$(date +%s)" '.schema == 1 and (.created_at | type) == "number" and $now >= .created_at and $now - .created_at <= 600 and (.rows | type) == "array"' "$cache" >/dev/null 2>&1; then
    jqf -c '.rows' "$cache"
    return
  fi
  query_started="$(date +%s)"
  query_file="$(mktemp "${TMPDIR:-/tmp}/intake-judge-candidates.XXXXXX")" || return 1
  if ! intake_judge_station_query_candidates >"$query_file" || ! jqf -e 'type == "array"' "$query_file" >/dev/null 2>&1; then
    rm -f -- "$query_file"
    return 1
  fi
  now="$(date +%s)"
  marker_cutoff=$(( query_started < now - 600 ? query_started : now - 600 ))
  cache_tmp="$cache.tmp.$BASHPID.$RANDOM"
  if ! (
    exec 9>"$cache.lock" || exit 1
    flock -x 9 || exit 1
    consumed_numbers='[]'
    if [[ -s "$consumed" ]]; then
      consumed_numbers="$(awk -F '\t' -v cutoff="$marker_cutoff" '$1 ~ /^[1-9][0-9]*$/ && $2 ~ /^[0-9]+$/ && $2 >= cutoff {print $1}' "$consumed" 2>/dev/null | sort -nu | jqf -Rsc 'split("\n") | map(tonumber?) | map(select(. != null))')" || exit 1
    fi
    jqf -n --argjson created_at "$now" --argjson consumed "$consumed_numbers" --slurpfile rows "$query_file" \
      '{schema:1,created_at:$created_at,rows:[$rows[0][] | select(.number as $number | ($consumed | index($number)) == null)]}' >"$cache_tmp" \
      && mv -f -- "$cache_tmp" "$cache" || { rm -f -- "$cache_tmp"; exit 1; }
  ); then
    rm -f -- "$cache_tmp" "$query_file"
    return 1
  fi
  jqf -c '.rows' "$cache"
  rm -f -- "$query_file"
}

intake_judge_station_consume_candidate() { # Record completion and remove the row, even if a candidate refresh is in flight.
  local number="$1" cache="$A/.intake-judge-candidates.json" consumed="$A/.intake-judge-consumed.tsv" now tmp="$A/.intake-judge-candidates.json.tmp.$BASHPID.$RANDOM" consumed_tmp="$A/.intake-judge-consumed.tsv.tmp.$BASHPID.$RANDOM"
  [[ "$number" =~ ^[1-9][0-9]*$ ]] || return 1
  now="$(date +%s)"
  (
    exec 9>"$cache.lock" || exit 1
    flock -x 9 || exit 1
    {
      awk -F '\t' -v cutoff="$((now - 600))" -v skip="$number" '$1 ~ /^[1-9][0-9]*$/ && $2 ~ /^[0-9]+$/ && $2 >= cutoff && $1 != skip {latest[$1]=$2} END {for (n in latest) print n "\t" latest[n]}' "$consumed" 2>/dev/null
      printf '%s\t%s\n' "$number" "$now"
    } >"$consumed_tmp" && mv -f -- "$consumed_tmp" "$consumed" || { rm -f -- "$consumed_tmp"; exit 1; }
    if [[ -s "$cache" ]]; then
      if ! jqf --argjson number "$number" '.rows |= map(select(.number != $number))' "$cache" >"$tmp"; then
        rm -f -- "$tmp"
        exit 1
      fi
      mv -f -- "$tmp" "$cache" || { rm -f -- "$tmp"; exit 1; }
    fi
  )
}

intake_judge_station_claim_candidate() { # Serialize snapshot validation with tick consumption before claiming the issue.
  local number="$1" stale_after="$2" cache="$A/.intake-judge-candidates.json" consumed="$A/.intake-judge-consumed.tsv" rc
  exec 9>"$cache.lock" || return 1
  flock -x 9 || { exec 9>&-; return 1; }
  if awk -F '\t' -v number="$number" -v cutoff="$(( $(date +%s) - 600 ))" '$1==number && $2 ~ /^[0-9]+$/ && $2 >= cutoff {found=1} END {exit !found}' "$consumed" 2>/dev/null \
    || ! jqf -e --argjson number "$number" 'any(.rows[]?; .number == $number)' "$cache" >/dev/null 2>&1; then
    flock -u 9
    exec 9>&-
    return 1
  fi
  intake_judge_claim_begin "$number" "$stale_after" || { rc=$?; flock -u 9; exec 9>&-; return "$rc"; }
  flock -u 9
  exec 9>&-
}

intake_judge_station_candidates() {
  local raw filtered issue number
  raw="$(intake_judge_station_raw_candidates)" || return 1
  jqf -e 'type == "array"' <<<"$raw" >/dev/null || return 1
  filtered="$(jqf -c 'unique_by(.number)[]' <<<"$raw")" || return 1
  {
    while IFS= read -r issue; do
      [[ -n "$issue" ]] || continue
      intake_priority_open_unlabelled_issue "$issue" || continue
      number="$(jqf -r '.number' <<<"$issue")"
      [[ "$number" =~ ^[1-9][0-9]*$ ]] || continue
      intake_priority_open_unlabelled_cooldown "$number" && continue
      printf '%s\n' "$issue"
    done <<<"$filtered"
  } | jqf -sc 'sort_by(.number)' # GitHub issue numbers preserve creation order for both cached rows and live queries.
}

intake_judge_station_worker() { # issue file, result dir, repo, stale seconds
  local issue_file="$1" result_dir="$2" repo="$3" stale_after="$4" issue number judged=0 applied=0 fallback=0 deferred=0 rc=0 labels gh_limit="${AUTOPI_GH_TIMEOUT_SECONDS:-120}"
  issue="$(cat -- "$issue_file")" || return 1
  number="$(jqf -r '.number' <<<"$issue")" || return 1
  if ! intake_judge_station_claim_candidate "$number" "$stale_after"; then
    deferred=1
  else
    judged=1
    intake_priority_judge_issue "$issue" "$number" "$repo" || rc=$?
    [[ "$INTAKE_PRIORITY_JUDGE_APPLIED" != true ]] || applied=1
    if [[ "$INTAKE_PRIORITY_JUDGE_APPLIED" == true ]]; then
      [[ "$gh_limit" =~ ^[1-9][0-9]*$ ]] || gh_limit=120
      labels="$(gh_timeout -k 1 "${gh_limit}s" issue view "$number" --repo "$repo" --json labels 2>/dev/null)" || labels=""
      jqf -e 'any(.labels[]?; if type == "string" then . == "judge:fallback" else .name == "judge:fallback" end)' <<<"$labels" >/dev/null 2>&1 \
        && INTAKE_PRIORITY_JUDGE_FALLBACK=true
    fi
    [[ "$INTAKE_PRIORITY_JUDGE_FALLBACK" != true ]] || fallback=1
    intake_judge_claim_end
  fi
  printf '%s\t%s\t%s\t%s\t%s\n' "$judged" "$applied" "$fallback" "$deferred" "$rc" >"$result_dir/$number.result"
  return "$rc"
}

intake_judge_station_pass() {
  local lock="${INTAKE_JUDGE_LOCK:-$A/.intake-judge-station.lock}" old rc=0 started=$SECONDS cap parallel stale_after repo candidates selected total deferred=0 judged=0 applied=0 fallback=0 work_dir result_dir issue number result j a f d w xargs_rc=0 rest_used
  local -a issue_files=() issue_numbers=()
  cd "$ROOT" || { say "scheduler: root $ROOT unavailable"; return 1; }
  mkdir -p -- "$A" || return 1
  if ! mkdir -- "$lock" 2>/dev/null; then
    old="$(cat "$lock/pid" 2>/dev/null || true)"
    if [[ "$old" =~ ^[0-9]+$ ]] && kill -0 "$old" 2>/dev/null; then return 0; fi
    rm -rf -- "$lock"
    mkdir -- "$lock" 2>/dev/null || return 0
  fi
  printf '%s\n' "$$" >"$lock/pid"
  date +%s >"$A/.intake-judge-epoch"
  tick_gh_calls_begin
  if [[ -e "$PAUSE_FILE" ]]; then
    say "intake-judge paused by $PAUSE_FILE: no pass"
  elif ! state_schema_ok; then
    say 'state schema invalid; intake-judge stopped before external actions'
    rc=2
  else
    cap="${ZF_INTAKE_JUDGE_PER_PASS:-25}"
    [[ "$cap" =~ ^[0-9]+$ ]] || cap=25
    cap=$((10#$cap))
    parallel="${ZF_INTAKE_JUDGE_PARALLEL:-4}"
    [[ "$parallel" =~ ^[0-9]+$ ]] || parallel=4
    parallel=$((10#$parallel))
    (( parallel > 0 )) || parallel=4
    stale_after="${AUTOPI_INTAKE_JUDGE_KILL_SECONDS:-1200}"
    [[ "$stale_after" =~ ^[1-9][0-9]*$ ]] || stale_after=1200
    repo="${REPO:-${ZF_REPO:-}}"
    if [[ -z "$repo" ]]; then
      rc=1
    elif ! candidates="$(intake_judge_station_candidates)"; then
      rc=1
    else
      total="$(jqf -r 'length' <<<"$candidates")" || total=0
      selected="$(jqf -c --argjson cap "$cap" 'sort_by(.number) | .[0:$cap]' <<<"$candidates")" || { selected='[]'; rc=1; }
      deferred=$((total - $(jqf -r 'length' <<<"$selected")))
      work_dir="$(mktemp -d "${TMPDIR:-/tmp}/intake-judge-pass.XXXXXX")" || { work_dir=""; rc=1; }
      if [[ -n "$work_dir" ]]; then
        result_dir="$work_dir/results"
        mkdir -p -- "$result_dir" || rc=1
        while IFS= read -r issue; do
          [[ -n "$issue" ]] || continue
          number="$(jqf -r '.number' <<<"$issue")"
          [[ "$number" =~ ^[1-9][0-9]*$ ]] || { rc=1; continue; }
          printf '%s\n' "$issue" >"$work_dir/$number.json" || { rc=1; continue; }
          issue_files+=("$work_dir/$number.json")
          issue_numbers+=("$number")
        done < <(jqf -c '.[]' <<<"$selected")
        if (( ${#issue_files[@]} > 0 )); then
          printf '%s\0' "${issue_files[@]}" | A="$A" HERE="$HERE" LOG="$LOG" STAMP="$STAMP" REPO="$repo" \
            INTAKE_JUDGE_RESULT_DIR="$result_dir" INTAKE_JUDGE_STALE_SECONDS="$stale_after" \
            xargs -0 -n 1 -P "$parallel" bash -c '
              jqf() { command jq "$@"; }
              source "$HERE/../lib.d/transport.sh" || exit 1
              source "$HERE/scheduler.d/intake-steps.sh" || exit 1
              source "$HERE/scheduler.d/intake-judge-station.sh" || exit 1
              intake_judge_station_worker "$1" "$INTAKE_JUDGE_RESULT_DIR" "$REPO" "$INTAKE_JUDGE_STALE_SECONDS"
            ' intake-judge-worker || xargs_rc=$?
        fi
        (( xargs_rc == 0 )) || rc=1
        for number in "${issue_numbers[@]}"; do
          result="$result_dir/$number.result"
          if [[ ! -s "$result" ]]; then deferred=$((deferred + 1)); rc=1; continue; fi
          IFS=$'\t' read -r j a f d w <"$result"
          judged=$((judged + ${j:-0})); applied=$((applied + ${a:-0})); fallback=$((fallback + ${f:-0})); deferred=$((deferred + ${d:-0}))
          [[ "${w:-0}" == 0 ]] || rc=1
        done
        rm -rf -- "$work_dir"
      fi
    fi
  fi
  rest_used="$(tick_rest_usage_summary)"
  say "intake-judge done secs=$((SECONDS - started)) judged=$judged applied=$applied fallback=$fallback deferred=$deferred rc=$rc $rest_used"
  rm -f -- "$GH_TICK_CALLS_FILE" "$TICK_INTAKE_READS_FILE" "$TICK_INTAKE_READS_FILE.lock" "$TICK_INTAKE_READS_FILE.reached" 2>/dev/null || :
  [[ "$(cat "$lock/pid" 2>/dev/null)" != "$$" ]] || rm -rf -- "$lock"
  return "$rc"
}

intake_judge_station_tick() { intake_judge_station_pass "$@"; }
