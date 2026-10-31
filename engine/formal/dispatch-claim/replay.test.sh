#!/usr/bin/env bash
# Replays the TLC counterexamples against the REAL dispatch() and claim code (issue #4785).
# Prints one RESULT line per guard. FORMAL_AGENT_DIR points at the engine tree to replay (default: this checkout).
set -euo pipefail
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd -P)/test-env.sh"
set +e  # scheduler.sh and coord.sh run without errexit (coord_acquire reads with a non-zero status)
AGENT_DIR="${FORMAL_AGENT_DIR:-$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd -P)}"
T="$(mktemp -d)"
cleanup() {
  local p
  for p in $(jq -r ".workers[].pid" "$T/workers.json" || :); do kill "$p" || :; done
  rm -rf "$T"
}
trap cleanup EXIT
export AGENT_HOME="$T/home"; mkdir -p "$AGENT_HOME" "$T/sup"
UNITS="$T/units.json"; WORKERS="$T/workers.json"; LOG="$T/log"; SUP="$T/sup"; ROOT="$T"; STAMP=replay; GH_PRS="$T/gh-prs.json"
SD="$AGENT_DIR/mac-autopilot/scheduler.d"
echo '{"units":[{"id":"issue-99","issue":99,"lane":"direct-main","stage":"implement-pending"}]}' > "$UNITS"
echo '{"workers":[]}' > "$WORKERS"; echo '[]' > "$GH_PRS"
source "$AGENT_DIR/coord.sh"
fn() { sed -n "/^$2() {/,/^}/p" "$SD/$1"; }  # the real function text, nothing else from the file
source <(fn core.sh jqf); source <(fn units.sh unit_field)
source <(fn harvest-workers.sh coord_scheduler_live_worker); source <(fn dispatch.sh dispatch)
# Stubs for what dispatch() needs around the claim: the worker command, the GitHub census, state writes, liveness.
build_codex_command() { CODEX_COMMAND=(sleep 300); CODEX_MODE=fresh; CODEX_PATH_REASON=replay; CODEX_SESSION_ID=""; CODEX_USAGE_START=0; }
tick_prs() { cat "$GH_PRS"; }
write_state() { local t; t="$(mktemp "$1.tmp.XXXXXX")"; cat > "$t"; mv "$t" "$1"; }
alive() { kill -0 "$1" 2>/dev/null; }
stuck_worker_stop() { kill "$1" 2>/dev/null; }
WORKER_STDOUT_REPORT=0; LIVE_WORKER_CACHE_UNTIL=0; declare -A LIVE_WORKER_CACHE_TYPES

launches() { jq '.workers|length' "$WORKERS"; }
try() { # refill? -> HELD / LAUNCHED
  local before; before="$(launches)"
  TICK_DISPATCH_LOCAL_REFILL="$1" dispatch implement m e issue-99 w.log w.md prompt >/dev/null 2>&1 || :
  (( $(launches) > before )) && echo LAUNCHED || echo HELD
}
result() { echo "RESULT $1: $2"; }

# Trace steps (refill-gap.cfg): refill launches w1, w1 opens a PR and dies without a report, the claim is released, a tick dispatches again.
[[ "$(try true)" == LAUNCHED ]] || { echo "replay setup failed: first dispatch held"; exit 2; }              # Snap/Check/Claim/Launch(refill)
result live-worker-guard "$(try false)"                                                                       # second tick while w1 lives
w1="$(jq -r '.workers[0]' "$WORKERS")"
pid1="$(jq -r .pid <<<"$w1")"; kill "$pid1"                                                                                                  # Crash(w1) ...
wait "$pid1" 2>/dev/null || :
echo '[{"number":501,"title":"fix #99","body":"","headRefName":"agent/issue-99"}]' > "$GH_PRS"               # ... after OpenPR(w1)
jq '.workers[0].harvested=true' "$WORKERS" | write_state "$WORKERS"
coord_release "$(jq -r .claim_key <<<"$w1")" "$(jq -r .claim_owner <<<"$w1")"                                 # harvest releases the claim
result slow-pr-guard "$(try false)"                                                                           # slow tick, PR open
result refill-pr-guard "$(try true)"                                                                          # refill tick, PR open
# Claim guard alone: nothing live, no PR, but another owner holds the ticket's claim.
w2="$(jq -r '.workers[1]' "$WORKERS")"; kill "$(jq -r .pid <<<"$w2")"
coord_release "$(jq -r .claim_key <<<"$w2")" "$(jq -r .claim_owner <<<"$w2")"
echo '[]' > "$GH_PRS"; echo '{"workers":[]}' > "$WORKERS"
coord_acquire issue-99 other-owner scheduler-worker 99 other implement
result claim-guard "$(try true)"
# Pretty-printed workers.json (jq default output): the live-worker loop must read one compact worker per line.
sleep 60 & live_pid=$!
jq -n --argjson pid "$live_pid" '{workers:[{unit:"issue-98",issue:98,type:"implement",pid:$pid}]}' > "$WORKERS"
: > "$LOG"
live98="$(coord_scheduler_live_worker issue-98 "" && echo LIVE || echo IDLE)"
result coord-live-worker-pretty "$live98"
[[ "$live98" == LIVE ]] || { echo "coord_scheduler_live_worker missed a live worker in pretty-printed workers.json" >&2; exit 1; }
! grep -Fq 'jqf error' "$LOG" || { echo "coord_scheduler_live_worker logged a jqf error" >&2; exit 1; }
