#!/usr/bin/env bash
# End-to-end (fakes) of the hand-agent exit and handoff chain: exited agents
# resume only when their blocked or unfinished work becomes actionable.
# A hand that exits while holding a local CI lease must not deadlock the next
# acquirer.
set -euo pipefail
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)/test-env.sh"

NIGHT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
SOURCE_REPO="$(cd -- "$NIGHT_DIR/../.." && pwd -P)"
export ZF_REPO=test/repo ZF_GH_REPO=test/repo AGENT_DRY_RUN=0
export ZF_WORKTREE_ROOT="$test_env_root/worktrees"
source "$SOURCE_REPO/engine/lib.sh"
REPO=test/repo
H="$AGENT_HOME"
NIGHT="$AGENT_HOME/night"
REPO_DIR="$test_env_root/repo"
WORKTREE_ROOT="$ZF_WORKTREE_ROOT"
LOG="$test_env_root/tick.log"
CALLS="$test_env_root/dispatch-calls"
SPAWNED="$test_env_root/spawned-pids"
export NIGHT CALLS SPAWNED
mkdir -p "$NIGHT" "$WORKTREE_ROOT" "$REPO_DIR/engine/night" "$AGENT_HOME/land-queue/requests"
git init -q -b main "$REPO_DIR"
git -C "$REPO_DIR" config user.name fixture
git -C "$REPO_DIR" config user.email fixture@example.invalid
git -C "$REPO_DIR" commit --allow-empty -qm base
: > "$CALLS"; : > "$SPAWNED"; : > "$NIGHT/agents.txt"
HAND_LAND_FINISH_LOG="$NIGHT/land-finish.log"
export HAND_LAND_FINISH_LOG
mkdir -p "$AGENT_HOME/checkout/engine"
cat > "$AGENT_HOME/checkout/engine/land-queue.sh" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$HAND_LAND_FINISH_LOG"
STUB
chmod +x "$AGENT_HOME/checkout/engine/land-queue.sh"
cleanup_spawned() {
  local pid
  while IFS= read -r pid; do kill "$pid" 2>/dev/null || true; done < "$SPAWNED"
}
trap cleanup_spawned EXIT

source "$NIGHT_DIR/hand-agent-watchdog.sh"
source "$NIGHT_DIR/hand-exit-handoff.sh"
BLOCKED_HAND_AGENTS="$NIGHT/blocked-hand-agents.json"

fail() { printf 'not ok - %s\n' "$*" >&2; printf -- '--- tick log\n' >&2; cat "$LOG" >&2 2>/dev/null || true; exit 1; }
ok() { printf 'ok - %s\n' "$*"; }
say() { printf '%s\n' "$*" >> "$LOG"; }
hand_agent_role_is_supported() { case "$1" in work|hand-zcode|production) return 0 ;; esac; return 1; }
hand_agent_role_for_identity() { printf 'work\n'; }

# ---- fakes: GitHub issue state and the hand dispatcher.
cat > "$test_env_bin/gh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
cmd="${1:-}:${2:-}"; shift 2 || true
case "$cmd" in
  issue:view) printf 'CLOSED\n' ;;
esac
EOF
chmod +x "$test_env_bin/gh"
# The dispatcher records the call and starts a live stand-in agent, recording
# it in the registry exactly as night/dispatch.sh does.
cat > "$REPO_DIR/engine/night/dispatch.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
WT="$1" BRIEF="$2" NAME="$3" ROLE="$4" REPORT="$5" ATTEMPT="$6" NOTE="${7:-}"
printf '%s\t%s\t%s\n' "$NAME" "$WT" "$NOTE" >> "$CALLS"
setsid sleep 600 >/dev/null 2>&1 < /dev/null &
pid=$!
printf '%s\n' "$pid" >> "$SPAWNED"
ticks="$(awk '{print $22}' "/proc/$pid/stat")"
source "$HAND_EXIT_HANDOFF_MODULE"
entry="$(jq -c --argjson pid "$pid" --arg ticks "$ticks" --argjson attempt "$ATTEMPT" \
  '.pid = $pid | .start_ticks = $ticks | .attempt = $attempt | del(.exit_head, .exit_dirty, .exit_at)' \
  "$NIGHT/hand-registry/$NAME.json")"
hand_registry_record "$NAME" "$entry"
EOF
chmod +x "$REPO_DIR/engine/night/dispatch.sh"
export HAND_EXIT_HANDOFF_MODULE="$NIGHT_DIR/hand-exit-handoff.sh"
cp "$SOURCE_REPO/engine/model-policy.default.json" "$REPO_DIR/engine/model-policy.default.json"

# ---- fixtures
make_worktree() {
  local name="$1" wt="$WORKTREE_ROOT/$1"
  git -C "$REPO_DIR" worktree add -q -b "fix/$name" "$wt" HEAD
  printf 'tracked\n' > "$wt/file.txt"
  git -C "$wt" add file.txt
  git -C "$wt" -c user.name=t -c user.email=t@example.invalid commit -q -m work
  printf '%s\n' "$wt"
}
dead_pid() { bash -c 'exit 0' & local pid=$!; wait "$pid"; printf '%s\n' "$pid"; }
# exited_hand <name> <report-first-line>: a hand agent dispatched, then exited
# (the roster row is gone; the registry record and the exit stamp remain).
exited_hand() {
  local name="$1" status="$2" wt pid
  wt="$(make_worktree "$name")"
  pid="$(dead_pid)"
  printf '%s\nfixture report body\n' "$status" > "$NIGHT/$name.report"
  printf 'brief for %s\n' "$name" > "$NIGHT/$name.brief.md"
  hand_registry_record "$name" "$(jq -cn --arg name "$name" --argjson pid "$pid" --arg wt "$wt" \
    --arg report "$NIGHT/$name.report" --arg brief "$NIGHT/$name.brief.md" --arg branch "fix/$name" \
    '{name:$name,pid:$pid,start_ticks:"1",role:"work",model:"m",effort:"e",worktree:$wt,brief:$brief,report:$report,log:"",attempt:1,branch:$branch,owned_issues:"",owned_nodes:""}')"
  hand_registry_record_exit "$wt" "$pid"
}
# The exit watcher stamps the tree as the agent left it.
restamp_exit() { hand_registry_record_exit "$WORKTREE_ROOT/$1" "$(jq -r .pid "$NIGHT/hand-registry/$1.json")"; }
# One handoff pass: capture exits, sweep handoff state, then redispatch eligible hands.
run_handoff() {
  capture_blocked_hand_agents
  hand_exit_handoff_sweep
  redispatch_landed_blocked_hand_agents
}
count() { grep -c -- "$2" "$1" 2>/dev/null || true; }
assert_no_ownerless() {
  local left
  left="$(hand_exit_handoff_ownerless)"
  [ -z "$left" ] || fail "$1: exited owners without an owner after the tick: $left"
}

grep -Fq 'hand_registry_record "$NAME"' "$NIGHT_DIR/dispatch.sh" || fail 'dispatch.sh records the durable hand registry'
grep -Fq 'hand_registry_record_exit' "$SOURCE_REPO/engine/worktree-lifecycle.sh" || fail 'exit watcher stamps the exit state'
ok 'chain wiring: hand registry writers and exit watcher'

# Deferred fast-lane conclusions are retried by the act-mode hand-exit sweep.
deferred_land_ticket=00000000000000009100
jq -n '{ticket:"00000000000000009100",owner:"hand-deferred-close",state:"landed",post_land_conclusion_pending:true,post_land_conclusion_deferred:true}' \
  > "$AGENT_HOME/land-queue/requests/$deferred_land_ticket.json"
exited_hand hand-deferred-close 'STATUS: DONE'
hand_exit_handoff_sweep
grep -Fqx 'finish-deferred-owner hand-deferred-close' "$HAND_LAND_FINISH_LOG" \
  || fail 'hand exit did not finish deferred direct-main conclusions'
ok 'hand exit routes deferred direct-main conclusions to land-queue'

# ---- 1. BLOCKED-ON landing-failed after the owner exited -> resumed once.
exited_hand hand-landing 'STATUS: DONE'
landing_ticket=00000000000000009005
printf 'STATUS: BLOCKED-ON landing-failed %s\n\nLANDING-FAILED %s preflight red: lib.test.sh\n' "$landing_ticket" "$landing_ticket" > "$NIGHT/hand-landing.report"
jq -n --arg t "$landing_ticket" --arg wt "$WORKTREE_ROOT/hand-landing" --arg report "$NIGHT/hand-landing.report" \
  '{ticket:$t,owner:"hand-landing",worktree:$wt,report:$report,state:"failed",reason:"preflight red: lib.test.sh",lesson_metadata_fix_forward:{sha:"0123456789abcdef0123456789abcdef01234567",fields:"candidate=V488; recurrence_difference missing",state:"queued",owner_queued:true}}' \
  > "$AGENT_HOME/land-queue/requests/$landing_ticket.json"
# ---- 4. exited with the fix uncommitted -> resumed once with "commit and re-land".
exited_hand hand-uncommitted 'STATUS: DONE'
printf 'the fix\n' >> "$WORKTREE_ROOT/hand-uncommitted/file.txt"
restamp_exit hand-uncommitted
# ---- 4b. uncommitted, but its landing is still queued -> the land queue owns it.
exited_hand hand-landing-queued 'STATUS: LANDING-QUEUED'
printf 'mid-rebase\n' >> "$WORKTREE_ROOT/hand-landing-queued/file.txt"
restamp_exit hand-landing-queued
jq -n --arg wt "$WORKTREE_ROOT/hand-landing-queued" '{ticket:"00000000000000009006",owner:"hand-landing-queued",worktree:$wt,report:"x",state:"running"}' \
  > "$AGENT_HOME/land-queue/requests/00000000000000009006.json"

# ---- 4c. a post-land metadata fix-forward resumes the exited landing owner.
metadata_ticket=00000000000000009007
exited_hand hand-metadata-fix-forward "STATUS: BLOCKED-ON lesson-metadata-fix-forward $metadata_ticket"
jq -n --arg ticket "$metadata_ticket" '{ticket:$ticket,owner:"hand-metadata-fix-forward",state:"landed",lesson_metadata_fix_forward:{sha:"0123456789abcdef0123456789abcdef01234567",fields:"candidate=V488; recurrence_difference missing",state:"queued",owner_queued:true}}' \
  > "$AGENT_HOME/land-queue/requests/$metadata_ticket.json"

run_handoff
assert_no_ownerless 'first tick'
[ "$(count "$CALLS" $'^hand-landing\t')" = 1 ] || fail '1: failed landing resumes its exited owner'
grep -F $'hand-landing\t' "$CALLS" | grep -Fq "RESUME: landing $landing_ticket failed: preflight red: lib.test.sh." \
  || { cat "$CALLS" >&2; fail '1: resume note names the failure'; }
grep -F $'hand-landing\t' "$CALLS" | grep -Fq "Log: $AGENT_HOME/land-queue/logs/$landing_ticket.log" \
  || fail '1: resume note names the landing log'
grep -F $'hand-landing\t' "$CALLS" | grep -Fq \
  'Also fix post-land metadata at 0123456789abcdef0123456789abcdef01234567: candidate=V488; recurrence_difference missing. Compare every named recurrence candidate' \
  || fail '1: failed landing resume keeps its metadata fix-forward and comparison instructions'
grep -F $'hand-landing\t' "$CALLS" | grep -Fq "$WORKTREE_ROOT/hand-landing" || fail '1: resumed in its own worktree'
[ "$(count "$CALLS" $'^hand-uncommitted\t')" = 1 ] || fail '2: uncommitted exit resumes its owner'
grep -F $'hand-uncommitted\t' "$CALLS" | grep -Fq 'commit what belongs to the fix' || fail '2: resume note says commit and re-land'
[ "$(count "$CALLS" $'^hand-landing-queued\t')" = 0 ] || fail '3: a running landing owns its worktree'
[ "$(count "$CALLS" $'^hand-metadata-fix-forward\t')" = 1 ] || fail '4: post-land metadata finding resumes its exited owner once'
grep -F $'hand-metadata-fix-forward\t' "$CALLS" | grep -Fq \
  'Compare every named recurrence candidate and write the difference in recurrence_difference; do not append candidate IDs without comparison.' \
  || fail '4: metadata fix-forward resume requires real candidate comparison'
ok '1: failed landing resumes once with its landing log and metadata instructions'
ok '2: uncommitted exit resumes once with commit-and-re-land'
ok '3: a running landing owns its worktree'
ok '4: post-land metadata fix-forward resumes its owner with real-comparison instructions'

calls_before="$(wc -l < "$CALLS")"

# The resumed owners exit again without resolving the step (same report, same
# uncommitted tree): the supervisor gets one inbox line each, and nothing loops.
cleanup_spawned; : > "$SPAWNED"
for name in hand-landing hand-uncommitted hand-metadata-fix-forward; do
  for _ in 1 2 3 4 5 6 7 8 9 10; do
    hand_registry_entry_live "$(cat "$NIGHT/hand-registry/$name.json")" || break
    sleep 0.2
  done
done
run_handoff; run_handoff
assert_no_ownerless 'repeat exits'
[ "$(wc -l < "$CALLS")" = "$calls_before" ] || fail 'repeat exit on the same step is not resumed again'
[ "$(count "$AGENT_HOME/supervisor-inbox" 'hand-exit-handoff name=hand-landing ')" = 1 ] \
  && [ "$(count "$AGENT_HOME/supervisor-inbox" 'hand-exit-handoff name=hand-uncommitted ')" = 1 ] \
  && [ "$(count "$AGENT_HOME/supervisor-inbox" 'hand-exit-handoff name=hand-metadata-fix-forward ')" = 1 ] \
  || fail 'repeat exit escalates once per owner to the supervisor inbox'
ok 'repeat exit on the same unresolved step escalates once instead of looping'

