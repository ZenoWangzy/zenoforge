
# _bounded_call_timed_out <detail> -- shared by gh()/git_fetch_bounded()
# below. Always logs loudly to stderr, so a timeout lands in the
# dispatched unit's own journal the same way every other failure here
# does. Additionally files a proper environment-fault ledger entry
# (record_env_fault() further down -- same ledger env:gh-api/env:worktree-
# add/env:git-identity already use) when the calling script has opted in
# by setting GH_ENV_FAULT_STAGE (and, where relevant, $N -- the current
# issue number every single-issue wrapper already carries).
#
# Opted in: run-triage.sh, run-implement.sh, run-recut.sh, run-release.sh
# -- each sets GH_ENV_FAULT_STAGE once near its own top. None of the four
# had ANY failure handling on their later mutating `gh` calls before this
# fix (only their first read, `gh issue view`, already checked itself) --
# the exact shape of a defect already found and fixed once, 2026-09-15,
# for run-advisor.sh alone (its apply_gh_write(), Defect 2, zf-
# advisor-1205: "TLS handshake timeout crashed the whole run under `set
# -e` AFTER the paid-for verdict was already computed, discarding it with
# nothing recorded"). This closes the same gap for its three siblings
# without copying apply_gh_write()'s per-script logic three more times.
#
# NOT opted in: issue-pipeline.sh's own multi-issue tick loop (no `$N` in
# scope across it, and the one place it charges an attempt --
# state_bump_attempts() before an implement dispatch -- is followed only
# by a local systemd-run call, never another `gh` call, so nothing there
# needs a refund; an unhandled failure already aborts the whole tick under
# `set -euo pipefail` into run-tick.sh's scheduler-failed refusal, counter
# + maintainer alert, which is what actually needed fixing -- see run-
# tick.sh's own header) and run-advisor.sh (apply_gh_write() already
# covers every one of its mutating calls end to end, correctly, including
# record_env_fault() and the attempt-refund question -- see its own
# comment; setting GH_ENV_FAULT_STAGE there too would only double-log the
# identical event under a second signature). record_env_fault() itself
# only ever refunds the dispatch-time attempts bump for stage=implement
# (lessons/RULES.md V79, a ticket must never be stuck four times);
# triage/recut/release have no such external pre-charge to refund, so for
# them this is ledger visibility (feeding the same systemic/quarantine
# check env:gh-api already feeds), not a refund.
#
# Accepted trade-off: each of the four scripts' OWN pre-existing initial
# `gh issue view` check already records its own env:gh-api entry on
# failure -- a timeout there now also produces this function's
# env:network-timeout entry, two ledger lines for one event. Suppressing
# that would need GH_ENV_FAULT_STAGE unset for one specific early call and
# set for every later one, i.e. exactly the per-call-site plumbing this
# whole mechanism exists to avoid. Two entries under two signatures cost
# nothing -- env_fault_is_systemic() evaluates each signature
# independently, so neither is double-counted against itself -- and are
# strictly more information, not less.
_bounded_call_timed_out() {
  local detail="$1"
  echo "$detail -- treated as an environment fault, not a verdict" >&2
  if [ -n "${GH_ENV_FAULT_STAGE:-}" ] && declare -F record_env_fault >/dev/null 2>&1; then
    record_env_fault env:network-timeout "$GH_ENV_FAULT_STAGE" "${N:-0}" "$detail"
  fi
}


# Retry only idempotent reads. A timed-out write may have landed before its
# response was lost, so replaying it can duplicate comments or mutations.
# An owner-admission caller may set ZF_GH_CALL_DEADLINE_EPOCH_MS as an
# unexported, dynamically scoped variable. It is an absolute cutoff for the
# parent tick's GH work (already reduced by that caller's dispatch reserve),
# not a child-process timeout setting. Each real attempt is independently
# bounded against the current time; ordinary callers leave it unset.
gh_call_now_ms() {
  local realtime="${EPOCHREALTIME/./}"
  [[ "$realtime" =~ ^[0-9]+$ ]] || return 1
  printf '%s\n' "$((realtime / 1000))"
}


gh_tick_attempt_timeout_sec() {
  local deadline="${ZF_GH_CALL_DEADLINE_EPOCH_MS:-}" now remaining_ms allowed_ms timeout_sec default_timeout
  default_timeout="${GH_CALL_TIMEOUT_SEC:-60}"
  [[ "$default_timeout" =~ ^[1-9][0-9]*$ ]] || default_timeout=60
  [ -z "$deadline" ] && { printf '%s\n' "$default_timeout"; return 0; }
  [[ "$deadline" =~ ^[0-9]+$ ]] || return 1
  now="$(gh_call_now_ms)" || return 1
  remaining_ms=$((deadline - now))
  # Keep timeout's 5s kill grace and 1s process-start/scheduling slack inside
  # the caller's absolute deadline. A one-second GH attempt is the minimum.
  allowed_ms=$((remaining_ms - 6000))
  (( allowed_ms >= 1000 )) || return 1
  timeout_sec=$((allowed_ms / 1000))
  (( timeout_sec > default_timeout )) && timeout_sec="$default_timeout"
  (( timeout_sec > 0 )) || return 1
  printf '%s\n' "$timeout_sec"
}


gh_tick_retry_fits() {
  local deadline="${ZF_GH_CALL_DEADLINE_EPOCH_MS:-}" now remaining_ms
  [ -z "$deadline" ] && return 0
  [[ "$deadline" =~ ^[0-9]+$ ]] || return 1
  now="$(gh_call_now_ms)" || return 1
  remaining_ms=$((deadline - now))
  # The existing retry delay is 2s. After it, the next attempt needs a
  # one-second timeout, five-second kill grace, and one-second setup slack.
  (( remaining_ms >= 9000 ))
}


gh() {
  local status attempt retry_read=0 stderr_file stderr i api_method="" api_fields=0 arg attempt_timeout
  local profile_source="" profile_function="" profile_line=0 profile_started_us="" profile_ended_us
  local args=("$@")
  if [ "${ZF_PIPELINE_CALL_PROFILE_ENABLED:-0}" = 1 ]; then
    profile_source="${BASH_SOURCE[1]:-}"
    profile_function="${FUNCNAME[1]:-main}"
    profile_line="${BASH_LINENO[0]:-0}"
    if [ "$profile_function" = guarded_write ]; then
      profile_source="${BASH_SOURCE[2]:-}"
      profile_function="${FUNCNAME[2]:-main}"
      profile_line="${BASH_LINENO[1]:-0}"
    fi
    profile_source="${profile_source##*/}"
    profile_started_us="${EPOCHREALTIME/./}"
  fi
  case "${1:-}:${2:-}" in
    issue:view|issue:list|pr:view|pr:list|pr:checks|pr:diff|pr:status|run:view|run:list|label:list|repo:view|repo:list|workflow:view|workflow:list|release:view|release:list|variable:get|variable:list|auth:status)
      retry_read=1
      ;;
    api:*)
      for ((i = 2; i < ${#args[@]}; i++)); do
        arg="${args[$i]}"
        case "$arg" in
          --method|-X)
            i=$((i + 1))
            api_method="${args[$i]:-}"
            ;;
          --method=*|-X=*) api_method="${arg#*=}" ;;
          -X?*) api_method="${arg#-X}" ;;
          -f|--field|-F|--raw-field|--input)
            api_fields=1
            i=$((i + 1))
            ;;
          --field=*|--raw-field=*|--input=*|-f?*|-F?*) api_fields=1 ;;
        esac
      done
      if [ "${api_method^^}" = GET ] || { [ -z "$api_method" ] && [ "$api_fields" -eq 0 ]; }; then
        retry_read=1
      fi
      ;;
  esac

  if [ "$retry_read" != 1 ]; then
    attempt_timeout="$(gh_tick_attempt_timeout_sec)" || {
      echo 'gh: refusing call because the owner-admission deadline cannot fit one bounded attempt' >&2
      if [ -n "$profile_started_us" ]; then
        profile_ended_us="${EPOCHREALTIME/./}"
        _call_profile_record gh "$profile_started_us" "$profile_ended_us" 124 \
          "$profile_source" "$profile_function" "$profile_line" "${args[@]}"
      fi
      return 124
    }
    [ -z "$profile_started_us" ] || profile_started_us="${EPOCHREALTIME/./}"
    if command timeout --kill-after=5s "${attempt_timeout}s" gh "$@"; then
      if [ -n "$profile_started_us" ]; then
        profile_ended_us="${EPOCHREALTIME/./}"
        _call_profile_record gh "$profile_started_us" "$profile_ended_us" 0 \
          "$profile_source" "$profile_function" "$profile_line" "${args[@]}"
      fi
      if ! ticket_stage_record_gh_write "$@"; then
        echo "gh: issue #${3:-?} changed stage but transition could not be recorded" >&2
        return 1
      fi
      return 0
    else
      status=$?
      if [ -n "$profile_started_us" ]; then
        profile_ended_us="${EPOCHREALTIME/./}"
        _call_profile_record gh "$profile_started_us" "$profile_ended_us" "$status" \
          "$profile_source" "$profile_function" "$profile_line" "${args[@]}"
      fi
    fi
    [ "$status" -eq 124 ] && _bounded_call_timed_out \
      "gh: call timed out after ${attempt_timeout}s: gh $*"
    return "$status"
  fi

  stderr_file="$(mktemp)" || return 1
  for attempt in 1 2; do
    [ -z "$profile_started_us" ] || profile_started_us="${EPOCHREALTIME/./}"
    attempt_timeout="$(gh_tick_attempt_timeout_sec)" || {
      rm -f -- "$stderr_file"
      echo 'gh: refusing read because the owner-admission deadline cannot fit one bounded attempt' >&2
      if [ -n "$profile_started_us" ]; then
        profile_ended_us="${EPOCHREALTIME/./}"
        _call_profile_record gh "$profile_started_us" "$profile_ended_us" 124 \
          "$profile_source" "$profile_function" "$profile_line" "${args[@]}"
      fi
      return 124
    }
    : > "$stderr_file"
    [ -z "$profile_started_us" ] || profile_started_us="${EPOCHREALTIME/./}"
    if command timeout --kill-after=5s "${attempt_timeout}s" gh "$@" 2>"$stderr_file"; then
      if [ -n "$profile_started_us" ]; then
        profile_ended_us="${EPOCHREALTIME/./}"
        _call_profile_record gh "$profile_started_us" "$profile_ended_us" 0 \
          "$profile_source" "$profile_function" "$profile_line" "${args[@]}"
      fi
      cat "$stderr_file" >&2
      rm -f "$stderr_file"
      return 0
    else
      status=$?
      if [ -n "$profile_started_us" ]; then
        profile_ended_us="${EPOCHREALTIME/./}"
        _call_profile_record gh "$profile_started_us" "$profile_ended_us" "$status" \
          "$profile_source" "$profile_function" "$profile_line" "${args[@]}"
      fi
    fi
    stderr="$(cat "$stderr_file")"
    if [ "$attempt" -eq 1 ] && { [ "$status" -eq 124 ] || gh_failure_is_transient "$stderr"; }; then
      if ! gh_tick_retry_fits; then
        cat "$stderr_file" >&2
        rm -f -- "$stderr_file"
        echo 'gh: skipping read retry because its backoff and bounded attempt would cross the owner-admission deadline' >&2
        echo "gh: transient read failed after bounded retry: gh $*" >&2
        return "$status"
      fi
      echo "gh: transient read failed; retrying once after 2s backoff: gh $*" >&2
      sleep 2
      continue
    fi
    if [ "$status" -eq 124 ] || gh_failure_is_transient "$stderr"; then
      echo "gh: transient read failed after bounded retry: gh $*" >&2
    fi
    cat "$stderr_file" >&2
    rm -f "$stderr_file"
    [ "$status" -eq 124 ] && _bounded_call_timed_out \
      "gh: read timed out twice after ${attempt_timeout}s per attempt: gh $*"
    return "$status"
  done
}


# Preserve older short read deadlines while letting the optional scheduler
# profiler observe the actual bounded GitHub invocation at its callsite.
gh_timeout() {
  local timeout_value profile_source="" profile_function="" profile_line=0
  local profile_started_us="" profile_ended_us status=0
  local -a timeout_options=()
  while [[ "${1:-}" == -k || "${1:-}" == --kill-after ]]; do
    [ "$#" -ge 2 ] || return 2
    timeout_options+=("$1" "$2")
    shift 2
  done
  [ "$#" -ge 1 ] || return 2
  timeout_value="$1"
  shift
  if [ "${ZF_PIPELINE_CALL_PROFILE_ENABLED:-0}" = 1 ]; then
    profile_source="${BASH_SOURCE[1]:-}"
    profile_function="${FUNCNAME[1]:-main}"
    profile_line="${BASH_LINENO[0]:-0}"
    profile_source="${profile_source##*/}"
    profile_started_us="${EPOCHREALTIME/./}"
  fi
  if command timeout "${timeout_options[@]}" "$timeout_value" gh "$@"; then status=0; else status=$?; fi
  if [ -n "$profile_started_us" ]; then
    profile_ended_us="${EPOCHREALTIME/./}"
    _call_profile_record gh "$profile_started_us" "$profile_ended_us" "$status" \
      "$profile_source" "$profile_function" "$profile_line" "$@"
  fi
  return "$status"
}


# git_fetch_remove_stale_lock <repo_dir> <git_stderr> -- remove only an old
# lock path named by Git's ref-lock diagnostic inside this repository's git dir.
git_fetch_remove_stale_lock() {
  local dir="$1" stderr_file="$2" repo_dir line pattern lock_path=""
  local git_common_dir lock_parent lock_base lock_mtime lock_stat now age profile_started_us="" profile_ended_us profile_status profile_line=0
  pattern="['\"]([^'\"]+\\.lock)['\"]"
  while IFS= read -r line; do
    [[ "$line" == *"cannot lock ref"* || "$line" == *"Unable to create"* ]] || continue
    if [[ "$line" =~ $pattern ]]; then
      lock_path="${BASH_REMATCH[1]}"
      break
    fi
  done < "$stderr_file"
  [[ "$lock_path" == *.lock ]] || return 1

  repo_dir="$(cd -- "$dir" 2>/dev/null && pwd -P)" || return 1
  if [ "${ZF_PIPELINE_CALL_PROFILE_ENABLED:-0}" = 1 ]; then
    profile_line=$((LINENO + 1))
    profile_started_us="${EPOCHREALTIME/./}"
  fi
  if git_common_dir="$(command git -C "$repo_dir" rev-parse --git-common-dir 2>/dev/null)"; then
    profile_status=0
  else
    profile_status=$?
  fi
  if [ -n "$profile_started_us" ]; then
    profile_ended_us="${EPOCHREALTIME/./}"
    _call_profile_record git "$profile_started_us" "$profile_ended_us" "$profile_status" \
      lib.sh git_fetch_remove_stale_lock "$profile_line" -C "$repo_dir" rev-parse --git-common-dir
  fi
  [ "$profile_status" = 0 ] || return 1
  [[ "$git_common_dir" == /* ]] || git_common_dir="$repo_dir/$git_common_dir"
  git_common_dir="$(cd -- "$git_common_dir" 2>/dev/null && pwd -P)" || return 1
  [[ "$lock_path" == /* ]] || lock_path="$repo_dir/$lock_path"
  lock_parent="$(cd -- "$(dirname -- "$lock_path")" 2>/dev/null && pwd -P)" || return 1
  lock_base="$(basename -- "$lock_path")"
  case "$lock_parent/" in
    "$git_common_dir/"*) ;;
    *) return 1 ;;
  esac
  lock_path="$lock_parent/$lock_base"
  [[ -f "$lock_path" && ! -L "$lock_path" ]] || return 1

  lock_stat="$(stat -c '%d:%i:%Y' -- "$lock_path" 2>/dev/null)" || return 1
  lock_mtime="${lock_stat##*:}"
  [[ "$lock_mtime" =~ ^[0-9]+$ ]] || return 1
  now="$(date +%s)" || return 1
  age=$((now - lock_mtime))
  (( age > 120 )) || return 1
  [[ "$(stat -c '%d:%i:%Y' -- "$lock_path" 2>/dev/null)" == "$lock_stat" ]] || return 1
  now="$(date +%s)" || return 1
  age=$((now - lock_mtime))
  (( age > 120 )) || return 1

  rm -- "$lock_path" || return 1
  supervisor_inbox_append stale-git-lock "path=$lock_path age=$age" || {
    echo "git_fetch_bounded: removed stale lock but could not record it in the supervisor inbox" >&2
    return 1
  }
  return 0
}


# git_fetch_bounded <repo_dir> [ref ...] -- bounded `git -C <repo_dir> fetch
# -q origin [ref ...]`, the one git subcommand in these scripts that
# reaches the network. Call sites pass whatever ref args they already
# passed to the raw `git fetch` this replaces (usually just `main`).
agent_transport_is_transient() {
  grep -qiE 'Authentication failed|Permission denied|response (401|403|407)|returned error: (401|403|407)' <<< "$1" && return 1
  grep -qiE 'Proxy CONNECT aborted|CONNECT tunnel failed|failed to refresh available models.{0,160}(timed out|timeout)|GnuTLS.*(handshake failed|non-properly terminated)|TLS connection.*terminated|response 50[0-9]|HTTP[ /][0-9.]* 50[0-9]|returned error: 50[0-9]|TLS handshake timeout|connection (reset|timed out|refused)|Could not resolve (host|proxy)|Failed to connect|unexpected EOF|Operation timed out|Operation too slow|GnuTLS recv error|No route to host|Network is unreachable' <<< "$1"
}


agent_ref_update_race_is_transient() {
  grep -qiE 'cannot lock ref .*: is at ([0-9a-f]{40}|[0-9a-f]{64}) but expected ([0-9a-f]{40}|[0-9a-f]{64})' <<< "$1"
}


agent_fetch_failure_is_transient() {
  agent_transport_is_transient "$1" ||
    agent_ref_update_race_is_transient "$1" ||
    grep -qiE 'Unable to create .*\.lock.*File exists|Another git process seems to be running' <<< "$1"
}


git_fetch_bounded() {
  local dir="$1" status stderr_file trace_file transient_retries=0 retry_delay=1 stale_lock_retried=0 timeout_retried=0
  local profile_source="" profile_function="" profile_line=0 profile_started_us="" profile_ended_us
  local transient_retry_limit="${ZF_GIT_FETCH_TRANSIENT_RETRIES:-2}"
  if [ "${ZF_PIPELINE_CALL_PROFILE_ENABLED:-0}" = 1 ]; then
    profile_source="${BASH_SOURCE[1]:-}"
    profile_function="${FUNCNAME[1]:-main}"
    profile_line="${BASH_LINENO[0]:-0}"
    profile_source="${profile_source##*/}"
  fi
  [[ "$transient_retry_limit" =~ ^[0-9]+$ ]] || return 2
  shift
  # An omitted ref must never inherit the remote wildcard refspec.
  (($#)) || set -- main
  GIT_FETCH_LAST_TRANSIENT=0
  GIT_FETCH_LAST_STDERR=""
  stderr_file="$(mktemp)" || return 1
  # Phase timings for a fetch that times out: the 20s low-speed abort never
  # fired on the train's 2026-10-22 timeouts, so the stall is not an idle
  # transfer, and the timeout line alone cannot say which phase held it.
  trace_file="$(mktemp)" || { rm -f -- "$stderr_file"; return 1; }
  while :; do
    [ "${ZF_PIPELINE_CALL_PROFILE_ENABLED:-0}" != 1 ] || profile_started_us="${EPOCHREALTIME/./}"
    # A proxy tunnel can stall after CONNECT (2026-10-22: two back-to-back 60s
    # stalls failed the release train). Abort a stalled transfer after 20s so
    # the transient retry below gets a fresh tunnel inside the same budget.
    : > "$trace_file"
    if GIT_TRACE2_PERF="$trace_file" command timeout -k 10 "${GIT_FETCH_TIMEOUT_SEC}s" git -c http.lowSpeedLimit=1024 -c http.lowSpeedTime=20 -C "$dir" fetch --no-tags -q origin "$@" 2>"$stderr_file"; then
      status=0
    else
      status=$?
    fi
    if [ -n "$profile_started_us" ]; then
      profile_ended_us="${EPOCHREALTIME/./}"
      _call_profile_record git "$profile_started_us" "$profile_ended_us" "$status" \
        "$profile_source" "$profile_function" "$profile_line" -C "$dir" fetch --no-tags -q origin "$@"
    fi
    if [ "$status" -ne 0 ] && [ "$stale_lock_retried" -eq 0 ] && git_fetch_remove_stale_lock "$dir" "$stderr_file"; then
      stale_lock_retried=1
      : > "$stderr_file"
      continue
    fi
    # GNU timeout returns 137 when its kill-after SIGKILL ends a child that
    # ignored SIGTERM; preserve callers' existing timeout handling as 124.
    [ "$status" -eq 137 ] && status=124
    if [ "$status" -eq 124 ]; then
      echo "git fetch: last phases before the timeout (elapsed, region, child):" >&2
      awk -F'|' 'NF > 6 && $NF !~ /def_param|cmd_name|ancestry|version/ { print "  " $6 "|" $7 "|" $NF }' "$trace_file" \
        | sed -E 's#(https?://)[^/@[:space:]]+@#\1[redacted]@#g' | tail -n 12 >&2
    fi
    if [ "$status" -eq 124 ] && [ "$timeout_retried" -eq 0 ]; then
      echo "git fetch: timed out; retrying once in ${retry_delay}s" >&2
      sleep "$retry_delay"
      timeout_retried=1
      : > "$stderr_file"
      continue
    fi
    # A short transport flap or concurrent fetch can break a fetch before caller retry policy runs.
    if [ "$status" -ne 0 ] && [ "$status" -ne 124 ] && [ "$transient_retries" -lt "$transient_retry_limit" ] && \
      agent_fetch_failure_is_transient "$(cat "$stderr_file")"; then
      echo "git fetch: transient failure; retrying in ${retry_delay}s" >&2
      sleep "$retry_delay"
      transient_retries=$((transient_retries + 1))
      retry_delay=$((retry_delay * 2))
      : > "$stderr_file"
      continue
    fi
    break
  done
  if [ "$status" -eq 124 ] || { [ "$status" -ne 0 ] && agent_fetch_failure_is_transient "$(cat "$stderr_file")"; }; then
    GIT_FETCH_LAST_TRANSIENT=1
  fi
  GIT_FETCH_LAST_STDERR="$(head -c 512 "$stderr_file" | tr '\r\n\t' ' ' | sed -E 's#(https?://)[^/@[:space:]]+@#\1[redacted]@#g')"
  cat "$stderr_file" >&2
  rm -f -- "$stderr_file" "$trace_file"
  [ "$status" -eq 124 ] && _bounded_call_timed_out \
    "git fetch: timed out after ${GIT_FETCH_TIMEOUT_SEC}s: git -C $dir fetch origin $*"
  return "$status"
}


# A hand needs current main, its open PR branch and matching rescued work only.
git_fetch_hand_bounded() {
  local dir="$1" issue="$2" branch="${3:-}" remote_refs ref sha stderr_file status
  local -a refs=(main)
  [[ "$issue" =~ ^[1-9][0-9]*$ ]] || return 2
  [[ -z "$branch" ]] || refs+=("+refs/heads/$branch:refs/remotes/origin/$branch")
  stderr_file="$(mktemp)" || return 1
  if remote_refs="$(command timeout -k 10 "${GIT_FETCH_TIMEOUT_SEC}s" git -C "$dir" ls-remote --heads origin "refs/heads/rescued/*issue-$issue*" "refs/heads/rescued/*hand-$issue*" 2>"$stderr_file")"; then
    status=0
  else
    status=$?
  fi
  GIT_FETCH_LAST_STDERR="$(head -c 512 "$stderr_file" | tr '\r\n\t' ' ' | sed -E 's#(https?://)[^/@[:space:]]+@#\1[redacted]@#g')"
  rm -f -- "$stderr_file"
  GIT_FETCH_LAST_TRANSIENT=0
  if [[ "$status" != 0 ]]; then
    if [[ "$status" == 124 || "$status" == 137 ]] || agent_fetch_failure_is_transient "$GIT_FETCH_LAST_STDERR"; then
      GIT_FETCH_LAST_TRANSIENT=1
    fi
    return "$status"
  fi
  while read -r sha ref; do
    [[ -n "$ref" ]] || continue
    [[ "$ref" == refs/heads/rescued/* && "$ref" =~ (issue-|hand-)${issue}([^0-9]|$) ]] || continue
    git check-ref-format "$ref" || return 2
    refs+=("+$ref:refs/remotes/origin/${ref#refs/heads/}")
  done <<< "$remote_refs"
  git_fetch_bounded "$dir" "${refs[@]}"
}


# gh_failure_is_transient <gh_stderr_text> -- true (0) iff the text names a
# network/infra shape (DNS, TLS, a timeout, a connection reset, a 5xx or 429
# from api.github.com) rather than a genuine `gh` refusal (a 404, a
# permissions error, a malformed query/mutation). Built from a live case
# (zf-advisor-1205, 2026-09-15): `Post "https://api.github.com/graphql":
# net/http: TLS handshake timeout` crashed run-advisor.sh's own apply block
# under `set -e` -- unlike the SAME script's initial `gh issue view` call
# (which already routes any failure through record_env_fault(), because at
# that point in the run nothing has been charged to the ticket yet to
# refund), the later `gh issue comment`/`gh issue edit`/`notify_email_
# verbatim` calls that actually apply a verdict had no such handling at all
# and just died. Matches on the error TEXT, not on which `gh` subcommand or
# which stage called it, because the identical subcommand (gh issue
# comment/edit) can fail either way and only the text says which -- a 404 or
# a permissions error must stay a real failure (this pattern deliberately
# does NOT match any 4xx), never get treated as an environment fault that
# quietly drops a verdict a real `model call` call already paid for.
#
# `timed out after [0-9]+s` (2026-09-15, the #1204 incident): gh()'s own
# bounded-timeout message, added alongside it -- a caller like
# apply_gh_write() that captures `gh`'s stdout+stderr and checks this
# function must classify gh()'s own timeout the same way it already
# classifies the network-error text `gh` prints on its own, or the exact
# failure this function exists to catch (a transient network fault killing
# an already-computed verdict) would be misclassified as "a real failure"
# specifically because it was CAUGHT rather than left to hang.
gh_failure_is_transient() {
  grep -qiE 'TLS handshake timeout|i/o timeout|connection reset|connection refused|dial tcp|context deadline exceeded|Temporary failure in name resolution|Could not resolve host|net/http: |HTTP 5[0-9][0-9]|HTTP 429|too many requests|Gateway Timeout|Service Unavailable|Bad Gateway|unexpected EOF|timed out after [0-9]+s' <<< "$1"
}


main_gh() {
  if declare -F gh_q >/dev/null 2>&1; then gh_q "$@"; else gh "$@"; fi
}
