#!/usr/bin/env bash
set -euo pipefail
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/test-env.sh"
# daemon-self-check.sh: a supervised loop is stale only when its own script or a file it sources differs from the live copy.
here=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
tmp=$(mktemp -d "${TMPDIR:-/tmp}/daemon-self-check-test.XXXXXX"); trap 'rm -rf "$tmp"' EXIT
fail() { echo "daemon-self-check.test.sh: $*" >&2; exit 1; }
source "$here/daemon-self-check.sh"
files=(loop.sh env.sh ../conf.sh)
mkdir -p "$tmp/v1/mac-autopilot"; for f in "${files[@]}"; do echo "$f one" > "$tmp/v1/mac-autopilot/$f"; done
started=$tmp/v1/mac-autopilot
newdir() { rm -rf "$tmp/$1"; cp -r "$tmp/v1" "$tmp/$1"; ln -sfn "$tmp/$1/mac-autopilot" "$tmp/live"; }
stale() { zf_daemon_stale "$started" "$tmp/live" "${files[@]}"; }

export INVOCATION_ID=test
newdir v2   # the pin moved, every byte is the same
stale && fail 'a pin with identical bytes asked for a restart'
echo 'two' >> "$tmp/v2/conf.sh"
stale || fail 'a changed sourced file did not ask for a restart'
newdir v3; echo 'two' >> "$tmp/v3/mac-autopilot/loop.sh"
stale || fail "a changed own script did not ask for a restart"
newdir v4; rm "$tmp/v4/mac-autopilot/env.sh"
stale || fail 'a sourced file missing on the live side did not ask for a restart'
newdir v5; rm "$tmp/v5/mac-autopilot/loop.sh"; echo 'two' >> "$tmp/v5/conf.sh"
stale && fail 'a restart was asked for with no own script on the live side'
zf_daemon_stale "$started" "$tmp/missing" "${files[@]}" && fail 'an unresolvable live dir asked for a restart'
newdir v6; echo 'two' >> "$tmp/v6/mac-autopilot/loop.sh"
( unset INVOCATION_ID; stale ) && fail 'an unsupervised loop asked for a restart'
grep -q 'zf_daemon_stale "\$HERE" "\$LIVE" bell-loop.sh runtime-env.sh' "$here/bell-loop.sh" || fail 'bell-loop.sh does not use the check'

# A live pin change is picked up after the tick and its refill child finish.
loop="$tmp/loop"; mkdir -p "$loop"/{runner,runtime,supervisor/autopi-live}
cp "$here/loop.sh" "$loop/runner/loop.sh"; cp "$here/loop.sh" "$loop/supervisor/autopi-live/loop.sh"
export TEST_ROOT="$loop"
printf 'MAC_AUTOPILOT_RUNTIME_DIR="%s/runtime"\nMAC_AUTOPILOT_SUPERVISOR_DIR="%s/supervisor"\npid_live() { kill -0 "$1" 2>/dev/null; }\n' "$loop" "$loop" > "$loop/runner/runtime-env.sh"
printf 'exit 0\n' > "$loop/runner/wait-scheduler-lock.sh"
cat > "$loop/supervisor/autopi-live/scheduler.sh" <<'EOF'
if [[ "${1:-}" == --refill ]]; then : > "$TEST_ROOT/refill.started"; until [[ -e "$TEST_ROOT/refill.release" ]]; do command sleep .01; done
else : > "$TEST_ROOT/tick.done"; fi
EOF
cat > "$loop/bash-env" <<'EOF'
sleep() {
  if [[ -e "$TEST_ROOT/tick.done" && ! -e "$TEST_ROOT/idle.release" ]]; then : > "$TEST_ROOT/idle"; until [[ -e "$TEST_ROOT/idle.release" ]]; do command sleep .01; done; fi
  SECONDS=$((SECONDS + ${1:-1}))
}
EOF
printf '{"tick_seconds":30}\n' > "$loop/runtime/config.json"; printf '{"workers":[]}\n' > "$loop/runtime/workers.json"
(
  ulimit -u 4096
  BASH_ENV="$loop/bash-env" AUTOPI_REFILL_SECONDS=5 AUTOPI_REFILL_LIMIT_SECONDS=30 timeout -k 1 8 bash "$loop/runner/loop.sh"
) & loop_pid=$!
for _ in {1..300}; do [[ -e "$loop/idle" ]] && break; sleep .01; done
[[ -e "$loop/idle" ]] || fail 'first tick did not reach the between-tick window'
echo '# pin changed' >> "$loop/supervisor/autopi-live/loop.sh"; touch "$loop/idle.release"
for _ in {1..300}; do [[ -e "$loop/refill.started" || -s "$loop/runtime/scheduler.log" ]] && break; sleep .01; done
held=true; [[ -e "$loop/refill.started" && ! -s "$loop/runtime/scheduler.log" ]] || held=false
touch "$loop/refill.release"; rc=0; wait "$loop_pid" || rc=$?
[[ "$held" == true ]] || fail 'loop exited before its refill child finished'
[[ "$rc" == 0 ]] || fail "loop did not exit 0 after live loop.sh changed (rc=$rc)"
[[ "$(grep -cF 'loop: autopi-live/loop.sh changed since start, exiting for systemd to restart' "$loop/runtime/scheduler.log")" == 1 ]] || fail 'missing or duplicate restart log line'
grep -Eq '^\[[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z\] loop: autopi-live/loop.sh changed since start, exiting for systemd to restart$' "$loop/runtime/scheduler.log" || fail 'restart line lacks an ISO timestamp'
echo "daemon-self-check.test.sh: ok"
