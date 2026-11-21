#!/usr/bin/env bash
set -euo pipefail
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)/test-env.sh"

engine="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
source "$engine/coord/sim/lib.sh"
sim_worker_pids=()
fail() { printf 'coordination.test.sh: %s\n' "$*" >&2; exit 1; }
sim_cleanup_workers() {
  local pid
  for pid in "${sim_worker_pids[@]}"; do
    kill "$pid" 2>/dev/null || :
    wait "$pid" 2>/dev/null || :
  done
}
sim_untrack_worker() {
  local target="$1" pid
  local -a keep=()
  for pid in "${sim_worker_pids[@]}"; do
    [[ $pid == "$target" ]] || keep+=("$pid")
  done
  sim_worker_pids=("${keep[@]}")
}
sim_wait_worker() {
  local pid="$1" rc
  if wait "$pid"; then rc=0; else rc=$?; fi
  sim_untrack_worker "$pid"
  return "$rc"
}
trap 'sim_cleanup_workers; test_env_chain_exit "$test_env_root" "$test_env_prior_exit"' EXIT

sim_world_new "$test_env_root/coord-sim"
sim_host_new A
sim_host_new B

# Both hosts observe the empty claim ref before either can attempt its compare-and-swap push.
race_dir="$SIM_WORLD/race"
mkdir -p "$race_dir"
SIM_RACE_DIR="$race_dir" sim_as A -- "$SIM_HARNESS_DIR/worker.sh" dispatch issue-7 implement > "$SIM_WORLD/A-race.out" 2>&1 &
worker_a=$!
sim_worker_pids+=("$worker_a")
SIM_RACE_DIR="$race_dir" sim_as B -- "$SIM_HARNESS_DIR/worker.sh" dispatch issue-7 implement > "$SIM_WORLD/B-race.out" 2>&1 &
worker_b=$!
sim_worker_pids+=("$worker_b")
if ! sim_wait_for "$race_dir/A.ready" || ! sim_wait_for "$race_dir/B.ready"; then
  : > "$race_dir/go"
  sim_wait_worker "$worker_a" || :
  sim_wait_worker "$worker_b" || :
  fail 'both hosts did not reach the race barrier'
fi
: > "$race_dir/go"
race_rc=0
sim_wait_worker "$worker_a" || race_rc=1
sim_wait_worker "$worker_b" || race_rc=1
(( race_rc == 0 )) || fail 'a race worker failed'
race_claim="$("$SIM_REAL_GIT" --git-dir="$SIM_REMOTE" cat-file blob refs/claims/issue-7)"
[[ $(awk '$1 == "issue-7" { count++ } END { print count+0 }' "$SIM_WORLD/dispatch.log") -eq 1 ]] \
  || fail 'race did not produce exactly one winner'
race_owner="$(jq -r '.owner' <<< "$race_claim")"
[[ $race_owner == A || $race_owner == B ]] || fail "race left unexpected owner: $race_owner"
[[ $(awk -v owner="$race_owner" '$1 == "issue-7" && $3 == owner { count++ } END { print count+0 }' \
  "$SIM_WORLD/dispatch.log") -eq 1 ]] || fail 'race winner does not match the claim owner'

# Each host publishes the existing status_record shape to its own status ref.
sim_as A -- "$SIM_HARNESS_DIR/worker.sh" status > "$SIM_WORLD/A-status.out" 2>&1 &
worker_a=$!
sim_worker_pids+=("$worker_a")
sim_as B -- "$SIM_HARNESS_DIR/worker.sh" status > "$SIM_WORLD/B-status.out" 2>&1 &
worker_b=$!
sim_worker_pids+=("$worker_b")
status_rc=0
sim_wait_worker "$worker_a" || status_rc=1
sim_wait_worker "$worker_b" || status_rc=1
(( status_rc == 0 )) || fail 'a status worker failed'
status_a="$("$SIM_REAL_GIT" --git-dir="$SIM_REMOTE" cat-file blob refs/status/A)"
status_b="$("$SIM_REAL_GIT" --git-dir="$SIM_REMOTE" cat-file blob refs/status/B)"
jq -e '.proto == 1 and .host == "A" and .instance == "A-instance"' <<< "$status_a" >/dev/null \
  || fail "host A status record is invalid: $status_a"
jq -e '.proto == 1 and .host == "B" and .instance == "B-instance"' <<< "$status_b" >/dev/null \
  || fail "host B status record is invalid: $status_b"
[[ $(awk '$1 == "refs/status/A" { count++ } END { print count+0 }' "$SIM_WORLD/refs.log") -eq 1 ]] \
  || fail 'bare remote did not log host A status'
[[ $(awk '$1 == "refs/status/B" { count++ } END { print count+0 }' "$SIM_WORLD/refs.log") -eq 1 ]] \
  || fail 'bare remote did not log host B status'

# Kill a worker after it claims work but before dispatch; after expiry, the peer takes over by CAS.
hold_ready="$SIM_WORLD/held-A"
hold_release="$SIM_WORLD/release-A"
SIM_HOLD_READY="$hold_ready" SIM_HOLD_RELEASE="$hold_release" \
  sim_as A -- "$SIM_HARNESS_DIR/worker.sh" hold issue-8 implement > "$SIM_WORLD/A-hold.out" 2>&1 &
dead_worker=$!
sim_worker_pids+=("$dead_worker")
if ! sim_wait_for "$hold_ready"; then
  kill "$dead_worker" 2>/dev/null || :
  sim_wait_worker "$dead_worker" || :
  fail 'host A did not establish the claim before death'
fi
# $! is only sim_as's wrapper shell; the ready file carries the pid of the process really looping in the hold.
hold_pid="$(<"$hold_ready")"
[[ $hold_pid =~ ^[0-9]+$ ]] || fail "hold ready file held no pid: $hold_pid"
sim_worker_pids+=("$hold_pid")
kill -KILL "$dead_worker" "$hold_pid" 2>/dev/null || :
hold_gone=0
for ((hold_poll = 0; hold_poll < 200; hold_poll++)); do
  kill -0 "$hold_pid" 2>/dev/null || { hold_gone=1; break; }
  sleep 0.01
done
(( hold_gone == 1 )) || fail 'killing the hold worker left its real process alive past the wrapper'
if sim_wait_worker "$dead_worker"; then fail 'plain-death worker exited before it was killed'; fi
sim_world_advance "$((SIM_LEASE_S + 1))"
sim_as B -- "$SIM_HARNESS_DIR/worker.sh" takeover issue-8 implement > "$SIM_WORLD/B-takeover.out" 2>&1 \
  || fail "host B failed to take over after expiry: $(cat "$SIM_WORLD/B-takeover.out")"
takeover_claim="$("$SIM_REAL_GIT" --git-dir="$SIM_REMOTE" cat-file blob refs/claims/issue-8)"
jq -e '.owner == "B" and .generation == 2 and .ticket == "issue-8"' <<< "$takeover_claim" >/dev/null \
  || fail "takeover claim is invalid: $takeover_claim"
[[ $(awk '$1 == "issue-8" { count++ } END { print count+0 }' "$SIM_WORLD/dispatch.log") -eq 1 ]] \
  || fail 'takeover did not dispatch exactly once'
[[ $(awk '$1 == "refs/claims/issue-8" { count++ } END { print count+0 }' "$SIM_WORLD/refs.log") -eq 2 ]] \
  || fail 'bare remote did not log the initial claim and takeover update'

# A hold whose release directory disappears ends by itself instead of looping for ever (11-21: an orphaned
# hold looped at 50 wakes/s for 18 h after its test directory was deleted).
gone_release_dir="$SIM_WORLD/vanished"
mkdir -p "$gone_release_dir"
gone_ready="$SIM_WORLD/held-gone"
SIM_HOLD_READY="$gone_ready" SIM_HOLD_RELEASE="$gone_release_dir/release" \
  sim_as A -- "$SIM_HARNESS_DIR/worker.sh" hold issue-9 implement > "$SIM_WORLD/A-hold-gone.out" 2>&1 &
gone_worker=$!
sim_worker_pids+=("$gone_worker")
if ! sim_wait_for "$gone_ready"; then
  sim_wait_worker "$gone_worker" || :
  fail 'host A did not reach the hold loop before its release directory vanished'
fi
gone_pid="$(<"$gone_ready")"
sim_worker_pids+=("$gone_pid")
rm -rf -- "$gone_release_dir"
gone_ended=0
for ((gone_poll = 0; gone_poll < 200; gone_poll++)); do
  kill -0 "$gone_pid" 2>/dev/null || { gone_ended=1; break; }
  sleep 0.01
done
(( gone_ended == 1 )) || fail 'hold did not end within 2 s of losing its release directory'
if sim_wait_worker "$gone_worker"; then fail 'hold ended with rc=0 after losing its release directory'; fi

[[ ! -s $SIM_WORLD/gh.log ]] || fail "first-version cases unexpectedly called gh: $(cat "$SIM_WORLD/gh.log")"

printf 'coordination.test.sh: PASS (race, status, plain death with takeover, hold ends when its release path vanishes)\n'
