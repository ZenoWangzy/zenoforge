#!/usr/bin/env bash
set -euo pipefail
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/test-env.sh"
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
# hold.sh --rule refuses a hold that is not scheduler-stop-loss and a non-owner comment.
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
# --reroute releases blocked_on and returns a supervisor-review unit to its work stage; --requeue on the same unit only logs.
(
  export AUTOPI_TEST_LIBRARY_ONLY=true MAC_AUTOPILOT_ROOT="$test_env_root/repo" MAC_AUTOPILOT_SUPERVISOR_DIR="$test_env_root/sup" MAC_AUTOPILOT_RUNTIME_DIR="$test_env_root/sup/autopi"
  mkdir -p "$test_env_root/repo" "$test_env_root/sup/autopi/alerts"
  cp "$SCRIPT_DIR/mac-autopilot/config.template.json" "$test_env_root/sup/autopi/config.json"
  echo '{"units":[{"id":"issue-10","stage":"supervisor-review","blocked_on":3,"task":"t","branch":"b","history":[]},{"id":"issue-11","stage":"supervisor-review","blocked_on":3,"task":"t","branch":"b","history":[]}]}' > "$test_env_root/sup/autopi/units.json"
  echo '{"workers":[]}' > "$test_env_root/sup/autopi/workers.json"
  source "$SCRIPT_DIR/mac-autopilot/scheduler.sh"
  rule_entry issue-10 reroute u "dependency dead" ""
  [ "$(jq -r '.units[]|select(.id=="issue-10")|.stage+"|"+(has("blocked_on")|tostring)+"|"+.history[-1].stage' "$UNITS")" = "implement-pending|false|supervisor-reroute" ] || { echo "FAIL: reroute" >&2; exit 1; }
  rule_entry issue-11 requeue u "" ""
  [ "$(jq -r '.units[]|select(.id=="issue-11")|.stage+"|"+(.blocked_on|tostring)+"|"+.history[-1].stage' "$UNITS")" = "supervisor-review|3|supervisor-requeue" ] || { echo "FAIL: requeue changed a non-parked unit" >&2; exit 1; }
)
printf 'ok - rule_entry reroute releases a blocked supervisor-review unit; requeue still only logs\n'
# hold.sh --rule accepts --reroute: it gets past the usage check (64) and stops at the owner-comment check.
rc=0; hold_cli_main --rule issue-5 --reroute --comment 7 2>/dev/null || rc=$?
[ "$rc" != 64 ] || { echo "FAIL: hold.sh rejects --reroute" >&2; exit 1; }
printf 'ok - hold.sh --rule accepts --reroute\n'
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
