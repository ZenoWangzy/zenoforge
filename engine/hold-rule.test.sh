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
