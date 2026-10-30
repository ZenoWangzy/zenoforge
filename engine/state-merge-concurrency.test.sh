#!/usr/bin/env bash
set -euo pipefail
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/." && pwd -P)/test-env.sh"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TEST_REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd -P)"
TEST_ROOT="$test_env_root"
trap 'rm -rf -- "$TEST_ROOT"' EXIT

STATE_HOME="$TEST_ROOT/state-merge-race"
mkdir -p "$STATE_HOME/state"
jq ".roles.advisor.disabled = false" "$SCRIPT_DIR/model-policy.default.json" > "$STATE_HOME/model-policy.json"
printf '%s\n' '{"attempts":0}' > "$STATE_HOME/state/19991.json"

workers=4
updates_per_worker=12
pids=()
for worker in $(seq 1 "$workers"); do
  (
    export AGENT_HOME="$STATE_HOME" ZF_REPO_DIR="$TEST_REPO_DIR" REPO=test/repo
    set -euo pipefail
    source "$SCRIPT_DIR/lib.sh"
    : > "$TEST_ROOT/ready-$worker"
    while [ ! -f "$TEST_ROOT/go" ]; do sleep 0.002; done
    for attempt in $(seq 1 "$updates_per_worker"); do
      state_bump_attempts 19991
    done
  ) > "$TEST_ROOT/worker-$worker.out" 2> "$TEST_ROOT/worker-$worker.err" &
  pids+=("$!")
done

ready=0
for _ in $(seq 1 1000); do
  ready=0
  for worker in $(seq 1 "$workers"); do
    [ ! -f "$TEST_ROOT/ready-$worker" ] || ready=$((ready + 1))
  done
  [ "$ready" -eq "$workers" ] && break
  sleep 0.01
done
: > "$TEST_ROOT/go"

worker_failures=0
for pid in "${pids[@]}"; do
  if wait "$pid"; then :; else worker_failures=$((worker_failures + 1)); fi
done

expected=$((workers * updates_per_worker))
actual="$(jq -r '.attempts // "invalid"' "$STATE_HOME/state/19991.json" 2>/dev/null || echo invalid)"
if [ "$ready" -eq "$workers" ] && [ "$worker_failures" -eq 0 ] && [ "$actual" = "$expected" ]; then
  echo "ok - concurrent state_merge calls retain all $expected updates"
else
  echo "not ok - concurrent state_merge calls (ready=$ready/$workers worker_failures=$worker_failures expected=$expected actual=$actual)"
  grep -nE 'mv:|parse error|state_merge: jq failed' "$TEST_ROOT"/worker-*.err || true
  exit 1
fi
