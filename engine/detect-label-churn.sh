#!/usr/bin/env bash
# Freeze an issue that keeps flipping between ready-for-agent and
# needs-advisor. loop_break_check() records the trajectory, holds the ticket,
# and returns it through the scheduler. Inline route callers stop when the shared check
# freezes the ticket. This periodic timer stays independent of AGENT_PIPELINE
# so it can stop a loop while the scheduler is paused.
#
# GitHub's timeline supplies durable transition timestamps. The latest event
# keys an episode in state, so repeated scans do not repeat the freeze notice.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=./lib.sh
source "$SCRIPT_DIR/lib.sh"

# These are the pair observed in the advisor routing loop.
WATCHED_A="ready-for-agent"
WATCHED_B="needs-advisor"

detect_one() {
  local n="$1"
  # The shared function owns detection, freeze, and episode deduplication.
  loop_break_check "$n" "$WATCHED_A" "$WATCHED_B"
}

main() {
  local n updated_at updated_epoch last_pass="" pass_started issues stamp_file stamp_tmp
  stamp_file="$STATE_DIR/detect-label-churn.last-pass"
  IFS= read -r last_pass < "$stamp_file" 2>/dev/null || last_pass=""
  [[ "$last_pass" =~ ^[0-9]+$ ]] || last_pass=""
  # GitHub timestamps have second precision; overlap the start boundary by one second.
  pass_started="$(date -u -d '1 second ago' +%s)" || return 1
  issues="$(
    gh issue list --repo "$REPO" --limit 1000 --label "$WATCHED_A" --state open --json number,updatedAt -q '.[] | [.number, .updatedAt] | @tsv' &&
    gh issue list --repo "$REPO" --limit 1000 --label "$WATCHED_B" --state open --json number,updatedAt -q '.[] | [.number, .updatedAt] | @tsv'
  )" || return 1
  # Every issue currently carrying either watched label is a candidate --
  # this is the live population that COULD be mid-churn; an issue that
  # already left both states isn't churning right now regardless of its
  # past history.
  while IFS=$'\t' read -r n updated_at; do
    [[ -n "$n" ]] || continue
    [[ "$n" =~ ^[0-9]+$ && -n "$updated_at" ]] || return 1
    updated_epoch="$(date -u -d "$updated_at" +%s 2>/dev/null)" || return 1
    [[ "$updated_epoch" =~ ^[0-9]+$ ]] || return 1
    [[ -z "$last_pass" ]] || (( updated_epoch > last_pass )) || continue
    detect_one "$n"
  done <<<"$issues"
  mkdir -p -- "$STATE_DIR" || return 1
  stamp_tmp="$(mktemp "$stamp_file.XXXXXX")" || return 1
  if ! printf '%s\n' "$pass_started" >"$stamp_tmp" || ! mv -f -- "$stamp_tmp" "$stamp_file"; then
    rm -f -- "$stamp_tmp"
    return 1
  fi
}

main "$@"
