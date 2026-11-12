#!/usr/bin/env bash
# Cache/label drift reconcile in issue_transition: a writer that edits stage
# labels out of band (2026-11-03 head-proxy arbiter ADMIT applies) moves the
# live GitHub label without $STATE_DIR/<n>.json. needs-advisor ->
# ready-for-human remains refused by ISSUE_TRANSITION_TABLE, while the live
# ready-for-agent -> ready-for-human transition is allowed. On refusal the
# live label is the authority: continue from it, log one drift line, and leave
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

# Exercise the transition refusal path directly with a table-refused pair.
LIVE_LABELS[5310]="enhancement,ready-for-agent,focus"
state_merge 5310 '{"state":"needs-advisor"}'
drift_err="$(mktemp)"
if ! issue_transition 5310 ready-for-human supervisor-reconcile 2>"$drift_err"; then
  echo 'not ok - table-refused transition still refused while the live label allows it' >&2
  cat "$drift_err" >&2
  exit 1
fi
grep -Fq 'issue_transition: state drift #5310 cached=needs-advisor label=ready-for-agent' "$drift_err" || {
  echo 'not ok - drift line missing or malformed' >&2
  cat "$drift_err" >&2
  exit 1
}
[[ "$(state_read 5310 | jq -r .state)" == ready-for-human ]]
grep -Fq -- '--add-label ready-for-human' "$GH_WRITES"
grep -Fq -- '--remove-label ready-for-agent' "$GH_WRITES"
grep -Fq -- '--remove-label needs-advisor' "$GH_WRITES"
echo 'ok - table-refused -> ready-for-human succeeds from the live label and logs the drift'

# The reconciled writer must leave the two surfaces equal: GitHub now shows
# exactly the stage label the state file caches.
LIVE_LABELS[5310]="enhancement,ready-for-human,focus"
[[ "$(issue_transition_live_label_state 5310)" == "$(state_read 5310 | jq -r .state)" ]] || {
  echo 'not ok - cached state and live label disagree after the reconciled transition' >&2
  exit 1
}
echo 'ok - reconciled transition leaves cache and live label equal'

# No drift -> no escape hatch: with the live label agreeing with the cache,
# needs-advisor -> ready-for-human stays refused by ISSUE_TRANSITION_TABLE.
LIVE_LABELS[5311]="needs-advisor"
state_merge 5311 '{"state":"needs-advisor"}'
refuse_err="$(mktemp)"
if issue_transition 5311 ready-for-human supervisor-reconcile 2>"$refuse_err"; then
  echo 'not ok - transition allowed from needs-advisor without drift' >&2
  exit 1
fi
grep -Fq 'issue_transition: refused #5311 needs-advisor -> ready-for-human (reason=supervisor-reconcile)' "$refuse_err" || {
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
LIVE_LABELS[5312]="checks-blocked"
state_merge 5312 '{"state":"needs-advisor"}'
stay_err="$(mktemp)"
if issue_transition 5312 ready-for-human supervisor-reconcile 2>"$stay_err"; then
  echo 'not ok - transition allowed from a live label the table forbids' >&2
  exit 1
fi
grep -Fq 'issue_transition: refused #5312 needs-advisor -> ready-for-human (reason=supervisor-reconcile)' "$stay_err" || {
  echo 'not ok - refusal line missing for disallowed live origin' >&2
  cat "$stay_err" >&2
  exit 1
}
echo 'ok - drift to a disallowed live origin still refuses'

# A refusal that used to return 1 with no output (roadmap parent placement
# failed; 2026-11-05 two issues ended rc=1 with an empty reason) must name the
# issue and the reason on stderr.
roadmap_ensure_issue_parent() { return 1; }
state_merge 5313 '{"state":"needs-advisor"}'
silent_err="$(mktemp)"
if issue_transition 5313 needs-triage supervisor-reconcile 2>"$silent_err"; then
  echo 'not ok - transition passed although the roadmap parent check failed' >&2
  exit 1
fi
grep -Fq 'issue_transition: roadmap parent check failed for #5313 -> needs-triage (rc=1)' "$silent_err" || {
  echo 'not ok - silent failure still has no reason line' >&2
  cat "$silent_err" >&2
  exit 1
}
echo 'ok - a failed roadmap parent check prints the issue and the reason'

# A rate-limited tree read is not a refusal (queue row 346: one GitHub burst
# limit on the graphql read held a ruling-released transition). The real
# roadmap_ensure_issue_parent runs against a gh that refuses the read.
unset -f roadmap_ensure_issue_parent
source "$SCRIPT_DIR/roadmap.sh"
export REPO=fixture/repo MODEL_POLICY_FILE="$AGENT_HOME/model-policy.json"
unset ZF_ROADMAP_TREE_CACHE_FILE
printf '{"switches":{"roadmap-order":true}}\n' > "$MODEL_POLICY_FILE"
export PARENT_GH_RESPONSE="$AGENT_HOME/parent-response.json" PARENT_GH_FAIL="$AGENT_HOME/parent-gh-fail"
cat > "$test_env_bin/gh" <<'GH'
#!/usr/bin/env bash
[[ "${1:-}" == api ]] || exit 0
if [[ -f "$PARENT_GH_FAIL" ]]; then
  echo 'gh: API rate limit already exceeded for user ID 1.' >&2
  exit 1
fi
cat "$PARENT_GH_RESPONSE"
GH
chmod +x "$test_env_bin/gh"
jq -cn '[{data:{repository:{issues:{nodes:[
  {number:1,title:"Roadmap",state:"OPEN",labels:{nodes:[{name:"roadmap"}]},subIssues:{nodes:[{number:2}]}},
  {number:2,title:"Ready",state:"OPEN",labels:{nodes:[]},subIssues:{nodes:[]}}
]}}}}]' > "$PARENT_GH_RESPONSE"

: > "$PARENT_GH_FAIL"
state_merge 5314 '{"state":"needs-advisor"}'
rate_err="$(mktemp)"
if ! issue_transition 5314 needs-triage supervisor-reconcile 2>"$rate_err"; then
  echo 'not ok - a rate-limited tree read refused the transition' >&2
  cat "$rate_err" >&2
  exit 1
fi
grep -Fq 'roadmap: tree fetch failed for #5314 (stage needs-triage, gh api graphql): gh: API rate limit already exceeded' "$rate_err" || {
  echo 'not ok - rate-limited tree read has no warning naming the call and the limit' >&2
  cat "$rate_err" >&2
  exit 1
}
[[ "$(state_read 5314 | jq -r .state)" == needs-triage ]]
echo 'ok - a rate-limited tree read warns and lets the transition continue'

# A real refusal stays one: a confirmed roadmap container is refused with rc 3
# and the state is untouched, even though the tree read itself now succeeds.
rm -f -- "$PARENT_GH_FAIL"
state_merge 1 '{"state":"needs-advisor"}'
container_err="$(mktemp)"
rc=0
issue_transition 1 needs-triage supervisor-reconcile 2>"$container_err" || rc=$?
[[ "$rc" == 3 ]] || {
  echo "not ok - confirmed container transition rc=$rc, want 3" >&2
  cat "$container_err" >&2
  exit 1
}
[[ "$(state_read 1 | jq -r .state)" == needs-advisor ]]
grep -Fq 'roadmap: refusing stage needs-triage on container #1' "$container_err" || {
  echo 'not ok - container refusal has no reason line' >&2
  exit 1
}
echo 'ok - a confirmed roadmap container is still refused with rc 3'

echo 'ok - all issue_transition drift reconcile checks passed'
