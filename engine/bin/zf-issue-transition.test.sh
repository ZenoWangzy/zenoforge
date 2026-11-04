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
ENGINE_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
source "$ENGINE_DIR/test-env.sh"

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
  cat "${ZF_GH_LIVE_LABELS:?}/${3}.labels" 2>/dev/null || true
  exit 0
fi
if [ "${1:-}" = issue ] && [ "${2:-}" = list ]; then
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

echo 'ok - all zf-issue-transition checks passed'
