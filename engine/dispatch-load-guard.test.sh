#!/usr/bin/env bash
set -euo pipefail
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/." && pwd -P)/test-env.sh"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/dispatch-load-guard.sh"

assert_status() {
  local expected="$1" actual=0
  shift
  dispatch_load_exceeded "$@" || actual=$?
  if [ "$actual" -ne "$expected" ]; then
    echo "not ok - dispatch_load_exceeded $* (expected $expected, got $actual)"
    exit 1
  fi
  echo "ok - dispatch_load_exceeded $* -> $actual"
}

assert_status 1 0.25 1
assert_status 1 18 9
assert_status 0 18.01 9
assert_status 1 27 9 3
assert_status 0 27.01 9 3
AGENT_DISPATCH_LOAD_LIMIT_MULTIPLIER=3 assert_status 1 27 9
AGENT_DISPATCH_LOAD_LIMIT_MULTIPLIER=3 assert_status 0 27.01 9
AGENT_DISPATCH_LOAD_LIMIT_MULTIPLIER=invalid assert_status 2 1 9
assert_status 1 17.99 9 2 1
assert_status 0 18 9 2 1
assert_status 0 18.01 9 2 1
assert_status 2 invalid 9
assert_status 2 1 0
assert_status 2 18 9 0 1
assert_status 2 18 9 2 invalid

[[ "$(hand_dispatch_worker_priority hotfix)" == hotfix ]] || { echo 'not ok - hotfix tier reaches luna/zc as hotfix' >&2; exit 1; }
[[ "$(hand_dispatch_worker_priority optimization)" == opt ]] || { echo 'not ok - optimization tier reaches luna/zc as opt' >&2; exit 1; }
[[ "$(hand_dispatch_worker_priority general)" == normal ]] || { echo 'not ok - general tier reaches luna/zc as normal' >&2; exit 1; }

# Implement admission is memory only (ruling crash-guard-is-memory-not-load, 2026-10-08).
if sed -n '/^agent_implement_dispatch_resources_allow() {/,/^}/p' "$SCRIPT_DIR/lib.d/dispatch-gates.sh" | grep -q 'dispatch_load_exceeded'; then
  echo 'not ok - implement admission must not refuse on CPU load'
  exit 1
fi

# Host capacity.env beats a multiplier inherited from the credentials env (2026-10-06 FIFO head-of-line wait).
capacity_home="$(mktemp -d)"
printf 'AGENT_DISPATCH_LOAD_LIMIT_MULTIPLIER=4\n' > "$capacity_home/capacity.env"
[ "$(AGENT_HOME="$capacity_home" AGENT_DISPATCH_LOAD_LIMIT_MULTIPLIER=2 bash -c 'source "$1/lib.sh" >/dev/null 2>&1; echo "$AGENT_DISPATCH_LOAD_LIMIT_MULTIPLIER"' _ "$SCRIPT_DIR")" = 4 ] || {
  echo 'not ok - lib.sh must let AGENT_HOME/capacity.env override the inherited load multiplier'
  exit 1
}
rm -f "$capacity_home/capacity.env"
[ "$(AGENT_HOME="$capacity_home" AGENT_DISPATCH_LOAD_LIMIT_MULTIPLIER=2 bash -c 'source "$1/lib.sh" >/dev/null 2>&1; echo "$AGENT_DISPATCH_LOAD_LIMIT_MULTIPLIER"' _ "$SCRIPT_DIR")" = 2 ] || {
  echo 'not ok - without capacity.env the inherited multiplier stays'
  exit 1
}
rm -rf -- "$capacity_home"
echo 'ok - host capacity.env overrides the inherited load multiplier'
