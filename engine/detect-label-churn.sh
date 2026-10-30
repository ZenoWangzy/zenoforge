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
  local n
  # Every issue currently carrying either watched label is a candidate --
  # this is the live population that COULD be mid-churn; an issue that
  # already left both states isn't churning right now regardless of its
  # past history.
  for n in $(gh issue list --repo "$REPO" --limit 1000 --label "$WATCHED_A" --state open --json number -q '.[].number'; \
             gh issue list --repo "$REPO" --limit 1000 --label "$WATCHED_B" --state open --json number -q '.[].number'); do
    detect_one "$n"
  done
}

main "$@"
