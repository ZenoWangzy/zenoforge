#!/usr/bin/env bash
set -euo pipefail
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/test-env.sh"
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
# hold.sh --rule refuses a hold that is neither scheduler-stop-loss nor on the supervisor/head allowlist, and a non-owner comment.
export ZF_REPO=test/repo ZF_REPO_DIR="$MODEL_POLICY_TEST_REPO" AGENT_DRY_RUN=0
source "$SCRIPT_DIR/lib.sh"
cat > "$test_env_bin/gh" <<'EOT'
#!/usr/bin/env bash
[ "$1:$2" = api:repos/test/repo/issues/comments/7 ] && echo '{"issue_url":"https://api.github.com/repos/test/repo/issues/5","author_association":"NONE","html_url":"u"}' && exit 0
exit 64
EOT
chmod +x "$test_env_bin/gh"
mkdir -p "$AGENT_HOME/state"
echo '{"state":"on-hold","hold":{"holder":"scheduler-stop-loss"}}' > "$AGENT_HOME/state/5.json"
echo '{"state":"on-hold","hold":{"holder":"other"}}' > "$AGENT_HOME/state/6.json"
! hold_rule 6 requeue 7 2>/dev/null || { echo "FAIL: foreign hold accepted" >&2; exit 1; }
! hold_rule 5 requeue 7 2>/dev/null || { echo "FAIL: non-owner comment accepted" >&2; exit 1; }
! hold_rule pr-9 recut 7 2>/dev/null || { echo "FAIL: comment on another number accepted for pr-9" >&2; exit 1; }
(
  fixture_engine="$test_env_root/hold-rule-engine"
  fixture_runtime="$test_env_root/hold-rule-autopi"
  fixture_bin="$test_env_root/hold-rule-bin"
  mkdir -p "$fixture_engine/mac-autopilot" "$fixture_runtime" "$fixture_bin" "$AGENT_HOME/state"
  cat > "$fixture_engine/mac-autopilot/scheduler.sh" <<'EOT'
#!/usr/bin/env bash
set -euo pipefail
[[ "${1:-}" == --rule && "${3:-}" == requeue ]] || exit 64
if [[ "${HOLD_RULE_FAKE_FAIL:-0}" == 1 ]]; then exit 1; fi
jq '.state = "ready-for-agent" | .hold = null' "$AGENT_HOME/state/7.json" > "$AGENT_HOME/state/7.json.tmp"
mv "$AGENT_HOME/state/7.json.tmp" "$AGENT_HOME/state/7.json"
jq --arg id "$2" '(.units[] | select(.id == $id) | .stage) = "rereview-pending" | (.units[] | select(.id == $id) | .history) += [{"stage":"supervisor-requeue"}]' "$MAC_AUTOPILOT_RUNTIME_DIR/units.json" > "$MAC_AUTOPILOT_RUNTIME_DIR/units.json.tmp"
mv "$MAC_AUTOPILOT_RUNTIME_DIR/units.json.tmp" "$MAC_AUTOPILOT_RUNTIME_DIR/units.json"
EOT
  cat > "$fixture_bin/gh" <<'EOT'
#!/usr/bin/env bash
[[ "$1:${2:-}" == api:repos/test/repo/issues/comments/9 ]] || exit 64
printf '%s\n' '{"issue_url":"https://api.github.com/repos/test/repo/issues/7","author_association":"OWNER","html_url":"https://github.com/test/repo/issues/7#issuecomment-9","body":"requeue"}'
EOT
  chmod +x "$fixture_engine/mac-autopilot/scheduler.sh" "$fixture_bin/gh"
  PATH="$fixture_bin:$PATH"
  _AGENT_LIB_DIR="$fixture_engine"
  export MAC_AUTOPILOT_RUNTIME_DIR="$fixture_runtime" OPEN_ISSUE_BLOCKER_GRAPH_JSON='[]'
  printf '%s\n' '{"state":"on-hold","hold":{"holder":"scheduler-stop-loss","kind":"conclusion","created_at":"before"},"recut_children":[]}' > "$AGENT_HOME/state/7.json"
  printf '%s\n' '{"units":[{"id":"issue-7","issue":7,"stage":"supervisor-review","pr":12,"lane":"pr","branch":"agent/issue-7","history":[{"stage":"review-request-changes"}]}]}' > "$fixture_runtime/units.json"
  rc=0
  hold_rule 7 requeue 9 > "$test_env_root/hold-rule-requeue.out" 2>&1 || rc=$?
  [ "$rc" = 0 ] && jq -e '.state == "ready-for-agent" and .hold == null' "$AGENT_HOME/state/7.json" >/dev/null && jq -e '.units[0].stage == "rereview-pending" and .units[0].history[-1].stage == "supervisor-requeue"' "$fixture_runtime/units.json" >/dev/null || {
    echo "FAIL: successful requeue did not return success with the unit requeued" >&2
    cat "$test_env_root/hold-rule-requeue.out" >&2
    exit 1
  }
  printf 'ok - hold --rule returns success when requeue already released the hold\n'
  printf '%s\n' '{"state":"on-hold","hold":{"holder":"scheduler-stop-loss","kind":"conclusion","created_at":"before"},"recut_children":[]}' > "$AGENT_HOME/state/7.json"
  printf '%s\n' '{"units":[{"id":"issue-7","issue":7,"stage":"supervisor-review","pr":12,"lane":"pr","branch":"agent/issue-7","history":[{"stage":"review-request-changes"}]}]}' > "$fixture_runtime/units.json"
  export HOLD_RULE_FAKE_FAIL=1
  rc=0
  hold_rule 7 requeue 9 > "$test_env_root/hold-rule-failed-requeue.out" 2>&1 || rc=$?
  [ "$rc" -ne 0 ] && jq -e '.state == "on-hold" and .hold.holder == "scheduler-stop-loss"' "$AGENT_HOME/state/7.json" >/dev/null && jq -e '.units[0].stage == "supervisor-review"' "$fixture_runtime/units.json" >/dev/null || {
    echo "FAIL: failed requeue did not remain non-zero with the unit unchanged" >&2
    exit 1
  }
  printf 'ok - hold --rule remains non-zero when scheduler requeue fails\n'
  # An allowlisted (holder, kind) pair is released by an owner ruling and recorded; every other holder stays refused.
  cat > "$fixture_bin/gh" <<'EOT'
#!/usr/bin/env bash
case "${2:-}" in
  repos/test/repo/issues/comments/9) a=OWNER ;;
  repos/test/repo/issues/comments/10) a=NONE ;;
  *) exit 64 ;;
esac
printf '%s\n' "{\"issue_url\":\"https://api.github.com/repos/test/repo/issues/7\",\"author_association\":\"$a\",\"html_url\":\"https://github.com/test/repo/issues/7#issuecomment-9\",\"body\":\"requeue\"}"
EOT
  unset HOLD_RULE_FAKE_FAIL
  release_calls="$test_env_root/hold-rule-release.calls"
  state_requeue() { printf '%s\n' "$1 $2" >> "$release_calls"; jq "$4 | .state = \"ready-for-agent\" | .hold = null" "$AGENT_HOME/state/$1.json" > "$AGENT_HOME/state/$1.json.tmp"; mv "$AGENT_HOME/state/$1.json.tmp" "$AGENT_HOME/state/$1.json"; }
  allow_case() { # holder kind comment expect(released|refused|foreign)
    : > "$release_calls"
    jq -cn --arg h "$1" --arg k "$2" '{state:"on-hold",hold:{holder:$h,kind:$k,release_condition:"why held",created_at:"before"},recut_children:[]}' > "$AGENT_HOME/state/7.json"
    printf '%s\n' '{"units":[{"id":"issue-7","issue":7,"stage":"supervisor-review","pr":12,"lane":"pr","branch":"agent/issue-7","history":[{"stage":"review-request-changes"}]}]}' > "$fixture_runtime/units.json"
    rc=0; hold_rule 7 requeue "$3" > "$test_env_root/hold-rule-allow.out" 2>&1 || rc=$?
    case "$4" in
      released)
        [ "$rc" = 0 ] && [ "$(cat "$release_calls")" = "7 release-hold" ] \
          && jq -e --arg h "$1" --arg k "$2" '.state == "ready-for-agent" and .hold == null and .hold_release_rulings[0].holder == $h and .hold_release_rulings[0].kind == $k and .hold_release_rulings[0].reason == "why held" and .hold_release_rulings[0].comment_id == 9' "$AGENT_HOME/state/7.json" >/dev/null \
          && jq -e '.units[0].stage == "rereview-pending" and .units[0].history[-1].stage == "supervisor-requeue"' "$fixture_runtime/units.json" >/dev/null || { echo "FAIL: $1/$2 hold not released, recorded and ruled" >&2; cat "$test_env_root/hold-rule-allow.out" >&2; exit 1; } ;;
      *)
        [ "$rc" -ne 0 ] && [ ! -s "$release_calls" ] && jq -e --arg h "$1" '.state == "on-hold" and .hold.holder == $h and (has("hold_release_rulings") | not)' "$AGENT_HOME/state/7.json" >/dev/null \
          && jq -e '.units[0].stage == "supervisor-review"' "$fixture_runtime/units.json" >/dev/null || { echo "FAIL: $1/$2 with comment $3 was not refused untouched" >&2; cat "$test_env_root/hold-rule-allow.out" >&2; exit 1; }
        [ "$4" != foreign ] || grep -Fq 'is held by someone other than scheduler-stop-loss' "$test_env_root/hold-rule-allow.out" || { echo "FAIL: $1/$2 refusal message changed" >&2; exit 1; } ;;
    esac
  }
  for pair in supervisor:production-access supervisor:guarded-recut-repeat supervisor:manual head:manual; do allow_case "${pair%%:*}" "${pair#*:}" 9 released; done
  for pair in supervisor:production-access head:manual; do allow_case "${pair%%:*}" "${pair#*:}" 10 refused; done
  for pair in founder:manual unknown:production-access supervisor:external-deliverable head:production-access vecta-aa:manual supervisor-inbox:supervisor-inbox; do allow_case "${pair%%:*}" "${pair#*:}" 9 foreign; done
  # scheduler-stop-loss: today's path, the fixture scheduler releases the hold and no ruling record or state_requeue is written.
  : > "$release_calls"
  printf '%s\n' '{"state":"on-hold","hold":{"holder":"scheduler-stop-loss","kind":"conclusion","created_at":"before"},"recut_children":[]}' > "$AGENT_HOME/state/7.json"
  printf '%s\n' '{"units":[{"id":"issue-7","issue":7,"stage":"supervisor-review","pr":12,"lane":"pr","branch":"agent/issue-7","history":[{"stage":"review-request-changes"}]}]}' > "$fixture_runtime/units.json"
  hold_rule 7 requeue 9 >/dev/null 2>&1 && [ ! -s "$release_calls" ] && jq -e '.hold == null and (has("hold_release_rulings") | not)' "$AGENT_HOME/state/7.json" >/dev/null || { echo "FAIL: stop-loss release changed" >&2; exit 1; }
  printf 'ok - hold --rule releases allowlisted supervisor/head holds on an owner comment and refuses every other holder\n'
)
printf 'ok - hold --rule refuses foreign holds and non-owner comments\n'
# --reblock returns a unit to dependency wait, naming the blocker when the unit has none.
(
  export AUTOPI_TEST_LIBRARY_ONLY=true MAC_AUTOPILOT_ROOT="$test_env_root/repo" MAC_AUTOPILOT_SUPERVISOR_DIR="$test_env_root/sup" MAC_AUTOPILOT_RUNTIME_DIR="$test_env_root/sup/autopi"
  mkdir -p "$test_env_root/repo" "$test_env_root/sup/autopi/alerts"
  cp "$SCRIPT_DIR/mac-autopilot/config.template.json" "$test_env_root/sup/autopi/config.json"
  echo '{"units":[{"id":"issue-8","issue":8,"stage":"supervisor-review","blocked_on":3},{"id":"issue-9","issue":9,"stage":"repair-pending"}]}' > "$test_env_root/sup/autopi/units.json"
  echo '{"workers":[]}' > "$test_env_root/sup/autopi/workers.json"
  source "$SCRIPT_DIR/mac-autopilot/scheduler.sh"
  rule_entry issue-8 reblock u "" ""
  rule_entry issue-9 reblock u "" 4
  [ "$(jq -r '[.units[]|.stage+(.blocked_on|tostring)]|join(",")' "$UNITS")" = "blocked-external3,blocked-external4" ] || { echo "FAIL: reblock" >&2; exit 1; }
)
printf 'ok - rule_entry reblock returns units to dependency wait\n'
# --reroute releases blocked_on; requeue moves supervisor-review back to work and rejects other active stages.
(
  export AUTOPI_TEST_LIBRARY_ONLY=true MAC_AUTOPILOT_ROOT="$test_env_root/repo" MAC_AUTOPILOT_SUPERVISOR_DIR="$test_env_root/sup" MAC_AUTOPILOT_RUNTIME_DIR="$test_env_root/sup/autopi"
  mkdir -p "$test_env_root/repo" "$test_env_root/sup/autopi/alerts"
  cp "$SCRIPT_DIR/mac-autopilot/config.template.json" "$test_env_root/sup/autopi/config.json"
  echo '{"units":[{"id":"issue-10","stage":"supervisor-review","blocked_on":3,"task":"t","branch":"b","history":[]},{"id":"issue-11","stage":"supervisor-review","lane":"direct-main","branch":"agent/issue-11","history":[{"stage":"repair-delivered"}]},{"id":"issue-12","stage":"implement-pending","task":"t","branch":"b","history":[]}]}' > "$test_env_root/sup/autopi/units.json"
  echo '{"workers":[]}' > "$test_env_root/sup/autopi/workers.json"
  source "$SCRIPT_DIR/mac-autopilot/scheduler.sh"
  rule_entry issue-10 reroute u "dependency dead" ""
  [ "$(jq -r '.units[]|select(.id=="issue-10")|.stage+"|"+(has("blocked_on")|tostring)+"|"+.history[-1].stage' "$UNITS")" = "implement-pending|false|supervisor-reroute" ] || { echo "FAIL: reroute" >&2; exit 1; }
  rule_entry issue-11 requeue u "" ""
  [ "$(jq -r '.units[]|select(.id=="issue-11")|.stage+"|"+.history[-1].stage' "$UNITS")" = "repair-pending|supervisor-requeue" ] || { echo "FAIL: requeue did not move delivered supervisor-review work to repair" >&2; exit 1; }
  rc=0; rule_entry issue-12 requeue u "" "" > "$test_env_root/requeue.out" 2>&1 || rc=$?
  [ "$rc" = 1 ] && grep -q -- '--reroute' "$test_env_root/requeue.out" || { echo "FAIL: non-supervisor requeue did not name --reroute" >&2; exit 1; }
  [ "$(jq -r '.units[]|select(.id=="issue-12")|.stage+"|"+(.history|length|tostring)' "$UNITS")" = "implement-pending|0" ] || { echo "FAIL: refused requeue changed the unit" >&2; exit 1; }
)
printf 'ok - rule_entry reroute releases a blocker; requeue moves supervisor-review and rejects other active stages\n'
# A closed unit whose open issue sits on a scheduler-stop-loss hold: the ruling requeues it and releases the hold. Every other
# closed unit refuses, and the hint names --recut (the kind that takes a closed unit), never --reroute.
(
  export AUTOPI_TEST_LIBRARY_ONLY=true MAC_AUTOPILOT_ROOT="$test_env_root/repo" MAC_AUTOPILOT_SUPERVISOR_DIR="$test_env_root/sup" MAC_AUTOPILOT_RUNTIME_DIR="$test_env_root/sup/autopi"
  mkdir -p "$test_env_root/repo" "$test_env_root/sup/autopi/alerts"
  cp "$SCRIPT_DIR/mac-autopilot/config.template.json" "$test_env_root/sup/autopi/config.json"
  echo '{"workers":[]}' > "$test_env_root/sup/autopi/workers.json"
  echo '{"units":[{"id":"issue-20","issue":20,"stage":"closed","task":"t","branch":"b","history":[]},{"id":"issue-21","issue":21,"stage":"closed","task":"t","branch":"b","history":[]},{"id":"issue-22","issue":22,"stage":"closed","task":"t","branch":"b","history":[]},{"id":"issue-23","issue":23,"stage":"closed","task":"t","branch":"b","history":[]},{"id":"issue-24","issue":24,"stage":"closed","task":"t","branch":"b","history":[]},{"id":"issue-25","issue":25,"stage":"closed","task":"t","branch":"b","history":[]}]}' > "$test_env_root/sup/autopi/units.json"
  source "$SCRIPT_DIR/mac-autopilot/scheduler.sh"
  scheduler_issue_state() { cat "$AGENT_HOME/state/$1.json"; }
  gh() { # the state check is REST only (the GraphQL issue view read is what the rate limit emptied); FAIL makes it unreadable
    [[ "$1" == issue ]] && { printf '{}\n'; return; } # the requeue refresh; scheduler_issue_transition is stubbed and ignores it
    [[ "$1" == api && "$2" == repos/test/repo/issues/* && "$4" == .state && "$FAKE_ISSUE_STATE" != FAIL ]] || return 1
    printf '%s\n' "$FAKE_ISSUE_STATE"; }
  scheduler_issue_transition() { jq '.state = "ready-for-agent" | .hold = null' "$AGENT_HOME/state/$1.json" > "$AGENT_HOME/state/$1.json.tmp" && mv "$AGENT_HOME/state/$1.json.tmp" "$AGENT_HOME/state/$1.json"; }
  stop_loss_state() { printf '%s\n' '{"state":"on-hold","hold":{"holder":"scheduler-stop-loss"}}' > "$AGENT_HOME/state/$1.json"; }
  stop_loss_state 20; stop_loss_state 21; stop_loss_state 23; stop_loss_state 25
  printf '%s\n' '{"state":"ready-for-agent"}' > "$AGENT_HOME/state/22.json"
  printf '%s\n' '{"state":"on-hold","hold":{"holder":"other"}}' > "$AGENT_HOME/state/24.json"
  FAKE_ISSUE_STATE=open; rule_entry issue-20 requeue u "" ""
  [ "$(jq -r '.units[]|select(.id=="issue-20")|.stage' "$UNITS")" = implement-pending ] && jq -e '.state == "ready-for-agent" and .hold == null' "$AGENT_HOME/state/20.json" >/dev/null || { echo "FAIL: closed stop-loss unit did not requeue with its hold released" >&2; exit 1; }
  FAKE_ISSUE_STATE=closed; rc=0; rule_entry issue-21 requeue u "" "" > "$test_env_root/closed-21.out" 2>&1 || rc=$?
  [ "$rc" = 1 ] && grep -q -- '--recut' "$test_env_root/closed-21.out" && ! grep -q -- '--reroute' "$test_env_root/closed-21.out" || { echo "FAIL: closed issue requeue hint" >&2; cat "$test_env_root/closed-21.out" >&2; exit 1; }
  [ "$(jq -r '.units[]|select(.id=="issue-21")|.stage' "$UNITS")" = closed ] || { echo "FAIL: refused closed issue requeue changed the unit" >&2; exit 1; }
  FAKE_ISSUE_STATE=open; rc=0; rule_entry issue-22 requeue u "" "" > "$test_env_root/closed-22.out" 2>&1 || rc=$?
  [ "$rc" = 1 ] && grep -q -- '--recut' "$test_env_root/closed-22.out" && ! grep -q -- '--reroute' "$test_env_root/closed-22.out" || { echo "FAIL: closed unit without a hold requeue hint" >&2; cat "$test_env_root/closed-22.out" >&2; exit 1; }
  rc=0; rule_entry issue-24 requeue u "" "" > "$test_env_root/closed-24.out" 2>&1 || rc=$?
  [ "$rc" = 1 ] && grep -q -- '--recut' "$test_env_root/closed-24.out" || { echo "FAIL: closed unit with a non-stop-loss hold was not refused" >&2; exit 1; }
  # An unreadable GitHub state (the read fails) refuses both ways without recut or requeue advice, and never releases the hold.
  for act in requeue reroute; do
    FAKE_ISSUE_STATE=FAIL; rc=0; rule_entry issue-25 "$act" u "dead" "" > "$test_env_root/closed-25-$act.out" 2>&1 || rc=$?
    [ "$rc" = 1 ] && grep -q -- 'could not be read' "$test_env_root/closed-25-$act.out" && ! grep -q -- '--recut' "$test_env_root/closed-25-$act.out" && ! grep -q -- '--requeue' "$test_env_root/closed-25-$act.out" || { echo "FAIL: unreadable closed state ($act) gave the wrong refusal" >&2; cat "$test_env_root/closed-25-$act.out" >&2; exit 1; }
    [ "$(jq -r '.units[]|select(.id=="issue-25")|.stage' "$UNITS")" = closed ] && jq -e '.state == "on-hold" and .hold.holder == "scheduler-stop-loss"' "$AGENT_HOME/state/25.json" >/dev/null || { echo "FAIL: unreadable closed state ($act) changed the unit or released its hold" >&2; exit 1; }
  done
  FAKE_ISSUE_STATE=closed; rc=0; rule_entry issue-21 reroute u "dead" "" > "$test_env_root/closed-reroute.out" 2>&1 || rc=$?
  [ "$rc" = 1 ] && grep -q -- '--recut' "$test_env_root/closed-reroute.out" && ! grep -q -- '--reroute' "$test_env_root/closed-reroute.out" || { echo "FAIL: reroute hint on a closed unit names --reroute" >&2; cat "$test_env_root/closed-reroute.out" >&2; exit 1; }
  FAKE_ISSUE_STATE=open; rc=0; rule_entry issue-23 reroute u "dead" ""> "$test_env_root/closed-reroute-hold.out" 2>&1 || rc=$?
  [ "$rc" = 1 ] && grep -q -- '--requeue' "$test_env_root/closed-reroute-hold.out" && ! grep -q -- '--reroute' "$test_env_root/closed-reroute-hold.out" || { echo "FAIL: reroute on a closed stop-loss unit must name --requeue" >&2; cat "$test_env_root/closed-reroute-hold.out" >&2; exit 1; }
)
printf 'ok - rule_entry requeues a closed unit whose issue is on a stop-loss hold; other closed units refuse with a working hint\n'
# hold.sh --rule accepts --reroute: it gets past the usage check (64) and stops at the owner-comment check.
rc=0; hold_cli_main --rule issue-5 --reroute --comment 7 2>/dev/null || rc=$?
[ "$rc" != 64 ] || { echo "FAIL: hold.sh rejects --reroute" >&2; exit 1; }
printf 'ok - hold.sh --rule accepts --reroute\n'
# --rule usage tells supervisors which wording the unchanged-head report-only harvest recognizes.
rc=0; bash "$SCRIPT_DIR/hold.sh" --rule >"$test_env_root/hold-rule-usage.out" 2>&1 || rc=$?
[ "$rc" = 64 ] && grep -Fq 'report only' "$test_env_root/hold-rule-usage.out" || { echo "FAIL: hold.sh --rule usage omits report-only requeue wording" >&2; exit 1; }
printf 'ok - hold.sh --rule usage names report-only requeue wording\n'
# A reroute drops the cleared blocker: the body reader does not re-derive it until a reblock names it again.
(
  export AUTOPI_TEST_LIBRARY_ONLY=true MAC_AUTOPILOT_ROOT="$test_env_root/repo" MAC_AUTOPILOT_SUPERVISOR_DIR="$test_env_root/sup" MAC_AUTOPILOT_RUNTIME_DIR="$test_env_root/sup/autopi"
  mkdir -p "$test_env_root/repo" "$test_env_root/sup/autopi/alerts"
  cp "$SCRIPT_DIR/mac-autopilot/config.template.json" "$test_env_root/sup/autopi/config.json"
  echo '{"units":[{"id":"issue-12","stage":"supervisor-review","blocked_on":5388,"task":"t","branch":"b","body_blocked_by":[5388],"history":[]}]}' > "$test_env_root/sup/autopi/units.json"
  echo '{"workers":[]}' > "$test_env_root/sup/autopi/workers.json"
  source "$SCRIPT_DIR/mac-autopilot/scheduler.sh"
  rule_entry issue-12 reroute u "dead blocker" ""
  [ "$(jq -r '.units[0] | .stage+"|"+(has("blocked_on")|tostring)+"|"+(.dropped_deps|tostring)+"|"+.history[-1].result' "$UNITS")" = "implement-pending|false|[5388]|supervisor ruling u: dead blocker (dropped blocker #5388)" ] || { echo "FAIL: reroute did not record the dropped blocker" >&2; exit 1; }
  [ "$(jq -r '.units[0].released_deps[0] | "\(.issue)|\(.kind)|\(.reason)"' "$UNITS")" = "5388|ruling|#5388 ruled resolved by supervisor (supervisor ruling u: dead blocker)" ] || { echo "FAIL: reroute did not record the ruling in released_deps" >&2; exit 1; }
  park_if_body_blocked "$(jq -c '.units[0]' "$UNITS")" || :
  [ "$(jq -r '.units[0].stage' "$UNITS")" = implement-pending ] || { echo "FAIL: body reader re-blocked a rerouted unit" >&2; exit 1; }
  [ -z "$(unit_body_blockers "$(jq -c '.units[0]' "$UNITS")")" ] || { echo "FAIL: body reader still derives #5388" >&2; exit 1; }
  rule_entry issue-12 reblock u "" 5388
  [ "$(jq -r '.units[0] | .stage+"|"+(.blocked_on|tostring)+"|"+(.dropped_deps|tostring)' "$UNITS")" = "blocked-external|5388|[]" ] || { echo "FAIL: reblock did not re-block" >&2; exit 1; }
  [ "$(unit_body_blockers "$(jq -c '.units[0]' "$UNITS")")" = 5388 ] || { echo "FAIL: reblock did not restore the body blocker" >&2; exit 1; }
)
printf 'ok - reroute keeps a dropped body blocker off the unit until reblock names it\n'
# A worker report that blocks on a dropped dependency does not park the unit; one on any other dependency still parks.
(
  export AUTOPI_TEST_LIBRARY_ONLY=true MAC_AUTOPILOT_ROOT="$test_env_root/repo" MAC_AUTOPILOT_SUPERVISOR_DIR="$test_env_root/sup" MAC_AUTOPILOT_RUNTIME_DIR="$test_env_root/sup/autopi"
  mkdir -p "$test_env_root/repo" "$test_env_root/sup/autopi/alerts"
  cp "$SCRIPT_DIR/mac-autopilot/config.template.json" "$test_env_root/sup/autopi/config.json"
  echo '{"units":[{"id":"issue-13","stage":"implement-pending","task":"t","branch":"b","dropped_deps":[5388],"history":[]},{"id":"issue-14","stage":"supervisor-review","blocked_on":5388,"task":"t","branch":"b","history":[]},{"id":"issue-15","stage":"implement-pending","task":"t","branch":"b","dropped_deps":[5388],"history":[]}]}' > "$test_env_root/sup/autopi/units.json"
  echo '{"workers":[]}' > "$test_env_root/sup/autopi/workers.json"
  source "$SCRIPT_DIR/mac-autopilot/scheduler.sh"
  report="$test_env_root/report-13.txt"; printf 'BLOCKED-ON: #5388\n' > "$report"
  park_blocked issue-13 "$(blocked_on_of "$report")"
  [ "$(jq -r '.units[]|select(.id=="issue-13")|.stage+"|"+(.history[-1].stage)' "$UNITS")" = "implement-pending|dropped-dep-ignored" ] || { echo "FAIL: dropped dependency parked the unit" >&2; exit 1; }
  rule_entry issue-14 reroute u "dead blocker" ""
  jq -e '.units[]|select(.id=="issue-14")|.task|contains("Supervisor ruling: dependency #5388 is resolved") and contains("do not report blocked on it")' "$UNITS" >/dev/null || { echo "FAIL: reroute task line missing" >&2; exit 1; }
  printf 'BLOCKED-ON: #9999\n' > "$report"
  park_blocked issue-15 "$(blocked_on_of "$report")"
  [ "$(jq -r '.units[]|select(.id=="issue-15")|.stage+"|"+(.blocked_on|tostring)' "$UNITS")" = "blocked-external|9999" ] || { echo "FAIL: undropped dependency did not park" >&2; exit 1; }
)
printf 'ok - a worker report on a dropped dependency does not park; the reroute task line says so; another dependency still parks\n'
# --supersede-handoff clears only the unit snapshot; the ruling and current PR head stay auditable.
(
  fixture_engine="$test_env_root/handoff-supersede-engine"
  fixture_repo="$test_env_root/handoff-supersede-repo"
  fixture_runtime="$test_env_root/handoff-supersede-autopi"
  fixture_sup="$test_env_root/handoff-supersede-supervisor"
  fixture_bin="$test_env_root/handoff-supersede-bin"
  remote_calls="$test_env_root/handoff-supersede-remote-calls.log"
  remote_refs="$test_env_root/handoff-supersede-remote-refs.txt"
  remote_head=1111111111111111111111111111111111111111
  rescue_sha=2222222222222222222222222222222222222222
  rescue_ref=refs/heads/rescued/agent-issue-7-fixture
  mkdir -p "$fixture_engine/mac-autopilot" "$fixture_repo" "$fixture_runtime/alerts" "$fixture_sup" "$fixture_bin" "$AGENT_HOME/state"
  cp "$SCRIPT_DIR/mac-autopilot/config.template.json" "$fixture_runtime/config.json"
  printf '%s\n' '{"state":"ready-for-agent"}' > "$AGENT_HOME/state/7.json"
  jq -cn --arg head "$remote_head" --arg sha "$rescue_sha" --arg ref "$rescue_ref" '{units:[{
    id:"issue-7",issue:7,pr:12,branch:"agent/issue-7",stage:"supervisor-review",reviewed_sha:$head,reviewed_pr_head:$head,history:[],
    handoff_worktree:"/preserved/owner",handoff_worktree_sha:$sha,handoff_worktree_dirty:true,handoff_worktree_applied:false,
    handoff_integration_sha:$sha,handoff_original_pr_head:"3333333333333333333333333333333333333333",handoff_delivery_verified_sha:null,
    handoff_start_ref:$ref,handoff_start_sha:$sha,handoff_start_applied:true
  }]}' > "$fixture_runtime/units.json"
  printf '%s %s\n' "$rescue_ref" "$rescue_sha" > "$remote_refs"
  cat > "$fixture_bin/git" <<'EOT'
#!/usr/bin/env bash
printf 'git %s\n' "$*" >> "$REMOTE_CALLS"
case " $* " in
  *' push '*|*' update-ref -d '*|*' branch -D '*)
    : > "$REMOTE_REFS"
    exit 91
    ;;
esac
exec "$REAL_GIT" "$@"
EOT
  cat > "$fixture_bin/gh" <<'EOT'
#!/usr/bin/env bash
printf 'gh %s\n' "$*" >> "$REMOTE_CALLS"
case " $* " in
  *' push '*|*' delete '*|*' DELETE '*)
    : > "$REMOTE_REFS"
    exit 91
    ;;
esac
case "$*" in
  'api repos/test/repo/issues/comments/9')
    printf '%s\n' '{"issue_url":"https://api.github.com/repos/test/repo/issues/7","author_association":"OWNER","html_url":"https://github.com/test/repo/issues/7#issuecomment-9","body":"supersede the old snapshot"}'
    ;;
  'pr view 12 --json headRefOid --jq .headRefOid') printf '%s\n' "$SUPERSEDE_HEAD" ;;
  *) exit 64 ;;
esac
EOT
  cat > "$fixture_engine/mac-autopilot/scheduler.sh" <<'EOT'
#!/usr/bin/env bash
set -euo pipefail
source "$TEST_ENGINE/mac-autopilot/scheduler.sh"
rule_entry "${2:-}" "${3:-}" "${4:-}" "${5:-}" "${6:-}"
unit_field "${2:-}" .stage > "$SUPERSEDE_STAGE_AFTER_RULE"
resume_handoff_integration "${2:-}" "$RESUME_WORKTREE"
: > "$RESUME_RESULT"
post_approved_status() { :; }
supervisor_apply_action "${2:-}" approve "$SUPERSEDE_REPORT"
EOT
  chmod +x "$fixture_bin/git" "$fixture_bin/gh" "$fixture_engine/mac-autopilot/scheduler.sh"
  export REMOTE_CALLS="$remote_calls" REMOTE_REFS="$remote_refs" REAL_GIT="$(command -v git)" SUPERSEDE_HEAD="$remote_head"
  export TEST_ENGINE="$SCRIPT_DIR" SUPERSEDE_STAGE_AFTER_RULE="$test_env_root/handoff-supersede-stage-after-rule"
  export RESUME_WORKTREE="$test_env_root/handoff-supersede-worktree" RESUME_RESULT="$test_env_root/handoff-supersede-resume-result"
  export SUPERSEDE_REPORT="$test_env_root/handoff-supersede-report.md"
  printf 'REASON: approve the reviewed current PR head\nREJECTED:\n- none\n' > "$SUPERSEDE_REPORT"
  export AUTOPI_TEST_LIBRARY_ONLY=true MAC_AUTOPILOT_ROOT="$fixture_repo" MAC_AUTOPILOT_SUPERVISOR_DIR="$fixture_sup" MAC_AUTOPILOT_RUNTIME_DIR="$fixture_runtime" TICK_PRS='[]'
  export PATH="$fixture_bin:$PATH"
  _AGENT_LIB_DIR="$fixture_engine"
  rc=0
  hold_cli_main --rule issue-7 --supersede-handoff > "$test_env_root/handoff-supersede-usage.out" 2>&1 || rc=$?
  [ "$rc" = 64 ] && grep -Fq -- '--comment <id>' "$test_env_root/handoff-supersede-usage.out" || { echo 'FAIL: supersede-handoff without --comment did not refuse with usage' >&2; exit 1; }
  rc=0
  hold_cli_main --rule issue-7 --supersede-handoff --comment 9 > "$test_env_root/handoff-supersede.out" 2>&1 || rc=$?
  [ "$rc" = 0 ] || { echo 'FAIL: supersede-handoff ruling was rejected' >&2; cat "$test_env_root/handoff-supersede.out" >&2; exit 1; }
  jq -e '([.units[0] | keys[] | select(startswith("handoff_"))] | length) == 0 and .units[0].stage == "ready-to-merge"' "$fixture_runtime/units.json" >/dev/null || {
    echo 'FAIL: supersede-handoff retained a handoff field or approve still refused' >&2
    exit 1
  }
  [ "$(cat "$SUPERSEDE_STAGE_AFTER_RULE")" = supervisor-review ] || { echo 'FAIL: supersede-handoff changed the stage before a separate requeue or approve' >&2; exit 1; }
  [ -f "$RESUME_RESULT" ] || { echo 'FAIL: next dispatch could not resume after the snapshot was cleared' >&2; exit 1; }
  ! grep -E 'git .* (merge|push|update-ref -d|branch -D)( |$)|gh .* (push|delete|DELETE)( |$)' "$remote_calls" >/dev/null || {
    echo 'FAIL: supersede-handoff tried to merge, push, or delete a remote ref' >&2
    cat "$remote_calls" >&2
    exit 1
  }
  grep -Fxq -- "$rescue_ref $rescue_sha" "$remote_refs" || { echo 'FAIL: supersede-handoff changed the rescued remote ref' >&2; exit 1; }
  jq -e --arg head "$remote_head" --arg id 9 '
    ([.units[0].history[] | select(.stage == "handoff-superseded")] | last) as $event
    | $event.stage == "handoff-superseded"
      and ($event.result | contains($id) and contains($head))
      and $event.ruling_comment_id == $id
      and $event.pr_head == $head
      and $event.superseded_by == $head
  ' "$fixture_runtime/units.json" >/dev/null || { echo 'FAIL: supersede-handoff history omitted the ruling id or superseding PR head' >&2; exit 1; }
  jq -e '.units[0].history[-1].stage == "supervisor-approve"' "$fixture_runtime/units.json" >/dev/null || { echo 'FAIL: supervisor approve still refused after supersede-handoff' >&2; exit 1; }
)
printf 'ok - supersede-handoff clears the snapshot, records the ruling and current head, and leaves the rescued ref intact\n'
# hold.sh --rule --ready (vecta#6299 shape): a tracker parent with a closed recut unit and an owner ruling moves to ready-for-agent
# with its from-state recorded. needs-advisor and needs-triage move too; ready-for-agent, another hold, and a closed issue are refused.
(
  fixture_engine="$test_env_root/ready-engine"
  fixture_runtime="$test_env_root/ready-autopi"
  ready_calls="$test_env_root/ready-calls.log"
  mkdir -p "$fixture_engine/mac-autopilot" "$fixture_runtime/alerts" "$test_env_root/ready-repo" "$test_env_root/ready-sup" "$AGENT_HOME/state"
  cp "$SCRIPT_DIR/mac-autopilot/config.template.json" "$fixture_runtime/config.json"
  printf '%s\n' '{"workers":[]}' > "$fixture_runtime/workers.json"
  cat > "$fixture_engine/mac-autopilot/scheduler.sh" <<'EOT2'
#!/usr/bin/env bash
set -euo pipefail
source "$TEST_ENGINE/mac-autopilot/scheduler.sh"
rule_entry "${2:-}" "${3:-}" "${4:-}" "${5:-}" "${6:-}"
EOT2
  chmod +x "$fixture_engine/mac-autopilot/scheduler.sh"
  export TEST_ENGINE="$SCRIPT_DIR" AUTOPI_TEST_LIBRARY_ONLY=true MAC_AUTOPILOT_ROOT="$test_env_root/ready-repo" MAC_AUTOPILOT_SUPERVISOR_DIR="$test_env_root/ready-sup" MAC_AUTOPILOT_RUNTIME_DIR="$fixture_runtime"
  export READY_CALLS="$ready_calls"
  _AGENT_LIB_DIR="$fixture_engine"
  # Stubs for the GitHub writes and the tracker-children gate, which has its own tests.
  gh() {
    printf 'gh %s\n' "$*" >> "$READY_CALLS"
    case "$*" in
      'api repos/test/repo/issues/comments/9') printf '%s\n' '{"issue_url":"https://api.github.com/repos/test/repo/issues/6299","author_association":"OWNER","html_url":"https://github.com/test/repo/issues/6299#issuecomment-9","body":"ready for the agent"}' ;;
      'issue view 6299 --repo test/repo --json state -q .state') printf '%s\n' "$READY_ISSUE_STATE" ;;
      *) return 0 ;;
    esac
  }
  guarded_write() { printf 'guarded %s\n' "$*" >> "$READY_CALLS"; }
  ensure_state_labels() { :; }
  roadmap_ensure_issue_parent() { :; }
  tracker_parent_transition_is_blocked() { return 1; }
  reset() { # state-json issue-state
    printf '%s\n' "$1" > "$AGENT_HOME/state/6299.json"
    jq -cn '{units:[{id:"issue-6299",issue:6299,stage:"closed",branch:"agent/issue-6299",history:[{stage:"supervisor-budget-recut",at:"2026-11-10T00:00:00Z"},{stage:"size-recut-completed",at:"2026-11-11T00:00:00Z"}]}]}' > "$fixture_runtime/units.json"
    : > "$READY_CALLS"
    READY_ISSUE_STATE="$2"
  }
  reset '{"state":"tracker"}' OPEN
  rc=0; hold_cli_main --rule 6299 --ready --comment 9 > "$test_env_root/ready.out" 2>&1 || rc=$?
  [ "$rc" = 0 ] || { echo "FAIL: --ready refused a tracker ruling" >&2; cat "$test_env_root/ready.out" >&2; exit 1; }
  jq -e '.state == "ready-for-agent" and .state_changed_from == "tracker" and (.state_changed_at // "") != ""' "$AGENT_HOME/state/6299.json" >/dev/null || { echo "FAIL: --ready did not record the tracker from-state" >&2; exit 1; }
  jq -e '.units[0].history[-1].stage == "supervisor-ready" and .units[0].stage == "closed"' "$fixture_runtime/units.json" >/dev/null || { echo "FAIL: --ready did not record the ruling in unit history" >&2; exit 1; }
  grep -Fq -- 'ready-for-agent' "$READY_CALLS" || { echo "FAIL: --ready did not write the ready-for-agent label" >&2; exit 1; }
  printf 'ok - hold --rule --ready moves a tracker parent to ready-for-agent with its from-state recorded\n'
  for from in needs-advisor needs-triage; do
    reset "{\"state\":\"$from\"}" OPEN
    hold_rule 6299 ready 9 >/dev/null 2>&1 || { echo "FAIL: --ready refused $from" >&2; exit 1; }
    jq -e --arg from "$from" '.state == "ready-for-agent" and .state_changed_from == $from' "$AGENT_HOME/state/6299.json" >/dev/null || { echo "FAIL: --ready did not record $from" >&2; exit 1; }
  done
  for case in '{"state":"ready-for-agent"}|OPEN' '{"state":"on-hold","hold":{"holder":"scheduler-stop-loss"}}|OPEN' '{"state":"tracker"}|CLOSED' '{"state":"needs-info"}|OPEN'; do
    reset "${case%|*}" "${case##*|}"
    state_before="$(cat "$AGENT_HOME/state/6299.json")"; units_before="$(cat "$fixture_runtime/units.json")"
    rc=0; hold_rule 6299 ready 9 >/dev/null 2>&1 || rc=$?
    [ "$rc" != 0 ] && [ "$(cat "$AGENT_HOME/state/6299.json")" = "$state_before" ] && [ "$(cat "$fixture_runtime/units.json")" = "$units_before" ] \
      || { echo "FAIL: --ready accepted or wrote for ${case%|*} issue ${case##*|}" >&2; exit 1; }
  done
  printf 'ok - hold --rule --ready refuses ready-for-agent, on-hold, other states and closed issues without writing\n'
)
rc=0; bash "$SCRIPT_DIR/hold.sh" --rule >"$test_env_root/hold-rule-ready-usage.out" 2>&1 || rc=$?
[ "$rc" = 64 ] && grep -Fq -- '--ready' "$test_env_root/hold-rule-ready-usage.out" || { echo "FAIL: hold.sh --rule usage omits --ready" >&2; exit 1; }
printf 'ok - hold.sh --rule usage names --ready\n'
