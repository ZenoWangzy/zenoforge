#!/usr/bin/env bash
# Supervisor inbox and wake-budget cases from the library suite.
set -euo pipefail
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/test-env.sh"
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/test-lib-helpers.sh"
# Supervisor events must use the shared append seam so every inbox wake is
# counted, and each metric row must remain one line.
if declare -F supervisor_inbox_append >/dev/null; then
  AGENT_HOME="$INBOX_HELPER_HOME"
  if supervisor_inbox_append test-kind $'alpha\nbeta\tgamma\rdelta'; then
    assert_eq 'shared inbox helper writes one inbox event' 1 "$(wc -l < "$INBOX_HELPER_HOME/supervisor-inbox" | tr -d '[:space:]')"
    assert_eq 'shared inbox helper writes one wake row' 1 "$(wc -l < "$INBOX_HELPER_HOME/logs/supervisor-wakes.log" | tr -d '[:space:]')"
    assert_true 'shared inbox event starts with a UTC timestamp' grep -Eq '^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z test-kind alpha beta gamma delta$' "$INBOX_HELPER_HOME/supervisor-inbox"
    assert_true 'wake log stores timestamp, kind, and sanitized text' grep -Eq $'^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z\ttest-kind\talpha beta gamma delta$' "$INBOX_HELPER_HOME/logs/supervisor-wakes.log"
    assert_eq 'inbox and wake rows share the timestamp' \
      "$(awk '{print $1}' "$INBOX_HELPER_HOME/supervisor-inbox")" \
      "$(awk -F '\t' '{print $1}' "$INBOX_HELPER_HOME/logs/supervisor-wakes.log")"
  else
    echo 'not ok - shared inbox helper appends event'
    FAILED=1
  fi
  # The supervisor empties the inbox after each wake; the same key must not
  # come back until its 24-hour window has passed.
  : > "$INBOX_HELPER_HOME/supervisor-inbox"
  supervisor_inbox_append_once 'once-key trace_ids=abc' 'once-key trace_ids=abc first'
  : > "$INBOX_HELPER_HOME/supervisor-inbox"
  supervisor_inbox_append_once 'once-key trace_ids=abc' 'once-key trace_ids=abc again'
  assert_eq 'append_once remembers a key after the inbox is emptied' 0 "$(wc -l < "$INBOX_HELPER_HOME/supervisor-inbox" | tr -d '[:space:]')"
  printf '%s\t%s\n' "$(( $(date +%s) - 90000 ))" 'old-key' > "$INBOX_HELPER_HOME/supervisor-inbox.once"
  supervisor_inbox_append_once 'old-key' 'old-key recurs'
  assert_eq 'append_once sends a key again after 24 hours' 1 "$(grep -c 'old-key recurs' "$INBOX_HELPER_HOME/supervisor-inbox")"
  assert_eq 'append_once prunes expired keys' 1 "$(grep -c 'old-key' "$INBOX_HELPER_HOME/supervisor-inbox.once")"
  : > "$INBOX_HELPER_HOME/supervisor-inbox"
  : > "$INBOX_HELPER_HOME/logs/supervisor-wakes.log"
  supervisor_inbox_append_once 'external-deliverable issue=#990002' \
    'external-deliverable issue=#990002 route=supervisor'
  supervisor_inbox_append_once 'external-deliverable issue=#990002' \
    'external-deliverable issue=#990002 route=supervisor'
  assert_eq 'external route is informational and appears once' 1 \
    "$(grep -c 'external-deliverable issue=#990002' "$INBOX_HELPER_HOME/supervisor-inbox")"
  assert_eq 'external route does not wake supervisor' 0 \
    "$(wc -l < "$INBOX_HELPER_HOME/logs/supervisor-wakes.log" | tr -d '[:space:]')"
  AGENT_HOME="$LIB_TEST_AGENT_HOME"
else
  echo 'not ok - shared inbox helper is defined in lib.sh'
  FAILED=1
fi

OPS_TRANSITION_HOME="$(mktemp -d)"
jq '.switches["roadmap-order"] = false | .roles.advisor.disabled = false' "$SCRIPT_DIR/model-policy.default.json" > "$OPS_TRANSITION_HOME/model-policy.json"
OPS_TRANSITION_STATUS=0
OPS_TRANSITION_OUT="$(AGENT_HOME="$OPS_TRANSITION_HOME" REPO=test/repo bash -c '
  set -euo pipefail
  source "$1/lib.sh"
  DRY_RUN=0 AGENT_DRY_RUN=0
  guarded_write() { :; }
  ensure_state_labels() { :; }
  issue_label_cache_invalidate() { :; }
  ticket_stage_record() { :; }
  roadmap_ensure_issue_parent() { :; }
  state_merge 990003 '\''{"state":"on-hold","deployed_sha":"sha-good","deploy_state":"pending","run":{"outcome":"merged","evidence":{"pr_number":990003}},"ops_acceptance_after_release":{"required":true,"status":"pending","release_sha":"","evidence":""}}'\''
  if issue_transition 990003 awaiting-release ops-acceptance-passed; then exit 21; fi
  state_merge 990003 '\''.ops_acceptance_after_release.status="passed" | .ops_acceptance_after_release.release_sha="sha-old" | .ops_acceptance_after_release.evidence="observed"'\''
  if issue_transition 990003 awaiting-release ops-acceptance-passed; then exit 22; fi
  state_merge 990003 '\''.ops_acceptance_after_release.release_sha="sha-good"'\''
  issue_transition 990003 awaiting-release ops-acceptance-passed
  jq -e '\''.state == "awaiting-release" and .hold == null and .ops_acceptance_after_release.release_sha == .deployed_sha'\'' \
    "$STATE_DIR/990003.json" >/dev/null
' _ "$SCRIPT_DIR" 2>&1)" || OPS_TRANSITION_STATUS=$?
assert_eq 'ops acceptance releases hold only with evidence for deployed SHA' 0 "$OPS_TRANSITION_STATUS"
assert_contains 'pending and stale-SHA ops acceptance were both rejected' "$OPS_TRANSITION_OUT" \
  'refusing ops acceptance release for #990003 without evidence for the deployed SHA'
rm -rf -- "$OPS_TRANSITION_HOME"
if [[ "${LIB_TEST_OPS_TRANSITION_ONLY:-0}" == 1 ]]; then lib_case_exit; fi

# The one-time helper must use the shared writer and keep its daily ticket
# collapse outside the inbox, which the supervisor clears after each wake.
INBOX_ONCE_HOME="$(mktemp -d)"
AGENT_HOME="$INBOX_ONCE_HOME"
supervisor_inbox_append_once 'repeat-dispatch issue=#990001 run=2' \
  'repeat-dispatch issue=#990001 unit=implement run=2'
: > "$INBOX_ONCE_HOME/supervisor-inbox"
supervisor_inbox_append_once 'repeat-dispatch issue=#990001 run=3' \
  'repeat-dispatch issue=#990001 unit=implement run=3'
: > "$INBOX_ONCE_HOME/supervisor-inbox"
supervisor_inbox_append_once 'repeat-dispatch issue=#990001 run=4' \
  'repeat-dispatch issue=#990001 unit=implement run=4'
assert_eq 'append-once events collapse ordinary repeats by ticket/class/day' 2 \
  "$(wc -l < "$INBOX_ONCE_HOME/logs/supervisor-wakes.log" | tr -d '[:space:]')"
assert_false 'repeat-dispatch run=3 stays collapsed' \
  grep -Fq $'\trepeat-dispatch\trepeat-dispatch issue=#990001 unit=implement run=3' "$INBOX_ONCE_HOME/logs/supervisor-wakes.log"
assert_true 'repeat-dispatch run=4 wakes as a loop signal' \
  grep -Fq $'\trepeat-dispatch\trepeat-dispatch issue=#990001 unit=implement run=4' "$INBOX_ONCE_HOME/logs/supervisor-wakes.log"
rm -rf -- "$INBOX_ONCE_HOME"

# Run >=4 bypasses per-ticket collapse, action-rate demotion, and daily budget.
INBOX_LOOP_HOME="$(mktemp -d)"
AGENT_HOME="$INBOX_LOOP_HOME"
mkdir -p "$INBOX_LOOP_HOME/logs" "$INBOX_LOOP_HOME/night"
loop_day="$(date -u +%Y-%m-%d)"
for budget_seed in $(seq 1 16); do
  printf '%sT00:00:00Z\trepeat-dispatch\tissue=#991%03d unit=implement run=2\n' \
    "$loop_day" "$budget_seed" >> "$INBOX_LOOP_HOME/logs/supervisor-wakes.log"
done
supervisor_inbox_append repeat-dispatch 'issue=#991999 unit=implement run=2'
printf '{"date":"%s","demoted_classes":["repeat-dispatch"]}\n' "$loop_day" \
  > "$INBOX_LOOP_HOME/night/supervisor-alert-policy.json"
supervisor_inbox_append repeat-dispatch 'issue=#991999 unit=implement run=4'
assert_true 'repeat-dispatch run=4 bypasses collapse, demotion, and budget' \
  grep -Fq $'\trepeat-dispatch\tissue=#991999 unit=implement run=4' "$INBOX_LOOP_HOME/logs/supervisor-wakes.log"
assert_true 'loop signal event is recorded as a wake' \
  jq -se 'any(.[]; .kind == "repeat-dispatch" and .decision == "wake" and any(.targets[]; .id == "991999"))' \
    "$INBOX_LOOP_HOME"/logs/supervisor-alerts-*.jsonl
rm -rf -- "$INBOX_LOOP_HOME"

# Per-target collapse for actionable classes; exact-text collapse without targets.
INBOX_COLLAPSE_HOME="$(mktemp -d)"
AGENT_HOME="$INBOX_COLLAPSE_HOME"
supervisor_inbox_append main-red-suite 'same failure text'
supervisor_inbox_append main-red-suite 'same failure text'
supervisor_inbox_append main-red-suite 'different failure text'
supervisor_inbox_append pipeline-ci-auto-revert 'issue=#990021 reason=first'
supervisor_inbox_append pipeline-ci-auto-revert 'issue=#990021 reason=second'
assert_eq 'same kind and target set collapse despite changed detail' 1 \
  "$(grep -cF $'\tpipeline-ci-auto-revert\t' "$INBOX_COLLAPSE_HOME/logs/supervisor-wakes.log")"
assert_eq 'targetless alerts collapse only when text matches exactly' 2 \
  "$(grep -cF $'\tmain-red-suite\t' "$INBOX_COLLAPSE_HOME/logs/supervisor-wakes.log")"
rm -rf -- "$INBOX_COLLAPSE_HOME"

# The default class budget is 20, independently for each class.
INBOX_DEFAULT_HOME="$(mktemp -d)"
AGENT_HOME="$INBOX_DEFAULT_HOME"
for budget_case in $(seq 1 21); do
  supervisor_inbox_append main-red-suite "finding=$budget_case"
  supervisor_inbox_append pipeline-ci-auto-revert "finding=$budget_case"
done
assert_eq 'default class budget allows 20 main-red-suite wakes' 20 \
  "$(awk -F '\t' '$2 == "main-red-suite" { count++ } END { print count + 0 }' "$INBOX_DEFAULT_HOME/logs/supervisor-wakes.log")"
assert_eq 'default class budget allows 20 pipeline-ci-auto-revert wakes' 20 \
  "$(awk -F '\t' '$2 == "pipeline-ci-auto-revert" { count++ } END { print count + 0 }' "$INBOX_DEFAULT_HOME/logs/supervisor-wakes.log")"
rm -rf -- "$INBOX_DEFAULT_HOME"

# ticket-progress wakes once per ticket/day and still honors action-rate demotion.
INBOX_PROGRESS_HOME="$(mktemp -d)"
AGENT_HOME="$INBOX_PROGRESS_HOME"
supervisor_inbox_append ticket-progress 'issue=#990101 status=STUCK reason=first'
supervisor_inbox_append ticket-progress 'issue=#990101 status=STUCK reason=repeat'
supervisor_inbox_append ticket-progress 'issue=#990102 status=STUCK reason=first'
assert_eq 'ticket-progress wakes first STUCK for each ticket' 2 \
  "$(grep -cF $'\tticket-progress\t' "$INBOX_PROGRESS_HOME/logs/supervisor-wakes.log")"
mkdir -p "$INBOX_PROGRESS_HOME/night"
progress_day="$(date -u +%Y-%m-%d)"
printf '{"date":"%s","demoted_classes":["ticket-progress"]}\n' "$progress_day" \
  > "$INBOX_PROGRESS_HOME/night/supervisor-alert-policy.json"
supervisor_inbox_append ticket-progress 'issue=#990103 status=STUCK reason=demoted'
assert_eq 'ticket-progress remains subject to action-rate demotion' 2 \
  "$(grep -cF $'\tticket-progress\t' "$INBOX_PROGRESS_HOME/logs/supervisor-wakes.log")"
assert_true 'ticket-progress demotion is recorded for the health report' \
  jq -se 'any(.[]; .kind == "ticket-progress" and .decision == "action-rate")' \
    "$INBOX_PROGRESS_HOME"/logs/supervisor-alerts-*.jsonl
rm -rf -- "$INBOX_PROGRESS_HOME"

# node-stuck cadence already bounds alert volume; same known episode must re-wake.
INBOX_NODE_HOME="$(mktemp -d)"
AGENT_HOME="$INBOX_NODE_HOME"
mkdir -p "$INBOX_NODE_HOME/night"
node_day="$(date -u +%Y-%m-%d)"
printf '{"date":"%s","demoted_classes":["node-stuck-30min"]}\n' "$node_day" \
  > "$INBOX_NODE_HOME/night/supervisor-alert-policy.json"
for node_sample in $(seq 1 12); do
  supervisor_inbox_append node-stuck-30min 'implement episode=known status=STUCK'
done
assert_eq 'node-stuck-30min has no daily wake budget' -1 "$(supervisor_alert_daily_budget node-stuck-30min)"
assert_eq 'landing-failed has no daily wake budget' -1 "$(supervisor_alert_daily_budget landing-failed)"
assert_eq 'prod-anomaly has no daily wake budget' -1 "$(supervisor_alert_daily_budget prod-anomaly)"
assert_eq 'founder-req has no daily wake budget' -1 "$(supervisor_alert_daily_budget founder-req)"
assert_eq 'efficiency-regression uses its per-metric six-hour cadence' -1 "$(supervisor_alert_daily_budget efficiency-regression)"
assert_eq 'known node-stuck alert wakes every emitted sample' 12 \
  "$(grep -cF $'\tnode-stuck-30min\t' "$INBOX_NODE_HOME/logs/supervisor-wakes.log")"
rm -rf -- "$INBOX_NODE_HOME"

INBOX_EFFICIENCY_HOME="$(mktemp -d)"
AGENT_HOME="$INBOX_EFFICIENCY_HOME"
supervisor_inbox_append efficiency-regression 'status=SLOW metric=released_issues current=6 baseline=10 tickets=#990001'
supervisor_inbox_append efficiency-regression 'status=SLOW metric=released_issues current=6 baseline=10 tickets=#990001'
assert_eq 'efficiency regression alerts are not collapsed by inbox target state' 2 \
  "$(grep -cF $'\tefficiency-regression\t' "$INBOX_EFFICIENCY_HOME/logs/supervisor-wakes.log")"
rm -rf -- "$INBOX_EFFICIENCY_HOME"


# A transient generic health-check BROKEN sample is report-only; the existing
# node-stuck-30min class owns persistent failures.
AGENT_HOME="$INBOX_HELPER_HOME"
supervisor_inbox_append health-check 'BROKEN node-health interrupted exit=143'
supervisor_inbox_append health-check 'OK node-health recovered'
assert_false 'one BROKEN health-check sample does not wake the supervisor' \
  grep -Fq $'\thealth-check\t' "$INBOX_HELPER_HOME/logs/supervisor-wakes.log"
assert_true 'the existing persistent node alert remains wake-eligible' \
  test "$(supervisor_alert_daily_budget node-stuck-30min)" = -1
AGENT_HOME="$LIB_TEST_AGENT_HOME"


lib_case_exit
