#!/usr/bin/env bash
set -uo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
REPO_DIR="${ZF_REPO_DIR:-$(cd -- "$SCRIPT_DIR/../.." && pwd -P)}"
H="${AGENT_HOME:-${ZF_HOME:-${HOME:?HOME is not set}/.zenoforge}}"
NIGHT="${ZF_NIGHT_DIR:-$H/night}"
mkdir -p -- "$NIGHT" || exit 1

write_result() {
  local path="$1" verdict="$2" result_detail="${3:0:240}" sampled_at tmp
  mkdir -p -- "$(dirname -- "$path")" || return 1
  sampled_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)" || return 1
  tmp="$(mktemp "${path}.XXXXXX")" || return 1
  if ! jq -n --arg at "$sampled_at" --arg verdict "$verdict" --arg result_detail "$result_detail" \
    '{sampled_at:$at,verdict:$verdict,detail:$result_detail}' > "$tmp" \
    || ! mv -f -- "$tmp" "$path"; then
    rm -f -- "$tmp"
    return 1
  fi
}

retain_output() {
  tail -c 65536 "$2" > "$NIGHT/$1.log"
}

last_output_line() {
  awk '!/^phase=worktree-reap:/ && !/^progress=/ && NF { gsub(/[[:space:]]+/, " "); line=$0 } END { if (line != "") print line }' "$1" | cut -c1-180
}

run_worktrees() {
  local output status detail stats failed=0 progress_line remote_progress_line verdict progress_cursor progress_total phase_line
  local remaining_seconds reserve_seconds
  local cursor_number total_number
  output="$(mktemp "$NIGHT/.worktree-reap-output.XXXXXX")" || {
    write_result "$NIGHT/worktree-reap-last-result.json" BROKEN 'could not create reaper output file'
    return $?
  }
  if timeout -k 5 "${ZF_WORKTREE_REAP_TIMEOUT_SECONDS:-180}" \
    bash "$REPO_DIR/engine/worktree-lifecycle.sh" reap "$REPO_DIR" >"$output" 2>&1; then
    status=0
  else
    status=$?
  fi
  retain_output worktree-reap "$output" || failed=1
  detail="$(last_output_line "$output")"
  if [ "$status" -eq 0 ]; then
    if [[ "$detail" =~ ^SLOW\ reaped=[0-9]{1,9}\ skipped-unreadable=[1-9][0-9]*$ ]]; then
      verdict=SLOW
    else
      verdict=OK
      detail="${detail:-worktree reap completed}"
    fi
  elif [ "$status" -eq 3 ]; then
    remote_progress_line="$(awk '/^progress=remote-batch / { count++; line=$0 } END { if (count == 1) print line }' "$output")"
    if [[ "$remote_progress_line" =~ ^progress=remote-batch[[:space:]]deferred=1[[:space:]]remaining_seconds=([0-9]{1,9})[[:space:]]reserve_seconds=([0-9]{1,9})$ ]]; then
      remaining_seconds="${BASH_REMATCH[1]}"
      reserve_seconds="${BASH_REMATCH[2]}"
      verdict=SLOW
      detail="${detail:+$detail; }remote batch remaining=${remaining_seconds}s reserve=${reserve_seconds}s"
    else
      progress_line="$(awk '/^progress=worktrees / { count++; line=$0 } END { if (count == 1) print line }' "$output")"
      if [[ "$progress_line" =~ ^progress=worktrees[[:space:]]next=([0-9]{1,9})[[:space:]]total=([0-9]{1,9})[[:space:]]removed_worktrees=[0-9]{1,9}[[:space:]]skipped_live=[0-9]{1,9}[[:space:]]skipped_safe=[0-9]{1,9}$ ]]; then
        progress_cursor="${BASH_REMATCH[1]}"
        progress_total="${BASH_REMATCH[2]}"
        cursor_number=$((10#$progress_cursor))
        total_number=$((10#$progress_total))
        if (( total_number > 0 && cursor_number < total_number )); then
          verdict=SLOW
          detail="${detail:+$detail; }worktree sweep progress=${cursor_number}/${total_number}"
        else
          verdict=BROKEN
          detail="worktree reap failed (exit $status)${detail:+: $detail}"
        fi
      else
        progress_line="$(awk '/^progress=owner-clones / { count++; line=$0 } END { if (count == 1) print line }' "$output")"
        if [[ "$progress_line" =~ ^progress=owner-clones[[:space:]]next=([0-9]{1,9})[[:space:]]total=([0-9]{1,9})$ ]]; then
          progress_cursor="${BASH_REMATCH[1]}"
          progress_total="${BASH_REMATCH[2]}"
          cursor_number=$((10#$progress_cursor))
          total_number=$((10#$progress_total))
          if (( total_number > 0 && cursor_number < total_number )); then
            verdict=SLOW
            detail="${detail:+$detail; }owner clone sweep progress=${cursor_number}/${total_number}"
          else
            verdict=BROKEN
            detail="worktree reap failed (exit $status)${detail:+: $detail}"
          fi
        else
          progress_line="$(awk '/^progress=main-patch-index / { count++; line=$0 } END { if (count == 1) print line }' "$output")"
          if [[ "$progress_line" =~ ^progress=main-patch-index[[:space:]]indexed=(-|[0-9a-f]{40,64})[[:space:]]pending=([0-9a-f]{40,64})[[:space:]]cursor=([0-9]{1,9})[[:space:]]total=([0-9]{1,9})[[:space:]]remaining_seconds=([0-9]{1,9})[[:space:]]reserve_seconds=([0-9]{1,9})$ ]]; then
            progress_cursor="${BASH_REMATCH[3]}"
            progress_total="${BASH_REMATCH[4]}"
            cursor_number=$((10#$progress_cursor))
            total_number=$((10#$progress_total))
            if (( cursor_number < total_number )); then
              verdict=SLOW
              detail="${detail:+$detail; }main patch index progress=${cursor_number}/${total_number}"
            else
              verdict=BROKEN
              detail="worktree reap failed (exit $status)${detail:+: $detail}"
            fi
          else
            verdict=BROKEN
            detail="worktree reap failed (exit $status)${detail:+: $detail}"
          fi
        fi
      fi
    fi
  else
    verdict=BROKEN
    phase_line="$(awk '/^phase=worktree-reap:(owner-ledger-read|origin-fetch|pr-list-query|worktree-sweep|stale-registration-prune|owner-clone-sweep|local-branch-sweep|remote-branch-sweep|remote-lease-readback|main-patch-index|rescue-issue-query|rescue-ref-sweep|rescue-patch-archive)$/ { phase=$0 } END { if (phase != "") print phase }' "$output")"
    [ -z "$phase_line" ] || detail="${detail:+$detail; }$phase_line"
    detail="worktree reap failed (exit $status)${detail:+: $detail}"
  fi
  write_result "$NIGHT/worktree-reap-last-result.json" "$verdict" "$detail" || failed=1
  rm -f -- "$output"

  output="$(mktemp "$NIGHT/.worktree-stats-output.XXXXXX")" || {
    write_result "$NIGHT/worktree-inventory-last-result.json" BROKEN 'could not create inventory output file'
    return $?
  }
  if timeout -k 5 "${ZF_WORKTREE_STATS_TIMEOUT_SECONDS:-45}" \
    bash "$REPO_DIR/engine/worktree-lifecycle.sh" stats "$REPO_DIR" >"$output" 2>&1; then
    stats="$(sed -n '1p' "$output")"
    if [[ "$stats" =~ ^worktrees=[0-9]+[[:space:]]local_branches=[0-9]+[[:space:]]remote_branches=[0-9]+[[:space:]]stale_over_24h=[0-9]+$ ]]; then
      write_result "$NIGHT/worktree-inventory-last-result.json" OK "$stats" || failed=1
    else
      write_result "$NIGHT/worktree-inventory-last-result.json" BROKEN 'worktree inventory output invalid' || failed=1
    fi
  else
    status=$?
    detail="$(last_output_line "$output")"
    write_result "$NIGHT/worktree-inventory-last-result.json" BROKEN "worktree inventory failed (exit $status)${detail:+: $detail}" || failed=1
  fi
  retain_output worktree-inventory "$output" || failed=1
  rm -f -- "$output"
  return "$failed"
}

run_maintainer_mail() {
  local output status detail partial_detail
  output="$(mktemp "$NIGHT/.maintainer-health-mail-output.XXXXXX")" || return 1
  timeout -k 5 "${ZF_MAINTAINER_HEALTH_MAIL_TIMEOUT_SECONDS:-120}" \
    bash "$REPO_DIR/engine/night/maintainer-health-mail.sh" tick 2>&1 | tail -c 65536 > "$output"
  status=${PIPESTATUS[0]}
  if ! retain_output maintainer-health-mail "$output"; then
    rm -f -- "$output"
    return 1
  fi
  detail="$(last_output_line "$output")"
  partial_detail="$(awk '/^maintainer health mail: partial-state-scan / { line=$0 } END { if (line != "") print line }' "$output")"
  rm -f -- "$output"
  if [ "$status" -eq 0 ]; then
    if [ -n "$partial_detail" ]; then
      write_result "$NIGHT/maintainer-health-mail-last-result.json" SLOW "$partial_detail"
    else
      write_result "$NIGHT/maintainer-health-mail-last-result.json" OK 'maintainer health mail tick completed'
    fi
  else
    write_result "$NIGHT/maintainer-health-mail-last-result.json" BROKEN "maintainer health mail tick failed (exit $status)${detail:+: $detail}"
  fi
}

# Hourly: flag a gh call site whose failure rate jumped (the meter is on while measure/gh.on exists; each host reads its own file).
run_gh_spikes() {
  local file="${ZF_GH_MEASURE_FILE:-$H/measure/gh-calls.tsv}" stamp="$NIGHT/gh-spikes.last" now site rate
  [ -s "$file" ] || return 0
  now="$(date +%s)"
  [ "$(( now - $(stat -c %Y "$stamp" 2>/dev/null || echo 0) ))" -ge 3600 ] || return 0
  : > "$stamp" || return 1
  python3 "$REPO_DIR/engine/gh-measure/summary.py" spikes "$file" | while IFS=$'\t' read -r site rate; do
    ( export AGENT_HOME="$H"; source "$REPO_DIR/engine/lib.sh"
      supervisor_inbox_append_once "gh-callsite-spike:$site" "gh-callsite-spike site=$site failed=$rate in the last hour" )
  done
}

run_maintenance() {
  local rc=0
  run_worktrees || rc=$?
  run_gh_spikes || true
  return "$rc"
}

case "${1:-}" in
  maintenance) run_maintenance ;;
  maintainer-mail) run_maintainer_mail ;;
  *) printf 'usage: %s maintenance|maintainer-mail\n' "$0" >&2; exit 2 ;;
esac
