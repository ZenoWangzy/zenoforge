#!/usr/bin/env bash
# zf-issue-transition: the supervisor stage-change CLI. During the 2026-11-03
# advisor outage a supervisor applied arbiter ADMIT verdicts with raw
# `gh issue edit --add-label ready-for-agent --remove-label needs-advisor`;
# the engine state cache never learned of it and conclude refused 8 merged
# issues for hours (#205 reconciles that drift only on the refusal path).
# These checks pin the supported path: one stage change through the command
# updates the state file and performs the label write exactly once, a
# disallowed transition exits non-zero and writes nothing, and --dry-run
# writes nothing at all. gh is a PATH stub.
set -euo pipefail
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)/test-env.sh"
ENGINE_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"

CLI="$ENGINE_DIR/bin/zf-issue-transition"
GH_LOG="$AGENT_HOME/gh-calls.log"
LIVE_LABELS_DIR="$AGENT_HOME/gh-live-labels"
mkdir -p "$LIVE_LABELS_DIR" "$AGENT_HOME/state"
# Roadmap parent placement (switch roadmap-order) is issue_transition's own
# upstream guard, exercised by its own suites; a fake gh cannot serve the
# roadmap tree, so seed the persistent policy from the engine default with
# that one switch off -- the documented roadmap-disabled deployment mode and
# the subprocess equivalent of the drift suite's roadmap_ensure_issue_parent
# stub. Same version as the default, so lib.sh's policy seeding leaves it.
jq '.switches["roadmap-order"] = false' "$ENGINE_DIR/model-policy.default.json" \
  > "$AGENT_HOME/model-policy.json"
chmod 600 "$AGENT_HOME/model-policy.json"
export ZF_GH_LOG="$GH_LOG" ZF_GH_LIVE_LABELS="$LIVE_LABELS_DIR"
# Every gh call the transition path can make: bulk label snapshots, label
# existence healing, live label reads, the sub-issue parent probe, and the
# one issue edit. Anything else fails the run loudly.
cat > "$test_env_bin/gh" <<'STUB'
#!/usr/bin/env bash
set -u
printf 'gh %s\n' "$*" >> "${ZF_GH_LOG:?}"
if [ "${1:-}" = issue ] && [ "${2:-}" = view ]; then
  case "$*" in
    *"--json comments"*) cat "${ZF_GH_LIVE_LABELS:?}/${3}.comments" 2>/dev/null || printf '{"comments":[]}\n'; exit 0 ;;
    *"--json state"*) cat "${ZF_GH_LIVE_LABELS:?}/${3}.state" 2>/dev/null || printf 'CLOSED\n'; exit 0 ;;
    *"--json title,body,subIssuesSummary"*) cat "${ZF_GH_LIVE_LABELS:?}/${3}.parent" 2>/dev/null || printf '{"title":"fixture leaf","body":"","subIssuesSummary":{"total":0,"completed":0}}\n'; exit 0 ;;
  esac
  cat "${ZF_GH_LIVE_LABELS:?}/${3}.labels" 2>/dev/null || true
  exit 0
fi
if [ "${1:-}" = issue ] && [ "${2:-}" = list ]; then
  # A lagging bulk label snapshot: numbers listed here still show as on-hold.
  case "$*" in *"--label on-hold"*) cat "${ZF_GH_LIVE_LABELS:?}/stale-on-hold" 2>/dev/null || true ;; esac
  exit 0
fi
if [ "${1:-}" = label ] && [ "${2:-}" = list ]; then
  printf '%s\n' needs-triage needs-info ready-for-agent ready-for-human needs-owner checks-blocked duplicate finish-first wontfix needs-advisor needs-recut awaiting-release awaiting-pipeline-sync awaiting-pipeline-health released concluded
  exit 0
fi
if [ "${1:-}" = api ]; then
  case "$*" in
    *sub_issues*) printf '[]\n'; exit 0 ;;
  esac
  printf 'unexpected gh api call: %s\n' "$*" >&2
  exit 1
fi
if [ "${1:-}" = issue ] && [ "${2:-}" = edit ]; then
  exit 0
fi
printf 'unexpected gh call: %s\n' "$*" >&2
exit 1
STUB
chmod +x "$test_env_bin/gh"
: > "$GH_LOG"

fail() { printf 'not ok - %s\n' "$*" >&2; exit 1; }
live_labels() { printf '%s\n' "$2" > "$LIVE_LABELS_DIR/$1.labels"; }
seed_state() { printf '%s\n' "$2" > "$AGENT_HOME/state/$1.json"; }
edit_count() { grep -c -- "issue edit $1 " "$GH_LOG" || true; }

# A stage change through the command updates the state file and calls the
# label write once (the 2026-11-03 incident shape: needs-advisor admitted to
# ready-for-agent).
live_labels 5310 needs-advisor
seed_state 5310 '{"state":"needs-advisor","attempts":0}'
: > "$GH_LOG"
err="$(mktemp)"
if ! out="$(bash "$CLI" 5310 ready-for-agent advisor-admit 2>"$err")"; then
  cat "$err" >&2
  fail 'allowed transition through the command failed'
fi
[ "$out" = 'transition #5310 needs-advisor -> ready-for-agent (reason=advisor-admit)' ] \
  || fail "unexpected success line: $out"
[ "$(jq -r .state "$AGENT_HOME/state/5310.json")" = ready-for-agent ] \
  || fail 'state file was not updated to the target state'
[ "$(jq -r .state_changed_from "$AGENT_HOME/state/5310.json")" = needs-advisor ] \
  || fail 'state file does not record the transition origin'
[ "$(edit_count 5310)" -eq 1 ] || fail "expected exactly one label write, got $(edit_count 5310)"
grep -Fq -- '--add-label ready-for-agent' "$GH_LOG" || fail 'label write misses --add-label ready-for-agent'
grep -Fq -- '--remove-label needs-advisor' "$GH_LOG" || fail 'label write misses --remove-label needs-advisor'
echo 'ok - stage change through the command updates state and writes labels once'

# A transition the table disallows exits non-zero with issue_transition's
# refusal line and writes nothing (state file bytes and label writes).
live_labels 5311 needs-info
seed_state 5311 '{"state":"needs-info","attempts":0}'
before_state="$(cat "$AGENT_HOME/state/5311.json")"
: > "$GH_LOG"
refuse_rc=0
out="$(bash "$CLI" 5311 awaiting-release merged-pr 2>"$err")" || refuse_rc=$?
[ "$refuse_rc" -ne 0 ] || fail 'disallowed transition exited 0'
[ -z "$out" ] || fail "disallowed transition printed stdout: $out"
grep -Fq 'issue_transition: refused #5311 needs-info -> awaiting-release (reason=merged-pr)' "$err" \
  || fail "refusal line missing or malformed: $(cat "$err")"
[ "$(cat "$AGENT_HOME/state/5311.json")" = "$before_state" ] \
  || fail 'refused transition changed the state file'
[ "$(edit_count 5311)" -eq 0 ] || fail 'refused transition wrote labels'
echo 'ok - disallowed transition refuses without writing'

# --dry-run answers from the table and writes nothing: no state change, no gh
# call at all.
live_labels 5312 needs-advisor
seed_state 5312 '{"state":"needs-advisor","attempts":0}'
before_state="$(cat "$AGENT_HOME/state/5312.json")"
: > "$GH_LOG"
if ! out="$(bash "$CLI" --dry-run 5312 ready-for-agent advisor-admit)"; then
  fail 'dry-run of an allowed transition failed'
fi
[ "$out" = 'dry-run: table allows #5312 needs-advisor -> ready-for-agent (reason=advisor-admit)' ] \
  || fail "unexpected dry-run allowed line: $out"
[ "$(cat "$AGENT_HOME/state/5312.json")" = "$before_state" ] || fail 'dry-run changed the state file'
[ ! -s "$GH_LOG" ] || fail "dry-run made gh calls: $(cat "$GH_LOG")"
dry_rc=0
out="$(bash "$CLI" --dry-run 5312 duplicate supervisor-close 2>"$err")" || dry_rc=$?
[ "$dry_rc" -ne 0 ] || fail 'dry-run of a disallowed transition exited 0'
grep -Fq 'dry-run: table refuses #5312 needs-advisor -> duplicate (reason=supervisor-close)' "$err" \
  || fail "unexpected dry-run refusal line: $(cat "$err")"
[ "$(cat "$AGENT_HOME/state/5312.json")" = "$before_state" ] || fail 'dry-run refusal changed the state file'
[ ! -s "$GH_LOG" ] || fail "dry-run refusal made gh calls: $(cat "$GH_LOG")"
echo 'ok - dry-run reports the table answer without writing'

# #352: a label-only hold (no state record) cannot be released by an ordinary
# reason, but `bare-hold-release:<why>` clears the label and moves the issue in
# one write. A state that records a hold keeps its own release reasons.
live_labels 5320 on-hold
printf '5320\n5321\n' > "$LIVE_LABELS_DIR/stale-on-hold"
: > "$GH_LOG"
refuse_rc=0
bash "$CLI" 5320 needs-triage supervisor-batch >/dev/null 2>"$err" || refuse_rc=$?
[ "$refuse_rc" -ne 0 ] || fail 'ordinary reason moved a bare-held issue'
grep -Fq 'issue_transition: refused held #5320 untracked -> needs-triage' "$err" \
  || fail "bare-hold refusal line missing: $(cat "$err")"
[ "$(edit_count 5320)" -eq 0 ] || fail 'refused bare-hold transition wrote labels'
if ! out="$(bash "$CLI" 5320 needs-triage bare-hold-release:prod-anomaly-batch 2>"$err")"; then
  cat "$err" >&2
  fail 'bare-hold-release failed'
fi
[ "$out" = 'transition #5320 untracked -> needs-triage (reason=bare-hold-release:prod-anomaly-batch)' ] \
  || fail "unexpected bare-hold success line: $out"
[ "$(edit_count 5320)" -eq 1 ] || fail "expected one label write, got $(edit_count 5320)"
grep -Fq -- '--remove-label on-hold' "$GH_LOG" || fail 'bare-hold release did not remove the on-hold label'
grep -Fq -- '--add-label needs-triage' "$GH_LOG" || fail 'bare-hold release did not add needs-triage'
[ "$(jq -r .state "$AGENT_HOME/state/5320.json")" = needs-triage ] || fail 'bare-hold release left the wrong state'
refuse_rc=0
bash "$CLI" 5320 needs-triage 'bare-hold-release:' >/dev/null 2>"$err" || refuse_rc=$?
[ "$refuse_rc" -ne 0 ] || fail 'bare-hold-release without a reason text was accepted'
live_labels 5321 on-hold
seed_state 5321 '{"state":"needs-info","hold":{"kind":"owner"}}'
refuse_rc=0
bash "$CLI" 5321 needs-triage bare-hold-release:no-record >/dev/null 2>"$err" || refuse_rc=$?
[ "$refuse_rc" -ne 0 ] || fail 'bare-hold-release moved a tracked hold'
grep -Fq 'refused bare-hold-release for #5321' "$err" || fail "tracked-hold refusal line missing: $(cat "$err")"
# A hold whose local state file is missing but whose durable record sits in the
# issue comments is a tracked hold: hold_restore can bring it back, so the bare
# release is refused and the label stays.
live_labels 5324 on-hold
record='{"holder":"supervisor","release_condition":"owner answers","expires_at":"2099-01-01T00:00:00Z","stage_before":"needs-info","kind":"owner"}'
jq -n --arg b "<!-- vecta-hold-record-v1 issue=5324 record=$(printf '%s' "$record" | base64 -w0) -->" \
  '{comments:[{body:$b}]}' > "$LIVE_LABELS_DIR/5324.comments"
rm -f "$AGENT_HOME/state/5324.json"
: > "$GH_LOG"
refuse_rc=0
bash "$CLI" 5324 needs-triage bare-hold-release:no-state-file >/dev/null 2>"$err" || refuse_rc=$?
[ "$refuse_rc" -ne 0 ] || fail 'bare-hold-release moved a hold recorded only in issue comments'
grep -Fq 'refused bare-hold-release for #5324' "$err" || fail "comment-record refusal line missing: $(cat "$err")"
[ "$(edit_count 5324)" -eq 0 ] || fail 'refused comment-record release wrote labels'
rm -f "$LIVE_LABELS_DIR/stale-on-hold"
echo 'ok - bare on-hold label is released by one reasoned command'

# #352: the bulk on-hold snapshot still lists an issue whose label was just
# removed; the live read of that one issue decides, so the move is not refused.
live_labels 5322 needs-info
seed_state 5322 '{"state":"needs-info","attempts":0}'
printf '5322\n' > "$LIVE_LABELS_DIR/stale-on-hold"
: > "$GH_LOG"
if ! out="$(bash "$CLI" 5322 needs-triage supervisor-batch 2>"$err")"; then
  cat "$err" >&2
  fail 'a lagging on-hold snapshot refused a live-unheld issue'
fi
[ "$(edit_count 5322)" -eq 1 ] || fail "lagging snapshot: expected one label write, got $(edit_count 5322)"
live_labels 5323 $'needs-info\non-hold'
seed_state 5323 '{"state":"needs-info","attempts":0}'
printf '5323\n' > "$LIVE_LABELS_DIR/stale-on-hold"
refuse_rc=0
bash "$CLI" 5323 needs-triage supervisor-batch >/dev/null 2>"$err" || refuse_rc=$?
[ "$refuse_rc" -ne 0 ] || fail 'a live-held issue was moved'
rm -f "$LIVE_LABELS_DIR/stale-on-hold"
echo 'ok - a lagging on-hold snapshot does not refuse a live-unheld issue'

# A state=tracker leaf can return to triage or dispatch, and a merged leaf can
# enter release state. The same transition guard keeps a tracker with an open
# recut child out of active lanes.
for issue in 5330 5331 5332 5334; do
  live_labels "$issue" tracker
  seed_state "$issue" '{"state":"tracker","tracker_parent":true,"recut_children":[]}'
done
: > "$GH_LOG"
if ! out="$(bash "$CLI" 5330 needs-triage supervisor-batch 2>"$err")"; then
  cat "$err" >&2
  fail 'childless tracker could not return to needs-triage'
fi
[ "$out" = 'transition #5330 tracker -> needs-triage (reason=supervisor-batch)' ] \
  || fail "unexpected childless tracker triage line: $out"
[ "$(jq -r '.state' "$AGENT_HOME/state/5330.json")" = needs-triage ] \
  || fail 'childless tracker did not leave tracker for needs-triage'
[ "$(jq -r '.tracker_parent // false' "$AGENT_HOME/state/5330.json")" = false ] \
  || fail 'childless tracker kept its parent flag after triage transition'
grep -Fq -- '--remove-label tracker' "$GH_LOG" || fail 'triage transition did not remove the tracker label'

: > "$GH_LOG"
seed_state 5331 '{"state":"tracker","tracker_parent":true,"recut_children":[],"run":{"outcome":"merged"},"deploy_state":"pending"}'
if ! out="$(bash "$CLI" 5331 awaiting-release merged-pr 2>"$err")"; then
  cat "$err" >&2
  fail 'childless tracker could not enter awaiting-release'
fi
[ "$out" = 'transition #5331 tracker -> awaiting-release (reason=merged-pr)' ] \
  || fail "unexpected childless tracker release line: $out"
[ "$(jq -r '.state' "$AGENT_HOME/state/5331.json")" = awaiting-release ] \
  || fail 'childless tracker did not enter awaiting-release'
[ "$(jq -r '.tracker_parent // false' "$AGENT_HOME/state/5331.json")" = false ] \
  || fail 'childless tracker kept its parent flag after release transition'
grep -Fq -- '--remove-label tracker' "$GH_LOG" || fail 'release transition did not remove the tracker label'
grep -Fq -- '--add-label awaiting-release' "$GH_LOG" || fail 'release transition did not add the awaiting-release label'

: > "$GH_LOG"
if ! out="$(bash "$CLI" 5332 ready-for-agent pipeline-requeue 2>"$err")"; then
  cat "$err" >&2
  fail 'childless tracker could not return to ready-for-agent for a new unit'
fi
[ "$(jq -r '.state' "$AGENT_HOME/state/5332.json")" = ready-for-agent ] \
  || fail 'new unit dispatch left childless issue in tracker'
[ "$(jq -r '.tracker_parent // false' "$AGENT_HOME/state/5332.json")" = false ] \
  || fail 'new unit dispatch kept the tracker parent flag'
grep -Fq -- '--remove-label tracker' "$GH_LOG" || fail 'new unit dispatch did not remove the tracker label'

seed_state 5334 '{"state":"tracker","tracker_parent":true,"recut_children":[5335]}'
printf 'OPEN\n' > "$LIVE_LABELS_DIR/5335.state"
: > "$GH_LOG"
refuse_rc=0
bash "$CLI" 5334 needs-triage supervisor-batch >/dev/null 2>"$err" || refuse_rc=$?
[ "$refuse_rc" -ne 0 ] || fail 'tracker with an open recut child left tracker'
grep -Fq 'issue_transition: refused tracker parent #5334 -> active state needs-triage' "$err" \
  || fail "open-child tracker refusal line missing: $(cat "$err")"
[ "$(jq -r '.state' "$AGENT_HOME/state/5334.json")" = tracker ] \
  || fail 'open-child tracker state changed after refusal'
[ "$(edit_count 5334)" -eq 0 ] || fail 'open-child tracker refusal wrote labels'
echo 'ok - childless trackers return to work or release, while a tracker with an open child stays parked'

echo 'ok - all zf-issue-transition checks passed'
