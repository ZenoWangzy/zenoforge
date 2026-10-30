#!/usr/bin/env bash
# sweep-parked-backlog.sh: a repeatable, committed sweep for tickets parked
# on ready-for-human BEFORE the ladder existed (2026-09-15, "every run
# concludes with an account of itself" -- see docs/agents/issue-pipeline.md
# "Every run concludes with an account of itself"). Maintainer ruling: the
# entry gate may ask him, but once a ticket is IN FLIGHT nothing waits for
# a human -- a ticket that entered the pipeline and then parked on
# ready-for-human is exactly what the ladder exists to eliminate. Every
# issue carrying ready-for-human today predates that ladder, so this is a
# one-time backlog catch-up, written as a script (not a hand-run one-off)
# because it needs to be repeatable and reviewable, and it will run again --
# a human can relabel an issue back to ready-for-human by hand at any time,
# and this sweep is what recovers it.
#
# Criterion, precise rather than a blanket relabel:
#   state file exists AND .attempts >= 1  -> was dispatched at least once
#     (issue-pipeline.sh's dispatch() bumps .attempts once per implement
#     dispatch, before the wrapper even starts -- see run-implement.sh's
#     own fail_attempt() comment) -- IN FLIGHT, so it climbs: route to
#     needs-advisor and let the advisor choose its rung.
#   no state file, or attempts == 0        -> never actually entered the
#     autonomy set (triage's own ready-for-human verdict at the gate, or a
#     human hand-labeled it without any dispatch ever touching it) --
#     ready-for-human is legitimate here. Left alone.
#
# Deliberately does NOT call conclude_run(): as of this writing `concluded`
# has never fired in production (0 issues carry it) -- this sweep is a
# plain relabel, the same guarded_write gh issue edit/comment mechanism
# every leg has used since before conclude_run existed, so it does not
# depend on a path nothing has exercised live yet.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./lib.sh
source "$SCRIPT_DIR/lib.sh"

ensure_state_labels

routed=0
left_no_state=0
left_zero_attempts=0
left_on_hold=0

for n in $(gh issue list --repo "$REPO" --limit 1000 --label ready-for-human --state open \
    --json number -q '.[].number'); do
  if is_on_hold "$n"; then
    echo "sweep: #$n -- on-hold, a human explicitly paused this ticket; leaving untouched" >&2
    left_on_hold=$((left_on_hold + 1))
    continue
  fi
  f="$(state_file "$n")"
  if [ ! -f "$f" ]; then
    echo "sweep: #$n -- no state file, never entered the pipeline; leaving ready-for-human" >&2
    left_no_state=$((left_no_state + 1))
    continue
  fi
  attempts="$(state_attempts "$n")"
  if [ "$attempts" -lt 1 ]; then
    echo "sweep: #$n -- state file exists but attempts=$attempts, never dispatched; leaving ready-for-human" >&2
    left_zero_attempts=$((left_zero_attempts + 1))
    continue
  fi
  echo "sweep: #$n -- attempts=$attempts, was in flight; routing to needs-advisor" >&2
  route_to_advisor "$n" ready-for-human
  [ "$ISSUE_VERDICT_GUARD_SKIPPED" != "1" ] || continue
  guarded_write gh issue comment "$n" --repo "$REPO" --body "$BOT_DISCLAIMER
这张票在「进了 pipeline 就要走到结果，不接受中间断开等人」这条裁决落地之前就已经停在 ready-for-human——它的状态文件显示已经被实际派发过（attempts=${attempts}），说明它曾经进过流水线，不是在入口就被判给人的。按新规则回收：转给顾问重新判一次去向，而不是继续停在这里。"
  routed=$((routed + 1))
done

echo "sweep: done -- routed=$routed, left(on-hold)=$left_on_hold, left(no state file)=$left_no_state, left(attempts=0)=$left_zero_attempts" >&2
