#!/usr/bin/env bash
# Cache/label drift reconcile in issue_transition: a writer that edits stage
# labels out of band (2026-11-03 head-proxy arbiter ADMIT applies) moves the
# live GitHub label without $STATE_DIR/<n>.json, and the next
# mark_awaiting_release refused needs-advisor -> awaiting-release
# (reason=merged-pr) on the stale cached "from" while the live label was
# already ready-for-agent -- a row the table allows. On refusal the live
# label is the authority: continue from it, log one drift line, and leave
# cache and label equal through the ordinary state and label writes.
set -euo pipefail
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/test-env.sh"

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
source "$SCRIPT_DIR/lib.sh"

roadmap_ensure_issue_parent() { :; }
ensure_state_labels() { :; }
GH_WRITES="$AGENT_HOME/gh-writes"
guarded_write() { printf '%s\n' "$*" >> "$GH_WRITES"; return 0; }

# Live GitHub labels per issue, as `gh issue view --json labels` reports them.
declare -A LIVE_LABELS=()
gh() {
  printf '%s\n' "$*" >> "$AGENT_HOME/gh-calls.log"
  if [ "${1:-}" = issue ] && [ "${2:-}" = view ]; then
    local n="$3" label
    local -a parts=()
    IFS=',' read -r -a parts <<< "${LIVE_LABELS[$n]:-}"
    for label in "${parts[@]}"; do printf '%s\n' "$label"; done
    return 0
  fi
  if [ "${1:-}" = issue ] && [ "${2:-}" = list ]; then
    return 0
  fi
  echo "unexpected gh call in test: $*" >&2
  return 1
}

# mark_awaiting_release (conclude-run.sh) is the production caller whose
# refusal stranded the merged issues; exercise the drift through it.
LIVE_LABELS[5310]="enhancement,ready-for-agent,focus"
state_merge 5310 '{"state":"needs-advisor"}'
drift_err="$(mktemp)"
if ! mark_awaiting_release 5310 5264 2>"$drift_err"; then
  echo 'not ok - merged-pr transition still refused while the live label allows it' >&2
  cat "$drift_err" >&2
  exit 1
fi
grep -Fq 'issue_transition: state drift #5310 cached=needs-advisor label=ready-for-agent' "$drift_err" || {
  echo 'not ok - drift line missing or malformed' >&2
  cat "$drift_err" >&2
  exit 1
}
[[ "$(state_read 5310 | jq -r .state)" == awaiting-release ]]
grep -Fq -- '--add-label awaiting-release' "$GH_WRITES"
grep -Fq -- '--remove-label ready-for-agent' "$GH_WRITES"
grep -Fq -- '--remove-label needs-advisor' "$GH_WRITES"
echo 'ok - merged-pr -> awaiting-release succeeds from the live label and logs the drift'

# The reconciled writer must leave the two surfaces equal: GitHub now shows
# exactly the stage label the state file caches.
LIVE_LABELS[5310]="enhancement,awaiting-release,focus"
[[ "$(issue_transition_live_label_state 5310)" == "$(state_read 5310 | jq -r .state)" ]] || {
  echo 'not ok - cached state and live label disagree after the reconciled transition' >&2
  exit 1
}
echo 'ok - reconciled transition leaves cache and live label equal'

# No drift -> no escape hatch: with the live label agreeing with the cache,
# the unsupported needs-advisor -> awaiting-release transition stays refused.
LIVE_LABELS[5311]="needs-advisor"
state_merge 5311 '{"state":"needs-advisor"}'
refuse_err="$(mktemp)"
if mark_awaiting_release 5311 5265 2>"$refuse_err"; then
  echo 'not ok - transition allowed from needs-advisor without drift' >&2
  exit 1
fi
grep -Fq 'issue_transition: refused #5311 needs-advisor -> awaiting-release (reason=merged-pr)' "$refuse_err" || {
  echo 'not ok - plain refusal line missing' >&2
  cat "$refuse_err" >&2
  exit 1
}
if grep -Fq 'state drift' "$refuse_err"; then
  echo 'not ok - drift line logged without drift' >&2
  exit 1
fi
[[ "$(state_read 5311 | jq -r .state)" == needs-advisor ]]
if grep -Fq -- 'issue edit 5311' "$GH_WRITES"; then
  echo 'not ok - refused transition wrote labels' >&2
  exit 1
fi
echo 'ok - agreeing live label keeps the refusal and writes nothing'

# Drift whose live origin is ALSO not allowed for this reason must not pass.
LIVE_LABELS[5312]="ready-for-human"
state_merge 5312 '{"state":"needs-advisor"}'
stay_err="$(mktemp)"
if mark_awaiting_release 5312 5266 2>"$stay_err"; then
  echo 'not ok - transition allowed from a live label the table forbids' >&2
  exit 1
fi
grep -Fq 'issue_transition: refused #5312 needs-advisor -> awaiting-release (reason=merged-pr)' "$stay_err" || {
  echo 'not ok - refusal line missing for disallowed live origin' >&2
  cat "$stay_err" >&2
  exit 1
}
echo 'ok - drift to a disallowed live origin still refuses'

echo 'ok - all issue_transition drift reconcile checks passed'
