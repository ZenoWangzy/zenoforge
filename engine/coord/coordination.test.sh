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
sim_effect_death_trial() {
  local kind="$1" claim="$2" effect_key="$3" expected="$4" ready
  ready="$SIM_WORLD/$kind-effect.ready"
  local worker gh_pid claim_record rc sink
  rm -f -- "$ready" "$SIM_WORLD/$kind-effect.release"
  SIM_PAUSE_READY="$ready" SIM_PAUSE_RELEASE="$SIM_WORLD/$kind-effect.release" \
    sim_as A -- "$SIM_HARNESS_DIR/worker.sh" effect "$claim" "$effect_key" "$kind" \
    >"$SIM_WORLD/$kind-effect.out" 2>&1 &
  worker=$!
  sim_worker_pids+=("$worker")
  if ! sim_wait_for "$ready"; then
    kill "$worker" 2>/dev/null || :
    sim_wait_worker "$worker" || :
    fail "$kind effect did not reach its external request"
  fi
  gh_pid="$(<"$ready")"
  [[ "$gh_pid" =~ ^[0-9]+$ ]] || fail "$kind effect pause recorded no process id"
  sim_worker_pids+=("$gh_pid")
  kill -KILL "$worker" "$gh_pid" 2>/dev/null || :
  if sim_wait_worker "$worker"; then fail "$kind effect worker survived its death point"; fi
  sim_untrack_worker "$gh_pid"
  sim_world_advance "$((SIM_LEASE_S + 1))"
  if sim_as B -- "$SIM_HARNESS_DIR/worker.sh" effect-takeover "$claim" >"$SIM_WORLD/$kind-observe.out" 2>&1; then
    fail "$kind effect claim was taken over before a full observation lease"
  else
    rc=$?
    [[ "$rc" == 1 ]] || fail "$kind effect first observation returned $rc instead of held"
  fi
  sim_world_advance "$((SIM_LEASE_S / 2))"
  if sim_as B -- "$SIM_HARNESS_DIR/worker.sh" effect-takeover "$claim" >"$SIM_WORLD/$kind-observe-half.out" 2>&1; then
    fail "$kind effect claim was taken over before a full observation lease"
  else
    rc=$?
    [[ "$rc" == 1 ]] || fail "$kind effect half-lease observation returned $rc instead of held"
  fi
  sim_world_advance "$((SIM_LEASE_S - SIM_LEASE_S / 2))"
  sim_as B -- "$SIM_HARNESS_DIR/worker.sh" effect-takeover "$claim" \
    >"$SIM_WORLD/$kind-reconcile.out" 2>&1 || fail "$kind effect reconciliation failed: $(cat "$SIM_WORLD/$kind-reconcile.out")"
  claim_record="$("$SIM_REAL_GIT" --git-dir="$SIM_REMOTE" cat-file blob "refs/claims/$claim:claim.json")"
  jq -e --arg key "$effect_key" --arg state "$expected" '.intents[$key].state == $state' <<<"$claim_record" >/dev/null \
    || fail "$kind effect ended in an unexpected state: $claim_record"
  sink="$SIM_WORLD/sinks/$kind.log"
  [[ "$(wc -l <"$sink")" -eq 1 ]] || fail "$kind external request was duplicated or missing"
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
status_a="$("$SIM_REAL_GIT" --git-dir="$SIM_REMOTE" cat-file blob refs/status/A:worker.json)"
status_b="$("$SIM_REAL_GIT" --git-dir="$SIM_REMOTE" cat-file blob refs/status/B:worker.json)"
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

sim_effect_death_trial merge issue-71 merge:pr-31 done
sim_effect_death_trial deploy issue-72 deploy:7 done
sim_effect_death_trial mail issue-73 mail:73:1 unknown
[[ -s $SIM_WORLD/gh.log ]] || fail 'effect trials did not call the fake GitHub boundary'

sim_world_new "$test_env_root/coord-renewd-sim"
sim_host_new A
sim_host_new B

death_ready="$SIM_WORLD/coord-death-ready"
death_release="$SIM_WORLD/coord-death-release"
SIM_HOLD_READY="$death_ready" SIM_HOLD_RELEASE="$death_release" \
  sim_as A -- "$SIM_HARNESS_DIR/worker.sh" coord-hold 10 feeder >"$SIM_WORLD/A-coord-death.out" 2>&1 &
death_worker=$!
sim_worker_pids+=("$death_worker")
if ! sim_wait_for "$death_ready"; then
  sim_wait_worker "$death_worker" || :
  fail 'host A did not establish the production claim before death'
fi
death_pid="$(<"$death_ready")"
[[ $death_pid =~ ^[0-9]+$ ]] || fail "production claim holder recorded no pid: $death_pid"
sim_worker_pids+=("$death_pid")
kill -KILL "$death_worker" "$death_pid" 2>/dev/null || :
if sim_wait_worker "$death_worker"; then fail 'production claim holder exited before it was killed'; fi
sim_untrack_worker "$death_pid"
sim_as A -- "$SIM_HARNESS_DIR/worker.sh" renewd >"$SIM_WORLD/A-renewd-death-first.out" 2>&1 \
  || fail "renewd failed to observe a dead harness run: $(cat "$SIM_WORLD/A-renewd-death-first.out")"
sim_world_advance 300
sim_as A -- "$SIM_HARNESS_DIR/worker.sh" renewd >"$SIM_WORLD/A-renewd-death-release.out" 2>&1 \
  || fail "renewd failed to release a dead harness run: $(cat "$SIM_WORLD/A-renewd-death-release.out")"
dead_claim="$("$SIM_REAL_GIT" --git-dir="$SIM_REMOTE" cat-file blob refs/claims/issue-10:claim.json)"
jq -e '.owner == null and .release_reason == "run-gone"' <<<"$dead_claim" >/dev/null \
  || fail "renewd left a dead harness claim owned: $dead_claim"
sim_as B -- "$SIM_HARNESS_DIR/worker.sh" coord-acquire 10 feeder >"$SIM_WORLD/B-coord-takeover.out" 2>&1 \
  || fail "host B could not acquire the released production claim: $(cat "$SIM_WORLD/B-coord-takeover.out")"
takeover_claim="$("$SIM_REAL_GIT" --git-dir="$SIM_REMOTE" cat-file blob refs/claims/issue-10:claim.json)"
jq -e '.generation == 2 and .owner_kind == "feeder"' <<<"$takeover_claim" >/dev/null \
  || fail "renewd death trial did not leave a second-generation takeover: $takeover_claim"

fence_ready="$SIM_WORLD/coord-fence-ready"
fence_release="$SIM_WORLD/coord-fence-release"
SIM_HOLD_READY="$fence_ready" SIM_HOLD_RELEASE="$fence_release" \
  sim_as A -- "$SIM_HARNESS_DIR/worker.sh" coord-hold 11 feeder >"$SIM_WORLD/A-coord-fence.out" 2>&1 &
fence_worker=$!
sim_worker_pids+=("$fence_worker")
if ! sim_wait_for "$fence_ready"; then
  sim_wait_worker "$fence_worker" || :
  fail 'host A did not establish the self-fence claim'
fi
fence_pid="$(<"$fence_ready")"
[[ $fence_pid =~ ^[0-9]+$ ]] || fail "self-fence holder recorded no pid: $fence_pid"
sim_worker_pids+=("$fence_pid")
sim_world_advance 600
sim_as A -- "$SIM_HARNESS_DIR/worker.sh" renewd >"$SIM_WORLD/A-renewd-fence.out" 2>&1 \
  || fail "renewd failed during the self-fence trial: $(cat "$SIM_WORLD/A-renewd-fence.out")"
if sim_wait_worker "$fence_worker"; then fail 'renewd did not stop the stale harness run'; fi
sim_untrack_worker "$fence_pid"
if kill -0 "$fence_pid" 2>/dev/null; then fail 'self-fence left the harness run alive'; fi
jq -e '.lost == true and .owner_kind == "feeder"' "$SIM_WORLD/hosts/A/coord/held/issue-11" >/dev/null \
  || fail 'self-fence did not mark the local claim lost'

ack_ready="$SIM_WORLD/coord-ack-ready"
ack_release="$SIM_WORLD/coord-ack-release"
SIM_HOLD_READY="$ack_ready" SIM_HOLD_RELEASE="$ack_release" \
  sim_as A -- "$SIM_HARNESS_DIR/worker.sh" coord-hold 12 feeder >"$SIM_WORLD/A-coord-ack.out" 2>&1 &
ack_worker=$!
sim_worker_pids+=("$ack_worker")
if ! sim_wait_for "$ack_ready"; then
  sim_wait_worker "$ack_worker" || :
  fail 'host A did not establish the lost-ack claim'
fi
ack_pid="$(<"$ack_ready")"
[[ $ack_pid =~ ^[0-9]+$ ]] || fail "lost-ack holder recorded no pid: $ack_pid"
sim_worker_pids+=("$ack_pid")
pushes_before="$(awk '$1 == "A" && $2 == "push" { count++ } END { print count+0 }' "$SIM_WORLD/git.log")"
SIM_LOST_ACK=1 sim_as A -- "$SIM_HARNESS_DIR/worker.sh" renewd >"$SIM_WORLD/A-renewd-lost-ack.out" 2>&1 \
  || fail "renewd did not resolve a lost push acknowledgement: $(cat "$SIM_WORLD/A-renewd-lost-ack.out")"
pushes_after="$(awk '$1 == "A" && $2 == "push" { count++ } END { print count+0 }' "$SIM_WORLD/git.log")"
[[ $((pushes_after - pushes_before)) -eq 1 ]] || fail 'lost-ack pass did not use exactly one batched push'
ack_claim="$("$SIM_REAL_GIT" --git-dir="$SIM_REMOTE" cat-file blob refs/claims/issue-12:claim.json)"
jq -e --argjson now "$(<"$SIM_CLOCK_FILE")" '.renewed_at == $now and .owner_kind == "feeder"' <<<"$ack_claim" >/dev/null \
  || fail "lost-ack pass did not retain its renewed claim: $ack_claim"
ack_status="$("$SIM_REAL_GIT" --git-dir="$SIM_REMOTE" cat-file blob refs/status/A:worker.json)"
jq -e '.host == "A" and .instance == "A-instance"' <<<"$ack_status" >/dev/null \
  || fail 'lost-ack pass did not publish host status'
: >"$ack_release"
sim_wait_worker "$ack_worker" || fail 'lost-ack holder did not release after the trial'
sim_untrack_worker "$ack_pid"

[[ ! -s $SIM_WORLD/gh.log ]] || fail "first-version cases unexpectedly called gh: $(cat "$SIM_WORLD/gh.log")"

printf 'coordination.test.sh: PASS (race, status, plain death, renewd death and takeover, self-fence, lost-ack, hold ends when its release path vanishes)\n'
