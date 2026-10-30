#!/usr/bin/env bash
# Regression tests for run-tick.sh's fast-forward-or-refuse guard — the
# entire point of the dedicated-checkout launcher (see run-tick.sh's header
# comment for why). Plain bash assertions, no framework — matches
# lib.test.sh's style.
#
# These fixtures never execute the real issue-pipeline.sh: each throwaway
# checkout either has no scheduler or uses a tiny fixture stub, so no unit
# dispatch or real email can happen.
set -euo pipefail
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/." && pwd -P)/test-env.sh"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LAUNCHER_SRC="$SCRIPT_DIR/run-tick.sh"
TIMER_LIST_SRC="$SCRIPT_DIR/systemd/pipeline-timers.list"

FAILED=0
TMP_DIRS=()
cleanup() {
  local d
  for d in "${TMP_DIRS[@]:-}"; do
    [ -n "$d" ] && rm -rf "$d"
  done
}
trap cleanup EXIT

# The timer invariant below must never touch the real user manager. This fake
# follows lib.test.sh's systemctl stub shape: enabled/active state is
# env-driven, and repairs are recorded in a throwaway log.
TICK_FAKE_BIN="$(mktemp -d)"
TMP_DIRS+=("$TICK_FAKE_BIN")
cat >"$TICK_FAKE_BIN/gh" <<'EOF'
#!/usr/bin/env bash
if [ "${1:-}" = "variable" ] && [ "${2:-}" = "get" ]; then
  case "${3:-}" in
    AGENT_SUPERVISOR) echo "${FAKE_SUPERVISOR_MODE:-observe}" ;;
    *) echo observe ;;
  esac
  exit 0
fi
exit 0
EOF
cat >"$TICK_FAKE_BIN/systemctl" <<'EOF'
#!/usr/bin/env bash
timer_in_list() {
  case ",${2:-}," in
    *",$1,"*) return 0 ;;
    *) return 1 ;;
  esac
}
timer_recovered() {
  [ -n "$FAKE_SYSTEMCTL_LOG" ] && [ -f "$FAKE_SYSTEMCTL_LOG.recovered.$1" ]
}
mark_timer_recovered() {
  if [ -n "$FAKE_SYSTEMCTL_LOG" ]; then
    : >"$FAKE_SYSTEMCTL_LOG.recovered.$1"
  fi
}

log_systemctl() {
  [ -n "${FAKE_SYSTEMCTL_LOG:-}" ] && echo "$*" >>"$FAKE_SYSTEMCTL_LOG"
}

timer=""
for timer in "$@"; do :; done
case "$*" in
  *"--user is-enabled --quiet "*)
    if timer_in_list "$timer" "${FAKE_DISABLED_TIMERS:-}" && ! timer_recovered "$timer"; then
      exit 1
    fi
    exit 0
    ;;
  *"--user is-active --quiet "*)
    if timer_in_list "$timer" "${FAKE_INACTIVE_TIMERS:-}" && ! timer_recovered "$timer"; then
      exit 3
    fi
    exit 0
    ;;
  *"--user enable --now "*)
    log_systemctl "$*"
    if timer_in_list "$timer" "${FAKE_ENABLE_FAIL_TIMERS:-}"; then
      exit 1
    fi
    mark_timer_recovered "$timer"
    exit 0
    ;;
  *"--user start "*)
    log_systemctl "$*"
    if timer_in_list "$timer" "${FAKE_START_FAIL_TIMERS:-}"; then
      exit 1
    fi
    if timer_in_list "$timer" "${FAKE_START_STAYS_INACTIVE_TIMERS:-}"; then
      exit 0
    fi
    mark_timer_recovered "$timer"
    exit 0
    ;;
  *)
    log_systemctl "$*"
    exit 0
    ;;
esac
EOF
chmod +x "$TICK_FAKE_BIN/gh" "$TICK_FAKE_BIN/systemctl"

assert_eq() {
  local desc="$1" expected="$2" actual="$3"
  if [ "$expected" = "$actual" ]; then
    echo "ok - $desc"
  else
    echo "not ok - $desc (expected [$expected], got [$actual])"
    FAILED=1
  fi
}

assert_contains() {
  local desc="$1" haystack="$2" needle="$3"
  if [[ "$haystack" == *"$needle"* ]]; then
    echo "ok - $desc"
  else
    echo "not ok - $desc (expected to find [$needle])"
    FAILED=1
  fi
}

assert_not_contains() {
  local desc="$1" haystack="$2" needle="$3"
  if [[ "$haystack" != *"$needle"* ]]; then
    echo "ok - $desc"
  else
    echo "not ok - $desc (expected NOT to find [$needle])"
    FAILED=1
  fi
}

# Builds a throwaway {bare origin, checkout} pair with one shared commit on
# main, checkout tracking origin/main, and copies the launcher plus its
# shared inbox helper dependencies into engine — so self-location
# resolves only inside the throwaway checkout. Prints "<repo>|<origin>".
make_fixture() {
  local origin repo
  origin="$(mktemp -d)"
  repo="$(mktemp -d)"
  TMP_DIRS+=("$origin" "$repo")

  git init -q --bare "$origin"
  # Bare repos default HEAD to whatever init.defaultBranch resolves to on
  # this machine, independent of which branch later gets pushed into them.
  # Pin it to main explicitly so a later `git clone` of this origin (the
  # diverged-history fixture below) checks out a real branch instead of
  # warning "remote HEAD refers to nonexistent ref" and leaving an empty
  # working tree.
  git -C "$origin" symbolic-ref HEAD refs/heads/main

  git -C "$repo" init -q -b main
  git -C "$repo" config user.email test@example.com
  git -C "$repo" config user.name "Test"
  echo "seed" >"$repo/seed.txt"
  # The launcher's own copy is part of the seed commit, not left
  # untracked on top of it — an untracked file would itself trip the
  # dirty-tree guard this fixture exists to test against.
  mkdir -p "$repo/engine/systemd"
  copy_agent_library "$repo/engine"
  rm -f "$repo/engine/issue-pipeline.sh"
  cp "$TIMER_LIST_SRC" "$repo/engine/systemd/pipeline-timers.list"
  chmod +x "$repo/engine/run-tick.sh"
  git -C "$repo" add -A
  git -C "$repo" commit -q -m seed
  git -C "$repo" remote add origin "$origin"
  git -C "$repo" push -q -u origin main

  echo "$repo|$origin"
}

# fresh_agent_home / fresh_roster — a throwaway AGENT_HOME directory and a
# throwaway recipients roster (fake address, nothing real — no real email
# address may enter this repo). Both registered in TMP_DIRS for cleanup.
fresh_agent_home() {
  local d
  d="$(mktemp -d)"
  TMP_DIRS+=("$d")
  echo "$d"
}

fresh_roster() {
  local f
  f="$(mktemp)"
  TMP_DIRS+=("$f")
  cat >"$f" <<'JSON'
{"founder_login":"testmaintainer","recipients":{"testmaintainer":"maintainer@example.invalid"}}
JSON
  echo "$f"
}

# run_launcher <repo> [agent_home] [roster] — runs run-tick.sh with an
# ISOLATED AGENT_HOME/roster, defaulting to a fresh throwaway pair per call
# when the caller doesn't need to reuse one
# across consecutive ticks (the counter-persistence scenarios below do,
# and pass the same agent_home/roster back in on each call).
#
# This isolation is not optional and every call site below MUST go
# through this helper, never invoke run-tick.sh directly: a scoping bug
# caught and fixed 2026-09-14 (see run-tick.sh's own AGENT_HOME comment --
# a bare `local AGENT_HOME` followed by a separate assignment silently
# shadowed and ignored an exported override) meant an earlier version of
# this exact isolation was silently bypassed and briefly hit the REAL
# $HOME/.zenoforge — including its real recipients.json — before
# being caught. Defaulting every call to a fresh throwaway pair, instead
# of requiring each call site to remember to pass one, is what actually
# closes that hole; a future call site cannot forget an argument that
# isn't required.
run_launcher() {
  local repo="$1"
  local agent_home="${2:-$(fresh_agent_home)}"
  local roster="${3:-$(fresh_roster)}"
  set +e
  RUN_OUTPUT="$(AGENT_HOME="$agent_home" AGENT_DRY_RUN=1 \
    ZF_AGENT_RECIPIENTS_FILE="$roster" \
    PATH="${TICK_GIT_SHIM_BIN:+$TICK_GIT_SHIM_BIN:}$TICK_FAKE_BIN:$PATH" \
    bash "$repo/engine/run-tick.sh" 2>&1)"
  RUN_STATUS=$?
  set -e
}

inbox_events() {
  local inbox="$1/supervisor-inbox"
  [ -f "$inbox" ] && cat "$inbox" || true
}

assert_not_contains "run-tick has no founder-mail path" "$(cat "$LAUNCHER_SRC")" "notify_maintainer"

# Retired timers must not be repaired or reported as outages.
for retired_timer in zf-work-plan-acceptance.timer zf-mac-ci-runners.timer; do
  pair="$(make_fixture)"; repo="${pair%%|*}"
  agent_home="$(fresh_agent_home)"
  retired_timer_log="$(mktemp)"
  TMP_DIRS+=("$retired_timer_log")
  export FAKE_DISABLED_TIMERS="$retired_timer"
  export FAKE_INACTIVE_TIMERS="$retired_timer"
  export FAKE_ENABLE_FAIL_TIMERS="$retired_timer"
  export FAKE_SYSTEMCTL_LOG="$retired_timer_log"
  run_launcher "$repo" "$agent_home"
  assert_eq "retired $retired_timer does not trigger a repair" "0" "$(grep -cF "$retired_timer" "$retired_timer_log" || true)"
  assert_eq "retired $retired_timer does not raise an outage" "" "$(inbox_events "$agent_home")"
  unset FAKE_DISABLED_TIMERS FAKE_INACTIVE_TIMERS FAKE_ENABLE_FAIL_TIMERS FAKE_SYSTEMCTL_LOG
done

# --- pipeline timer invariant: all dependencies, not one named timer ------
mapfile -t pipeline_timers < <(awk '!/^#/ && NF { print $1 }' "$TIMER_LIST_SRC")
all_timers_csv="$(IFS=,; echo "${pipeline_timers[*]}")"
timer_alert_marker() {
  awk -v timer="$1" '$1 == timer { print $3 }' "$TIMER_LIST_SRC"
}
for core_timer in zenoforge-agent.timer zenoforge-supervisor.timer; do
  assert_contains "the unit-adjacent timer list keeps $core_timer" " ${pipeline_timers[*]} " " $core_timer "
done
assert_eq "the supervisor keeps #1531's existing outage marker" \
  "supervisor-timer-alerted" "$(timer_alert_marker zenoforge-supervisor.timer)"

# A stopped timer is repaired by the next agent tick. Verified recovery is
# silent; only a repair that leaves the timer inactive needs an alert.
fixture="$(make_fixture)"
repo="${fixture%%|*}"
timer_log="$(mktemp)"
TMP_DIRS+=("$timer_log")
: >"$timer_log"
export FAKE_INACTIVE_TIMERS="$all_timers_csv"
export FAKE_DISABLED_TIMERS=""
export FAKE_SUPERVISOR_MODE=observe
export FAKE_SYSTEMCTL_LOG="$timer_log"
agent_home="$(fresh_agent_home)"
roster="$(fresh_roster)"

run_launcher "$repo" "$agent_home" "$roster"
assert_eq "stopped timers still let the fixture reach the handoff" "1" "$RUN_STATUS"
for timer in "${pipeline_timers[@]}"; do
  assert_contains "a stopped $timer is started by the tick" \
    "$RUN_OUTPUT" "started $timer"
  assert_eq "$timer gets one start command on its first outage tick" \
    "1" "$(grep -cF -- "--user start $timer" "$timer_log" || true)"
done
assert_not_contains "successful timer repairs do not send email" \
  "$RUN_OUTPUT" "dry-run] send_email"

run_launcher "$repo" "$agent_home" "$roster"
assert_not_contains "verified recovery stays silent on later ticks" \
  "$RUN_OUTPUT" "dry-run] send_email"
for timer in "${pipeline_timers[@]}"; do
  assert_eq "$timer is not restarted after verified recovery" \
    "1" "$(grep -cF -- "--user start $timer" "$timer_log" || true)"
done

export FAKE_INACTIVE_TIMERS=""
run_launcher "$repo" "$agent_home" "$roster"
for timer in "${pipeline_timers[@]}"; do
  if [ -f "$agent_home/$(timer_alert_marker "$timer")" ]; then
    echo "not ok - an active $timer clears its outage marker"
    FAILED=1
  else
    echo "ok - an active $timer clears its outage marker"
  fi
done
export FAKE_INACTIVE_TIMERS=zenoforge-label-churn.timer
rm -f "$timer_log.recovered.zenoforge-label-churn.timer"
run_launcher "$repo" "$agent_home" "$roster"
assert_not_contains "a later label-churn outage is silent after successful repair" \
  "$RUN_OUTPUT" "dry-run] send_email"
assert_eq "the later label-churn outage is repaired again" \
  "2" "$(grep -cF -- "--user start zenoforge-label-churn.timer" "$timer_log" || true)"
unset FAKE_INACTIVE_TIMERS

# Upgrading this invariant must not turn #1531's existing supervisor marker
# into a second inbox event for the same still-open outage.
fixture="$(make_fixture)"
repo="${fixture%%|*}"
legacy_marker_log="$(mktemp)"
TMP_DIRS+=("$legacy_marker_log")
: >"$legacy_marker_log"
export FAKE_INACTIVE_TIMERS=zenoforge-supervisor.timer
export FAKE_SUPERVISOR_MODE=observe
export FAKE_SYSTEMCTL_LOG="$legacy_marker_log"
agent_home="$(fresh_agent_home)"
roster="$(fresh_roster)"
touch "$agent_home/$(timer_alert_marker zenoforge-supervisor.timer)"

run_launcher "$repo" "$agent_home" "$roster"
assert_eq "a marked legacy supervisor outage is still retried" \
  "1" "$(grep -cF -- '--user start zenoforge-supervisor.timer' "$legacy_marker_log" || true)"
assert_eq "a marked legacy supervisor outage does not add an inbox event" \
  "" "$(inbox_events "$agent_home")"
unset FAKE_INACTIVE_TIMERS

# ZF_UNIT_PREFIX renames every timer the list names; no timer keeps the list's own prefix.
fixture="$(make_fixture)"
repo="${fixture%%|*}"
prefix_log="$(mktemp)"
TMP_DIRS+=("$prefix_log")
: >"$prefix_log"
export ZF_UNIT_PREFIX=acme FAKE_INACTIVE_TIMERS=acme-agent.timer FAKE_SUPERVISOR_MODE=observe FAKE_SYSTEMCTL_LOG="$prefix_log"
agent_home="$(fresh_agent_home)"
roster="$(fresh_roster)"
run_launcher "$repo" "$agent_home" "$roster"
assert_eq "a unit prefix setting renames the timer the list names" \
  "1" "$(grep -cF -- '--user start acme-agent.timer' "$prefix_log" || true)"
list_prefix="${pipeline_timers[0]%%-*}"
assert_eq "no list timer keeps its own prefix under another setting" \
  "0" "$(grep -cF -- "$list_prefix-" "$prefix_log" || true)"
unset ZF_UNIT_PREFIX FAKE_INACTIVE_TIMERS

# Disabled is a different fault: enable --now restores boot persistence and
# current activity, rather than treating it as a plain start.
fixture="$(make_fixture)"
repo="${fixture%%|*}"
disabled_log="$(mktemp)"
TMP_DIRS+=("$disabled_log")
: >"$disabled_log"
export FAKE_DISABLED_TIMERS="$all_timers_csv"
export FAKE_SUPERVISOR_MODE=observe
export FAKE_SYSTEMCTL_LOG="$disabled_log"
agent_home="$(fresh_agent_home)"
roster="$(fresh_roster)"

run_launcher "$repo" "$agent_home" "$roster"
for timer in "${pipeline_timers[@]}"; do
  assert_contains "a disabled $timer is enabled and started by the tick" \
    "$RUN_OUTPUT" "enabled and started $timer"
  assert_eq "$timer gets enable --now, not a plain start, when disabled" \
    "1" "$(grep -cF -- "--user enable --now $timer" "$disabled_log" || true)"
  assert_eq "$timer gets no plain start while disabled" \
    "0" "$(grep -cF -- "--user start $timer" "$disabled_log" || true)"
done
assert_not_contains "successfully enabling timers does not send email" \
  "$RUN_OUTPUT" "dry-run] send_email"

run_launcher "$repo" "$agent_home" "$roster"
assert_not_contains "disabled retries do not repeat their notifications" \
  "$RUN_OUTPUT" "dry-run] send_email"
for timer in "${pipeline_timers[@]}"; do
  assert_eq "$timer is not re-enabled after verified recovery" \
    "1" "$(grep -cF -- "--user enable --now $timer" "$disabled_log" || true)"
done
unset FAKE_DISABLED_TIMERS

# A failed enable is not silently retried: it writes one supervisor event,
# then continues trying without duplicating it.
fixture="$(make_fixture)"
repo="${fixture%%|*}"
failed_enable_log="$(mktemp)"
TMP_DIRS+=("$failed_enable_log")
: >"$failed_enable_log"
export FAKE_DISABLED_TIMERS=zenoforge-label-churn.timer
export FAKE_INACTIVE_TIMERS=zenoforge-label-churn.timer
export FAKE_ENABLE_FAIL_TIMERS=zenoforge-label-churn.timer
export FAKE_SYSTEMCTL_LOG="$failed_enable_log"
agent_home="$(fresh_agent_home)"
roster="$(fresh_roster)"

run_launcher "$repo" "$agent_home" "$roster"
assert_contains "a failed disabled repair says it could not enable and start" \
  "$RUN_OUTPUT" "failed to enable and start zenoforge-label-churn.timer"
assert_contains "a failed disabled repair writes a supervisor event" \
  "$(inbox_events "$agent_home")" "timer-outage timer=zenoforge-label-churn.timer"
assert_contains "a failed disabled repair records its enable command" \
  "$(inbox_events "$agent_home")" 'repair_command="systemctl --user enable --now zenoforge-label-churn.timer"'
assert_contains "an unrecovered disabled timer event includes its status command" \
  "$(inbox_events "$agent_home")" 'status_command="systemctl --user status zenoforge-label-churn.timer"'
assert_eq "only an unrecovered disabled timer writes one event" \
  "1" "$(grep -cF 'timer-outage timer=zenoforge-label-churn.timer' <<<"$(inbox_events "$agent_home")" || true)"
assert_not_contains "a failed disabled repair does not send maintainer mail" \
  "$RUN_OUTPUT" "send_email"
run_launcher "$repo" "$agent_home" "$roster"
assert_eq "a failed repair still writes one outage event" \
  "1" "$(grep -cF 'timer-outage timer=zenoforge-label-churn.timer' <<<"$(inbox_events "$agent_home")" || true)"
assert_eq "a failed disabled repair keeps retrying enable --now" \
  "2" "$(grep -cF -- '--user enable --now zenoforge-label-churn.timer' "$failed_enable_log" || true)"
unset FAKE_DISABLED_TIMERS FAKE_ENABLE_FAIL_TIMERS FAKE_INACTIVE_TIMERS

# A failed start follows the same once-per-outage inbox contract.
fixture="$(make_fixture)"
repo="${fixture%%|*}"
failed_start_log="$(mktemp)"
TMP_DIRS+=("$failed_start_log")
: >"$failed_start_log"
export FAKE_INACTIVE_TIMERS=zenoforge-supervisor.timer
export FAKE_START_FAIL_TIMERS=zenoforge-supervisor.timer
export FAKE_SYSTEMCTL_LOG="$failed_start_log"
agent_home="$(fresh_agent_home)"
roster="$(fresh_roster)"

run_launcher "$repo" "$agent_home" "$roster"
assert_contains "a failed start reports the timer still inactive" \
  "$RUN_OUTPUT" "failed to start zenoforge-supervisor.timer"
assert_contains "a failed start writes one supervisor event" \
  "$(inbox_events "$agent_home")" "timer-outage timer=zenoforge-supervisor.timer"
assert_contains "a failed start event includes its unit status command" \
  "$(inbox_events "$agent_home")" 'status_command="systemctl --user status zenoforge-supervisor.timer"'
run_launcher "$repo" "$agent_home" "$roster"
assert_eq "a failed start does not repeat its event while retrying" \
  "1" "$(grep -cF 'timer-outage timer=zenoforge-supervisor.timer' <<<"$(inbox_events "$agent_home")" || true)"
assert_eq "a failed start remains retried" \
  "2" "$(grep -cF -- "--user start zenoforge-supervisor.timer" "$failed_start_log" || true)"
unset FAKE_INACTIVE_TIMERS FAKE_START_FAIL_TIMERS

# A zero exit from start is not enough when active-state readback still fails.
fixture="$(make_fixture)"
repo="${fixture%%|*}"
unconfirmed_start_log="$(mktemp)"
TMP_DIRS+=("$unconfirmed_start_log")
: >"$unconfirmed_start_log"
export FAKE_INACTIVE_TIMERS=zenoforge-supervisor.timer
export FAKE_START_STAYS_INACTIVE_TIMERS=zenoforge-supervisor.timer
export FAKE_SYSTEMCTL_LOG="$unconfirmed_start_log"
agent_home="$(fresh_agent_home)"
roster="$(fresh_roster)"

run_launcher "$repo" "$agent_home" "$roster"
assert_contains "a successful start command with inactive readback writes an event" \
  "$(inbox_events "$agent_home")" "timer-outage timer=zenoforge-supervisor.timer"
assert_contains "an inactive readback event includes its unit status command" \
  "$(inbox_events "$agent_home")" 'status_command="systemctl --user status zenoforge-supervisor.timer"'
assert_contains "unrecovered timer state is recorded before alert" \
  "$RUN_OUTPUT" "zenoforge-supervisor.timer remains inactive after systemctl --user start"
unset FAKE_INACTIVE_TIMERS FAKE_START_STAYS_INACTIVE_TIMERS

# AGENT_SUPERVISOR=off is the real operator switch. It only suppresses the
# supervisor entry declared with that switch; other stopped dependencies heal.
fixture="$(make_fixture)"
repo="${fixture%%|*}"
switch_log="$(mktemp)"
TMP_DIRS+=("$switch_log")
: >"$switch_log"
export FAKE_INACTIVE_TIMERS="$all_timers_csv"
export FAKE_SUPERVISOR_MODE=off
export FAKE_SYSTEMCTL_LOG="$switch_log"
agent_home="$(fresh_agent_home)"
roster="$(fresh_roster)"
touch "$agent_home/$(timer_alert_marker zenoforge-supervisor.timer)"

run_launcher "$repo" "$agent_home" "$roster"
assert_eq "AGENT_SUPERVISOR=off leaves its stopped timer alone" \
  "0" "$(grep -cF -- '--user start zenoforge-supervisor.timer' "$switch_log" || true)"
if [ -f "$agent_home/$(timer_alert_marker zenoforge-supervisor.timer)" ]; then
  echo "not ok - AGENT_SUPERVISOR=off clears its stale outage marker"
  FAILED=1
else
  echo "ok - AGENT_SUPERVISOR=off clears its stale outage marker"
fi
for timer in zenoforge-agent.timer zenoforge-label-churn.timer zenoforge-disk-reclaim.timer; do
  assert_eq "$timer still heals while the supervisor is intentionally off" \
    "1" "$(grep -cF -- "--user start $timer" "$switch_log" || true)"
done
assert_not_contains "successfully healed timers stay silent while supervisor is off" \
  "$RUN_OUTPUT" "dry-run] send_email"
unset FAKE_INACTIVE_TIMERS FAKE_SUPERVISOR_MODE FAKE_SYSTEMCTL_LOG

# --- live model policy follows only a changed deployed default --------------
fixture="$(make_fixture)"
repo="${fixture%%|*}"
origin="${fixture#*|}"
publisher="$(mktemp -d)"
TMP_DIRS+=("$publisher")
git clone -q "$origin" "$publisher"
git -C "$publisher" config user.email test@example.com
git -C "$publisher" config user.name Test
jq '.roles.work.service_tier = "ffsync"' "$publisher/engine/model-policy.default.json" >"$publisher/model-policy.default.json.tmp"
mv "$publisher/model-policy.default.json.tmp" "$publisher/engine/model-policy.default.json"
git -C "$publisher" add engine/model-policy.default.json
git -C "$publisher" commit -q -m 'change model policy default'
git -C "$publisher" push -q origin main
agent_home="$(fresh_agent_home)"
roster="$(fresh_roster)"
# A schema-less stale host snapshot is backed up and reset to the deployed default.
jq 'del(.schema_version, .roles.work.fallback_model, .roles.production.fallback_model, .roles.review)
  | .roles.work.service_tier = "operator-fast"
  | .switches["roadmap-order"] = false
  | .fixture_live_marker = "old-policy"' \
  "$repo/engine/model-policy.default.json" >"$agent_home/model-policy.json"
cp "$agent_home/model-policy.json" "$agent_home/old-model-policy.json"
if AGENT_HOME="$agent_home" ZF_REPO_DIR="$repo" bash -c '
  MODEL_POLICY_SOURCE_CHECK_ONLY=1
  source "$ZF_REPO_DIR/engine/lib.sh"
  model_policy_validate_file "$AGENT_HOME/model-policy.json"
' >/dev/null 2>&1; then
  stale_policy_strict_status=0
else
  stale_policy_strict_status=$?
fi
assert_eq "the strict product validator rejects a schema-less persisted policy" "1" "$stale_policy_strict_status"
stale_policy_check="$(AGENT_HOME="$agent_home" ZF_REPO_DIR="$repo" bash -c '
  MODEL_POLICY_SOURCE_CHECK_ONLY=1
  source "$ZF_REPO_DIR/engine/lib.sh"
  model_policy source-check
')"
assert_eq "source-check can validate a legacy policy without migrating it" clean "$stale_policy_check"
if cmp -s "$agent_home/old-model-policy.json" "$agent_home/model-policy.json"; then
  source_check_write_status=0
else
  source_check_write_status=$?
fi
assert_eq "source-check leaves the original legacy policy bytes untouched" "0" "$source_check_write_status"
source_check_backup_count="$(find "$agent_home" -maxdepth 1 -type f -name 'model-policy.json.bak.schema-v0.*' -print | wc -l | tr -d '[:space:]')"
assert_eq "source-check does not create a migration backup" "0" "$source_check_backup_count"

missing_policy_home="$(fresh_agent_home)"
if AGENT_HOME="$missing_policy_home" ZF_REPO_DIR="$repo" bash -c '
  MODEL_POLICY_SOURCE_CHECK_ONLY=1
  source "$ZF_REPO_DIR/engine/lib.sh"
  model_policy source-check
' >/dev/null 2>&1; then
  missing_source_check_status=0
else
  missing_source_check_status=$?
fi
assert_eq "source-check rejects a missing persisted policy" "1" "$missing_source_check_status"
assert_eq "source-check does not seed a missing persisted policy" "0" "$([[ ! -e "$missing_policy_home/model-policy.json" ]] && echo 0 || echo 1)"

if stale_policy_identity="$(AGENT_HOME="$agent_home" ZF_REPO_DIR="$repo" bash -c '
  source "$ZF_REPO_DIR/engine/lib.sh"
  model_policy identity work
' 2>&1)"; then
  stale_policy_resolution_status=0
else
  stale_policy_resolution_status=$?
fi
assert_eq "new code resolves the old live policy before post-fast-forward sync" "$MODEL_POLICY_TEST_WORK_IDENTITY" "$stale_policy_identity"
assert_eq "new code loads successfully against the old live policy" "0" "$stale_policy_resolution_status"
schema_migration_backups=("$agent_home"/model-policy.json.bak.schema-v0.*)
assert_eq "startup migration keeps one recoverable copy of the schema-less policy" \
  "1" "${#schema_migration_backups[@]}"
if cmp -s "$agent_home/old-model-policy.json" "${schema_migration_backups[0]}"; then
  migration_backup_status=0
else
  migration_backup_status=$?
fi
assert_eq "the migration backup retains the original policy bytes" "0" "$migration_backup_status"
stale_policy_check="$(AGENT_HOME="$agent_home" ZF_REPO_DIR="$repo" bash -c '
  MODEL_POLICY_SOURCE_CHECK_ONLY=1
  source "$ZF_REPO_DIR/engine/lib.sh"
  model_policy source-check
')"
assert_eq "migrated persistent policy passes source-check" clean "$stale_policy_check"
jq -e --slurpfile default "$repo/engine/model-policy.default.json" \
  '. == $default[0]' "$agent_home/model-policy.json" >/dev/null
stale_review_identity="$(AGENT_HOME="$agent_home" ZF_REPO_DIR="$repo" bash -c '
  source "$ZF_REPO_DIR/engine/lib.sh"
  model_policy identity review
')"
assert_eq "whole-default migration resolves a role from the deployed default" "$MODEL_POLICY_TEST_REVIEW_IDENTITY" "$stale_review_identity"
jq '.roles.work.model = .forbidden[0]' "$agent_home/old-model-policy.json" >"$agent_home/model-policy.json"
if AGENT_HOME="$agent_home" ZF_REPO_DIR="$repo" bash -c '
  source "$ZF_REPO_DIR/engine/lib.sh"
  model_policy identity work
' >/dev/null 2>&1; then
  forbidden_live_status=0
else
  forbidden_live_status=$?
fi
assert_eq "default forbidden-model protection rejects merged live policy" "1" "$forbidden_live_status"
cp "$agent_home/old-model-policy.json" "$agent_home/model-policy.json"

run_launcher "$repo" "$agent_home" "$roster"
assert_eq "a default-changing fast-forward reaches fixture handoff" "1" "$RUN_STATUS"
assert_contains "a default-changing fast-forward logs live policy sync" \
  "$RUN_OUTPUT" "model-policy-sync: synchronized live model policy from deployed default"
assert_eq "a changed default writes one sync record" \
  "1" "$(grep -cF 'model-policy-sync: synchronized live model policy from deployed default' <<<"$RUN_OUTPUT")"
if jq -e --slurpfile default "$repo/engine/model-policy.default.json" \
    '. == $default[0]' "$agent_home/model-policy.json" >/dev/null; then
  migrated_policy_status=0
else
  migrated_policy_status=$?
fi
assert_eq "a default-changing fast-forward installs the complete deployed default" \
  "0" "$migrated_policy_status"
resolved_policy_tier="$(AGENT_HOME="$agent_home" ZF_REPO_DIR="$repo" bash -c '
  source "$ZF_REPO_DIR/engine/lib.sh"
  model_policy tier work
')"
assert_eq "a default-changing fast-forward applies the new work service tier" \
  "$(jq -r '.roles.work.service_tier // empty' "$repo/engine/model-policy.default.json")" \
  "$resolved_policy_tier"
assert_eq "the synced live policy is private" "600" "$(stat -c '%a' "$agent_home/model-policy.json")"
if AGENT_HOME="$agent_home" ZF_REPO_DIR="$repo" bash -c '
  source "$ZF_REPO_DIR/engine/lib.sh"
  model_policy_validate_file "$AGENT_HOME/model-policy.json"
'; then
  policy_validation_status=0
else
  policy_validation_status=$?
fi
assert_eq "the synced policy passes model_policy_validate_file" "0" "$policy_validation_status"

# An unrelated fast-forward must preserve an existing operator policy byte-for-byte.
fixture="$(make_fixture)"
repo="${fixture%%|*}"
origin="${fixture#*|}"
publisher="$(mktemp -d)"
TMP_DIRS+=("$publisher")
git clone -q "$origin" "$publisher"
git -C "$publisher" config user.email test@example.com
git -C "$publisher" config user.name Test
echo unrelated >"$publisher/unrelated.txt"
git -C "$publisher" add unrelated.txt
git -C "$publisher" commit -q -m 'unrelated fast-forward'
git -C "$publisher" push -q origin main
agent_home="$(fresh_agent_home)"
roster="$(fresh_roster)"
jq '.fixture_live_marker = "preserve"' "$repo/engine/model-policy.default.json" >"$agent_home/model-policy.json"
cp "$agent_home/model-policy.json" "$agent_home/expected-model-policy.json"

run_launcher "$repo" "$agent_home" "$roster"
assert_eq "an unrelated fast-forward reaches fixture handoff" "1" "$RUN_STATUS"
assert_contains "an unrelated fast-forward still completes merge" \
  "$RUN_OUTPUT" "fast-forwarded to origin/main"
if cmp -s "$agent_home/expected-model-policy.json" "$agent_home/model-policy.json"; then
  policy_cmp_status=0
else
  policy_cmp_status=$?
fi
assert_eq "an unchanged default leaves the live policy untouched" "0" "$policy_cmp_status"
assert_not_contains "an unchanged default writes no sync record" \
  "$RUN_OUTPUT" "model-policy-sync: synchronized live model policy from deployed default"

# If the shared apply cannot fetch its landed source, keep old live bytes and alert with the reason.
fixture="$(make_fixture)"
repo="${fixture%%|*}"
origin="${fixture#*|}"
publisher="$(mktemp -d)"
TMP_DIRS+=("$publisher")
git clone -q "$origin" "$publisher"
git -C "$publisher" config user.email test@example.com
git -C "$publisher" config user.name Test
jq '.roles.work.service_tier = "ffsync"' "$publisher/engine/model-policy.default.json" >"$publisher/model-policy.default.json.tmp"
mv "$publisher/model-policy.default.json.tmp" "$publisher/engine/model-policy.default.json"
git -C "$publisher" add engine/model-policy.default.json
git -C "$publisher" commit -q -m 'change model policy default'
git -C "$publisher" push -q origin main
agent_home="$(fresh_agent_home)"
roster="$(fresh_roster)"
jq '.fixture_live_marker = "preserve-on-error"' "$repo/engine/model-policy.default.json" >"$agent_home/model-policy.json"
cp "$agent_home/model-policy.json" "$agent_home/expected-model-policy.json"
TICK_GIT_SHIM_BIN="$(mktemp -d)"
TMP_DIRS+=("$TICK_GIT_SHIM_BIN")
REAL_GIT_BIN="$(command -v git)"
FAKE_GIT_FETCH_COUNT_FILE="$(mktemp)"
TMP_DIRS+=("$FAKE_GIT_FETCH_COUNT_FILE")
cat >"$TICK_GIT_SHIM_BIN/git" <<'FAKE_GIT'
#!/usr/bin/env bash
if [[ " $* " == *" fetch "* && " $* " == *" origin main "* ]]; then
  count="$(cat "$FAKE_GIT_FETCH_COUNT_FILE" 2>/dev/null || echo 0)"
  count=$((count + 1))
  echo "$count" > "$FAKE_GIT_FETCH_COUNT_FILE"
  if [[ "$count" == 2 ]]; then
    echo 'simulated second fetch failure' >&2
    exit 73
  fi
fi
exec "$REAL_GIT_BIN" "$@"
FAKE_GIT
chmod +x "$TICK_GIT_SHIM_BIN/git"
export TICK_GIT_SHIM_BIN REAL_GIT_BIN FAKE_GIT_FETCH_COUNT_FILE

run_launcher "$repo" "$agent_home" "$roster"
assert_eq "a failed policy apply refuses tick" "1" "$RUN_STATUS"
assert_contains "a failed policy apply preserves the failure reason in its alert" \
  "$(inbox_events "$agent_home")" "model-policy-apply-failed"
assert_contains "a failed policy apply alert includes the underlying reason" \
  "$(inbox_events "$agent_home")" "simulated second fetch failure"
if cmp -s "$agent_home/expected-model-policy.json" "$agent_home/model-policy.json"; then
  policy_cmp_status=0
else
  policy_cmp_status=$?
fi
assert_eq "a failed policy apply leaves old live bytes untouched" "0" "$policy_cmp_status"
unset TICK_GIT_SHIM_BIN REAL_GIT_BIN FAKE_GIT_FETCH_COUNT_FILE

# --- clean + up to date: guard passes, reaches the handoff -----------------
fixture="$(make_fixture)"
repo="${fixture%%|*}"

run_launcher "$repo"
assert_eq "a clean, up-to-date checkout reaches the handoff, only failing on the fixture's missing scheduler" \
  "1" "$RUN_STATUS"
assert_contains "...and its last log line names the handoff" \
  "$RUN_OUTPUT" "handing off to issue-pipeline.sh"

# --- one timeout retries once; recovery still reaches the handoff -----------
fixture="$(make_fixture)"
repo="${fixture%%|*}"
TICK_GIT_SHIM_BIN="$(mktemp -d)"
TMP_DIRS+=("$TICK_GIT_SHIM_BIN")
REAL_GIT_BIN="$(command -v git)"
fetch_count_file="$(mktemp)"
TMP_DIRS+=("$fetch_count_file")
cat >"$TICK_GIT_SHIM_BIN/git" <<'FAKE_GIT'
#!/usr/bin/env bash
if [[ " $* " == *" fetch "* ]]; then
  count=0
  [ ! -f "$FAKE_GIT_FETCH_COUNT_FILE" ] || count="$(cat "$FAKE_GIT_FETCH_COUNT_FILE")"
  count=$((count + 1))
  printf '%s\n' "$count" >"$FAKE_GIT_FETCH_COUNT_FILE"
  if [ "$count" -eq 1 ]; then sleep 2; fi
fi
exec "$REAL_GIT_BIN" "$@"
FAKE_GIT
chmod +x "$TICK_GIT_SHIM_BIN/git"
export TICK_GIT_SHIM_BIN REAL_GIT_BIN
export FAKE_GIT_FETCH_COUNT_FILE="$fetch_count_file"
export GIT_FETCH_TIMEOUT_SEC=1

run_launcher "$repo"
assert_eq "a stalled fetch retries once, then fixture fails only at missing scheduler" "1" "$RUN_STATUS"
assert_eq "the bounded retry performs exactly two fetches" "2" "$(cat "$fetch_count_file")"
assert_contains "the transient timeout is visible" "$RUN_OUTPUT" "retrying once"
assert_contains "the successful retry reaches scheduler handoff" "$RUN_OUTPUT" "handing off to issue-pipeline.sh"
unset TICK_GIT_SHIM_BIN REAL_GIT_BIN FAKE_GIT_FETCH_COUNT_FILE GIT_FETCH_TIMEOUT_SEC

# --- repeated fetch timeout under high local load is not blamed on network --
fixture="$(make_fixture)"
repo="${fixture%%|*}"
TICK_GIT_SHIM_BIN="$(mktemp -d)"
TMP_DIRS+=("$TICK_GIT_SHIM_BIN")
REAL_GIT_BIN="$(command -v git)"
REAL_AWK_BIN="$(command -v awk)"
fetch_count_file="$(mktemp)"
TMP_DIRS+=("$fetch_count_file")
cat >"$TICK_GIT_SHIM_BIN/git" <<'FAKE_GIT'
#!/usr/bin/env bash
if [[ " $* " == *" fetch "* ]]; then
  count=0
  [ ! -f "$FAKE_GIT_FETCH_COUNT_FILE" ] || count="$(cat "$FAKE_GIT_FETCH_COUNT_FILE")"
  count=$((count + 1))
  printf '%s\n' "$count" >"$FAKE_GIT_FETCH_COUNT_FILE"
  sleep 2
fi
exec "$REAL_GIT_BIN" "$@"
FAKE_GIT
cat >"$TICK_GIT_SHIM_BIN/awk" <<'FAKE_AWK'
#!/usr/bin/env bash
for arg in "$@"; do
  [ "$arg" = "/proc/loadavg" ] && { echo "28.0"; exit 0; }
done
exec "$REAL_AWK_BIN" "$@"
FAKE_AWK
cat >"$TICK_GIT_SHIM_BIN/nproc" <<'FAKE_NPROC'
#!/usr/bin/env bash
echo 9
FAKE_NPROC
chmod +x "$TICK_GIT_SHIM_BIN/git" "$TICK_GIT_SHIM_BIN/awk" "$TICK_GIT_SHIM_BIN/nproc"
export TICK_GIT_SHIM_BIN REAL_GIT_BIN REAL_AWK_BIN
export FAKE_GIT_FETCH_COUNT_FILE="$fetch_count_file"
export GIT_FETCH_TIMEOUT_SEC=1
agent_home="$(fresh_agent_home)"
roster="$(fresh_roster)"
for attempt in 1 2 3; do
  run_launcher "$repo" "$agent_home" "$roster"
done
assert_eq "the repeated timeout crosses the existing alert threshold" \
  "3" "$(cat "$agent_home/tick-failure-count")"
assert_contains "high local load writes its exact cause to supervisor inbox" \
  "$(inbox_events "$agent_home")" "tick-outage cause=fetch-starved failures=3"
assert_contains "high-load event preserves the observed sync timeout and load" \
  "$(inbox_events "$agent_home")" "observed=git fetch timed out after 1s while host 1m load 28.0 exceeded 2x processors (9)"
assert_not_contains "a high-load local timeout does not send maintainer mail" \
  "$RUN_OUTPUT" "send_email"
unset TICK_GIT_SHIM_BIN REAL_GIT_BIN REAL_AWK_BIN FAKE_GIT_FETCH_COUNT_FILE GIT_FETCH_TIMEOUT_SEC

# --- dirty tree: quarantine, restore, and continue --------------------------
fixture="$(make_fixture)"
repo="${fixture%%|*}"
echo "staged" >>"$repo/seed.txt"
git -C "$repo" add seed.txt
echo "unstaged" >>"$repo/seed.txt"
echo "untracked payload" >"$repo/recovery-note.txt"
agent_home="$(fresh_agent_home)"
roster="$(fresh_roster)"

run_launcher "$repo" "$agent_home" "$roster"
assert_eq "a quarantined dirty checkout reaches the fixture handoff" "1" "$RUN_STATUS"
assert_contains "the recovery event is one log line" "$RUN_OUTPUT" \
  "dirty checkout quarantined at $agent_home/quarantine/checkout-dirty-"
assert_contains "the recovered checkout reaches scheduler handoff" \
  "$RUN_OUTPUT" "handing off to issue-pipeline.sh"
assert_eq "tracked and untracked changes are removed from the checkout" \
  "" "$(git -C "$repo" status --porcelain --untracked-files=all)"
snapshot="$(find "$agent_home/quarantine" -mindepth 1 -maxdepth 1 -type d -name 'checkout-dirty-*' -print -quit)"
assert_contains "tracked diff is saved in quarantine" "$(cat "$snapshot/tracked.patch")" "+staged"
assert_contains "tracked diff includes unstaged content" "$(cat "$snapshot/tracked.patch")" "+unstaged"
assert_eq "untracked path list is saved" "recovery-note.txt" \
  "$(tr '\0' '\n' <"$snapshot/untracked.paths")"
assert_eq "untracked file contents are recoverable from the archive" \
  "recovery-note.txt" "$(tar -tf "$snapshot/untracked.tar")"
assert_not_contains "recovered dirty checkout does not alert as a network failure" \
  "$RUN_OUTPUT" "网络或者内部代理"

# --- restore failure is the only dirty-checkout refusal ---------------------
fixture="$(make_fixture)"
repo="${fixture%%|*}"
echo "dirty" >>"$repo/seed.txt"
TICK_GIT_SHIM_BIN="$(mktemp -d)"
TMP_DIRS+=("$TICK_GIT_SHIM_BIN")
REAL_GIT_BIN="$(command -v git)"
cat >"$TICK_GIT_SHIM_BIN/git" <<'FAKE_GIT'
#!/usr/bin/env bash
if [ "${FAKE_GIT_RESET_FAIL:-0}" = "1" ] && [[ " $* " == *" reset --hard HEAD "* ]]; then
  exit 23
fi
exec "$REAL_GIT_BIN" "$@"
FAKE_GIT
chmod +x "$TICK_GIT_SHIM_BIN/git"
export TICK_GIT_SHIM_BIN REAL_GIT_BIN FAKE_GIT_RESET_FAIL=1
run_launcher "$repo"
assert_eq "a failed restore exits non-zero" "1" "$RUN_STATUS"
assert_contains "the refusal names restore failure" "$RUN_OUTPUT" \
  "could not restore dirty checkout to HEAD"
assert_not_contains "a failed restore never reaches scheduler handoff" \
  "$RUN_OUTPUT" "handing off"
assert_not_contains "restore failure is not mislabeled as network trouble" \
  "$RUN_OUTPUT" "网络或者内部代理"
unset TICK_GIT_SHIM_BIN REAL_GIT_BIN FAKE_GIT_RESET_FAIL

# --- wrong branch: refuses ---------------------------------------------------
fixture="$(make_fixture)"
repo="${fixture%%|*}"
git -C "$repo" checkout -q -b other

run_launcher "$repo"
assert_eq "a checkout not on main exits non-zero" "1" "$RUN_STATUS"
assert_contains "...naming the branch as the reason" "$RUN_OUTPUT" "not main"

# --- diverged history: refuses (THE fast-forward-failure case) -------------
fixture="$(make_fixture)"
repo="${fixture%%|*}"
origin="${fixture##*|}"

other_clone="$(mktemp -d)"
TMP_DIRS+=("$other_clone")
git clone -q "$origin" "$other_clone"
git -C "$other_clone" config user.email test@example.com
git -C "$other_clone" config user.name "Test"
echo "origin-side change" >>"$other_clone/seed.txt"
git -C "$other_clone" commit -q -am "origin-side change"
git -C "$other_clone" push -q origin main

git -C "$repo" config user.email test@example.com
git -C "$repo" config user.name "Test"
echo "local-side change" >>"$repo/seed.txt"
git -C "$repo" commit -q -am "local-side change"

run_launcher "$repo"
assert_eq "a diverged checkout exits non-zero" "1" "$RUN_STATUS"
assert_contains "...naming the divergence as the reason" "$RUN_OUTPUT" "diverged"

# --- fetch failure (origin unreachable): refuses ----------------------------
fixture="$(make_fixture)"
repo="${fixture%%|*}"
origin="${fixture##*|}"
rm -rf "$origin"

run_launcher "$repo"
assert_eq "an unreachable origin exits non-zero" "1" "$RUN_STATUS"
assert_contains "...naming the fetch as the reason" "$RUN_OUTPUT" "fetch"

# --- repeated fetch timeout records its observed cause ----------------------
fixture="$(make_fixture)"
repo="${fixture%%|*}"
TICK_GIT_SHIM_BIN="$(mktemp -d)"
TMP_DIRS+=("$TICK_GIT_SHIM_BIN")
REAL_GIT_BIN="$(command -v git)"
REAL_AWK_BIN="$(command -v awk)"
cat >"$TICK_GIT_SHIM_BIN/git" <<'FAKE_GIT'
#!/usr/bin/env bash
if [[ " $* " == *" fetch "* ]]; then sleep 2; fi
exec "$REAL_GIT_BIN" "$@"
FAKE_GIT
cat >"$TICK_GIT_SHIM_BIN/awk" <<'FAKE_AWK'
#!/usr/bin/env bash
for arg in "$@"; do
  [ "$arg" = "/proc/loadavg" ] && { echo "0.01"; exit 0; }
done
exec "$REAL_AWK_BIN" "$@"
FAKE_AWK
cat >"$TICK_GIT_SHIM_BIN/nproc" <<'FAKE_NPROC'
#!/usr/bin/env bash
echo 9
FAKE_NPROC
chmod +x "$TICK_GIT_SHIM_BIN/git" "$TICK_GIT_SHIM_BIN/awk" "$TICK_GIT_SHIM_BIN/nproc"
agent_home="$(fresh_agent_home)"
roster="$(fresh_roster)"
echo 2 >"$agent_home/tick-failure-count"
export TICK_GIT_SHIM_BIN REAL_GIT_BIN REAL_AWK_BIN GIT_FETCH_TIMEOUT_SEC=1
run_launcher "$repo" "$agent_home" "$roster"
assert_eq "a repeated fetch timeout still refuses this tick" "1" "$RUN_STATUS"
assert_contains "the supervisor event names fetch timeout" "$(inbox_events "$agent_home")" \
  "tick-outage cause=fetch-timeout failures=3"
assert_contains "the fetch-timeout event preserves the observed cause" \
  "$(inbox_events "$agent_home")" "observed=git fetch origin main timed out after 1s"
unset TICK_GIT_SHIM_BIN REAL_GIT_BIN REAL_AWK_BIN GIT_FETCH_TIMEOUT_SEC

# --- scheduler failure records its typed cause ------------------------------
fixture="$(make_fixture)"
repo="${fixture%%|*}"
cat >"$repo/engine/issue-pipeline.sh" <<'EOF'
#!/usr/bin/env bash
exit 17
EOF
chmod +x "$repo/engine/issue-pipeline.sh"
git -C "$repo" add engine/issue-pipeline.sh
git -C "$repo" commit -q -m "fixture failing scheduler"
git -C "$repo" push -q origin main
agent_home="$(fresh_agent_home)"
roster="$(fresh_roster)"
echo 2 >"$agent_home/tick-failure-count"
run_launcher "$repo" "$agent_home" "$roster"
assert_eq "a failed scheduler exits non-zero" "1" "$RUN_STATUS"
assert_contains "the supervisor event names scheduler failure" "$(inbox_events "$agent_home")" \
  "tick-outage cause=scheduler-failed failures=3"
assert_contains "the scheduler event records its observed exit status" \
  "$(inbox_events "$agent_home")" "observed=issue-pipeline.sh exited with status 17"

# --- sustained-failure counter: bumps every refusal, records once at the ---
# --- threshold, not again on the next failure, resets and records recovery.
# --- Same agent_home/roster reused across every call below (on
# purpose -- these ticks must persist state across the "outage"); every
# call still goes through run_launcher, so it's still dry-run/isolated.
fixture="$(make_fixture)"
repo="${fixture%%|*}"
echo "dirty" >>"$repo/seed.txt"
agent_home="$(fresh_agent_home)"
roster="$(fresh_roster)"

run_launcher "$repo" "$agent_home" "$roster"
assert_eq "1st consecutive failure: counter is 1" "1" "$(cat "$agent_home/tick-failure-count")"
assert_eq "...and does not record yet (below threshold)" "" "$(inbox_events "$agent_home")"

run_launcher "$repo" "$agent_home" "$roster"
assert_eq "2nd consecutive failure: counter is 2" "2" "$(cat "$agent_home/tick-failure-count")"
assert_eq "...still no event (below threshold)" "" "$(inbox_events "$agent_home")"

run_launcher "$repo" "$agent_home" "$roster"
assert_eq "3rd consecutive failure: counter is 3" "3" "$(cat "$agent_home/tick-failure-count")"
assert_contains "...supervisor event fires exactly at the threshold" \
  "$(inbox_events "$agent_home")" "tick-outage cause=scheduler-failed failures=3"
assert_eq "one tick wake is logged at the alert threshold" \
  "1" "$(grep -cF 'tick-outage' "$agent_home/logs/supervisor-wakes.log")"
if [ -f "$agent_home/tick-failure-alerted" ]; then
  echo "ok - alerted marker written at the threshold"
else
  echo "not ok - alerted marker written at the threshold"
  FAILED=1
fi

run_launcher "$repo" "$agent_home" "$roster"
assert_eq "4th consecutive failure: counter keeps climbing" "4" "$(cat "$agent_home/tick-failure-count")"
assert_eq "...but does NOT record again -- once per outage" \
  "1" "$(grep -cF 'tick-outage cause=scheduler-failed' <<<"$(inbox_events "$agent_home")" || true)"
assert_eq "...and does NOT log another wake" \
  "1" "$(grep -cF 'tick-outage' "$agent_home/logs/supervisor-wakes.log")"

# Fixing the checkout (revert the dirty edit, still the same commit as
# origin) clears the outage. Add a harmless scheduler stub too: current
# run-tick.sh owns the child process, so a missing scheduler is correctly a
# failed tick rather than the old exec-shaped 127 handoff.
git -C "$repo" checkout -q -- seed.txt
cat >"$repo/engine/issue-pipeline.sh" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
chmod +x "$repo/engine/issue-pipeline.sh"
git -C "$repo" add engine/issue-pipeline.sh
git -C "$repo" commit -q -m "test scheduler success"
git -C "$repo" push -q origin main
run_launcher "$repo" "$agent_home" "$roster"
assert_eq "a clean tick after the outage reaches the handoff again" "0" "$RUN_STATUS"
assert_contains "...and records recovery, since we were in alerted state" \
  "$(inbox_events "$agent_home")" "tick-recovery"
assert_eq "recovery is recorded once in the supervisor inbox" \
  "1" "$(grep -cF 'tick-recovery' <<<"$(inbox_events "$agent_home")" || true)"
assert_eq "tick recovery is logged as one wake" \
  "1" "$(grep -cF 'tick-recovery' "$agent_home/logs/supervisor-wakes.log")"
assert_not_contains "recovery does not send maintainer mail" "$RUN_OUTPUT" "send_email"
if [ -f "$agent_home/tick-failure-count" ]; then
  echo "not ok - failure counter cleared on success"
  FAILED=1
else
  echo "ok - failure counter cleared on success"
fi
if [ -f "$agent_home/tick-failure-alerted" ]; then
  echo "not ok - alerted marker cleared on recovery"
  FAILED=1
else
  echo "ok - alerted marker cleared on recovery"
fi

# --- unexpected internal failure: still explains itself, never silently --
# --- (the class of hole the 21:22 incident investigation is about) -------
fixture="$(make_fixture)"
repo="${fixture%%|*}"
blocked_parent="$(mktemp -d)"
TMP_DIRS+=("$blocked_parent")
: >"$blocked_parent/not-a-directory"
bogus_agent_home="$blocked_parent/not-a-directory/nested"

run_launcher "$repo" "$bogus_agent_home" "/nonexistent/roster.json"
assert_eq "an internal failure (AGENT_HOME itself unwritable) still exits non-zero" \
  "1" "$RUN_STATUS"
assert_contains "...and still explains itself, never silently" \
  "$RUN_OUTPUT" "run-tick: refusing to run this tick"
assert_contains "...naming it as an internal/unexpected failure, not a known refusal" \
  "$RUN_OUTPUT" "internal error"

# --- systemd unit self-install: repo -> the directory systemd --user -----
# --- actually reads (#1299 review) ----------------------------------------
# The fixture's unit is deliberately named something that can never
# collide with the real zenoforge-agent.service/.timer, and both
# SYSTEMD_USER_UNIT_DIR and `systemctl` on PATH point at throwaway fakes --
# this never touches the real systemd --user manager or the real unit
# directory (see run-tick.sh's own install-loop comment for why that
# matters: this exact mechanism is what was missing live).
fixture="$(make_fixture)"
repo="${fixture%%|*}"
mkdir -p "$repo/engine/systemd"
cat >"$repo/engine/systemd/zf-selftest-unit.service" <<'EOF'
[Unit]
Description=throwaway fixture unit -- never installed for real, run-tick.test.sh only
[Service]
Type=oneshot
ExecStart=/bin/true
EOF
git -C "$repo" add -A
git -C "$repo" commit -q -m "add fixture unit"
git -C "$repo" push -q origin main

unit_dest_dir="$(mktemp -d)"
TMP_DIRS+=("$unit_dest_dir")
fake_bin="$(mktemp -d)"
TMP_DIRS+=("$fake_bin")
reload_log="$(mktemp)"
TMP_DIRS+=("$reload_log")
cat >"$fake_bin/systemctl" <<EOF
#!/usr/bin/env bash
case "\$*" in
  "--user daemon-reload") echo "systemctl \$*" >> "$reload_log" ;;
esac
exit 0
EOF
chmod +x "$fake_bin/systemctl"

agent_home="$(fresh_agent_home)"
roster="$(fresh_roster)"
set +e
RUN_OUTPUT="$(AGENT_HOME="$agent_home" AGENT_DRY_RUN=1 \
  ZF_AGENT_RECIPIENTS_FILE="$roster" \
  SYSTEMD_USER_UNIT_DIR="$unit_dest_dir" \
  PATH="$fake_bin:$TICK_FAKE_BIN:$PATH" \
  bash "$repo/engine/run-tick.sh" 2>&1)"
RUN_STATUS=$?
set -e

if [ -f "$unit_dest_dir/zf-selftest-unit.service" ]; then
  echo "ok - a unit missing from the dest dir gets installed"
else
  echo "not ok - a unit missing from the dest dir gets installed"
  FAILED=1
fi
assert_contains "...and the launcher logs which unit it installed" \
  "$RUN_OUTPUT" "installed updated unit: zf-selftest-unit.service"
assert_contains "...then reloads systemd exactly because something changed" \
  "$(<"$reload_log")" "daemon-reload"

# Second tick against the SAME dest dir: nothing changed, no reinstall, no
# reload noise -- daemon-reload is not free (it reparses every unit on the
# box) and every tick reaching this point unconditionally would mean
# calling it every 5 minutes forever for no reason.
: >"$reload_log"
set +e
RUN_OUTPUT="$(AGENT_HOME="$(fresh_agent_home)" AGENT_DRY_RUN=1 \
  ZF_AGENT_RECIPIENTS_FILE="$(fresh_roster)" \
  SYSTEMD_USER_UNIT_DIR="$unit_dest_dir" \
  PATH="$fake_bin:$TICK_FAKE_BIN:$PATH" \
  bash "$repo/engine/run-tick.sh" 2>&1)"
RUN_STATUS=$?
set -e
assert_not_contains "an already-current unit is not reinstalled on the next tick" \
  "$RUN_OUTPUT" "installed updated unit"
if [ -s "$reload_log" ]; then
  echo "not ok - daemon-reload is not called again when nothing changed"
  FAILED=1
else
  echo "ok - daemon-reload is not called again when nothing changed"
fi

fixture="$(make_fixture)"
repo="${fixture%%|*}"
daemon_sync_log="$(mktemp)"
TMP_DIRS+=("$daemon_sync_log")
export HOST_DAEMON_SYNC_LOG="$daemon_sync_log"
cat > "$repo/engine/check-host-daemons.py" <<'EOF'
import os, pathlib, sys
pathlib.Path(os.environ["HOST_DAEMON_SYNC_LOG"]).write_text(" ".join(sys.argv[1:]))
raise SystemExit(int(os.environ.get("HOST_DAEMON_SYNC_FAIL", "0")))
EOF
git -C "$repo" add engine/check-host-daemons.py
git -C "$repo" commit -q -m 'fixture daemon sync'
git -C "$repo" push -q origin main
run_launcher "$repo" "$(fresh_agent_home)" "$(fresh_roster)"
assert_contains "tick syncs running daemons after checkout advances" "$(<"$daemon_sync_log")" "$repo --sync "
export HOST_DAEMON_SYNC_FAIL=1
run_launcher "$repo" "$(fresh_agent_home)" "$(fresh_roster)"
assert_contains "daemon sync failures refuse dispatch" "$RUN_OUTPUT" "could not synchronize running host daemons after fast-forward"
unset HOST_DAEMON_SYNC_FAIL HOST_DAEMON_SYNC_LOG

if [ "$FAILED" -eq 1 ]; then
  echo "FAILED"
  exit 1
fi
echo "ALL PASS"
