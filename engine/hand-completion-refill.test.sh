#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "$0")/test-env.sh"
script_dir="$(cd "$(dirname "$0")" && pwd -P)"
source "$script_dir/hand-completion-refill.sh"
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/bin" "$tmp/repo/engine"
export REFILL_TRACE="$tmp/trace" REFILL_HELPER="$script_dir/hand-completion-refill.sh"
cat > "$tmp/bin/python3" <<'FAKE'
#!/bin/bash
for arg; do
  case "$arg" in
    watch-cleanup)
      echo cleanup >> "$REFILL_TRACE"
      if [ -n "${REFILL_WATCH_SCRIPT:-}" ]; then exec bash "$REFILL_WATCH_SCRIPT"; fi
      exit "${REFILL_EXIT:-0}" ;;
  esac
done
FAKE
chmod +x "$tmp/bin/python3"
watch_source="${REFILL_WATCH_SOURCE:-$script_dir/worktree-lifecycle.sh}"
watch_fn=$(sed -n '/^watch() {$/,/^}$/p' "$watch_source")
PATH="$tmp/bin:$PATH" bash -eu -c '
  pid_live() { return 1; }
  eval "$1"
  _WORKTREE_LIFECYCLE_DIR="$2"; REPO=/fixture/repo
  watch /fixture/worktree 99999999 123
' _ "$watch_fn" "$script_dir"
[[ "$(cat "$REFILL_TRACE")" == cleanup ]]
event_dir="$(hand_completion_event_dir)"
[[ "$(jq -r .phase "$event_dir/99999999-123.json")" == done ]]
echo 'PASS terminal watcher publishes durable event and completes cleanup'
: > "$REFILL_TRACE"
hand_completion_event_publish 99999999 123 /fixture/worktree
PATH="$tmp/bin:$PATH" hand_completion_event_run "$tmp/repo" "$HAND_COMPLETION_EVENT"
[[ ! -s "$REFILL_TRACE" ]]
echo 'PASS duplicate completed event never resets phase or creates another intake'

hand_completion_event_publish 99999999 124 /fixture/worktree
export REFILL_EXIT=75
status=0; PATH="$tmp/bin:$PATH" hand_completion_event_run "$tmp/repo" "$HAND_COMPLETION_EVENT" || status=$?
[[ "$status" == 75 && "$(jq -r .phase "$HAND_COMPLETION_EVENT")" == cleanup ]]
unset REFILL_EXIT
before=$(grep -c cleanup "$REFILL_TRACE")
PATH="$tmp/bin:$PATH" hand_completion_event_run "$tmp/repo" "$HAND_COMPLETION_EVENT"
[[ "$(jq -r .phase "$HAND_COMPLETION_EVENT")" == done && "$(grep -c cleanup "$REFILL_TRACE")" == "$((before + 1))" ]]
echo 'PASS deferred cleanup remains pending and retries'

hand_completion_event_publish 99999999 125 /fixture/worktree
exec {held}>"$HAND_COMPLETION_EVENT.lock"; flock -n "$held"
status=0; hand_completion_event_run "$tmp/repo" "$HAND_COMPLETION_EVENT" || status=$?
[[ "$status" == 75 && "$(jq -r .phase "$HAND_COMPLETION_EVENT")" == cleanup ]]
exec {held}>&-
echo 'PASS concurrent event writer preserves pending cleanup identity'

hand_completion_event_publish 99999999 126 /fixture/worktree
printf '%s\n' '{"pid":99999999,"start_ticks":"126","phase":"cleanup","worktree":"/fixture/worktree","command":"never-execute"}' > "$HAND_COMPLETION_EVENT"
status=0; hand_completion_event_run "$tmp/repo" "$HAND_COMPLETION_EVENT" || status=$?
[[ "$status" == 75 ]] && hand_completion_events_pending
echo 'PASS malformed/unreadable continuation is pending and arbitrary command payload is rejected'

# The same decision lock used by normal intake must defer this event, rather
# than return a false successful/no-eligible result that consumes its receipt.
decision_block="$(sed -n '/^# A slice inherits the parent/,/^# --- tick timing/p' "$script_dir/issue-pipeline.sh" | sed '$d')"
exec {held}>"$tmp/intake.lock"; flock -n "$held"
status=0
EVENT_REFILL=1 LOCK_FILE="$tmp/intake.lock" bash -eu -c 'eval "$1"' _ "$decision_block" || status=$?
[[ "$status" == 75 ]]
exec {held}>&-
echo 'PASS existing intake singleton contention defers75 rather than consuming an event'

# The pipeline maintenance tick retries existing completion events without a hand queue.
export ZF_NIGHT_DIR="$tmp/recovery-night"
: > "$REFILL_TRACE"
hand_completion_event_publish 99999998 42 /fixture/worktree
export REFILL_EXIT=75
status=0; PATH="$tmp/bin:$PATH" hand_completion_events_run_once "$tmp/repo" || status=$?
[[ "$status" == 75 && "$(jq -r .phase "$HAND_COMPLETION_EVENT")" == cleanup ]]
unset REFILL_EXIT
PATH="$tmp/bin:$PATH" hand_completion_events_run_once "$tmp/repo"
[[ "$(jq -r .phase "$HAND_COMPLETION_EVENT")" == done ]]
unset ZF_NIGHT_DIR
echo 'PASS maintenance retries the deferred completion event without a hand queue'

# A malformed or deferred older event must not starve a later cleanup.
export ZF_NIGHT_DIR="$tmp/rotation-night"
hand_completion_event_publish 99999991 1 /fixture/broken
broken_event="$HAND_COMPLETION_EVENT"
printf '%s\n' '{"phase":"invalid"}' > "$broken_event"
hand_completion_event_publish 99999992 2 /fixture/next
next_event="$HAND_COMPLETION_EVENT"
PATH="$tmp/bin:$PATH" hand_completion_events_run_once "$tmp/repo"
[[ "$(jq -r .phase "$broken_event")" == invalid && "$(jq -r .phase "$next_event")" == done ]]
unset ZF_NIGHT_DIR
echo 'PASS an invalid older event does not starve the next completion'

cat > "$tmp/watch-cleanup-fixture.sh" <<'SH'
#!/bin/bash
set -euo pipefail
eval "$(sed -n '/^watch_cleanup() {$/,/^}$/p' "$REFILL_WATCH_SOURCE")"
NIGHT="$REFILL_NIGHT"; AGENTS_FILE="$NIGHT/agents.txt"; mkdir -p "$NIGHT"
hand_registry_record_exit() { :; }
hand_exit_followup_dependencies() { :; }
finish_worktree() { :; }
hand_exit_blocked_on_dependency() { :; }
hand_addendum_after_exit() { [ "${REFILL_HANDOFF_FAIL:-0}" != 1 ]; }
say() { :; }
watch_cleanup /fixture/worktree 99999997 33
SH
export REFILL_WATCH_SOURCE="$script_dir/worktree-lifecycle.sh" REFILL_WATCH_SCRIPT="$tmp/watch-cleanup-fixture.sh" REFILL_NIGHT="$tmp/watch-night"
hand_completion_event_publish 99999997 33 /fixture/worktree
export REFILL_HANDOFF_FAIL=1
status=0; PATH="$tmp/bin:$PATH" hand_completion_events_run_once "$tmp/repo" || status=$?
[[ "$status" == 75 && "$(jq -r .phase "$HAND_COMPLETION_EVENT")" == cleanup ]]
unset REFILL_HANDOFF_FAIL
PATH="$tmp/bin:$PATH" hand_completion_events_run_once "$tmp/repo"
[[ "$(jq -r .phase "$HAND_COMPLETION_EVENT")" == done ]]
unset REFILL_WATCH_SCRIPT REFILL_WATCH_SOURCE REFILL_NIGHT
echo 'PASS maintenance retries an exit handoff after its callback fails'

# Full shared budget refuses the phase before the helper can consume an event.
python3 - "$script_dir" "$tmp/repo" <<'PY'
import fcntl, json, os, pathlib, subprocess, sys
scripts, repo = sys.argv[1:]
home = pathlib.Path(os.environ['AGENT_HOME']); locks = home/'locks'; locks.mkdir(exist_ok=True)
handle = (locks/'execution-0.lock').open('a+')
fcntl.flock(handle,fcntl.LOCK_EX|fcntl.LOCK_NB)
pid=os.getpid(); fields=pathlib.Path(f'/proc/{pid}/stat').read_text().rsplit(')',1)[1].split()
cgroup=next(x.split(':',2)[2] for x in pathlib.Path(f'/proc/{pid}/cgroup').read_text().splitlines() if x.startswith('0::'))
(locks/'execution-0.json').write_text(json.dumps({'pid':pid,'start_ticks':fields[19],'ppid':os.getppid(),'cgroup':cgroup}))
env=dict(os.environ,AGENT_GLOBAL_EXECUTION_CAP='1')
result=subprocess.run(['python3',scripts+'/execution-admission.py','run','--','bash',scripts+'/hand-completion-refill.sh',repo,'99999999','126'],env=env,capture_output=True,text=True)
assert result.returncode==75 and 'active=1 cap=1' in result.stderr
print('PASS full shared budget refuses independent intake before execution')
PY
