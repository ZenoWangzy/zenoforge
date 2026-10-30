#!/usr/bin/env bash
# Shared hand-agent identity and activity checks for dispatch and supervision.
if ! declare -F agent_epoch >/dev/null; then
  source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)/lib.sh"
fi
HAND_AGENT_IDLE_SECONDS=1800
HAND_AGENT_SPIN_THRESHOLD_SECONDS="${ZF_AGENT_SPIN_THRESHOLD_SECONDS:-1200}"
# 2026-10-08 maintainer ruling no-hand-agent-token-cap: no stop by default; WARN only flags pathological spins.
HAND_AGENT_TOKEN_WARN="${HAND_AGENT_TOKEN_WARN:-100000000}"
HAND_AGENT_TOKEN_STOP="${HAND_AGENT_TOKEN_STOP:-0}" # 0 = never stop
# /proc start ticks and file timestamps round to seconds; avoid treating a
# pre-dispatch commit in the same second as work from this process.
HAND_AGENT_START_SKEW_SECONDS=2
HAND_AGENT_STOP_GRACE_SECONDS="${HAND_AGENT_STOP_GRACE_SECONDS:-3}"
[[ "$HAND_AGENT_SPIN_THRESHOLD_SECONDS" =~ ^[1-9][0-9]*$ ]] || HAND_AGENT_SPIN_THRESHOLD_SECONDS=1200
[[ "$HAND_AGENT_STOP_GRACE_SECONDS" =~ ^[1-9][0-9]*$ ]] || HAND_AGENT_STOP_GRACE_SECONDS=3
[[ "$HAND_AGENT_TOKEN_WARN" =~ ^[1-9][0-9]{0,17}$ ]] || HAND_AGENT_TOKEN_WARN=100000000
[[ "$HAND_AGENT_TOKEN_STOP" =~ ^[0-9]{1,18}$ ]] || HAND_AGENT_TOKEN_STOP=0

hand_agent_log_path() {
  local pid="$1" recorded_log="${2:-}" fd fd_path
  if [ -n "$recorded_log" ] && [ -f "$recorded_log" ]; then
    printf '%s\n' "$recorded_log"
    return 0
  fi
  for fd in 1 2; do
    fd_path="/proc/$pid/fd/$fd"
    [ -f "$fd_path" ] || continue
    printf '%s\n' "$fd_path"
    return 0
  done
  return 1
}

hand_agent_issue_ids() {
  local name="$1" explicit="${2:-}" issue result=""
  local -a supplied=()
  local -A seen=()
  if [[ "$name" =~ ^hand-([1-9][0-9]*)$ ]]; then
    explicit="${explicit:+$explicit }${BASH_REMATCH[1]}"
  fi
  case "$explicit" in *$'\t'*|*$'\n'*) return 2 ;; esac
  read -r -a supplied <<< "$explicit"
  for issue in "${supplied[@]}"; do
    [[ "$issue" =~ ^[1-9][0-9]*$ ]] || return 2
    [ -z "${seen[$issue]:-}" ] || continue
    seen["$issue"]=1
    result="${result:+$result }$issue"
  done
  printf '%s\n' "$result"
}

hand_agent_issue_ids_from_brief() {
  local name="$1" brief="$2" explicit="${3:-}" header=""
  if [ -r "$brief" ]; then
    header="$(sed -n 's/^Owned issues:[[:space:]]*//p' "$brief" | sed -n '1p')"
  fi
  hand_agent_issue_ids "$name" "${explicit:+$explicit }$header"
}

hand_agent_node_names() {
  local explicit="${2:-}" name result=""
  local -a supplied=()
  local -A seen=()
  case "$explicit" in *$'\t'*|*$'\n'*) return 2 ;; esac
  read -r -a supplied <<< "$explicit"
  for name in "${supplied[@]}"; do
    [[ "$name" =~ ^[A-Za-z0-9][A-Za-z0-9_.-]*$ ]] || return 2
    [ -z "${seen[$name]:-}" ] || continue
    seen["$name"]=1
    result="${result:+$result }$name"
  done
  printf '%s\n' "$result"
}

hand_agent_process_start_ticks() {
  local stats cpu ticks state
  stats="$(hand_agent_proc_stats "$1")" || return 1
  read -r cpu ticks state <<< "$stats"
  [ "$state" != Z ] || return 1
  printf '%s\n' "$ticks"
}

hand_agent_pid_live() {
  local pid="$1" expected_start_ticks="${2:-}" stat_line rest state stats cpu actual_start_ticks
  kill -0 "$pid" 2>/dev/null || return 1
  IFS= read -r stat_line < "/proc/$pid/stat" 2>/dev/null || return 1
  rest="${stat_line##*) }"
  read -r state _ <<< "$rest"
  [ "$state" != Z ] || return 1
  if [ -n "$expected_start_ticks" ]; then
    [[ "$expected_start_ticks" =~ ^[0-9]+$ ]] || return 1
    stats="$(hand_agent_proc_stats "$pid")" || return 1
    read -r cpu actual_start_ticks state <<< "$stats"
    [ "$state" != Z ] && [ "$actual_start_ticks" = "$expected_start_ticks" ]
  fi
}

# Shared flag-order-independent Codex identity; PID/start ticks remain the roster contract.
hand_agent_worktree_pid() {
  hand_codex_worktree_pid "$1"
}

hand_agent_session_id() {
  local pid="$1" stat_line rest _state _ppid _pgrp sid
  IFS= read -r stat_line < "/proc/$pid/stat" 2>/dev/null || return 1
  rest="${stat_line##*) }"
  read -r _state _ppid _pgrp sid _rest <<< "$rest"
  [[ "$sid" =~ ^[1-9][0-9]*$ ]] || return 1
  printf '%s\n' "$sid"
}

# Zombies still hold their session id but cannot be signaled or do work; only a
# live member keeps a stop waiting for its grace.
hand_agent_session_alive() {
  local sid="$1" row member_sid state
  while IFS= read -r row; do
    read -r member_sid state <<< "$row"
    [ "$member_sid" = "$sid" ] || continue
    case "$state" in Z*) continue ;; esac
    return 0
  done < <(ps -eo sid=,stat= 2>/dev/null)
  return 1
}

# A hand runner launched with setsid owns its session. Stop that whole session
# to include descendants reparented after runner exit; never target a session
# the requested PID does not lead.
hand_agent_stop_session() {
  local pid="$1" waited=0 sid
  [[ "$pid" =~ ^[1-9][0-9]*$ ]] || return 1
  sid="$(hand_agent_session_id "$pid" 2>/dev/null || true)"
  if [ "$sid" = "$pid" ]; then
    pkill -TERM -s "$pid" 2>/dev/null || return 1
    while [ "$waited" -lt "$HAND_AGENT_STOP_GRACE_SECONDS" ]; do
      hand_agent_session_alive "$pid" || return 0
      sleep 1
      waited=$((waited + 1))
    done
    pkill -KILL -s "$pid" 2>/dev/null || true
  else
    kill -TERM "$pid" 2>/dev/null || return 1
    while [ "$waited" -lt "$HAND_AGENT_STOP_GRACE_SECONDS" ]; do
      hand_agent_pid_live "$pid" "" || return 0
      sleep 1
      waited=$((waited + 1))
    done
    kill -KILL "$pid" 2>/dev/null || true
  fi
  return 0
}

hand_agent_issue_is_live_owned() {
  local issue="$1" row pid name model effort worktree brief report log attempt started_at role start_ticks owned_issues owned_nodes owner_issue
  local -a issue_numbers=()
  [[ "$issue" =~ ^[1-9][0-9]*$ ]] || return 1
  [ -r "${NIGHT:-}/agents.txt" ] || return 1
  while IFS= read -r row || [ -n "$row" ]; do
    [[ "$row" == *$'\t'* ]] || continue
    IFS=$'\x1f' read -r pid name model effort worktree brief report log attempt started_at role start_ticks owned_issues owned_nodes \
      <<< "${row//$'\t'/$'\x1f'}"
    [[ "$pid" =~ ^[1-9][0-9]*$ && "$start_ticks" =~ ^[0-9]+$ ]] || continue
    read -r -a issue_numbers <<< "$owned_issues"
    for owner_issue in "${issue_numbers[@]}"; do
      [ "$owner_issue" = "$issue" ] || continue
      hand_agent_pid_live "$pid" "$start_ticks" && return 0
      break
    done
  done < "$NIGHT/agents.txt"
  return 1
}

hand_agent_node_is_live_owned() {
  local node="$1" row pid name model effort worktree brief report log attempt started_at role start_ticks owned_issues owned_nodes owner_node
  local -a node_names=()
  [[ "$node" =~ ^[A-Za-z0-9][A-Za-z0-9_.-]*$ ]] || return 1
  [ -r "${NIGHT:-}/agents.txt" ] || return 1
  while IFS= read -r row || [ -n "$row" ]; do
    [[ "$row" == *$'\t'* ]] || continue
    IFS=$'\x1f' read -r pid name model effort worktree brief report log attempt started_at role start_ticks owned_issues owned_nodes \
      <<< "${row//$'\t'/$'\x1f'}"
    [[ "$pid" =~ ^[1-9][0-9]*$ && "$start_ticks" =~ ^[0-9]+$ ]] || continue
    hand_agent_pid_live "$pid" "$start_ticks" || continue
    read -r -a node_names <<< "$owned_nodes"
    for owner_node in "${node_names[@]}"; do
      [ "$owner_node" = "$node" ] && return 0
    done
  done < "$NIGHT/agents.txt"
  return 1
}

hand_agent_proc_stats() {
  local pid="$1" stat_line rest state _ppid _pgrp _session _tty _tpgid _flags
  local _minflt _cminflt _majflt _cmajflt utime stime cutime cstime
  local _priority _nice _threads _itrealvalue starttime _rest
  IFS= read -r stat_line < "/proc/$pid/stat" 2>/dev/null || return 1
  rest="${stat_line##*) }"
  read -r state _ppid _pgrp _session _tty _tpgid _flags _minflt _cminflt \
    _majflt _cmajflt utime stime cutime cstime _priority _nice _threads \
    _itrealvalue starttime _rest <<< "$rest"
  [[ "$utime" =~ ^[0-9]+$ && "$stime" =~ ^[0-9]+$ && "$starttime" =~ ^[0-9]+$ ]] || return 1
  [[ "$cutime" =~ ^[0-9]+$ ]] || cutime=0
  [[ "$cstime" =~ ^[0-9]+$ ]] || cstime=0
  printf '%s %s %s\n' "$((utime + stime + cutime + cstime))" "$starttime" "$state"
}

hand_agent_process_tree() {
  local root="$1" process_rows
  process_rows="$(ps -eo pid=,ppid=)" || return 1
  printf '%s\n' "$process_rows" | awk -v root="$root" '
    { children[$2] = children[$2] " " $1 }
    function visit(pid, list, count, i) {
      if (seen[pid]++) return
      print pid
      count = split(children[pid], list, " ")
      for (i = 1; i <= count; i++) if (list[i] ~ /^[0-9]+$/) visit(list[i])
    }
    END { visit(root) }
  '
}

hand_agent_pipeline_codex_pid() {
  local root="$1" proc_pid process_name
  while IFS= read -r proc_pid; do
    [[ "$proc_pid" =~ ^[1-9][0-9]*$ && "$proc_pid" != "$root" ]] || continue
    IFS= read -r process_name <"/proc/$proc_pid/comm" 2>/dev/null || continue
    if [ "$process_name" = codex ]; then
      printf '%s\n' "$proc_pid"
      return 0
    fi
  done < <(hand_agent_process_tree "$root" 2>/dev/null)
  printf '%s\n' "$root"
}

hand_agent_record_cpu_activity() {
  local root="$1" now="$2" state_file="$NIGHT/.hand-agent-cpu-$root"
  local uptime_raw uptime_seconds ticks_per_second tree proc_pid stats cpu start state identity old last_activity=0
  local first=1 tmp
  local -A previous=() current=()
  if [ -r "$state_file" ]; then
    while IFS=' ' read -r identity old; do
      if [ "$first" -eq 1 ]; then
        [[ "$identity" =~ ^[0-9]+$ ]] && last_activity="$identity"
        first=0
      elif [[ "$old" =~ ^[0-9]+$ ]]; then
        previous["$identity"]="$old"
      fi
    done < "$state_file"
  fi
  uptime_raw="$(awk '{print $1}' /proc/uptime 2>/dev/null)" || return 2
  uptime_seconds="${uptime_raw%%.*}"
  ticks_per_second="$(getconf CLK_TCK 2>/dev/null || true)"
  [[ "$uptime_seconds" =~ ^[0-9]+$ && "$ticks_per_second" =~ ^[1-9][0-9]*$ ]] || return 2
  tree="$(hand_agent_process_tree "$root")" || return 2
  while IFS= read -r proc_pid; do
    [[ "$proc_pid" =~ ^[1-9][0-9]*$ ]] || continue
    stats="$(hand_agent_proc_stats "$proc_pid")" || continue
    read -r cpu start state <<< "$stats"
    [ "$state" = Z ] && continue
    identity="$proc_pid:$start"
    current["$identity"]="$cpu"
    old="${previous[$identity]:-}"
    if [[ "$old" =~ ^[0-9]+$ ]] && [ "$cpu" -gt "$old" ]; then
      last_activity="$now"
    elif [ -z "$old" ] && [ "$cpu" -gt 0 ] \
      && [ $((uptime_seconds - start / ticks_per_second)) -le "$HAND_AGENT_IDLE_SECONDS" ]; then
      last_activity="$now"
    fi
  done <<< "$tree"
  tmp="$(mktemp "$NIGHT/.hand-agent-cpu-$root.XXXXXX")" || return 2
  {
    printf '%s\n' "$last_activity"
    for identity in "${!current[@]}"; do printf '%s %s\n' "$identity" "${current[$identity]}"; done
  } > "$tmp" && mv -- "$tmp" "$state_file" || { rm -f -- "$tmp"; return 2; }
  [[ "$last_activity" =~ ^[0-9]+$ ]] && [ "$last_activity" -gt 0 ] \
    && [ $((now - last_activity)) -le "$HAND_AGENT_IDLE_SECONDS" ]
}

hand_agent_record_worktree_activity() {
  local root="$1" worktree="$2" now="$3"
  [ -n "$worktree" ] || return 1
  [ -d "$worktree" ] || return 2
  local snapshot="$NIGHT/.hand-agent-worktree-$root"
  local changed_at="$NIGHT/.hand-agent-worktree-time-$root"
  local snapshot_tmp time_tmp last_change=0
  snapshot_tmp="$(mktemp "$NIGHT/.hand-agent-worktree-$root.XXXXXX")" || return 2
  if ! hand_agent_write_worktree_snapshot "$worktree" "$snapshot_tmp"; then
    rm -f -- "$snapshot_tmp"
    return 2
  fi
  if [ -e "$snapshot" ]; then
    if ! cmp -s -- "$snapshot_tmp" "$snapshot"; then last_change="$now"; fi
  fi
  mv -- "$snapshot_tmp" "$snapshot" || { rm -f -- "$snapshot_tmp"; return 2; }
  if [ "$last_change" -gt 0 ]; then
    time_tmp="$(mktemp "$NIGHT/.hand-agent-worktree-time-$root.XXXXXX")" || return 2
    printf '%s\n' "$last_change" > "$time_tmp" && mv -- "$time_tmp" "$changed_at" \
      || { rm -f -- "$time_tmp"; return 2; }
  fi
  if [ -r "$changed_at" ]; then IFS= read -r last_change < "$changed_at" || last_change=0; fi
  [[ "$last_change" =~ ^[0-9]+$ ]] && [ "$last_change" -gt 0 ] \
    && [ $((now - last_change)) -le "$HAND_AGENT_IDLE_SECONDS" ]
}

hand_agent_write_worktree_snapshot() {
  local worktree="$1" output="$2" path
  if ! timeout 10 git -C "$worktree" status --porcelain=v1 -z --untracked-files=all >/dev/null 2>&1 \
    || ! timeout 10 git -C "$worktree" rev-parse --verify HEAD > "$output" 2>/dev/null \
    || ! timeout 10 git -C "$worktree" diff --binary HEAD >> "$output" 2>/dev/null; then
    return 1
  fi
  while IFS= read -r -d '' path; do
    [ -f "$worktree/$path" ] || continue
    printf '\0untracked:%s\0' "$path" >> "$output" || return 1
    cat -- "$worktree/$path" >> "$output" || return 1
  done < <(timeout 10 git -C "$worktree" ls-files --others --exclude-standard -z 2>/dev/null)
}

hand_agent_process_started_at() {
  local pid="$1" stat_line rest _state _ppid _pgrp _session _tty _tpgid _flags
  local _minflt _cminflt _majflt _cmajflt _utime _stime _cutime _cstime
  local _priority _nice _threads _itrealvalue starttime _tail ticks boot
  IFS= read -r stat_line < "/proc/$pid/stat" 2>/dev/null || return 1
  rest="${stat_line##*) }"
  read -r _state _ppid _pgrp _session _tty _tpgid _flags _minflt _cminflt \
    _majflt _cmajflt _utime _stime _cutime _cstime _priority _nice _threads \
    _itrealvalue starttime _tail <<< "$rest"
  [[ "$starttime" =~ ^[0-9]+$ ]] || return 1
  ticks="$(getconf CLK_TCK 2>/dev/null || true)"
  boot="$(awk '$1=="btime" {print $2; exit}' /proc/stat 2>/dev/null)"
  [[ "$ticks" =~ ^[1-9][0-9]*$ && "$boot" =~ ^[0-9]+$ ]] || return 1
  echo $((boot + starttime / ticks))
}

hand_agent_codex_session_file() {
  local root="$1" codex_home="${CODEX_HOME:-$HOME/.codex}" proc_pid target modified newest=0 newest_file="" newest_pid=""
  local tree owner_cwd started_at session_cwd session_at
  owner_cwd="$(readlink -f -- "/proc/$root/cwd" 2>/dev/null)" || return 1
  started_at="$(hand_agent_process_started_at "$root" 2>/dev/null)" || return 1
  tree="$(hand_agent_process_tree "$root" 2>/dev/null)" || return 1
  while IFS= read -r proc_pid; do
    [[ "$proc_pid" =~ ^[1-9][0-9]*$ ]] || continue
    # Batch FDs: one readlink per process, not hundreds of forks per owner.
    while IFS= read -r target; do
      case "$target" in "$codex_home"/sessions/*rollout-*.jsonl) ;; *) continue ;; esac
      [ -r "$target" ] || continue
      # Codex can hold older/other sessions open; their spend is not this owner's.
      IFS=$'\t' read -r session_cwd session_at < <(head -n 1 -- "$target" | jq -r '
        select(.type == "session_meta") | [.payload.cwd, .timestamp] | @tsv' 2>/dev/null)
      [ "$session_cwd" = "$owner_cwd" ] || continue
      session_at="$(agent_epoch "$session_at" 2>/dev/null || true)"
      [[ "$session_at" =~ ^[0-9]+$ ]] && [ "$session_at" -ge "$started_at" ] || continue
      modified="$(stat -c %Y -- "$target" 2>/dev/null || true)"
      if [[ "$modified" =~ ^[0-9]+$ ]] && [ "$modified" -ge "$newest" ]; then
        newest="$modified"; newest_file="$target"; newest_pid="$proc_pid"
      fi
    done < <(readlink -f -- "/proc/$proc_pid"/fd/* 2>/dev/null)
  done <<< "$tree"
  [ -n "$newest_file" ] || return 1
  printf '%s\t%s\n' "$newest_file" "$newest_pid"
}

hand_agent_codex_session_usage() {
  local file="$1" pid="$2" rows=() previous latest previous_at latest_at
  # Match the spend ledger: repeated cached context is not fresh input spend.
  mapfile -t rows < <(tail -n 1000 -- "$file" 2>/dev/null \
    | jq -Rr 'try fromjson catch empty
        | select(.type=="event_msg" and .payload.type=="token_count")
        | (if .payload.thread_token_usage.total_tokens != null then .payload.thread_token_usage
           else .payload.info.total_token_usage end) as $usage
        | select($usage.total_tokens | type == "number")
        | [.timestamp, ($usage.total_tokens - ($usage.cached_input_tokens // 0))]
        | @tsv' 2>/dev/null | tail -n 2)
  [ "${#rows[@]}" -gt 0 ] || return 1
  IFS=$'\t' read -r latest_at latest <<< "${rows[$((${#rows[@]} - 1))]}"
  latest_at="$(agent_epoch "$latest_at" 2>/dev/null || true)"
  [[ "$latest" =~ ^[0-9]+$ && "$latest_at" =~ ^[0-9]+$ ]] || return 1
  previous=0; previous_at=0
  if [ "${#rows[@]}" -gt 1 ]; then
    IFS=$'\t' read -r previous_at previous <<< "${rows[$((${#rows[@]} - 2))]}"
    previous_at="$(agent_epoch "$previous_at" 2>/dev/null || true)"
    [[ "$previous" =~ ^[0-9]+$ ]] || previous=0
    [[ "$previous_at" =~ ^[0-9]+$ ]] || previous_at=0
  fi
  printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$file" "$pid" "$previous_at" "$previous" "$latest_at" "$latest"
}

hand_agent_issue_updated_at() {
  local issue="$1" updated
  [[ "$issue" =~ ^[0-9]+$ ]] || return 1
  declare -p HEALTH_OPEN_ISSUE_UPDATED_AT >/dev/null 2>&1 || return 1
  updated="${HEALTH_OPEN_ISSUE_UPDATED_AT[$issue]:-}"
  [[ "$updated" =~ ^[1-9][0-9]*$ ]] || return 1
  printf '%s\n' "$updated"
}

hand_agent_index_open_issues() {
  local number updated
  declare -gA HEALTH_OPEN_ISSUE_UPDATED_AT=()
  while IFS=$'\t' read -r number updated; do
    [[ "$number" =~ ^[1-9][0-9]*$ && "$updated" =~ ^[1-9][0-9]*$ ]] \
      && HEALTH_OPEN_ISSUE_UPDATED_AT["$number"]="$updated"
  done < <(jq -r '
    def epoch: try fromdateiso8601 catch 0;
    .[] | select(.number | type == "number")
    | [(.number | tostring), ((.updatedAt // "") | epoch | tostring)] | @tsv
  ' <<< "${1:-[]}" 2>/dev/null)
}

hand_agent_spend_tokens() {
  local issue="$1" now="$2" today yesterday
  [[ "$issue" =~ ^[0-9]+$ ]] || return 1
  today="$(date -u -d "@$now" +%F)"
  yesterday="$(date -u -d "@$((now - 86400))" +%F)"
  awk -F '\t' -v issue="$issue" '
    $4==issue && $3 ~ /^codex:/ && $6 ~ /^[0-9]+$/ { total += $6; if ($1 > latest) latest=$1 }
    END { if (total > 0) printf "%.0f\t%s\n", total, latest }
  ' "$H/spend/$yesterday.log" "$H/spend/$today.log" 2>/dev/null
}

hand_agent_codex_issue_from_text() {
  grep -oE '#[0-9]{2,}' <<< "$1" 2>/dev/null | sed -n '1s/#//p'
}

hand_agent_codex_spin_status() {
  local identity="$1" pid="$2" worktree="${3:-}" report="${4:-}" log="${5:-}" issue="${6:-}" repo="${7:-$REPO}" now="${8:-$(date +%s)}"
  local state_id state_file state started_at start_known session_started codex_session codex_pid session_file source tokens token_epoch instant_growth
  local previous_source previous_tokens previous_progress previous_marker_at previous_started_at progress_at marker_at growth_at growth_window
  local issue_at session_write_at snapshot had_snapshot worktree_at result age growth_age
  [[ "$now" =~ ^[0-9]+$ ]] || now="$(date +%s)"
  state_id="${identity//[^[:alnum:]_.-]/_}"
  state_file="$NIGHT/.codex-spin-$state_id.json"
  state="$(jq -c . "$state_file" 2>/dev/null || echo '{}')"
  previous_source="$(jq -r '.source // empty' <<< "$state")"
  previous_tokens="$(jq -r '.tokens // empty' <<< "$state")"
  previous_progress="$(jq -r '.progress_at // 0' <<< "$state")"
  previous_marker_at="$(jq -r '.marker_at // 0' <<< "$state")"
  previous_started_at="$(jq -r '.process_started_at // 0' <<< "$state")"
  marker_at="$previous_marker_at"
  growth_at="$(jq -r '.growth_at // 0' <<< "$state")"
  started_at="$(hand_agent_process_started_at "$pid" 2>/dev/null || true)"
  if [[ "$started_at" =~ ^[0-9]+$ ]]; then start_known=1; else start_known=0; started_at="$now"; fi

  source=""; tokens=""; token_epoch=0; instant_growth=0; codex_pid="$pid"; session_file=""
  if codex_session="$(hand_agent_codex_session_file "$pid" 2>/dev/null)"; then
    IFS=$'\t' read -r session_file codex_pid <<< "$codex_session"
    session_started="$(hand_agent_process_started_at "$codex_pid" 2>/dev/null || true)"
    if [[ "$session_started" =~ ^[0-9]+$ ]]; then started_at="$session_started"; start_known=1; fi
    if result="$(hand_agent_codex_session_usage "$session_file" "$codex_pid" 2>/dev/null)"; then
      IFS=$'\t' read -r source codex_pid _prev_epoch _prev_tokens token_epoch tokens <<< "$result"
      source="session:$source"
      if [[ "${_prev_tokens:-0}" =~ ^[0-9]+$ && "$tokens" =~ ^[0-9]+$ ]] && [ "$tokens" -gt "${_prev_tokens:-0}" ]; then instant_growth="$token_epoch"; fi
    fi
  fi
  if [ "$start_known" -eq 1 ] && [ "$previous_started_at" != "$started_at" ]; then
    previous_source=""; previous_tokens=""; previous_progress=0; previous_marker_at=0
    marker_at=0; growth_at=0
    rm -f -- "$NIGHT/.hand-agent-worktree-$pid" "$NIGHT/.hand-agent-worktree-time-$pid"
  elif [ "$start_known" -eq 0 ] && [[ "$previous_started_at" =~ ^[1-9][0-9]*$ ]]; then
    started_at="$previous_started_at"
  fi
  if [ -z "$tokens" ] && [ -n "$log" ]; then
    tokens="$(codex_tokens_used "$log" 2>/dev/null || true)"
    if [[ "$tokens" =~ ^[0-9]+$ ]]; then source="log:$log"; token_epoch="$now"; fi
  fi
  if [ -z "$tokens" ] && [ -n "$issue" ]; then
    result="$(hand_agent_spend_tokens "$issue" "$now" 2>/dev/null || true)"
    if [ -n "$result" ]; then
      IFS=$'\t' read -r tokens token_epoch <<< "$result"
      if [[ "$tokens" =~ ^[0-9]+$ ]]; then source="spend:$issue"; else tokens=""; fi
    fi
  fi

  local base_at="$started_at" process_log_at
  process_log_at="$(stat -L -c %Y -- "$log" 2>/dev/null || true)"
  if [[ "$process_log_at" =~ ^[0-9]+$ ]] && [ "$process_log_at" -lt "$base_at" ]; then base_at="$process_log_at"; fi
  progress_at="$base_at"
  if [ -n "$worktree" ] && [ -d "$worktree" ]; then
    snapshot="$NIGHT/.hand-agent-worktree-$pid"
    had_snapshot=0; [ -e "$snapshot" ] && had_snapshot=1
    hand_agent_record_worktree_activity "$pid" "$worktree" "$now" || true
    if [ "$had_snapshot" = 1 ]; then
      worktree_at="$(cat "$NIGHT/.hand-agent-worktree-time-$pid" 2>/dev/null || echo 0)"
    else
      worktree_at=0
    fi
    if [[ "$worktree_at" =~ ^[0-9]+$ ]] && [ "$worktree_at" -gt "$marker_at" ]; then marker_at="$worktree_at"; fi
  fi
  if [ -n "$issue" ]; then
    issue_at="$(hand_agent_issue_updated_at "$issue" "$repo" "$now" 2>/dev/null || echo 0)"
    if [[ "$issue_at" =~ ^[0-9]+$ ]] && [ "$issue_at" -gt $((started_at + HAND_AGENT_START_SKEW_SECONDS)) ] && [ "$issue_at" -gt "$marker_at" ]; then marker_at="$issue_at"; fi
  fi
  if [ -n "$session_file" ]; then
    session_write_at="$(hand_agent_codex_session_write_epoch "$session_file" 2>/dev/null || echo 0)"
    if [[ "$session_write_at" =~ ^[0-9]+$ ]] && [ "$session_write_at" -gt $((started_at + HAND_AGENT_START_SKEW_SECONDS)) ] && [ "$session_write_at" -gt "$marker_at" ]; then marker_at="$session_write_at"; fi
  fi
  if [ "$marker_at" -gt 0 ]; then progress_at="$marker_at"; fi
  [[ "$previous_progress" =~ ^[0-9]+$ ]] || previous_progress=0
  if [ "$previous_progress" -gt "$progress_at" ]; then progress_at="$previous_progress"; fi
  if [ "$progress_at" -gt "$now" ]; then progress_at="$now"; fi
  if [ "$marker_at" -gt "$previous_marker_at" ]; then growth_at=0; fi

  if [ -n "$source" ] && [[ "$tokens" =~ ^[0-9]+$ ]]; then
    if [ "$source" != "$previous_source" ]; then previous_tokens=""; growth_at=0; fi
    if [[ "$previous_tokens" =~ ^[0-9]+$ ]] && [ "$tokens" -gt "$previous_tokens" ]; then
      token_epoch="${token_epoch:-$now}"
      if [[ "$token_epoch" =~ ^[0-9]+$ ]] && [ "$token_epoch" -gt "$progress_at" ]; then growth_at="$token_epoch"; fi
    elif [ "$instant_growth" -gt "$progress_at" ]; then
      growth_at="$instant_growth"
    elif [[ "$previous_tokens" =~ ^[0-9]+$ ]] && [ "$tokens" -lt "$previous_tokens" ]; then
      growth_at=0
    fi
  else
    source=""; tokens=""; growth_at=0
  fi

  jq -n --arg source "$source" --arg tokens "$tokens" --argjson process_started_at "$started_at" --argjson progress_at "$progress_at" \
    --argjson marker_at "$marker_at" --argjson growth_at "$growth_at" --argjson now "$now" \
    '{source:$source,tokens:(if $tokens|test("^[0-9]+$") then ($tokens|tonumber) else null end),process_started_at:$process_started_at,progress_at:$progress_at,marker_at:$marker_at,growth_at:$growth_at,sampled_at:$now}' \
    > "$state_file.tmp.$$" && mv -- "$state_file.tmp.$$" "$state_file" || rm -f -- "$state_file.tmp.$$"

  age=$((now - progress_at)); [ "$age" -ge 0 ] || age=0
  growth_age=$((now - growth_at))
  growth_window=$((HAND_AGENT_SPIN_THRESHOLD_SECONDS < 600 ? HAND_AGENT_SPIN_THRESHOLD_SECONDS : 600))
  if [ "$age" -ge "$HAND_AGENT_SPIN_THRESHOLD_SECONDS" ] && [ "$growth_at" -ge "$progress_at" ] \
    && [ "$growth_at" -gt 0 ] && [ "$growth_age" -ge 0 ] && [ "$growth_age" -le "$growth_window" ]; then
    printf 'SPINNING\t%s\t%s\n' "${tokens:-?}" "$age"
  elif [ "$marker_at" -gt 0 ] && [ $((now - marker_at)) -lt "$HAND_AGENT_SPIN_THRESHOLD_SECONDS" ]; then
    printf 'PROGRESSING\t%s\t%s\n' "${tokens:-?}" "$age"
  elif [ "$age" -ge "$HAND_AGENT_IDLE_SECONDS" ]; then
    printf 'IDLE\t%s\t%s\n' "${tokens:-?}" "$age"
  else
    printf 'WAITING\t%s\t%s\n' "${tokens:-?}" "$age"
  fi
}

hand_agent_watchdog_enforce() {
  local name="$1" identity="$2" root_pid="$3" report="${4:-}" spin_state="${5:-}" now="${6:-$(date +%s)}"
  local status tokens no_progress state_id watchdog_state spinning_at previous_spinning_at process_identity previous_process_identity
  local terminal_pattern='^STATUS: (LANDED|PR-OPEN|BLOCKED-ON|DONE|FAILED|READY-TO-LAND)([[:space:]]|$)'
  local first_line="" terminal=0 report_at=0 marker_at=0 reason="" elapsed=0 minutes
  local codex_pid process_name start_ticks process_started_at stop_marker report_tmp role_identity runner_provider
  local brief="${8:-}" token_limit="$HAND_AGENT_TOKEN_STOP" token_budget warning_marker started_at runtime last_report_line
  [[ "$now" =~ ^[0-9]+$ ]] || now="$(date +%s)"
  IFS=$'\t' read -r status tokens no_progress <<< "$spin_state"
  [[ "$tokens" =~ ^[0-9]+$ ]] || tokens="?"
  [[ "$no_progress" =~ ^[0-9]+$ ]] || no_progress=0
  state_id="${identity//[^[:alnum:]_.-]/_}"
  watchdog_state="$NIGHT/.hand-agent-watchdog-$state_id.json"
  role_identity="$(model_policy identity "${7:-work}" 2>/dev/null || true)"
  # A disabled role (GLM ruling 2026-10-09) dispatches nothing new, but a process it started before
  # then still needs stopping, so fall back to the disabled role's provider.
  [ -n "$role_identity" ] || role_identity="$(jq -r --arg role "${7:-work}" \
    '.roles[$role] | select(.disabled == true) | .provider + ":"' "$MODEL_POLICY_FILE" 2>/dev/null || true)"
  case "$role_identity" in
    codex:*) runner_provider=codex; codex_pid="$(hand_agent_pipeline_codex_pid "$root_pid" 2>/dev/null)" || return 0 ;;
    zcode:*) runner_provider=zcode; codex_pid="$root_pid" ;;
    *) return 0 ;;
  esac
  [[ "$codex_pid" =~ ^[1-9][0-9]*$ ]] || return 0
  if [ "$runner_provider" = codex ]; then
    IFS= read -r process_name < "/proc/$codex_pid/comm" 2>/dev/null || return 0
    [ "$process_name" = codex ] || return 0
  fi
  start_ticks="$(hand_agent_process_start_ticks "$codex_pid" 2>/dev/null)" || return 0
  process_started_at="$(hand_agent_process_started_at "$codex_pid" 2>/dev/null || true)"
  process_identity="$codex_pid:$start_ticks"
  previous_process_identity="$(jq -r '.process_identity // empty' "$watchdog_state" 2>/dev/null || true)"
  previous_spinning_at="$(jq -r '.spinning_at // 0' "$watchdog_state" 2>/dev/null || echo 0)"
  [ "$previous_process_identity" = "$process_identity" ] || previous_spinning_at=0

  if [ -r "$brief" ]; then
    token_budget="$(awk '{ sub(/\r$/, "") } /^Token budget: [0-9]+$/ { sub(/^Token budget: /, ""); print; exit }' "$brief" 2>/dev/null || true)"
    if (( HAND_AGENT_TOKEN_STOP > 0 )) && [[ "$token_budget" =~ ^[1-9][0-9]{0,17}$ ]] && (( 10#$token_budget > HAND_AGENT_TOKEN_STOP )); then
      token_limit="$token_budget"
    fi
  fi
  if [[ "$tokens" =~ ^[0-9]+$ ]] && (( 10#$tokens >= HAND_AGENT_TOKEN_WARN )); then
    warning_marker="$NIGHT/.hand-agent-token-warning-$codex_pid-$start_ticks"
    if mkdir -- "$warning_marker" 2>/dev/null; then
      started_at="$(hand_agent_process_started_at "$codex_pid" 2>/dev/null || echo "$now")"
      runtime=$((now - started_at)); ((runtime >= 0)) || runtime=0
      last_report_line="$(tail -n 1 -- "$report" 2>/dev/null | tr '\r\n\t' '   ' || true)"
      AGENT_HOME="${AGENT_HOME:-${H:-}}" supervisor_inbox_append hand-agent-token-budget \
        "name=$name tokens=$tokens runtime=${runtime}s last_report=$last_report_line" || {
          rmdir -- "$warning_marker" 2>/dev/null || true
        }
    fi
  fi
  if (( token_limit > 0 )) && [[ "$tokens" =~ ^[0-9]+$ ]] && (( 10#$tokens >= token_limit )); then
    reason=token-budget
    started_at="$(hand_agent_process_started_at "$codex_pid" 2>/dev/null || echo "$now")"
    elapsed=$((now - started_at)); ((elapsed >= 0)) || elapsed=0
  fi
  if [ "$status" = SPINNING ]; then
    if [[ "$previous_spinning_at" =~ ^[1-9][0-9]*$ ]] && [ "$previous_spinning_at" -le "$now" ]; then
      spinning_at="$previous_spinning_at"
    else
      spinning_at="$now"
    fi
  else
    spinning_at=0
  fi
  jq -n --argjson spinning_at "$spinning_at" --arg process_identity "$process_identity" \
    '{spinning_at:$spinning_at,process_identity:$process_identity}' \
    > "$watchdog_state.tmp.$$" && mv -- "$watchdog_state.tmp.$$" "$watchdog_state" \
    || { rm -f -- "$watchdog_state.tmp.$$"; return 1; }

  if [ -n "$report" ] && [ -f "$report" ]; then
    IFS= read -r first_line < "$report" || true
    [[ "$first_line" =~ $terminal_pattern ]] && terminal=1
    report_at="$(stat -c %Y -- "$report" 2>/dev/null || echo 0)"
    marker_at="$(jq -r '.marker_at // 0' "$NIGHT/.codex-spin-$state_id.json" 2>/dev/null || echo 0)"
    if [[ "$report_at" =~ ^[0-9]+$ && "$marker_at" =~ ^[0-9]+$ && "$process_started_at" =~ ^[1-9][0-9]*$ ]] \
      && [ "$terminal" -eq 1 ] && [ "$report_at" -le "$now" ] \
      && [ "$report_at" -ge "$process_started_at" ] \
      && [ -z "$reason" ] && [ "$marker_at" -le "$report_at" ] \
      && [ $((now - report_at)) -ge "$HAND_AGENT_SPIN_THRESHOLD_SECONDS" ]; then
      reason=finished-report
      elapsed=$((now - report_at))
    fi
  fi
  if [ -z "$reason" ] && [ "$status" = SPINNING ] \
    && [ $((now - spinning_at)) -ge "$HAND_AGENT_SPIN_THRESHOLD_SECONDS" ]; then
    reason=spinning
    elapsed="$no_progress"
  fi
  [ -n "$reason" ] || return 0

  stop_marker="$NIGHT/.hand-agent-stopped-$codex_pid-$start_ticks"
  mkdir -- "$stop_marker" 2>/dev/null || return 0
  if ! hand_agent_pid_live "$codex_pid" "$start_ticks"; then
    rmdir -- "$stop_marker" 2>/dev/null || true
    return 0
  fi
  if [ "$runner_provider" = codex ]; then
    IFS= read -r process_name < "/proc/$codex_pid/comm" 2>/dev/null || process_name=""
  fi
  if { [ "$runner_provider" = codex ] && [ "$process_name" != codex ]; } || ! kill -TERM "$codex_pid" 2>/dev/null; then
    rmdir -- "$stop_marker" 2>/dev/null || true
    return 0
  fi

  if [ "$reason" = spinning ] && [ -n "$report" ]; then
    if [ -f "$report" ]; then
      first_line=""
      IFS= read -r first_line < "$report" || true
      [[ "$first_line" =~ $terminal_pattern ]] && terminal=1
    fi
  fi
  if [ "$reason" = token-budget ] && [ -n "$report" ]; then
    mkdir -p -- "$(dirname -- "$report")" || true
    report_tmp="$(mktemp "$report.tmp.XXXXXX" 2>/dev/null || true)"
    if [ -n "$report_tmp" ]; then
      {
        printf 'STATUS: BLOCKED-ON token-budget (%s)\n\n' "$tokens"
        if [ -f "$report" ]; then cat -- "$report"; fi
      } > "$report_tmp" && mv -- "$report_tmp" "$report" || rm -f -- "$report_tmp"
    fi
  elif [ "$reason" = spinning ] && [ "$terminal" -eq 0 ] && [ -n "$report" ]; then
    minutes=$((elapsed / 60))
    mkdir -p -- "$(dirname -- "$report")" || true
    report_tmp="$(mktemp "$report.tmp.XXXXXX" 2>/dev/null || true)"
    if [ -n "$report_tmp" ]; then
      {
        printf 'STATUS: BLOCKED-ON spinning (watchdog stopped pid=%s after %s tokens, %s min without progress)\n\n' \
          "$codex_pid" "$tokens" "$minutes"
        if [ -f "$report" ]; then cat -- "$report"; fi
      } > "$report_tmp" && mv -- "$report_tmp" "$report" || rm -f -- "$report_tmp"
    fi
  fi
  AGENT_HOME="${AGENT_HOME:-${H:-}}" supervisor_inbox_append hand-agent-stopped \
    "name=$name pid=$codex_pid tokens=$tokens reason=$reason"
}

hand_agent_codex_session_write_epoch() {
  local file="$1" at
  at="$(tail -n 2000 -- "$file" 2>/dev/null | jq -Rr 'try fromjson catch empty
    | select(.type=="response_item" and .payload.type=="custom_tool_call_output")
    | ([.payload.output[]?.text // ""] | join("\n")) as $output
    | select((($output|test("To https?://[^\\n]+")) and ($output|test("->")) and (($output|test("rejected";"i"))|not))
        or ($output|test("https://github\\.com/[^/]+/[^/]+/(issues|pull)/[0-9]+#issuecomment-[0-9]+")))
    | .timestamp' 2>/dev/null | tail -n 1)"
  agent_epoch "$at" 2>/dev/null
}

hand_agent_recently_active() {
  local pid="$1" worktree="$2" now="$3" cpu_status worktree_status
  hand_agent_record_cpu_activity "$pid" "$now" || cpu_status=$?
  cpu_status="${cpu_status:-0}"
  hand_agent_record_worktree_activity "$pid" "$worktree" "$now" || worktree_status=$?
  worktree_status="${worktree_status:-0}"
  if [ "$cpu_status" -eq 0 ] || [ "$worktree_status" -eq 0 ]; then return 0; fi
  if [ "$cpu_status" -eq 2 ] || [ "$worktree_status" -eq 2 ]; then return 2; fi
  return 1
}

hand_agent_report_unknown() {
  local name="$1" pid="$2" reason="$3" identity stats marker
  stats="$(hand_agent_proc_stats "$pid" 2>/dev/null || true)"
  read -r _ identity _ <<< "$stats"
  identity="${identity:-unknown}"
  marker="$NIGHT/.hand-agent-unknown-$pid-$identity"
  mkdir -p -- "$H" "$NIGHT"
  mkdir -- "$marker" 2>/dev/null || return 0
  if ! AGENT_HOME="$H" supervisor_inbox_append UNKNOWN "hand-agent name=$name pid=$pid reason=$reason"; then
    rmdir -- "$marker" 2>/dev/null || true
    return 1
  fi
}
