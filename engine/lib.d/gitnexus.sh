_AGENT_LIB_DIR="${_AGENT_LIB_DIR:-$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)}" # a module sourced without lib.sh (land snapshot) still finds the lib dir

gitnexus_refresh_minimum_available_kb() {
  printf '%s\n' "$((3 * 1024 * 1024))"
}


gitnexus_cihost_index_refresh() {
  local helper="${GITNEXUS_CIHOST_INDEX_SCRIPT:-${_AGENT_LIB_DIR}/gitnexus-cihost-index.sh}"
  timeout 40m bash "$helper" refresh "$@"
}


gitnexus_available_memory_kb() {
  local key value unit
  while read -r key value unit; do
    if [ "$key" = "MemAvailable:" ]; then
      printf '%s\n' "$value"
      return 0
    fi
  done < /proc/meminfo
  return 1
}


gitnexus_index_matches_origin_main() {
  local repo_dir="$1" origin_main_sha indexed indexed_at indexed_epoch now age commits_behind
  origin_main_sha="$(git -C "$repo_dir" rev-parse origin/main 2>/dev/null || echo unknown)"
  [[ "$origin_main_sha" =~ ^[0-9a-f]{40}$ ]] || return 1
  indexed="$(jq -r '.lastCommit // empty' "$repo_dir/.gitnexus/meta.json" 2>/dev/null)" || return 1
  [[ -n "$indexed" ]] && git -C "$repo_dir" merge-base --is-ancestor "$indexed" "$origin_main_sha" 2>/dev/null || return 1
  commits_behind="$(git -C "$repo_dir" rev-list --count "$indexed..$origin_main_sha" 2>/dev/null)" || return 1
  [[ "$commits_behind" =~ ^[0-9]+$ ]] && (( commits_behind <= 20 )) || return 1
  indexed_at="$(jq -r '.indexedAt // empty' "$repo_dir/.gitnexus/meta.json" 2>/dev/null)" || return 1
  indexed_epoch="$(agent_epoch -u "$indexed_at" 2>/dev/null)" || return 1
  now="$(date +%s 2>/dev/null)" || return 1
  age=$((now - indexed_epoch))
  (( age >= 0 )) || age=0
  (( age <= 3600 ))
}


gitnexus_product_lag() {
  local repo_dir="$1" now="${2:-$(date +%s)}" origin indexed count first_missed first_epoch age
  GITNEXUS_PRODUCT_LAG_COMMITS=unknown
  GITNEXUS_PRODUCT_LAG_HOURS=unknown
  GITNEXUS_PRODUCT_LAG_AGE_SECONDS=unknown
  GITNEXUS_PRODUCT_LAG_INDEXED_SHA=""
  GITNEXUS_PRODUCT_LAG_ORIGIN_SHA=""
  GITNEXUS_PRODUCT_LAG_FIRST_MISSED_SHA=""
  GITNEXUS_PRODUCT_LAG_FIRST_MISSED_EPOCH=""
  origin="$(git -C "$repo_dir" rev-parse --verify -q refs/remotes/origin/main 2>/dev/null)" || return 1
  indexed="$(jq -r '.lastCommit // empty' "$repo_dir/.gitnexus/meta.json" 2>/dev/null)" || return 1
  [ -n "$indexed" ] || return 1
  git -C "$repo_dir" merge-base --is-ancestor "$indexed" "$origin" 2>/dev/null || return 1
  GITNEXUS_PRODUCT_LAG_INDEXED_SHA="$indexed"
  GITNEXUS_PRODUCT_LAG_ORIGIN_SHA="$origin"
  if git -C "$repo_dir" diff --quiet "$indexed" "$origin" -- packages migrations; then
    GITNEXUS_PRODUCT_LAG_COMMITS=0
    GITNEXUS_PRODUCT_LAG_HOURS=0
    GITNEXUS_PRODUCT_LAG_AGE_SECONDS=0
    return 0
  fi
  count="$(git -C "$repo_dir" rev-list --count "$indexed..$origin" -- packages migrations 2>/dev/null)" || return 1
  first_missed="$(git -C "$repo_dir" log --reverse --format=%H "$indexed..$origin" -- packages migrations 2>/dev/null | sed -n '1p')" || return 1
  first_epoch="$(git -C "$repo_dir" show -s --format=%ct "$first_missed" 2>/dev/null)" || return 1
  [[ "$count" =~ ^[0-9]+$ && "$first_epoch" =~ ^[0-9]+$ && "$now" =~ ^[0-9]+$ ]] || return 1
  age=$((now - first_epoch))
  (( age >= 0 )) || age=0
  GITNEXUS_PRODUCT_LAG_COMMITS="$count"
  GITNEXUS_PRODUCT_LAG_HOURS=$((age / 3600))
  GITNEXUS_PRODUCT_LAG_AGE_SECONDS="$age"
  GITNEXUS_PRODUCT_LAG_FIRST_MISSED_SHA="$first_missed"
  GITNEXUS_PRODUCT_LAG_FIRST_MISSED_EPOCH="$first_epoch"
}


# zcode-cli rewrites its argv to "zcode-cli" (2026-10-07), so zcode hand agents are found by
# the environment dispatch.sh gives them. Prints "<pid>\t<agent name>", one line per agent
# (its lowest PID), for agents whose ZF_REPO_DIR is under <worktree root>; optional <name>.
# ponytail: a codex agent running a command with "zcode" in its argv can be listed for a moment.
hand_zcode_agents() {
  local root="$1" name="${2:-}" pid
  for pid in $(pgrep -f zcode 2>/dev/null | sort -n); do
    tr '\0' '\n' 2>/dev/null < "/proc/$pid/environ" \
      | awk -v pid="$pid" -v root="$root" -v want="$name" -F= '
          $1 == "ZF_REPO_DIR" && index($0, "ZF_REPO_DIR=" root) == 1 { under = 1 }
          $1 == "ZF_AGENT_NAME" { agent = substr($0, 18) }
          END { if (under && agent != "" && (want == "" || agent == want)) print pid "\t" agent }'
    # A zcode launched without that environment is still known by its original argv.
    [ -n "$name" ] || tr '\0' ' ' 2>/dev/null < "/proc/$pid/cmdline" \
      | awk -v pid="$pid" -v root="$root" '$0 ~ /zcode[^[:space:]]* -p / && index($0, "--cwd " root) > 0 { print pid "\tpid:" pid }'
  done | awk -F'\t' '!seen[$1]++ && !seen[$2]++'
}


hand_agent_process_count() {
  local worktree_root="${1:-${ZF_WORKTREE_ROOT:-$HOME/wt}/}" codex_count zcode_count
  local worktrees scope="${2:-all}" pid worktree production_rows production_worktrees="" unit_name
  local -a records
  worktrees="$(hand_codex_worktrees "$worktree_root")" || return 1
  if [ "$scope" = ordinary-hand ] || [ "$scope" = finishing ]; then
    if [ "$scope" = finishing ]; then
      printf '%s' "$production_worktrees" | awk 'NF && !seen[$0]++ {n++} END {print n+0}'
      return 0
    fi
    # Pipeline issue units have their own cap; production admission uses memory/load guards.
    worktrees="$(awk -v root="${worktree_root%/}/" '
      { name=substr($0,length(root)+1) }
      name !~ /^issue-[0-9]+$/ { print }' <<< "$worktrees")"
    records=("${ZF_NIGHT_DIR:-$AGENT_HOME/night}"/hand-registry/*.json)
    production_rows="$(jq -rs '
      .[] | select(.role == "production" and (.pid | type == "number") and (.worktree | type == "string"))
      | [.pid,.worktree] | @tsv' "${records[@]}" 2>/dev/null || true)"
    while IFS=$'\t' read -r pid worktree; do
      [ -n "$pid" ] || continue
      if hand_codex_pid_matches "$pid" "$worktree"; then
        production_worktrees+="$worktree"$'\n'
      fi
    done <<< "$production_rows"
    worktrees="$(awk 'FILENAME==ARGV[1] { if (NF) production[$0]=1; next } !($0 in production)' \
      <(printf '%s' "$production_worktrees") <(printf '%s\n' "$worktrees"))"
  fi
  codex_count="$(awk 'NF {n++} END {print n+0}' <<< "$worktrees")"
  zcode_count="$(hand_zcode_agents "$worktree_root" | wc -l)"
  echo $((codex_count + zcode_count))
}


# gitnexus_refresh_index_once <repo_dir> <expected_index_sha|target> <freshness_function>
# Returns success only when freshness is confirmed before or after refresh.
# GITNEXUS_REFRESH_OUTPUT carries analyzer/lock details for the existing
# non-fatal "NOT confirmed fresh" fallback at each caller.
gitnexus_refresh_index_once() {
  local repo_dir="$1" expected_sha="$2" freshness_function="$3" target_sha
  local lock_file="$AGENT_HOME/gitnexus-analyze.lock"
  local attempt_file="$AGENT_HOME/gitnexus-analyze-attempt"
  local throttle_file="$AGENT_HOME/gitnexus-analyze-last-start"
  local live_marker="$AGENT_HOME/gitnexus-analyze-guard-live-since"
  local memory_log="$AGENT_HOME/night/gitnexus-analyze-memory.tsv"
  local attempt_key lock_fd status=1 now available_kb previous_attempt previous_refresh
  local run_id sample_file sample_marker sampler_pid sampler_parent_pid sampler_status minimum_kb sample_kb wrapper_minimum_kb
  local analyzer_status ended_at freshness_checked_at indexed_at indexed_sha indexed_epoch index_age origin_main_sha commits_behind freshness_evidence
  local failure_detail failure_pair refresh_line
  GITNEXUS_REFRESH_OUTPUT=""

  if ! declare -F "$freshness_function" >/dev/null || [ -z "$expected_sha" ] || [ "$expected_sha" = "unknown" ]; then
    GITNEXUS_REFRESH_OUTPUT="checkout SHA or freshness check unavailable"
    return 1
  fi
  if ! mkdir -p "$AGENT_HOME" || ! exec {lock_fd}>"$lock_file"; then
    GITNEXUS_REFRESH_OUTPUT="could not open GitNexus refresh lock"
    return 1
  fi
  if ! flock -w "$GITNEXUS_REFRESH_LOCK_WAIT_SECONDS" "$lock_fd"; then
    GITNEXUS_REFRESH_OUTPUT="GitNexus refresh lock wait timed out after ${GITNEXUS_REFRESH_LOCK_WAIT_SECONDS}s"
    exec {lock_fd}>&-
    return 1
  fi

  if [ ! -s "$live_marker" ]; then
    date +%s > "$live_marker" 2>/dev/null || true
  fi

  # The origin-main path targets its remote ref; checkout HEAD may lag behind it.
  if [ "$freshness_function" = "gitnexus_index_matches_origin_main" ]; then
    target_sha="$(git -C "$repo_dir" rev-parse --verify refs/remotes/origin/main 2>/dev/null || echo unknown)"
  else
    target_sha="$(git -C "$repo_dir" rev-parse HEAD 2>/dev/null || echo unknown)"
  fi
  if [ "$target_sha" = "unknown" ]; then
    GITNEXUS_REFRESH_OUTPUT="checkout SHA unavailable"
  else
    attempt_key="$repo_dir $target_sha"
  fi

  if [ "$target_sha" = "unknown" ]; then
    :
  elif "$freshness_function" "$repo_dir" "$expected_sha"; then
    GITNEXUS_REFRESH_OUTPUT="index freshness already confirmed for $expected_sha"
    status=0
  else
    now="$(date +%s 2>/dev/null || true)"
    if ! [[ "$now" =~ ^[0-9]+$ ]]; then
      GITNEXUS_REFRESH_OUTPUT="clock unavailable; deferring GitNexus refresh"
    else
      previous_refresh="$(cat "$throttle_file" 2>/dev/null || true)"
      if [[ "$previous_refresh" =~ ^[0-9]+$ ]] \
        && (( now - previous_refresh < GITNEXUS_REFRESH_MIN_INTERVAL_SECONDS )); then
        GITNEXUS_REFRESH_OUTPUT="refresh deferred by latest-wins throttle (${GITNEXUS_REFRESH_MIN_INTERVAL_SECONDS}s)"
      else
        available_kb="$(gitnexus_available_memory_kb 2>/dev/null || true)"
        wrapper_minimum_kb="$(gitnexus_refresh_minimum_available_kb 2>/dev/null || true)"
        if ! [[ "$wrapper_minimum_kb" =~ ^[0-9]+$ ]]; then
          GITNEXUS_REFRESH_OUTPUT="WSL GitNexus refresh memory floor unavailable; deferring refresh"
        elif ! [[ "$available_kb" =~ ^[0-9]+$ ]]; then
          GITNEXUS_REFRESH_OUTPUT="MemAvailable unavailable; deferring GitNexus refresh"
        elif (( available_kb < wrapper_minimum_kb )); then
          GITNEXUS_REFRESH_OUTPUT="MemAvailable $((available_kb / 1024))MB < 3072MB; deferring remote GitNexus refresh"
        else
          previous_attempt="$(cat "$attempt_file" 2>/dev/null || true)"
          if ! mkdir -p "$AGENT_HOME/night"; then
            GITNEXUS_REFRESH_OUTPUT="could not open GitNexus memory log directory"
          elif ! sample_file="$(mktemp "$AGENT_HOME/night/gitnexus-analyze-min.XXXXXX" 2>/dev/null)"; then
            GITNEXUS_REFRESH_OUTPUT="could not record GitNexus memory sample"
          elif ! sample_marker="$(mktemp "$AGENT_HOME/night/gitnexus-analyze-running.XXXXXX" 2>/dev/null)"; then
            rm -f "$sample_file"
            GITNEXUS_REFRESH_OUTPUT="could not start GitNexus memory sample"
          elif ! printf '%s\n' "$attempt_key" > "$attempt_file"; then
            rm -f "$sample_file" "$sample_marker"
            GITNEXUS_REFRESH_OUTPUT="could not record GitNexus refresh attempt"
          elif ! printf '%s\n' "$now" > "$throttle_file"; then
            if [ -n "$previous_attempt" ]; then printf '%s\n' "$previous_attempt" > "$attempt_file"; else rm -f "$attempt_file"; fi
            rm -f "$sample_file" "$sample_marker"
            GITNEXUS_REFRESH_OUTPUT="could not record GitNexus refresh throttle"
          elif ! printf '%s\n' "$available_kb" > "$sample_file"; then
            if [ -n "$previous_attempt" ]; then printf '%s\n' "$previous_attempt" > "$attempt_file"; else rm -f "$attempt_file"; fi
            if [ -n "$previous_refresh" ]; then printf '%s\n' "$previous_refresh" > "$throttle_file"; else rm -f "$throttle_file"; fi
            rm -f "$sample_file" "$sample_marker"
            GITNEXUS_REFRESH_OUTPUT="could not record GitNexus memory baseline"
          else
            run_id="${BASHPID:-$$}-$now"
            if ! printf 'start\t%s\t%s\t%s\n' "$run_id" "$now" "$target_sha" >> "$memory_log"; then
              if [ -n "$previous_attempt" ]; then printf '%s\n' "$previous_attempt" > "$attempt_file"; else rm -f "$attempt_file"; fi
              if [ -n "$previous_refresh" ]; then printf '%s\n' "$previous_refresh" > "$throttle_file"; else rm -f "$throttle_file"; fi
              rm -f "$sample_file" "$sample_marker"
            GITNEXUS_REFRESH_OUTPUT="could not log GitNexus refresh start"
            else
              sampler_parent_pid="${BASHPID:-$$}"
              (
                minimum_kb="$available_kb"
                sample_write_failed=0
                while [ -e "$sample_marker" ] && kill -0 "$sampler_parent_pid" 2>/dev/null; do
                  sample_kb="$(gitnexus_available_memory_kb 2>/dev/null || true)"
                  if [[ "$sample_kb" =~ ^[0-9]+$ ]] && (( sample_kb < minimum_kb )); then
                    minimum_kb="$sample_kb"
                    if ! printf '%s\n' "$minimum_kb" > "$sample_file"; then sample_write_failed=1; fi
                  fi
                  sleep 1
                done
                printf '%s\n' "$minimum_kb" > "$sample_file" || sample_write_failed=1
                (( sample_write_failed == 0 ))
              ) &
              sampler_pid=$!

              if GITNEXUS_REFRESH_OUTPUT="$(gitnexus_cihost_index_refresh "$repo_dir" "$target_sha" 2>&1)"; then
                analyzer_status=0
              else
                analyzer_status=$?
              fi
              rm -f "$sample_marker"
              if wait "$sampler_pid"; then sampler_status=0; else sampler_status=$?; fi
              minimum_kb="$(cat "$sample_file" 2>/dev/null || echo "$available_kb")"
              rm -f "$sample_file"
              ended_at="$(date +%s 2>/dev/null || echo "$now")"
              failure_detail=none
              if [ "$analyzer_status" -ne 0 ]; then
                failure_detail=""
                while IFS= read -r refresh_line; do
                  if [[ "$refresh_line" =~ gitnexus-refresh[[:space:]]stage=([a-z0-9-]+)[[:space:]]exit=([0-9]+) ]]; then
                    failure_pair="stage=${BASH_REMATCH[1]} exit=${BASH_REMATCH[2]}"
                    failure_detail="${failure_detail:+$failure_detail; }$failure_pair"
                  fi
                done <<< "$GITNEXUS_REFRESH_OUTPUT"
                if [ -z "$failure_detail" ]; then
                  failure_detail="stage=remote-index-refresh exit=$analyzer_status"
                  GITNEXUS_REFRESH_OUTPUT="${GITNEXUS_REFRESH_OUTPUT:+$GITNEXUS_REFRESH_OUTPUT$'\n'}gitnexus-refresh stage=remote-index-refresh exit=$analyzer_status"
                fi
                GITNEXUS_REFRESH_OUTPUT="${GITNEXUS_REFRESH_OUTPUT:+$GITNEXUS_REFRESH_OUTPUT$'\n'}GitNexus refresh failure: $failure_detail"
              fi
              printf 'run\t%s\t%s\t%s\t%s\t%s\t%s\t%s\trefresh-audit-v1\t%s\n' \
                "$run_id" "$ended_at" "$target_sha" "$available_kb" "$minimum_kb" \
                "$analyzer_status" "$sampler_status" "$failure_detail" >> "$memory_log" || true

              if [ "$sampler_status" -ne 0 ]; then
                GITNEXUS_REFRESH_OUTPUT="${GITNEXUS_REFRESH_OUTPUT:+$GITNEXUS_REFRESH_OUTPUT; }WSL MemAvailable sample did not cover the full refresh"
              elif ! [[ "$minimum_kb" =~ ^[0-9]+$ ]] || (( minimum_kb < wrapper_minimum_kb )); then
                GITNEXUS_REFRESH_OUTPUT="${GITNEXUS_REFRESH_OUTPUT:+$GITNEXUS_REFRESH_OUTPUT; }WSL MemAvailable fell below 3072MB during refresh"
              elif [ "$analyzer_status" -eq 0 ] && "$freshness_function" "$repo_dir" "$expected_sha"; then
                freshness_checked_at="$(date +%s 2>/dev/null || echo "$ended_at")"
                [[ "$freshness_checked_at" =~ ^[0-9]+$ ]] || freshness_checked_at="$ended_at"
                indexed_at="$(jq -r '.indexedAt // empty' "$repo_dir/.gitnexus/meta.json" 2>/dev/null || true)"
                indexed_sha="$(jq -r '.lastCommit // empty' "$repo_dir/.gitnexus/meta.json" 2>/dev/null || true)"
                indexed_epoch="$(agent_epoch -u "$indexed_at" 2>/dev/null || true)"
                index_age=unknown
                if [[ "$indexed_epoch" =~ ^[0-9]+$ ]]; then
                  index_age=$((freshness_checked_at - indexed_epoch))
                  (( index_age >= 0 )) || index_age=0
                fi
                origin_main_sha="$(git -C "$repo_dir" rev-parse --verify -q refs/remotes/origin/main 2>/dev/null || echo unknown)"
                commits_behind=unknown
                if [[ "$indexed_sha" =~ ^[0-9a-f]{40}$ && "$origin_main_sha" =~ ^[0-9a-f]{40}$ ]] \
                  && git -C "$repo_dir" merge-base --is-ancestor "$indexed_sha" "$origin_main_sha" 2>/dev/null; then
                  commits_behind="$(git -C "$repo_dir" rev-list --count "$indexed_sha..$origin_main_sha" 2>/dev/null || echo unknown)"
                  [[ "$commits_behind" =~ ^[0-9]+$ ]] || commits_behind=unknown
                fi
                freshness_evidence=0
                if { [[ "$index_age" =~ ^[0-9]+$ ]] && (( index_age <= 3600 )); } \
                  || { [[ "$commits_behind" =~ ^[0-9]+$ ]] && (( commits_behind <= 20 )); }; then
                  freshness_evidence=1
                fi
                if (( freshness_evidence == 1 )); then
                  status=0
                  printf 'confirmed\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
                    "$run_id" "$freshness_checked_at" "$expected_sha" "$indexed_at" "$indexed_sha" \
                    "$index_age" "$commits_behind" "$origin_main_sha" >> "$memory_log" || true
                else
                  GITNEXUS_REFRESH_OUTPUT="${GITNEXUS_REFRESH_OUTPUT:+$GITNEXUS_REFRESH_OUTPUT; }refreshed index freshness metadata could not be recorded"
                fi
              elif [ -z "$GITNEXUS_REFRESH_OUTPUT" ]; then
                GITNEXUS_REFRESH_OUTPUT="remote refresh completed but index freshness was not confirmed"
              fi
            fi
          fi
        fi
      fi
    fi
  fi

  flock -u "$lock_fd" 2>/dev/null || true
  exec {lock_fd}>&-
  return "$status"
}


# gitnexus_refresh_health_detail <memory_log> <now_epoch>
# Keep refresh freshness visible in HEALTH without turning a stale index
# into a page. Legacy run rows predate explicit confirmation records.
gitnexus_refresh_health_detail() {
  local memory_log="$1" now="$2" detail status=0 minimum_kb
  if ! [[ "$now" =~ ^[0-9]+$ ]]; then
    now="$(date +%s)"
  fi
  minimum_kb="$(gitnexus_refresh_minimum_available_kb)"
  if [ ! -r "$memory_log" ]; then
    printf 'last-confirmed-age-sec=unknown last-refresh-exit=unknown refresh-samples=0/20 refresh-successes=0 refresh-rate=unknown refresh-target=95%% refresh-memory-floor-violations=0\n'
    return 0
  fi
  if detail="$(awk -F '\t' -v now="$now" -v floor="$minimum_kb" '
    # Only tagged rows carry the per-refresh metadata required by this audit.
    $1 == "run" {
      if ($7 ~ /^[0-9]+$/) last_exit = $7
      if ($7 == 0 && $3 ~ /^[0-9]+$/) legacy_confirmed = $3
      if ($9 == "refresh-audit-v1") {
        attempts++
        ids[attempts] = $2
        run_exit[$2] = $7
        min_available[$2] = $6
        sampler_exit[$2] = $8
      }
    }
    $1 == "confirmed" && $3 ~ /^[0-9]+$/ {
      confirmed = $3
      if ($7 ~ /^[0-9]+$/) confirmed_age[$2] = $7
      if ($8 ~ /^[0-9]+$/) confirmed_behind[$2] = $8
      confirmed_ids[$2] = 1
    }
    END {
      refreshed = confirmed
      if (refreshed == "") refreshed = legacy_confirmed
      if (refreshed ~ /^[0-9]+$/) {
        age = now - refreshed
        if (age < 0) age = 0
      } else {
        age = "unknown"
      }
      if (last_exit == "") last_exit = "unknown"
      first = attempts - 19
      if (first < 1) first = 1
      samples = attempts - first + 1
      for (i = first; i <= attempts; i++) {
        id = ids[i]
        if (sampler_exit[id] != "0" || min_available[id] !~ /^[0-9]+$/ || min_available[id] < floor) memory_violations++
        fresh = (confirmed_age[id] ~ /^[0-9]+$/ && confirmed_age[id] <= 3600) \
          || (confirmed_behind[id] ~ /^[0-9]+$/ && confirmed_behind[id] <= 20)
        if (run_exit[id] == 0 && sampler_exit[id] == 0 \
          && min_available[id] ~ /^[0-9]+$/ && min_available[id] >= floor \
          && confirmed_ids[id] && fresh) successes++
      }
      rate = "unknown"
      if (samples >= 20) rate = int(successes * 100 / samples) "%"
      printf "last-confirmed-age-sec=%s last-refresh-exit=%s refresh-samples=%d/20 refresh-successes=%d refresh-rate=%s refresh-target=95%% refresh-memory-floor-violations=%d\n", age, last_exit, samples, successes, rate, memory_violations
      if (memory_violations > 0 || (samples >= 20 && successes * 100 < samples * 95)) exit 1
    }
  ' "$memory_log")"; then
    :
  else
    status=$?
  fi
  printf '%s' "$detail"
  return "$status"
}


# gitnexus_index_health <repo_dir> <memory_log> <now_epoch>
# A missing or unverifiable index stays UNKNOWN; stale indexed data stays visible to HEALTH.
gitnexus_index_health() {
  local repo_dir="$1" memory_log="$2" now="$3" indexed_at indexed_epoch indexed origin age behind failure_codes refresh_detail
  local refresh_quality_status=0
  GITNEXUS_INDEX_HEALTH_STATE=UNKNOWN
  GITNEXUS_INDEX_HEALTH_DETAIL="index-age-sec=unknown commits-behind=unknown refresh-failure-streak=unknown"
  [[ "$now" =~ ^[0-9]+$ ]] || now="$(date +%s 2>/dev/null || true)"
  [[ "$now" =~ ^[0-9]+$ ]] || return 0
  if refresh_detail="$(gitnexus_refresh_health_detail "$memory_log" "$now")"; then
    :
  else
    refresh_quality_status=$?
  fi
  failure_codes="$(gitnexus_recent_analyze_failure_codes "$memory_log" 2>/dev/null || true)"
  if [[ -n "$failure_codes" ]]; then
    GITNEXUS_INDEX_HEALTH_STATE=BROKEN
    GITNEXUS_INDEX_HEALTH_DETAIL="index-age-sec=unknown commits-behind=unknown refresh-failure-streak=3+ exit-codes=$failure_codes $refresh_detail"
  elif (( refresh_quality_status != 0 )); then
    GITNEXUS_INDEX_HEALTH_STATE=BROKEN
    GITNEXUS_INDEX_HEALTH_DETAIL="index-age-sec=unknown commits-behind=unknown refresh-failure-streak=below-3 refresh-quality=below-target-or-memory-floor $refresh_detail"
  else
    GITNEXUS_INDEX_HEALTH_DETAIL="index-age-sec=unknown commits-behind=unknown refresh-failure-streak=below-3 $refresh_detail"
  fi
  indexed_at="$(jq -r '.indexedAt // empty' "$repo_dir/.gitnexus/meta.json" 2>/dev/null)" || return 0
  indexed="$(jq -r '.lastCommit // empty' "$repo_dir/.gitnexus/meta.json" 2>/dev/null)" || return 0
  origin="$(git -C "$repo_dir" rev-parse --verify -q refs/remotes/origin/main 2>/dev/null)" || return 0
  [[ -n "$indexed" ]] && git -C "$repo_dir" merge-base --is-ancestor "$indexed" "$origin" 2>/dev/null || return 0
  indexed_epoch="$(agent_epoch -u "$indexed_at" 2>/dev/null)" || return 0
  behind="$(git -C "$repo_dir" rev-list --count "$indexed..$origin" 2>/dev/null)" || return 0
  [[ "$behind" =~ ^[0-9]+$ ]] || return 0
  age=$((now - indexed_epoch))
  (( age >= 0 )) || age=0
  GITNEXUS_INDEX_HEALTH_STATE=OK
  GITNEXUS_INDEX_HEALTH_DETAIL="index-age-sec=$age commits-behind=$behind refresh-failure-streak=below-3 $refresh_detail"
  if [[ -n "$failure_codes" ]]; then
    GITNEXUS_INDEX_HEALTH_STATE=BROKEN
    GITNEXUS_INDEX_HEALTH_DETAIL="index-age-sec=$age commits-behind=$behind refresh-failure-streak=3+ exit-codes=$failure_codes $refresh_detail"
  elif (( refresh_quality_status != 0 )); then
    GITNEXUS_INDEX_HEALTH_STATE=BROKEN
    GITNEXUS_INDEX_HEALTH_DETAIL="index-age-sec=$age commits-behind=$behind refresh-failure-streak=below-3 refresh-quality=below-target-or-memory-floor $refresh_detail"
  elif (( age > 7200 || behind > 50 )); then
    GITNEXUS_INDEX_HEALTH_STATE=STUCK
  fi
}
