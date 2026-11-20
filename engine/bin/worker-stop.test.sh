#!/usr/bin/env bash
# worker-stop reports "stopped" only when the run's event log is still, and stops a child that left the process group.
set -uo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
fail() { echo "FAIL $1"; exit 1; }
"$here/worker-stop" >/dev/null; [[ $? == 64 ]] || fail 'no key must exit 64'
# The scope cases need a user systemd manager; a CI container has none.
systemd-run --user --scope --quiet true 2>/dev/null || { echo 'PASS usage only (no user systemd manager here: scope cases skipped)'; exit 0; }
T="$(mktemp -d)"; tag="wstest$$"
cleanup() { systemctl --user stop "luna-$tag-1-$$.scope" "luna-$tag-1-more-$$.scope" >/dev/null 2>&1; pkill -g "${stray:-0}" 2>/dev/null; rm -rf -- "$T"; }
trap cleanup EXIT
writer='for i in $(seq 40); do echo x >> "$0/events.jsonl"; sleep 1; done'
mkdir -p "$T/luna/$tag-1" "$T/luna/$tag-1-more" "$T/luna/$tag-2"
# A run in a scope whose writer double-forks into its own session, as a backend command does.
systemd-run --user --scope --quiet --unit="luna-$tag-1-$$" bash -c "( setsid bash -c '$writer' \"\$0\" & ); sleep 40" "$T/luna/$tag-1" >/dev/null 2>&1 &
# A second run whose key starts with the first key: stopping the first must leave it alone.
systemd-run --user --scope --quiet --unit="luna-$tag-1-more-$$" bash -c "$writer" "$T/luna/$tag-1-more" >/dev/null 2>&1 &
sleep 3
WORKER_SCRATCH_ROOT="$T" ZF_WORKER_STOP_QUIET=3 "$here/worker-stop" "$tag-1" >/dev/null || fail 'a scoped run with a detached child was not stopped'
a="$(wc -l < "$T/luna/$tag-1/events.jsonl")"; m1="$(wc -l < "$T/luna/$tag-1-more/events.jsonl")"; sleep 2
[[ "$(wc -l < "$T/luna/$tag-1/events.jsonl")" == "$a" ]] || fail 'the detached child kept writing after "stopped"'
[[ "$(wc -l < "$T/luna/$tag-1-more/events.jsonl")" -gt "$m1" ]] || fail 'stopping one key also stopped a longer key with the same prefix'
# A writer outside any scope and with no pid file cannot be reached: the answer must be "still running", not "stopped".
setsid bash -c "$writer" "$T/luna/$tag-2" >/dev/null 2>&1 & stray=$!
sleep 2
out="$(WORKER_SCRATCH_ROOT="$T" ZF_WORKER_STOP_QUIET=3 "$here/worker-stop" "$tag-2")"; rc=$?
[[ $rc == 1 && "$out" == *'STILL RUNNING'* ]] || fail "a run that keeps writing events was reported stopped (rc=$rc)"
echo 'PASS worker-stop: detached child stopped, prefix key untouched, unreachable writer reported still running'
